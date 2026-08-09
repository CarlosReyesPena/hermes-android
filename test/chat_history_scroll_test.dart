import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/utils/chat_history_scroll.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({'verbose_mode': false});
  });

  group('REST history', () {
    test('stays chronological and appends the current prompt exactly once', () {
      final history = buildRestChatHistory([
        {'role': 'user', 'content': 'oldest question'},
        {'role': 'assistant', 'content': 'middle answer'},
      ]);

      final requestMessages = GatewayChatClient.buildChatCompletionMessages(
        message: 'current question',
        history: history,
      );

      expect(requestMessages, [
        {'role': 'user', 'content': 'oldest question'},
        {'role': 'assistant', 'content': 'middle answer'},
        {'role': 'user', 'content': 'current question'},
      ]);
      expect(
        requestMessages.where(
          (message) => message['content'] == 'current question',
        ),
        hasLength(1),
      );
    });
  });

  group('saved scroll position identity', () {
    test('isolates two connection IDs that share one session ID', () {
      final first = ChatScrollPositionKey.fromConnection(
        connectionId: 'connection-a',
        fallbackConnectionIdentity: 'http://same-host',
        sessionId: 'shared-session',
      );
      final second = ChatScrollPositionKey.fromConnection(
        connectionId: 'connection-b',
        fallbackConnectionIdentity: 'http://same-host',
        sessionId: 'shared-session',
      );
      final positions = <ChatScrollPositionKey, double>{
        first: 120,
        second: 640,
      };

      expect(first, isNot(second));
      expect(positions[first], 120);
      expect(positions[second], 640);
    });
  });

  group('scroll coordinator', () {
    test('consumes the initial restore target exactly once', () {
      final coordinator = ChatScrollCoordinator();

      final first = coordinator.consumeInitialRestore(275);
      final second = coordinator.consumeInitialRestore(900);

      expect(first?.offset, 275);
      expect(first?.isBottom, isFalse);
      expect(second, isNull);
      expect(coordinator.initialRestoreConsumed, isTrue);
    });

    test('a user already at bottom follows streaming content', () {
      final coordinator = ChatScrollCoordinator();
      coordinator.beginStreaming(isNearBottom: true);

      final restDeltaTarget = coordinator.streamingContentChanged();
      final remoteDeltaTarget = coordinator.streamingContentChanged();

      expect(restDeltaTarget?.isBottom, isTrue);
      expect(remoteDeltaTarget?.isBottom, isTrue);
      expect(coordinator.endStreaming()?.isBottom, isTrue);
    });

    test('a user reading history is not moved by streaming content', () {
      final coordinator = ChatScrollCoordinator();
      coordinator.beginStreaming(isNearBottom: true);
      coordinator.updateFromUserScroll(isNearBottom: false);

      expect(coordinator.streamingContentChanged(), isNull);
      expect(coordinator.endStreaming(), isNull);
    });

    test('REST completion never replays the old restored position', () {
      final coordinator = ChatScrollCoordinator();
      final restored = coordinator.consumeInitialRestore(480);
      coordinator.beginStreaming(isNearBottom: false);

      final completionTarget = coordinator.endStreaming();

      expect(restored?.offset, 480);
      expect(completionTarget, isNull);
      expect(coordinator.consumeInitialRestore(480), isNull);
    });
  });

  group('ChatScreen integration', () {
    testWidgets(
      'composer stays overflow-free at font scale 200% on compact screens',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);

        for (final width in [320.0, 360.0]) {
          tester.view.physicalSize = Size(width, 640);
          await _pumpChat(
            tester,
            client: _ControlledChatHttpClient(const []),
            connectionId: 'compact-$width',
            sessionId: 'compact-$width',
            textScale: 2,
          );

          for (final label in const [
            'Add attachment',
            'Message',
            'Start voice input',
            'Spoken replies',
            'Send message',
          ]) {
            expect(find.bySemanticsLabel(label), findsOneWidget);
          }
          for (final tooltip in const [
            'Attach image or file',
            'Speak to Hermes',
            'Send',
          ]) {
            expect(tester.getSize(find.byTooltip(tooltip)), const Size(48, 48));
          }
          expect(tester.takeException(), isNull);
        }
      },
    );

    testWidgets('sends chronological REST history through the real screen', (
      tester,
    ) async {
      final initialMessages = [
        {'role': 'user', 'content': 'oldest question'},
        {'role': 'assistant', 'content': 'middle answer'},
      ];
      final client = _ControlledChatHttpClient(initialMessages);

      await _pumpChat(
        tester,
        client: client,
        connectionId: 'integration-history',
        sessionId: 'history-session',
      );
      await tester.enterText(find.byType(TextField), 'current question');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await client.postStarted.future;

      final request =
          jsonDecode(client.lastRequestBody!) as Map<String, dynamic>;
      expect(request['messages'], [
        {'role': 'user', 'content': 'oldest question'},
        {'role': 'assistant', 'content': 'middle answer'},
        {'role': 'user', 'content': 'current question'},
      ]);

      client.finish([
        ...initialMessages,
        {'role': 'user', 'content': 'current question'},
        {'role': 'assistant', 'content': 'final answer'},
      ]);
      await tester.pumpAndSettle();
    });

    testWidgets(
      'follows deltas at bottom, then preserves history reading through completion',
      (tester) async {
        final initialMessages = _longHistory();
        final client = _ControlledChatHttpClient(initialMessages);

        await _pumpChat(
          tester,
          client: client,
          connectionId: 'integration-stream-follow',
          sessionId: 'stream-session',
        );
        final controller = tester
            .widget<ListView>(find.byType(ListView))
            .controller!;
        expect(controller.position.pixels, controller.position.maxScrollExtent);

        await tester.enterText(find.byType(TextField), 'stream this');
        await tester.tap(find.byTooltip('Send'));
        await tester.pump();
        await client.postStarted.future;

        final firstDelta = List.filled(50, 'first delta line').join('\n');
        client.emitToken(firstDelta);
        await tester.pump();
        await tester.pump();
        expect(controller.position.pixels, controller.position.maxScrollExtent);

        await tester.drag(find.byType(ListView), const Offset(0, 700));
        await tester.pump();
        final historyPosition = controller.position.pixels;
        expect(
          historyPosition,
          lessThan(controller.position.maxScrollExtent - 200),
        );

        final secondDelta = List.filled(50, 'second delta line').join('\n');
        client.emitToken(secondDelta);
        await tester.pump();
        await tester.pump();
        expect(controller.position.pixels, closeTo(historyPosition, 0.01));

        client.finish([
          ...initialMessages,
          {'role': 'user', 'content': 'stream this'},
          {'role': 'assistant', 'content': '$firstDelta\n$secondDelta'},
        ]);
        await tester.pumpAndSettle();
        expect(controller.position.pixels, closeTo(historyPosition, 0.01));
      },
    );

    testWidgets(
      'restores once, then neither refresh nor REST completion restores again',
      (tester) async {
        final messages = _longHistory();
        final firstClient = _ControlledChatHttpClient(messages);

        await _pumpChat(
          tester,
          client: firstClient,
          connectionId: 'integration-one-shot',
          sessionId: 'restore-session',
        );
        final firstController = tester
            .widget<ListView>(find.byType(ListView))
            .controller!;
        firstController.jumpTo(320);
        await tester.pump();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();

        final reopenedClient = _ControlledChatHttpClient(messages);
        await _pumpChat(
          tester,
          client: reopenedClient,
          connectionId: 'integration-one-shot',
          sessionId: 'restore-session',
        );
        final reopenedController = tester
            .widget<ListView>(find.byType(ListView))
            .controller!;
        expect(reopenedController.position.pixels, closeTo(320, 0.01));

        reopenedController.jumpTo(80);
        await tester.pump();
        await tester.tap(find.byTooltip('Chat actions'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Refresh'));
        await tester.pumpAndSettle();

        expect(reopenedController.position.pixels, closeTo(80, 0.01));

        await tester.enterText(find.byType(TextField), 'stay in history');
        await tester.tap(find.byTooltip('Send'));
        await tester.pump();
        await reopenedClient.postStarted.future;
        reopenedClient.emitToken('short streamed answer');
        await tester.pump();
        await tester.pump();
        reopenedClient.finish([
          ...messages,
          {'role': 'user', 'content': 'stay in history'},
          {'role': 'assistant', 'content': 'short streamed answer'},
        ]);
        await tester.pumpAndSettle();

        expect(reopenedController.position.pixels, closeTo(80, 0.01));
        expect(reopenedController.position.pixels, isNot(closeTo(320, 0.01)));
      },
    );
  });
}

