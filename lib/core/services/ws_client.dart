/// WebSocket client for the Hermes dashboard JSON-RPC gateway (/api/ws).
/// Provides session management (resume, list) and chat (send, stream).
///
/// Wire protocol: newline-delimited JSON-RPC 2.0, same as the TUI gateway.
import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
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

/// WebSocket client for the Hermes JSON-RPC gateway.
class WsClient {
  final String baseUrl;
  IOWebSocketChannel? _channel;
  int _nextId = 1;

  /// Pending requests: id -> (completer, timer).
  final Map<int, _Pending> _pending = {};

  WsClient(this.baseUrl);

  /// Connect to the WebSocket gateway.
  Future<void> connect() async {
    if (_channel != null && _channel!.sink.isActive) return;
    final wsUrl = baseUrl.replaceFirst('http://', 'ws://')
        .replaceFirst('https://', 'wss://') + '/api/ws';
    _channel = IOWebSocketChannel.connect(Uri.parse(wsUrl));
    _channel!.stream.listen(_handleMessage, onDone: () { _channel = null; });
  }

  /// Handle inbound messages.
  void _handleMessage(dynamic msg) {
    try {
      Map<String, dynamic> data;
      if (msg is String) {
        data = jsonDecode(msg) as Map<String, dynamic>;
      } else if (msg is Map) {
        data = msg;
      } else {
        return;
      }

      final id = data['id'];
      if (id != null) {
        final pending = _pending[id];
        if (pending != null) {
          _pending.remove(id);
          pending.timer?.cancel();
          pending.completer.complete(data);
          return;
        }
      }
    } catch (_) {
      // Ignore parse errors for event pass-through
    }
  }

  /// Send a JSON-RPC method call and wait for response.
  Future<Map<String, dynamic>> send(
    String method,
    Map<String, dynamic> params, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (_channel == null || !_channel!.sink.isActive) {
      throw Exception('Not connected');
    }

    final id = _nextId++;
    _channel!.sink.add(jsonEncode({
      'jsonrpc': '2.0',
      'method': method,
      'params': params,
      'id': id,
    }));

    final completer = Completer<Map<String, dynamic>>();
    final timer = Timer(timeout, () {
      _pending.remove(id);
      if (!completer.isCompleted) {
        completer.completeError(JsonRpcError(method, 'Timeout'));
      }
    });

    _pending[id] = _Pending(completer, timer);
    return completer.future;
  }

  /// Resume an existing session.
  Future<String> resumeSession(String sessionId) async {
    final result = await send('session.resume', {'session_id': sessionId});
    if (result['error'] != null) {
      throw JsonRpcError('session.resume', result['error']['message'] as String?);
    }
    return result['result']?['session_id'] as String? ?? sessionId;
  }

  /// Submit a message to the active session.
  Future<String> sendMessage(String message) async {
    final result = await send('prompt.submit', {'message': message});
    if (result['error'] != null) {
      throw JsonRpcError('prompt.submit', result['error']['message'] as String?);
    }
    return result['result']?['session_id'] as String? ?? '';
  }

  /// Close the connection.
  void close() {
    for (var entry in _pending.values) {
      entry.timer?.cancel();
      if (!entry.completer.isCompleted) {
        entry.completer.completeError(Exception('Connection closed'));
      }
    }
    _pending.clear();
    _channel?.sink.close();
    _channel = null;
  }
}

class _Pending {
  final Completer<Map<String, dynamic>> completer;
  final Timer? timer;
  _Pending(this.completer, this.timer);
}
