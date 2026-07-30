// WebSocket client for the Hermes gateway JSON-RPC API (/api/ws).
// Supports both request-response calls AND server-pushed streaming events.
//
// Wire protocol: newline-delimited JSON-RPC 2.0, same as the TUI gateway.
// After submitting a prompt, the server pushes stream events and finally
// a JSON-RPC response with the same id.
import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/io.dart';

/// A JSON-RPC error response from the gateway.
class JsonRpcError implements Exception {
  final String method;
  final String message;
  final int? code;

  JsonRpcError(this.method, this.message, {this.code});

  @override
  String toString() => 'JsonRpcError($method): $message';
}

/// Event types streamed from the gateway during a prompt submission.
class StreamEvent {
  final String type; // 'tool_call', 'tool_result', 'assistant', 'session', etc.
  final Map<String, dynamic> data;
  final bool isComplete; // true when the assistant message is done

  const StreamEvent({
    required this.type,
    required this.data,
    this.isComplete = false,
  });
}

/// Gateway-side file reference returned by `file.attach`.
class RemoteFileAttachment {
  final String name;
  final String path;
  final String refText;
  final bool uploaded;
  final bool? atlasIntakeAccepted;
  final String? atlasIntakeStatus;
  final String? atlasRelativePath;

  const RemoteFileAttachment({
    required this.name,
    required this.path,
    required this.refText,
    required this.uploaded,
    this.atlasIntakeAccepted,
    this.atlasIntakeStatus,
    this.atlasRelativePath,
  });
}

typedef StreamCallback = void Function(StreamEvent event);
typedef ConnectionCallback = void Function(bool connected);

/// WebSocket client for the Hermes JSON-RPC gateway.
class WsClient {
  final String baseUrl;
  final String? _token;
  final String? _ticket;
  IOWebSocketChannel? _channel;
  bool _connected = false;
  int _nextId = 1;

  /// Pending requests: id -> (completer, timer).
  final Map<int, _Pending> _pending = {};

  /// Active stream subscriptions: id -> callback.
  final Map<int, List<StreamCallback>> _streams = {};

  /// Gateway events are emitted independently of a JSON-RPC request ID. Keep
  /// per-session listeners so one active session cannot consume another one's
  /// streamed response.
  final Map<String, List<StreamCallback>> _sessionStreams = {};

  /// Global stream listener (receives all untargeted events).
  StreamCallback? onStreamEvent;
  ConnectionCallback? onConnectionChanged;

  factory WsClient(String baseUrl, {String? token, String? ticket}) {
    return WsClient._(baseUrl, token, ticket);
  }

  WsClient._(this.baseUrl, this._token, this._ticket);

  /// Connect to the WebSocket gateway.
  Future<void> connect() async {
    if (_connected) return;
    final wsUrl = buildWebSocketUrl(baseUrl, token: _token, ticket: _ticket);
    final channel = IOWebSocketChannel.connect(Uri.parse(wsUrl));
    _channel = channel;
    channel.stream.listen(
      _handleMessage,
      onError: (_) => _handleClosedConnection(),
      onDone: () {
        _handleClosedConnection();
      },
    );
    try {
      await channel.ready.timeout(const Duration(seconds: 15));
      _connected = true;
      onConnectionChanged?.call(true);
    } catch (_) {
      _handleClosedConnection();
      rethrow;
    }
  }

  void _handleClosedConnection() {
    final wasConnected = _connected || _channel != null;
    _connected = false;
    _channel = null;
    if (wasConnected) onConnectionChanged?.call(false);
    // Reject all pending request-response calls.
    for (var entry in _pending.values) {
      entry.timer?.cancel();
      if (!entry.completer.isCompleted) {
        entry.completer.completeError(Exception('Connection closed'));
      }
    }
    _pending.clear();

    // Prompt acknowledgements may already have arrived when the socket drops.
    // Notify their terminal-event listeners immediately instead of waiting for
    // the long turn timeout.
    final failure = StreamEvent(
      type: 'turn.error',
      data: const {'message': 'Desktop gateway connection closed'},
      isComplete: true,
    );
    for (final listeners in _sessionStreams.values) {
      for (final listener in List<StreamCallback>.from(listeners)) {
        listener(failure);
      }
    }
    _sessionStreams.clear();
  }