Future<void> _pumpChat(
  WidgetTester tester, {
  required _ControlledChatHttpClient client,
  required String connectionId,
  required String sessionId,
  double textScale = 1,
}) async {
  final apiClient = ApiClient(
    baseUrl: 'http://fixture.example',
    apiKey: 'synthetic-test-key',
    httpClient: client,
  );
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: ChatScreen(
        connection: SavedConnection(
          id: connectionId,
          label: 'Fixture',
          host: 'fixture.example',
          port: 8642,
          apiKey: 'synthetic-test-key',
        ),
        session: Session(
          id: sessionId,
          title: 'Fixture chat',
          model: 'fixture-model',
          source: 'test',
          messageCount: client.serverMessages.length,
          isActive: true,
          preview: '',
          startedAt: 1,
        ),
        testApiClient: apiClient,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

List<Map<String, dynamic>> _longHistory() {
  return [
    for (var index = 0; index < 24; index++)
      {
        'role': index.isEven ? 'user' : 'assistant',
        'content':
            'message $index\n${List.filled(5, 'history line').join('\n')}',
      },
  ];
}

class _ControlledChatHttpClient extends http.BaseClient {
  List<Map<String, dynamic>> serverMessages;
  final Completer<void> postStarted = Completer<void>();
  StreamController<List<int>>? _completionStream;
  String? lastRequestBody;

  _ControlledChatHttpClient(List<Map<String, dynamic>> messages)
    : serverMessages = List<Map<String, dynamic>>.from(messages);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.method == 'GET' && request.url.path.endsWith('/messages')) {
      return _jsonResponse({'data': serverMessages});
    }
    if (request.method == 'POST' &&
        request.url.path.endsWith('/v1/chat/completions')) {
      lastRequestBody = (request as http.Request).body;
      _completionStream = StreamController<List<int>>();
      if (!postStarted.isCompleted) postStarted.complete();
      return http.StreamedResponse(
        _completionStream!.stream,
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    }
    return _jsonResponse({'error': 'unexpected request'}, statusCode: 404);
  }

  void emitToken(String token) {
    _completionStream!.add(
      utf8.encode(
        'data: ${jsonEncode({
          'choices': [
            {
              'delta': {'content': token},
            },
          ],
        })}\n\n',
      ),
    );
  }

  void finish(List<Map<String, dynamic>> finalMessages) {
    serverMessages = List<Map<String, dynamic>>.from(finalMessages);
    _completionStream!
      ..add(utf8.encode('data: [DONE]\n\n'))
      ..close();
  }

  http.StreamedResponse _jsonResponse(Object body, {int statusCode = 200}) {
    return http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode(body))),
      statusCode,
      headers: {'content-type': 'application/json'},
    );
  }
}
