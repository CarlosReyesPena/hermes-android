import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/ws_client.dart';

/// Case-insensitive request header lookup — package:http normalises header
/// names when sending, so tests should not assume a particular casing.
String? _header(http.BaseRequest request, String name) {
  final lower = name.toLowerCase();
  for (final entry in request.headers.entries) {
    if (entry.key.toLowerCase() == lower) return entry.value;
  }
  return null;
}

class _BlockingStreamingClient extends http.BaseClient {
  bool cancelled = false;
  late final StreamController<List<int>> controller =
      StreamController<List<int>>(onCancel: () => cancelled = true);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(controller.stream, 200);
  }

  @override
  void close() {
    if (!controller.isClosed) controller.close();
  }
}

class _MemoryCredentialStore implements CredentialStore {
  final Map<String, String> values = <String, String>{};
  final Map<String, String> _cache = <String, String>{};

  @override
  Future<void> delete(String key) async {
    values.remove(key);
    _cache.remove(key);
  }

  @override
  Future<String?> read(String key) async {
    final value = values[key];
    if (value == null) {
      _cache.remove(key);
    } else {
      _cache[key] = value;
    }
    return value;
  }

  @override
  String? readCached(String key) => _cache[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

enum _PromptDisconnectPoint {
  beforeAck,
  afterAckBeforeFirstDelta,
  midStreamAfterTwoDeltas,
}

Future<void> _expectFailClosedPromptDisconnect(
  _PromptDisconnectPoint point, {
  required int expectedDeltaCount,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final requests = <Map<String, dynamic>>[];
  final events = <StreamEvent>[];
  final socketClosed = Completer<void>();
  var connectionCount = 0;
  final socketSubscription = server.transform(WebSocketTransformer()).listen((
    socket,
  ) {
    connectionCount += 1;
    socket.listen(
      (raw) {
        final request = jsonDecode(raw as String) as Map<String, dynamic>;
        if (request['method'] != 'prompt.submit') return;
        requests.add(request);

        if (point == _PromptDisconnectPoint.beforeAck) {
          unawaited(
            socket.close(
              WebSocketStatus.goingAway,
              'fixture disconnect before ack',
            ),
          );
          return;
        }

        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': request['id'],
            'result': {'accepted': true},
          }),
        );
        if (point == _PromptDisconnectPoint.afterAckBeforeFirstDelta) {
          unawaited(
            socket.close(
              WebSocketStatus.goingAway,
              'fixture disconnect after ack',
            ),
          );
          return;
        }

        for (var index = 0; index < 2; index += 1) {
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'method': 'event',
              'params': {
                'type': 'message.delta',
                'sid': 'disconnect-session',
                'payload': {'text': 'delta-${index + 1}'},
              },
            }),
          );
        }
        unawaited(
          socket.close(
            WebSocketStatus.goingAway,
            'fixture disconnect mid-stream',
          ),
        );
      },
      onError: (Object error) {
        if (!socketClosed.isCompleted) socketClosed.completeError(error);
      },
      onDone: () {
        if (!socketClosed.isCompleted) socketClosed.complete();
      },
    );
  });
  final client = WsClient('http://127.0.0.1:${server.port}');

  try {
    await client.connect().timeout(const Duration(seconds: 5));
    Object? surfacedError;
    try {
      await client.submitPrompt(
        'Synthetic disconnect prompt',
        sessionId: 'disconnect-session',
        onEvent: events.add,
        timeout: const Duration(seconds: 5),
      );
    } catch (error) {
      surfacedError = error;
    }
    await socketClosed.future.timeout(const Duration(seconds: 5));

    expect(surfacedError, isA<Exception>());
    if (point == _PromptDisconnectPoint.beforeAck) {
      expect(surfacedError.toString(), 'Exception: Connection closed');
    } else {
      expect(surfacedError, isA<JsonRpcError>());
      expect(
        surfacedError.toString(),
        'JsonRpcError(prompt.submit): Desktop gateway connection closed',
      );
    }
    expect(connectionCount, 1);
    expect(requests, hasLength(1));
    expect(requests.single['params'], {
      'session_id': 'disconnect-session',
      'text': 'Synthetic disconnect prompt',
    });
    expect(
      events.where((event) => event.type == 'message.delta'),
      hasLength(expectedDeltaCount),
    );
    expect(events.where((event) => event.type == 'turn.end'), isEmpty);
    expect(events.where((event) => event.type == 'turn.error'), hasLength(1));
    expect(events.last.isComplete, isTrue);
  } finally {
    client.close();
    await socketSubscription.cancel();
    await server.close(force: true);
  }
}