  /// Produces the gateway `/api/ws` URL. Secured Desktop gateways use a
  /// single-use ticket; insecure legacy gateways still use a session token.
  static String buildWebSocketUrl(
    String baseUrl, {
    String? token,
    String? ticket,
  }) {
    final socketBase = baseUrl
        .replaceFirst('http://', 'ws://')
        .replaceFirst('https://', 'wss://');
    final uri = Uri.parse('$socketBase/api/ws');
    final credential = ticket?.trim().isNotEmpty == true
        ? {'ticket': ticket!.trim()}
        : token?.trim().isNotEmpty == true
        ? {'token': token!.trim()}
        : const <String, String>{};
    return uri.replace(queryParameters: credential).toString();
  }

  /// Handle inbound messages.
  void _handleMessage(dynamic msg) {
    try {
      Map<String, dynamic> data;
      if (msg is String) {
        data = jsonDecode(msg) as Map<String, dynamic>;
      } else if (msg is Map<String, dynamic>) {
        data = msg;
      } else {
        return;
      }

      final id = data['id'];
      final method = data['method'] as String?;
      final params = data['params'];

      // Server-pushed events have the JSON-RPC method `event` and carry their
      // actual type/session/payload inside params.
      if (method == 'event' && id == null && params is Map<String, dynamic>) {
        final event = parseGatewayEvent(params);
        if (event != null) _dispatchEvent(event);
        return;
      }

      // Response to a request (has id, may have method for streaming completion)
      if (id != null) {
        final pending = _pending[id];
        if (pending != null) {
          // If this is a stream completion (method field present), also dispatch
          if (method != null && params != null) {
            _dispatchStreamEvent(
              id,
              method,
              params is Map<String, dynamic> ? params : {},
            );
          }
          _pending.remove(id);
          pending.timer?.cancel();
          pending.completer.complete(data);
          return;
        }
      }
    } catch (_) {
      // Ignore parse errors
    }
  }

  /// Dispatch a server-pushed event to registered listeners.
  static StreamEvent? parseGatewayEvent(Map<String, dynamic> params) {
    final type = params['type']?.toString();
    if (type == null || type.isEmpty) return null;
    final payload = params['payload'];
    final data = payload is Map<String, dynamic>
        ? Map<String, dynamic>.from(payload)
        : <String, dynamic>{};
    final sessionId =
        params['session_id']?.toString() ?? params['sid']?.toString();
    if (sessionId != null && sessionId.isNotEmpty) {
      data['session_id'] = sessionId;
    }
    return StreamEvent(
      type: type,
      data: data,
      isComplete:
          type == 'message.complete' ||
          type == 'error' ||
          type == 'turn.end' ||
          type == 'turn.error',
    );
  }

  void _dispatchEvent(StreamEvent event) {
    onStreamEvent?.call(event);
    final sessionId = event.data['session_id']?.toString();
    if (sessionId == null || sessionId.isEmpty) return;
    final listeners = _sessionStreams[sessionId];
    if (listeners == null) return;
    for (final listener in List<StreamCallback>.from(listeners)) {
      listener(event);
    }
  }

  /// Dispatch a streaming event to a specific request's subscribers.
  void _dispatchStreamEvent(int id, String type, Map<String, dynamic> data) {
    final listeners = _streams[id];
    if (listeners == null) return;
    final event = StreamEvent(
      type: type,
      data: data,
      isComplete: type == 'done' || type == 'error',
    );
    for (var listener in listeners) {
      listener(event);
    }
  }

  /// Send a JSON-RPC method call and wait for response.
  Future<Map<String, dynamic>> send(
    String method,
    Map<String, dynamic> params, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (!_connected || _channel == null) {
      throw Exception('Not connected');
    }

    final id = _nextId++;
    final completer = Completer<Map<String, dynamic>>();
    final timer = Timer(timeout, () {
      _pending.remove(id);
      if (!completer.isCompleted) {
        completer.completeError(JsonRpcError(method, 'Timeout'));
      }
    });

    _pending[id] = _Pending(completer, timer);
    _channel!.sink.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'method': method,
        'params': params,
        'id': id,
      }),
    );
    return completer.future;
  }

  /// Send a JSON-RPC method call and receive streaming events.
  /// Returns the final response when the stream completes.
  Future<Map<String, dynamic>> sendStreaming(
    String method,
    Map<String, dynamic> params, {
    StreamCallback? onEvent,
    Duration timeout = const Duration(seconds: 120),
  }) async {
    if (!_connected || _channel == null) {
      throw Exception('Not connected');
    }

    final id = _nextId++;
    if (onEvent != null) {
      _streams[id] = [onEvent];
    }
    final completer = Completer<Map<String, dynamic>>();
    final timer = Timer(timeout, () {
      _pending.remove(id);
      _streams.remove(id);
      if (!completer.isCompleted) {
        completer.completeError(JsonRpcError(method, 'Timeout'));
      }
    });

    _pending[id] = _Pending(completer, timer);
    _channel!.sink.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'method': method,
        'params': params,
        'id': id,
      }),
    );
    return completer.future;
  }

  /// Sends `prompt.submit`, then waits for the gateway's terminal turn event.
  /// The RPC acknowledgement only confirms that the turn was accepted; it is
  /// not the end of streamed model output.
  Future<void> submitPrompt(
    String message, {
    required String sessionId,
    required StreamCallback onEvent,
    Duration timeout = const Duration(minutes: 10),
  }) async {
    final completion = Completer<void>();
    late final StreamCallback listener;
    Timer? timer;

    listener = (event) {
      onEvent(event);
      if (!event.isComplete || completion.isCompleted) return;
      if (event.type == 'error' || event.type == 'turn.error') {
        completion.completeError(
          JsonRpcError(
            'prompt.submit',
            event.data['message']?.toString() ?? 'Gateway turn failed',
          ),
        );
      } else {
        completion.complete();
      }
    };

    final listeners = _sessionStreams.putIfAbsent(sessionId, () => []);
    listeners.add(listener);
    timer = Timer(timeout, () {
      if (!completion.isCompleted) {
        completion.completeError(JsonRpcError('prompt.submit', 'Timeout'));
      }
    });

    try {
      final response = await send('prompt.submit', {
        'session_id': sessionId,
        'text': message,
      });
      final error = response['error'];
      if (error is Map<String, dynamic>) {
        throw JsonRpcError(
          'prompt.submit',
          error['message']?.toString() ?? 'Unknown error',
          code: error['code'] as int?,
        );
      }
      await completion.future;
    } finally {
      timer.cancel();
      final current = _sessionStreams[sessionId];
      current?.remove(listener);
      if (current != null && current.isEmpty) {
        _sessionStreams.remove(sessionId);
      }
    }
  }

  /// Cooperatively interrupts the active turn for one gateway session.
  Future<void> interruptSession(String sessionId) async {
    final response = await send('session.interrupt', {'session_id': sessionId});
    final error = response['error'];
    if (error is Map<String, dynamic>) {
      throw JsonRpcError(
        'session.interrupt',
        error['message']?.toString() ?? 'Gateway interrupt failed',
        code: error['code'] as int?,
      );
    }
  }

  /// Resolves the single in-flight Hermes approval for one gateway session.
  Future<void> respondToApproval({
    required String sessionId,
    required String choice,
  }) async {
    const allowedChoices = {'once', 'session', 'always', 'deny'};
    if (!allowedChoices.contains(choice)) {
      throw ArgumentError.value(
        choice,
        'choice',
        'Unsupported approval choice',
      );
    }
    final response = await send('approval.respond', {
      'session_id': sessionId,
      'choice': choice,
    });
    final error = response['error'];
    if (error is Map<String, dynamic>) {
      throw JsonRpcError(
        'approval.respond',
        error['message']?.toString() ?? 'Gateway approval failed',
        code: error['code'] as int?,
      );
    }
  }

  Future<void> respondToSudo({
    required String requestId,
    required String password,
  }) {
    return _respondToSensitivePrompt(
      method: 'sudo.respond',
      requestId: requestId,
      valueKey: 'password',
      value: password,
    );
  }

  Future<void> respondToSecret({
    required String requestId,
    required String value,
  }) {
    return _respondToSensitivePrompt(
      method: 'secret.respond',
      requestId: requestId,
      valueKey: 'value',
      value: value,
    );
  }

  Future<void> respondToClarify({
    required String requestId,
    required String answer,
  }) async {
    if (requestId.trim().isEmpty) {
      throw ArgumentError.value(
        requestId,
        'requestId',
        'A Hermes request ID is required',
      );
    }
    final response = await send('clarify.respond', {
      'request_id': requestId,
      'answer': answer,
    });
    final error = response['error'];
    if (error is Map<String, dynamic>) {
      throw JsonRpcError(
        'clarify.respond',
        error['message']?.toString() ?? 'Gateway clarification failed',
        code: error['code'] as int?,
      );
    }
  }

  Future<void> _respondToSensitivePrompt({
    required String method,
    required String requestId,
    required String valueKey,
    required String value,
  }) async {
    if (requestId.trim().isEmpty) {
      throw ArgumentError.value(
        requestId,
        'requestId',
        'A Hermes request ID is required',
      );
    }
    final response = await send(method, {
      'request_id': requestId,
      valueKey: value,
    });
    final error = response['error'];
    if (error is Map<String, dynamic>) {
      throw JsonRpcError(
        method,
        error['message']?.toString() ?? 'Gateway response failed',
        code: error['code'] as int?,
      );
    }
  }

  /// Resume an existing session.
  Future<String> resumeSession(String sessionId) async {
    final result = await send('session.resume', {'session_id': sessionId});
    if (result['error'] != null) {
      final errMap = result['error'] as Map<String, dynamic>;
      final errorMsg = errMap['message'] as String?;
      throw JsonRpcError(
        'session.resume',
        errorMsg ?? 'Unknown error',
        code: errMap['code'] as int?,
      );
    }
    return result['result']?['session_id'] as String? ?? sessionId;
  }

  Future<void> setSessionTitle(String sessionId, String title) async {
    final response = await send('session.title', {
      'session_id': sessionId,
      'title': title,
    });
    final error = response['error'];
    if (error is Map<String, dynamic>) {
      throw JsonRpcError(
        'session.title',
        error['message']?.toString() ?? 'Could not rename session',
        code: error['code'] as int?,
      );
    }
  }

  Future<Map<String, dynamic>> branchSession(
    String sessionId, {
    required String name,
  }) async {
    final response = await send('session.branch', {
      'session_id': sessionId,
      'name': name,
    });
    final error = response['error'];
    if (error is Map<String, dynamic>) {
      throw JsonRpcError(
        'session.branch',
        error['message']?.toString() ?? 'Could not branch session',
        code: error['code'] as int?,
      );
    }
    final result = response['result'];
    if (result is Map<String, dynamic>) return result;
    throw JsonRpcError('session.branch', 'Gateway returned no branch');
  }

  /// Submit a message to the active session with streaming.
  /// Returns the final response and streams events via callback.
  Future<String> sendMessageStreaming(
    String message, {
    required String sessionId,
    StreamCallback? onEvent,
  }) async {
    await submitPrompt(
      message,
      sessionId: sessionId,
      onEvent: onEvent ?? (_) {},
    );
    return sessionId;
  }

  /// Submit a message to the active session (non-streaming, backward-compatible).
  Future<String> sendMessage(String message) async {
    throw UnsupportedError(
      'Use sendMessageStreaming with a gateway session ID instead.',
    );
  }

  /// Uploads one file or image to a remote Desktop gateway and returns the
  /// canonical `@file:` reference that must be included in the following turn.
  Future<RemoteFileAttachment> attachFile({
    required String sessionId,
    required String name,
    required String dataUrl,
    String path = '',
    String? sourceChannel,
    String? sourceProfile,
  }) async {
    final params = <String, dynamic>{
      'session_id': sessionId,
      'name': name,
      'path': path,
      'data_url': dataUrl,
    };
    if (sourceChannel?.isNotEmpty == true) {
      params['source_channel'] = sourceChannel;
    }
    if (sourceProfile?.isNotEmpty == true) {
      params['source_profile'] = sourceProfile;
    }
    final response = await send('file.attach', params);
    final error = response['error'];
    if (error is Map<String, dynamic>) {
      throw JsonRpcError(
        'file.attach',
        error['message']?.toString() ?? 'Unknown error',
        code: error['code'] as int?,
      );
    }
    final result = response['result'];
    if (result is! Map<String, dynamic> || result['attached'] != true) {
      throw JsonRpcError('file.attach', 'Gateway did not attach the file');
    }
    final refText = result['ref_text']?.toString() ?? '';
    if (refText.isEmpty) {
      throw JsonRpcError('file.attach', 'Gateway returned no file reference');
    }
    final atlasIntake = result['atlas_intake'];
    return RemoteFileAttachment(
      name: result['name']?.toString() ?? name,
      path: result['path']?.toString() ?? path,
      refText: refText,
      uploaded: result['uploaded'] == true,
      atlasIntakeAccepted: atlasIntake is Map<String, dynamic>
          ? atlasIntake['accepted'] == true
          : null,
      atlasIntakeStatus: atlasIntake is Map<String, dynamic>
          ? atlasIntake['status']?.toString()
          : null,
      atlasRelativePath: atlasIntake is Map<String, dynamic>
          ? atlasIntake['relative_path']?.toString()
          : null,
    );
  }

  /// Create a new chat session.
  Future<String> createSession({String? model}) async {
    final params = <String, dynamic>{};
    if (model != null) params['model'] = model;
    final result = await send('session.create', params);
    if (result['error'] != null) {
      final errMap = result['error'] as Map<String, dynamic>;
      final errorMsg = errMap['message'] as String?;
      throw JsonRpcError('session.create', errorMsg ?? 'Unknown error');
    }
    return result['result']?['session_id'] as String? ?? '';
  }

  /// Resume an existing session via session.create (which starts a new
  /// agent process for the given session ID). This works for sessions
  /// that exist in the REST API but aren't active in the gateway.
  Future<String> createOrResumeSession(String sessionId) async {
    final result = await send('session.create', {'session_id': sessionId});
    if (result['error'] != null) {
      final errMap = result['error'] as Map<String, dynamic>;
      final errorMsg = errMap['message'] as String?;
      throw JsonRpcError('session.create', errorMsg ?? 'Unknown error');
    }
    return result['result']?['session_id'] as String? ?? sessionId;
  }

  /// Applies a model only to one live gateway session.  Hermes interprets the
  /// `--session` flag as a persistent per-session override; it must never be
  /// replaced with a profile-wide config write from the mobile client.
  Future<void> setSessionModel({
    required String sessionId,
    required String provider,
    required String model,
  }) async {
    final result = await send('config.set', {
      'session_id': sessionId,
      'key': 'model',
      'value': buildSessionModelValue(provider: provider, model: model),
    });
    if (result['error'] != null) {
      final error = result['error'] as Map<String, dynamic>;
      throw JsonRpcError(
        'config.set',
        error['message']?.toString() ?? 'Model switch failed',
        code: error['code'] as int?,
      );
    }
    final payload = result['result'];
    if (payload is Map && payload['confirm_required'] == true) {
      throw JsonRpcError(
        'config.set',
        payload['confirm_message']?.toString() ??
            'This model needs confirmation before it can be selected.',
      );
    }
  }

  /// Returns the effective reasoning effort for one live gateway session.
  Future<String> getSessionReasoning(String sessionId) async {
    final response = await send('config.get', {
      'session_id': sessionId,
      'key': 'reasoning',
    });
    final error = response['error'];
    if (error is Map<String, dynamic>) {
      throw JsonRpcError(
        'config.get',
        error['message']?.toString() ?? 'Could not read reasoning effort',
        code: error['code'] as int?,
      );
    }
    final result = response['result'];
    if (result is! Map) {
      throw JsonRpcError('config.get', 'Gateway returned no reasoning effort');
    }
    return normalizeReasoningEffort(result['value']);
  }

  /// Applies reasoning effort only to one live gateway session.
  Future<void> setSessionReasoning({
    required String sessionId,
    required String effort,
  }) async {
    final normalized = effort.trim().toLowerCase();
    if (!validReasoningEfforts.contains(normalized)) {
      throw ArgumentError.value(
        effort,
        'effort',
        'Unsupported reasoning effort',
      );
    }
    final response = await send('config.set', {
      'session_id': sessionId,
      'key': 'reasoning',
      'value': normalized,
    });
    final error = response['error'];
    if (error is Map<String, dynamic>) {
      throw JsonRpcError(
        'config.set',
        error['message']?.toString() ?? 'Reasoning effort switch failed',
        code: error['code'] as int?,
      );
    }
  }

  static const validReasoningEfforts = <String>{
    'none',
    'minimal',
    'low',
    'medium',
    'high',
    'xhigh',
    'max',
    'ultra',
  };

  static String normalizeReasoningEffort(Object? value) {
    final normalized = value?.toString().trim().toLowerCase() ?? '';
    return validReasoningEfforts.contains(normalized) ? normalized : 'medium';
  }

  /// Builds the gateway `/model` value used for one live session.
  ///
  /// A bare `custom` provider represents the endpoint already stored in the
  /// profile's `model.base_url`; it is not a resolvable named provider before
  /// the deferred agent build finishes. Omitting the redundant provider flag
  /// lets Hermes resolve that endpoint from the active profile immediately.
  static String buildSessionModelValue({
    required String provider,
    required String model,
  }) {
    final normalizedProvider = provider.trim();
    final modelValue = model.trim();
    if (normalizedProvider.isEmpty || normalizedProvider == 'custom') {
      return '$modelValue --session';
    }
    return '$modelValue --provider $normalizedProvider --session';
  }

  bool get isConnected => _connected;

  /// Close the connection.
  void close() {
    for (var entry in _pending.values) {
      entry.timer?.cancel();
      if (!entry.completer.isCompleted) {
        entry.completer.completeError(Exception('Connection closed'));
      }
    }
    _pending.clear();
    _streams.clear();
    _sessionStreams.clear();
    final wasConnected = _connected || _channel != null;
    _connected = false;
    _channel?.sink.close();
    _channel = null;
    if (wasConnected) onConnectionChanged?.call(false);
  }
}

class _Pending {
  final Completer<Map<String, dynamic>> completer;
  final Timer? timer;
  _Pending(this.completer, this.timer);
}