void main() {
  group('SavedConnection', () {
    test('normalizes bare HTTP gateway hosts with fallback port', () {
      final normalized = SavedConnection.normalizeHostAndPort(
        '192.168.1.50',
        8642,
      );

      expect(normalized.host, '192.168.1.50');
      expect(normalized.port, 8642);
      expect(normalized.useHttps, isFalse);
    });

    test('normalizes HTTPS URLs without an explicit port to 443', () {
      final normalized = SavedConnection.normalizeHostAndPort(
        'https://hermes.example.com',
        8642,
      );

      expect(normalized.host, 'hermes.example.com');
      expect(normalized.port, 443);
      expect(normalized.useHttps, isTrue);
    });

    test('normalizes HTTPS URLs with a custom fallback port', () {
      final normalized = SavedConnection.normalizeHostAndPort(
        'https://hermes.example.com',
        8443,
      );

      expect(normalized.host, 'hermes.example.com');
      expect(normalized.port, 8443);
      expect(normalized.useHttps, isTrue);
    });

    test('serializes HTTPS flag and remains backward compatible', () {
      final conn = SavedConnection(
        id: '1',
        label: 'Remote',
        host: 'hermes.example.com',
        port: 443,
        apiKey: 'key',
        useHttps: true,
      );

      expect(SavedConnection.fromMap(conn.toMap()).useHttps, isTrue);
      expect(
        SavedConnection.fromMap({
          'id': '2',
          'label': 'Old',
          'host': '192.168.1.50',
          'port': 8642,
          'api_key': 'key',
        }).useHttps,
        isFalse,
      );
    });

    test('uses dashboard port 9119 for local gateway connections', () {
      final conn = SavedConnection(
        id: '1',
        label: 'Home',
        host: '192.168.1.50',
        port: 8642,
        apiKey: 'key',
      );

      expect(conn.dashboardPort, 9119);
      expect(
        DashboardClient(host: conn.host, port: conn.dashboardPort).baseUrl,
        'http://192.168.1.50:9119',
      );
    });

    test('uses the HTTPS proxy port for dashboard calls over HTTPS', () {
      final conn = SavedConnection(
        id: '1',
        label: 'Remote',
        host: 'hermes.example.com',
        port: 443,
        apiKey: 'key',
        useHttps: true,
      );

      expect(conn.dashboardPort, 443);
      expect(
        DashboardClient(
          host: conn.host,
          port: conn.dashboardPort,
          useHttps: conn.useHttps,
        ).baseUrl,
        'https://hermes.example.com:443',
      );
    });

    test('explicit dashboard port override wins over topology default', () {
      final local = SavedConnection(
        id: '1',
        label: 'Home',
        host: '192.168.1.50',
        port: 8642,
        apiKey: 'key',
        dashboardPortOverride: 30433,
      );
      expect(local.dashboardPort, 30433);

      final https = SavedConnection(
        id: '2',
        label: 'Remote',
        host: 'hermes.example.com',
        port: 443,
        apiKey: 'key',
        useHttps: true,
        dashboardPortOverride: 8443,
      );
      expect(https.dashboardPort, 8443);
    });

    test('serializes dashboard metadata without plaintext credentials', () {
      final conn = SavedConnection(
        id: '1',
        label: 'Home',
        host: '192.168.1.50',
        port: 8642,
        apiKey: 'key',
        dashboardPortOverride: 30433,
        dashboardUsername: 'misha',
        dashboardPassword: 'secret',
      );

      final map = conn.toMap();
      final restored = SavedConnection.fromMap(map);
      expect(map, isNot(contains('api_key')));
      expect(map, isNot(contains('dashboard_password')));
      expect(restored.dashboardPortOverride, 30433);
      expect(restored.dashboardUsername, 'misha');
      expect(restored.apiKey, isEmpty);
      expect(restored.dashboardPassword, isNull);
      expect(restored.dashboardPort, 30433);
    });

    test('fromMap is backward compatible with maps lacking dashboard keys', () {
      final restored = SavedConnection.fromMap({
        'id': '2',
        'label': 'Old',
        'host': '192.168.1.50',
        'port': 8642,
        'api_key': 'key',
      });
      expect(restored.dashboardPortOverride, isNull);
      expect(restored.dashboardUsername, isNull);
      expect(restored.dashboardPassword, isNull);
      expect(restored.dashboardPort, 9119);
    });

    test('fromMap normalises blank credentials to null', () {
      final restored = SavedConnection.fromMap({
        'id': '3',
        'label': 'Blank',
        'host': '192.168.1.50',
        'port': 8642,
        'api_key': 'key',
        'dashboard_username': '   ',
        'dashboard_password': '',
      });
      expect(restored.dashboardUsername, isNull);
      expect(restored.dashboardPassword, isNull);
    });

    test('copyWith preserves unset fields and clears via flags', () {
      final conn = SavedConnection(
        id: '1',
        label: 'Home',
        host: '192.168.1.50',
        port: 8642,
        apiKey: 'key',
        gatewayPrefix: '/profile/peter',
        dashboardPrefix: '/dashboard',
        dashboardProxied: true,
        dashboardPortOverride: 30433,
        dashboardUsername: 'misha',
        dashboardPassword: 'secret',
      );

      final keyOnly = conn.copyWith(apiKey: 'new-key');
      expect(keyOnly.apiKey, 'new-key');
      expect(keyOnly.gatewayPrefix, '/profile/peter');
      expect(keyOnly.dashboardPrefix, '/dashboard');
      expect(keyOnly.dashboardProxied, isTrue);
      expect(keyOnly.dashboardPortOverride, 30433);
      expect(keyOnly.dashboardUsername, 'misha');
      expect(keyOnly.dashboardPassword, 'secret');

      final cleared = conn.copyWith(
        clearGatewayPrefix: true,
        clearDashboardPrefix: true,
        clearDashboardPort: true,
        clearDashboardUsername: true,
        clearDashboardPassword: true,
      );
      expect(cleared.gatewayPrefix, isNull);
      expect(cleared.dashboardPrefix, isNull);
      expect(cleared.dashboardProxied, isTrue);
      expect(cleared.dashboardPortOverride, isNull);
      expect(cleared.dashboardUsername, isNull);
      expect(cleared.dashboardPassword, isNull);
      // Identity and unrelated fields are retained.
      expect(cleared.id, '1');
      expect(cleared.apiKey, 'key');
    });
  });

  group('ApiClient', () {
    test('healthCheck verifies an authenticated endpoint', () async {
      final client = ApiClient(
        baseUrl: 'http://hermes.local:8642',
        apiKey: 'valid-key',
        httpClient: MockClient((request) async {
          expect(request.headers['authorization'], 'Bearer valid-key');
          if (request.url.path == '/health') {
            return http.Response('{}', 200);
          }
          if (request.url.path == '/api/sessions') {
            return http.Response('{"object":"list","data":[]}', 200);
          }
          return http.Response('not found', 404);
        }),
      );

      expect(await client.healthCheck(), isTrue);
      client.close();
    });

    test('healthCheck rejects invalid API keys', () async {
      final client = ApiClient(
        baseUrl: 'http://hermes.local:8642',
        apiKey: 'bad-key',
        httpClient: MockClient((request) async {
          if (request.url.path == '/health') {
            return http.Response('{}', 200);
          }
          if (request.url.path == '/api/sessions') {
            return http.Response('unauthorized', 401);
          }
          return http.Response('not found', 404);
        }),
      );

      expect(await client.healthCheck(), isFalse);
      client.close();
    });

    test('deleteSession deletes a remote Hermes session', () async {
      final client = ApiClient(
        baseUrl: 'http://hermes.local:8642',
        apiKey: 'valid-key',
        httpClient: MockClient((request) async {
          expect(request.method, 'DELETE');
          expect(request.url.path, '/api/sessions/mob-123');
          expect(request.headers['authorization'], 'Bearer valid-key');
          return http.Response('{"object":"hermes.session.deleted"}', 200);
        }),
      );

      await client.deleteSession('mob-123');
      client.close();
    });

    test('deleteSession treats already-missing sessions as synced', () async {
      final client = ApiClient(
        baseUrl: 'http://hermes.local:8642',
        apiKey: 'valid-key',
        httpClient: MockClient((request) async {
          expect(request.method, 'DELETE');
          expect(request.url.path, '/api/sessions/mob-absent');
          return http.Response('not found', 404);
        }),
      );

      await client.deleteSession('mob-absent');
      client.close();
    });
  });

  group('GatewayChatClient', () {
    test('appends latest user message to existing history exactly once', () {
      final messages = GatewayChatClient.buildChatCompletionMessages(
        message: 'new question',
        history: [
          {'role': 'user', 'content': 'old question'},
          {'role': 'assistant', 'content': 'old answer'},
        ],
      );

      expect(messages, [
        {'role': 'user', 'content': 'old question'},
        {'role': 'assistant', 'content': 'old answer'},
        {'role': 'user', 'content': 'new question'},
      ]);
    });

    test(
      'does not duplicate latest user message already present in history',
      () {
        final messages = GatewayChatClient.buildChatCompletionMessages(
          message: 'new question',
          history: [
            {'role': 'user', 'content': 'old question'},
            {'role': 'assistant', 'content': 'old answer'},
            {'role': 'user', 'content': 'new question'},
          ],
        );

        expect(
          messages.where((m) => m['content'] == 'new question'),
          hasLength(1),
        );
        expect(messages.last, {'role': 'user', 'content': 'new question'});
      },
    );

    test('builds an OpenAI image_url content part for an attached image', () {
      const dataUrl = 'data:image/jpeg;base64,aGVybWVz';

      final messages = GatewayChatClient.buildChatCompletionMessages(
        message: 'What is in this image?',
        imageDataUrl: dataUrl,
      );

      expect(messages, [
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'What is in this image?'},
            {
              'type': 'image_url',
              'image_url': {'url': dataUrl},
            },
          ],
        },
      ]);
    });

    test('preserves multimodal history when sending a later message', () {
      final previousImageMessage = {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': 'Earlier image'},
          {
            'type': 'image_url',
            'image_url': {'url': 'data:image/png;base64,cHJldmlvdXM='},
          },
        ],
      };

      final messages = GatewayChatClient.buildChatCompletionMessages(
        message: 'Describe it further.',
        history: [previousImageMessage],
      );

      expect(messages.first, previousImageMessage);
      expect(messages.last, {
        'role': 'user',
        'content': 'Describe it further.',
      });
    });

    test('parses normal chat completion SSE token frames', () {
      final token = GatewayChatClient.parseSseFrame(
        'data: {"choices":[{"delta":{"content":"hello"}}]}',
      );

      expect(token, 'hello');
    });

    test('parses Hermes tool progress SSE frames via callback', () {
      Map<String, dynamic>? progress;
      final token = GatewayChatClient.parseSseFrame(
        'event: hermes.tool.progress\n'
        'data: {"tool":"read_file","toolCallId":"call_1","status":"running"}',
        onToolProgress: (p) => progress = p,
      );

      expect(token, isNull);
      expect(progress, isNotNull);
      expect(progress!['tool'], 'read_file');
      expect(progress!['toolCallId'], 'call_1');
      expect(progress!['status'], 'running');
    });

    test(
      'cancels the active SSE request without reporting completion',
      () async {
        final transport = _BlockingStreamingClient();
        final api = ApiClient(
          baseUrl: 'http://hermes.local:8642',
          apiKey: 'valid-key',
          httpClient: transport,
        );
        final gateway = GatewayChatClient(api);
        final firstToken = Completer<void>();
        var done = false;
        String? error;

        final sending = gateway.sendMessageStreaming(
          message: 'slow response',
          sessionId: 'mob-stop-test',
          onToken: (token) {
            if (!firstToken.isCompleted) firstToken.complete();
          },
          onDone: () => done = true,
          onError: (value) => error = value,
        );
        transport.controller.add(
          utf8.encode(
            'data: {"choices":[{"delta":{"content":"partial"}}]}\n\n',
          ),
        );
        await firstToken.future;

        expect(await gateway.cancelActiveMessage(), isTrue);
        await sending;

        expect(transport.cancelled, isTrue);
        expect(done, isFalse);
        expect(error, isNull);
        api.close();
      },
    );
  });

  group('DashboardClient', () {
    test('wraps cron job updates for dashboard endpoint', () {
      final updates = {'name': 'Daily', 'no_agent': true};

      expect(DashboardClient.buildCronUpdateBody(updates), {
        'updates': updates,
      });
    });

    test(
      'logs in and authenticates /api calls with the session cookie',
      () async {
        var loginCalls = 0;
        final client = DashboardClient(
          host: 'hermes.local',
          port: 30433,
          username: 'misha',
          password: 'secret',
          httpClient: MockClient((request) async {
            if (request.url.path == '/auth/password-login') {
              loginCalls++;
              expect(request.method, 'POST');
              expect(jsonDecode(request.body), {
                'provider': 'basic',
                'username': 'misha',
                'password': 'secret',
              });
              return http.Response(
                '{"ok":true}',
                200,
                headers: {
                  'set-cookie':
                      'hermes_session_at=TOK123; Path=/; HttpOnly; SameSite=Lax',
                },
              );
            }
            if (request.url.path == '/api/model/info') {
              // Cookie auth, not the insecure token header.
              expect(_header(request, 'cookie'), 'hermes_session_at=TOK123');
              expect(_header(request, 'x-hermes-session-token'), isNull);
              return http.Response('{"model":"hermes-agent"}', 200);
            }
            return http.Response('not found', 404);
          }),
        );

        final info = await client.getModelInfo();
        expect(info['model'], 'hermes-agent');

        // A second call reuses the cached cookie (no re-login).
        await client.getModelInfo();
        expect(loginCalls, 1);
        client.close();
      },
    );

    test('falls back to homepage token scrape when no credentials', () async {
      final client = DashboardClient(
        host: 'hermes.local',
        port: 9119,
        httpClient: MockClient((request) async {
          if (request.url.path == '/') {
            return http.Response(
              '<script>window.__HERMES_SESSION_TOKEN__="SPA_TOK";</script>',
              200,
            );
          }
          if (request.url.path == '/api/model/info') {
            expect(_header(request, 'x-hermes-session-token'), 'SPA_TOK');
            expect(_header(request, 'cookie'), isNull);
            return http.Response('{"model":"hermes-agent"}', 200);
          }
          return http.Response('not found', 404);
        }),
      );

      final info = await client.getModelInfo();
      expect(info['model'], 'hermes-agent');
      client.close();
    });

    test('re-authenticates once on a 401 from an /api call', () async {
      var apiCalls = 0;
      var loginCalls = 0;
      final client = DashboardClient(
        host: 'hermes.local',
        port: 30433,
        username: 'misha',
        password: 'secret',
        httpClient: MockClient((request) async {
          if (request.url.path == '/auth/password-login') {
            loginCalls++;
            final cookie = 'hermes_session_at=TOK$loginCalls';
            return http.Response(
              '{"ok":true}',
              200,
              headers: {'set-cookie': '$cookie; Path=/'},
            );
          }
          if (request.url.path == '/api/model/info') {
            apiCalls++;
            // First attempt: stale cookie → 401. Retry: succeeds.
            if (apiCalls == 1) return http.Response('unauthorized', 401);
            expect(_header(request, 'cookie'), 'hermes_session_at=TOK2');
            return http.Response('{"model":"hermes-agent"}', 200);
          }
          return http.Response('not found', 404);
        }),
      );

      final info = await client.getModelInfo();
      expect(info['model'], 'hermes-agent');
      expect(apiCalls, 2);
      expect(loginCalls, 2);
      client.close();
    });

    test('surfaces invalid dashboard credentials', () async {
      final client = DashboardClient(
        host: 'hermes.local',
        port: 30433,
        username: 'misha',
        password: 'wrong',
        httpClient: MockClient((request) async {
          if (request.url.path == '/auth/password-login') {
            return http.Response('{"detail":"Invalid credentials"}', 401);
          }
          return http.Response('not found', 404);
        }),
      );

      expect(client.getModelInfo(), throwsA(isA<Exception>()));
      client.close();
    });

    test(
      'mints a WebSocket ticket with the dashboard session cookie',
      () async {
        final client = DashboardClient(
          host: 'desktop.hermes.local',
          port: 443,
          useHttps: true,
          username: 'misha',
          password: 'secret',
          httpClient: MockClient((request) async {
            if (request.url.path == '/auth/password-login') {
              return http.Response(
                '{"ok":true}',
                200,
                headers: {'set-cookie': 'hermes_session_at=TOK123; Path=/'},
              );
            }
            if (request.url.path == '/api/auth/ws-ticket') {
              expect(request.method, 'POST');
              expect(_header(request, 'cookie'), 'hermes_session_at=TOK123');
              return http.Response('{"ticket":"ONE_TIME_TICKET"}', 200);
            }
            return http.Response('not found', 404);
          }),
        );

        await expectLater(
          client.mintWebSocketTicket(),
          completion('ONE_TIME_TICKET'),
        );
        client.close();
      },
    );
  });

  group('ConnectionManager', () {
    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
    });

    test('saveConnection persists dashboard port and credentials', () async {
      final prefs = await SharedPreferences.getInstance();
      final mgr = await ConnectionManager.create(
        prefs,
        credentialStore: _MemoryCredentialStore(),
      );
      await mgr.saveConnection(
        'Home',
        '192.168.1.50',
        8642,
        'key',
        dashboardPort: 30433,
        dashboardUsername: 'misha',
        dashboardPassword: 'secret',
      );

      final conn = mgr.getConnections().single;
      expect(conn.dashboardPortOverride, 30433);
      expect(conn.dashboardUsername, 'misha');
      expect(conn.dashboardPassword, 'secret');
    });

    test('updateDashboardAuth sets then clears fields', () async {
      final prefs = await SharedPreferences.getInstance();
      final mgr = await ConnectionManager.create(
        prefs,
        credentialStore: _MemoryCredentialStore(),
      );
      await mgr.saveConnection('Home', '192.168.1.50', 8642, 'key');
      final id = mgr.getConnections().single.id;

      await mgr.updateDashboardAuth(
        id,
        gatewayPrefix: '/profile/peter',
        dashboardPrefix: '/dashboard',
        dashboardProxied: true,
        dashboardPort: 30433,
        username: 'misha',
        password: 'secret',
      );
      var conn = mgr.getConnections().single;
      expect(conn.gatewayPrefix, '/profile/peter');
      expect(conn.dashboardPrefix, '/dashboard');
      expect(conn.dashboardProxied, isTrue);
      expect(conn.dashboardPortOverride, 30433);
      expect(conn.dashboardUsername, 'misha');
      expect(conn.dashboardPassword, 'secret');

      // Blank values clear the corresponding fields.
      await mgr.updateDashboardAuth(
        id,
        gatewayPrefix: '',
        dashboardPrefix: '',
        dashboardProxied: false,
        username: '',
        password: '',
      );
      conn = mgr.getConnections().single;
      expect(conn.gatewayPrefix, isNull);
      expect(conn.dashboardPrefix, isNull);
      expect(conn.dashboardProxied, isFalse);
      expect(conn.dashboardPortOverride, isNull);
      expect(conn.dashboardUsername, isNull);
      expect(conn.dashboardPassword, isNull);
    });

    test('updateApiKey preserves dashboard credentials', () async {
      final prefs = await SharedPreferences.getInstance();
      final mgr = await ConnectionManager.create(
        prefs,
        credentialStore: _MemoryCredentialStore(),
      );
      await mgr.saveConnection(
        'Home',
        '192.168.1.50',
        8642,
        'key',
        dashboardPort: 30433,
        dashboardUsername: 'misha',
        dashboardPassword: 'secret',
      );
      final id = mgr.getConnections().single.id;

      await mgr.updateApiKey(id, 'new-key');
      final conn = mgr.getConnections().single;
      expect(conn.apiKey, 'new-key');
      expect(conn.dashboardPortOverride, 30433);
      expect(conn.dashboardUsername, 'misha');
      expect(conn.dashboardPassword, 'secret');
    });

    test(
      'updateConnection edits host, port, key, and clears optional fields',
      () async {
        final prefs = await SharedPreferences.getInstance();
        final mgr = await ConnectionManager.create(
          prefs,
          credentialStore: _MemoryCredentialStore(),
        );
        await mgr.saveConnection(
          'Home',
          '192.168.1.50',
          8642,
          'key',
          gatewayPrefix: '/old-gateway',
          dashboardPrefix: '/old-dashboard',
          dashboardProxied: true,
          dashboardPort: 30433,
          dashboardUsername: 'misha',
          dashboardPassword: 'secret',
        );
        final id = mgr.getConnections().single.id;

        await mgr.updateConnection(
          id,
          'Moved',
          'https://hermes.example.com',
          8642,
          'new-key',
          gatewayPrefix: '',
          dashboardPrefix: '',
          dashboardProxied: false,
          dashboardUsername: '',
          dashboardPassword: '',
        );

        final conn = mgr.getConnections().single;
        expect(conn.id, id);
        expect(conn.label, 'Moved');
        expect(conn.host, 'hermes.example.com');
        expect(conn.port, 443);
        expect(conn.useHttps, isTrue);
        expect(conn.apiKey, 'new-key');
        expect(conn.gatewayPrefix, isNull);
        expect(conn.dashboardPrefix, isNull);
        expect(conn.dashboardProxied, isFalse);
        expect(conn.dashboardPortOverride, isNull);
        expect(conn.dashboardUsername, isNull);
        expect(conn.dashboardPassword, isNull);
      },
    );
  });

  group('Path prefix support', () {
    test('joinBaseUrl without prefix returns baseUrl unchanged', () {
      expect(
        SavedConnection.joinBaseUrl('https://hermes.example.com:443', ''),
        'https://hermes.example.com:443',
      );
    });

    test('joinBaseUrl appends prefix between base and API path', () {
      expect(
        SavedConnection.joinBaseUrl(
          'https://hermes.example.com:443',
          '/profile/peter',
        ),
        'https://hermes.example.com:443/profile/peter',
      );
    });

    test('ApiClient pathPrefix is prepended to baseUrl', () {
      final client = ApiClient(
        baseUrl: 'https://hermes.example.com:443',
        apiKey: 'key',
        pathPrefix: '/profile/peter',
      );
      expect(client.baseUrl, 'https://hermes.example.com:443/profile/peter');
      client.close();
    });

    test('DashboardClient uses pathPrefix', () {
      final client = DashboardClient(
        host: 'hermes.example.com',
        port: 443,
        useHttps: true,
        pathPrefix: '/dashboard',
      );
      expect(client.baseUrl, 'https://hermes.example.com:443/dashboard');
      client.close();
    });

    test('DashboardClient proxied sends no auth headers', () async {
      final client = DashboardClient(
        host: 'hermes.example.com',
        port: 443,
        useHttps: true,
        pathPrefix: '/dashboard',
        proxied: true,
        httpClient: MockClient((request) async {
          expect(
            request.headers.containsKey('x-hermes-session-token'),
            isFalse,
          );
          expect(request.headers.containsKey('cookie'), isFalse);
          return http.Response('{"data": {}}', 200);
        }),
      );
      await client.apiGet('model/info');
      client.close();
    });

    test(
      'DashboardClient proxied ignores credentials, sends clean headers',
      () async {
        final client = DashboardClient(
          host: 'hermes.example.com',
          port: 443,
          useHttps: true,
          pathPrefix: '/dashboard',
          proxied: true,
          username: 'user',
          password: 'pass',
          httpClient: MockClient((request) async {
            expect(
              request.headers.containsKey('x-hermes-session-token'),
              isFalse,
            );
            expect(request.headers.containsKey('cookie'), isFalse);
            return http.Response('{"data": {}}', 200);
          }),
        );
        await client.apiGet('model/info');
        client.close();
      },
    );

    test('SavedConnection serializes gateway and dashboard prefixes', () {
      final conn = SavedConnection(
        id: '1',
        label: 'Proxy',
        host: 'hermes.example.com',
        port: 443,
        apiKey: 'key',
        useHttps: true,
        gatewayPrefix: '/profile/peter',
        dashboardPrefix: '/dashboard',
        dashboardProxied: true,
      );
      final map = conn.toMap();
      expect(map['gateway_prefix'], '/profile/peter');
      expect(map['dashboard_prefix'], '/dashboard');
      expect(map['dashboard_proxied'], true);
    });

    test('SavedConnection preserves an optional Desktop gateway URL', () {
      final conn = SavedConnection(
        id: '1',
        label: 'ATLAS',
        host: 'hermes-api.example.lan',
        port: 443,
        apiKey: 'key',
        useHttps: true,
        desktopGatewayUrl: 'https://hermes-desktop.example.lan',
      );

      final restored = SavedConnection.fromMap(conn.toMap());
      expect(restored.desktopGatewayUrl, 'https://hermes-desktop.example.lan');
    });
  });

  group('Desktop gateway WebSocket URL', () {
    test('uses a ticket for a secured Desktop gateway', () {
      expect(
        WsClient.buildWebSocketUrl(
          'https://hermes-desktop.example.lan',
          ticket: 'one time+ticket',
        ),
        'wss://hermes-desktop.example.lan/api/ws?ticket=one+time%2Bticket',
      );
    });

    test('keeps legacy token support for insecure gateways', () {
      expect(
        WsClient.buildWebSocketUrl('http://hermes.local:9119', token: 'spa'),
        'ws://hermes.local:9119/api/ws?token=spa',
      );
    });

    test('fails closed when the socket closes before prompt ACK', () async {
      await _expectFailClosedPromptDisconnect(
        _PromptDisconnectPoint.beforeAck,
        expectedDeltaCount: 0,
      );
    });

    test(
      'fails closed when the socket closes after ACK before first delta',
      () async {
        await _expectFailClosedPromptDisconnect(
          _PromptDisconnectPoint.afterAckBeforeFirstDelta,
          expectedDeltaCount: 0,
        );
      },
    );

    test(
      'fails closed after two deltas without reconnect or resubmit',
      () async {
        await _expectFailClosedPromptDisconnect(
          _PromptDisconnectPoint.midStreamAfterTwoDeltas,
          expectedDeltaCount: 2,
        );
      },
    );

    test('sends the official session.interrupt JSON-RPC method', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requestSeen = Completer<Map<String, dynamic>>();
      final socketSubscription = server
          .transform(WebSocketTransformer())
          .listen((socket) {
            socket.listen((raw) {
              final request = jsonDecode(raw as String) as Map<String, dynamic>;
              if (!requestSeen.isCompleted) requestSeen.complete(request);
              socket.add(
                jsonEncode({
                  'jsonrpc': '2.0',
                  'id': request['id'],
                  'result': {'status': 'interrupted'},
                }),
              );
            });
          });
      final client = WsClient('http://127.0.0.1:${server.port}');

      try {
        await client.connect();
        await client.interruptSession('gateway-session-123');
        final request = await requestSeen.future;

        expect(request['method'], 'session.interrupt');
        expect(request['params'], {'session_id': 'gateway-session-123'});
      } finally {
        client.close();
        await socketSubscription.cancel();
        await server.close(force: true);
      }
    });

    test('preserves mobile source_profile on generic file.attach', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requestSeen = Completer<Map<String, dynamic>>();
      final socketSubscription = server
          .transform(WebSocketTransformer())
          .listen((socket) {
            socket.listen((raw) {
              final request = jsonDecode(raw as String) as Map<String, dynamic>;
              if (!requestSeen.isCompleted) requestSeen.complete(request);
              socket.add(
                jsonEncode({
                  'jsonrpc': '2.0',
                  'id': request['id'],
                  'result': {
                    'attached': true,
                    'name': 'fixture.txt',
                    'ref_text': '@file:fixture.txt',
                  },
                }),
              );
            });
          });
      final client = WsClient('http://127.0.0.1:${server.port}');

      try {
        await client.connect();
        await client.attachFile(
          sessionId: 'gateway-session-123',
          name: 'fixture.txt',
          dataUrl: 'data:application/octet-stream;base64,ZmFrZQ==',
          sourceChannel: 'hermes_mobile',
          sourceProfile: 'pro',
        );
        final request = await requestSeen.future;

        expect(request['method'], 'file.attach');
        expect(request['params'], {
          'session_id': 'gateway-session-123',
          'name': 'fixture.txt',
          'path': '',
          'data_url': 'data:application/octet-stream;base64,ZmFrZQ==',
          'source_channel': 'hermes_mobile',
          'source_profile': 'pro',
        });
      } finally {
        client.close();
        await socketSubscription.cancel();
        await server.close(force: true);
      }
    });

    test('sends the official session.resume JSON-RPC method', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requestSeen = Completer<Map<String, dynamic>>();
      final socketSubscription = server
          .transform(WebSocketTransformer())
          .listen((socket) {
            socket.listen((raw) {
              final request = jsonDecode(raw as String) as Map<String, dynamic>;
              requestSeen.complete(request);
              socket.add(
                jsonEncode({
                  'jsonrpc': '2.0',
                  'id': request['id'],
                  'result': {'session_id': 'runtime-123'},
                }),
              );
            });
          });
      final client = WsClient('http://127.0.0.1:${server.port}');

      try {
        await client.connect();
        expect(await client.resumeSession('stored-123'), 'runtime-123');
        final request = await requestSeen.future;
        expect(request['method'], 'session.resume');
        expect(request['params'], {'session_id': 'stored-123'});
      } finally {
        client.close();
        await socketSubscription.cancel();
        await server.close(force: true);
      }
    });

    test('sends official session.title and session.branch frames', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = <Map<String, dynamic>>[];
      final socketSubscription = server
          .transform(WebSocketTransformer())
          .listen((socket) {
            socket.listen((raw) {
              final request = jsonDecode(raw as String) as Map<String, dynamic>;
              requests.add(request);
              socket.add(
                jsonEncode({
                  'jsonrpc': '2.0',
                  'id': request['id'],
                  'result': request['method'] == 'session.branch'
                      ? {'session_id': 'branch-runtime', 'title': 'Copy'}
                      : {'ok': true},
                }),
              );
            });
          });
      final client = WsClient('http://127.0.0.1:${server.port}');

      try {
        await client.connect();
        await client.setSessionTitle('runtime-123', 'Renamed');
        final branch = await client.branchSession('runtime-123', name: 'Copy');
        expect(branch['session_id'], 'branch-runtime');
        expect(requests[0]['method'], 'session.title');
        expect(requests[0]['params'], {
          'session_id': 'runtime-123',
          'title': 'Renamed',
        });
        expect(requests[1]['method'], 'session.branch');
        expect(requests[1]['params'], {
          'session_id': 'runtime-123',
          'name': 'Copy',
        });
      } finally {
        client.close();
        await socketSubscription.cancel();
        await server.close(force: true);
      }
    });

    test('reads and writes session-scoped reasoning effort', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = <Map<String, dynamic>>[];
      final socketSubscription = server
          .transform(WebSocketTransformer())
          .listen((socket) {
            socket.listen((raw) {
              final request = jsonDecode(raw as String) as Map<String, dynamic>;
              requests.add(request);
              socket.add(
                jsonEncode({
                  'jsonrpc': '2.0',
                  'id': request['id'],
                  'result': request['method'] == 'config.get'
                      ? {'key': 'reasoning', 'value': 'high'}
                      : {'key': 'reasoning', 'value': 'xhigh'},
                }),
              );
            });
          });
      final client = WsClient('http://127.0.0.1:${server.port}');

      try {
        await client.connect();
        expect(await client.getSessionReasoning('runtime-123'), 'high');
        await client.setSessionReasoning(
          sessionId: 'runtime-123',
          effort: 'xhigh',
        );

        expect(requests[0], {
          'jsonrpc': '2.0',
          'id': requests[0]['id'],
          'method': 'config.get',
          'params': {'session_id': 'runtime-123', 'key': 'reasoning'},
        });
        expect(requests[1], {
          'jsonrpc': '2.0',
          'id': requests[1]['id'],
          'method': 'config.set',
          'params': {
            'session_id': 'runtime-123',
            'key': 'reasoning',
            'value': 'xhigh',
          },
        });
      } finally {
        client.close();
        await socketSubscription.cancel();
        await server.close(force: true);
      }
    });

    test('rejects invalid reasoning effort before sending it', () async {
      final client = WsClient('http://127.0.0.1:1');

      expect(
        () => client.setSessionReasoning(
          sessionId: 'runtime-123',
          effort: 'impossible',
        ),
        throwsArgumentError,
      );
    });

    test('sends the official approval.respond JSON-RPC method', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requestSeen = Completer<Map<String, dynamic>>();
      final socketSubscription = server
          .transform(WebSocketTransformer())
          .listen((socket) {
            socket.listen((raw) {
              final request = jsonDecode(raw as String) as Map<String, dynamic>;
              if (!requestSeen.isCompleted) requestSeen.complete(request);
              socket.add(
                jsonEncode({
                  'jsonrpc': '2.0',
                  'id': request['id'],
                  'result': {'resolved': true},
                }),
              );
            });
          });
      final client = WsClient('http://127.0.0.1:${server.port}');

      try {
        await client.connect();
        await client.respondToApproval(
          sessionId: 'gateway-session-123',
          choice: 'session',
        );
        final request = await requestSeen.future;

        expect(request['method'], 'approval.respond');
        expect(request['params'], {
          'session_id': 'gateway-session-123',
          'choice': 'session',
        });
      } finally {
        client.close();
        await socketSubscription.cancel();
        await server.close(force: true);
      }
    });

    test('sends the official sudo.respond JSON-RPC method', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requestSeen = Completer<Map<String, dynamic>>();
      final socketSubscription = server
          .transform(WebSocketTransformer())
          .listen((socket) {
            socket.listen((raw) {
              final request = jsonDecode(raw as String) as Map<String, dynamic>;
              if (!requestSeen.isCompleted) requestSeen.complete(request);
              socket.add(
                jsonEncode({
                  'jsonrpc': '2.0',
                  'id': request['id'],
                  'result': {'status': 'ok'},
                }),
              );
            });
          });
      final client = WsClient('http://127.0.0.1:${server.port}');

      try {
        await client.connect();
        await client.respondToSudo(
          requestId: 'sudo-request-123',
          password: 'synthetic-password',
        );
        final request = await requestSeen.future;

        expect(request['method'], 'sudo.respond');
        expect(request['params'], {
          'request_id': 'sudo-request-123',
          'password': 'synthetic-password',
        });
      } finally {
        client.close();
        await socketSubscription.cancel();
        await server.close(force: true);
      }
    });

    test('sends the official secret.respond JSON-RPC method', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requestSeen = Completer<Map<String, dynamic>>();
      final socketSubscription = server
          .transform(WebSocketTransformer())
          .listen((socket) {
            socket.listen((raw) {
              final request = jsonDecode(raw as String) as Map<String, dynamic>;
              if (!requestSeen.isCompleted) requestSeen.complete(request);
              socket.add(
                jsonEncode({
                  'jsonrpc': '2.0',
                  'id': request['id'],
                  'result': {'status': 'ok'},
                }),
              );
            });
          });
      final client = WsClient('http://127.0.0.1:${server.port}');

      try {
        await client.connect();
        await client.respondToSecret(
          requestId: 'secret-request-123',
          value: 'synthetic-secret',
        );
        final request = await requestSeen.future;

        expect(request['method'], 'secret.respond');
        expect(request['params'], {
          'request_id': 'secret-request-123',
          'value': 'synthetic-secret',
        });
      } finally {
        client.close();
        await socketSubscription.cancel();
        await server.close(force: true);
      }
    });

    test('sends the official clarify.respond JSON-RPC method', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requestSeen = Completer<Map<String, dynamic>>();
      final socketSubscription = server
          .transform(WebSocketTransformer())
          .listen((socket) {
            socket.listen((raw) {
              final request = jsonDecode(raw as String) as Map<String, dynamic>;
              if (!requestSeen.isCompleted) requestSeen.complete(request);
              socket.add(
                jsonEncode({
                  'jsonrpc': '2.0',
                  'id': request['id'],
                  'result': {'status': 'expired'},
                }),
              );
            });
          });
      final client = WsClient('http://127.0.0.1:${server.port}');

      try {
        await client.connect();
        await client.respondToClarify(
          requestId: 'clarify-request-123',
          answer: 'Balanced',
        );
        final request = await requestSeen.future;

        expect(request['method'], 'clarify.respond');
        expect(request['params'], {
          'request_id': 'clarify-request-123',
          'answer': 'Balanced',
        });
      } finally {
        client.close();
        await socketSubscription.cancel();
        await server.close(force: true);
      }
    });

    test('rejects an invalid approval choice before sending it', () async {
      final client = WsClient('http://127.0.0.1:1');

      expect(
        () => client.respondToApproval(
          sessionId: 'gateway-session-123',
          choice: 'unsafe',
        ),
        throwsArgumentError,
      );
    });

    test('unwraps a gateway event into its session payload', () {
      final event = WsClient.parseGatewayEvent({
        'type': 'message.delta',
        'sid': 'session-123',
        'payload': {'text': 'Hello'},
      });

      expect(event, isNotNull);
      expect(event!.type, 'message.delta');
      expect(event.data, {'text': 'Hello', 'session_id': 'session-123'});
      expect(event.isComplete, isFalse);
    });

    test('unwraps the real gateway session_id event field', () {
      final event = WsClient.parseGatewayEvent({
        'type': 'message.delta',
        'session_id': 'gateway-session-123',
        'payload': {'text': 'Hello'},
      });

      expect(event, isNotNull);
      expect(event!.data, {
        'text': 'Hello',
        'session_id': 'gateway-session-123',
      });
    });

    test('marks a gateway turn error as terminal', () {
      final event = WsClient.parseGatewayEvent({
        'type': 'turn.error',
        'sid': 'session-123',
        'payload': {'message': 'failed'},
      });

      expect(event?.isComplete, isTrue);
    });

    test('marks the real gateway message.complete event as terminal', () {
      final event = WsClient.parseGatewayEvent({
        'type': 'message.complete',
        'sid': 'session-123',
        'payload': {'text': 'Done', 'status': 'complete'},
      });

      expect(event?.isComplete, isTrue);
    });

    test('marks the real gateway error event as terminal', () {
      final event = WsClient.parseGatewayEvent({
        'type': 'error',
        'sid': 'session-123',
        'payload': {'message': 'failed'},
      });

      expect(event?.isComplete, isTrue);
    });

    test('omits bare custom provider from an early session model switch', () {
      expect(
        WsClient.buildSessionModelValue(
          provider: 'custom',
          model: 'hermes-android-fixture',
        ),
        'hermes-android-fixture --session',
      );
      expect(
        WsClient.buildSessionModelValue(
          provider: 'anthropic',
          model: 'claude-sonnet-4.6',
        ),
        'claude-sonnet-4.6 --provider anthropic --session',
      );
    });
  });
}
