/// Read access to the server-owned Assets index (`assets.list`).
///
/// Assets live on the Desktop Gateway JSON-RPC transport, exactly like
/// Projects. Every call goes through the gateway, so an older gateway that
/// predates the index surfaces an [AssetsUnsupportedException] once and then
/// stays silent, letting the UI show a calm compatibility notice instead of
/// an error screen.
library;

import '../models/project_asset.dart';
import 'capability_registry.dart';
import 'projects_gateway_client.dart';
import 'ws_client.dart';

/// Thrown when the connected Hermes Gateway predates the `assets.*` RPC.
class AssetsUnsupportedException implements Exception {
  final String method;
  final String message;

  const AssetsUnsupportedException(this.method, this.message);

  @override
  String toString() => 'AssetsUnsupportedException($method): $message';
}

/// Read-only client for the `assets.list` method.
class AssetsGatewayClient {
  static const _unknownMethodCode = -32601;
  static const _method = 'assets.list';

  final GatewayRpcCall _call;
  final CapabilityRegistry? capabilities;
  bool _unsupported = false;

  AssetsGatewayClient(this._call, {this.capabilities});

  /// Lists assets, scoped to [projectId] when given, newest first.
  Future<AssetsView> list({String? projectId, int? limit}) async {
    final params = <String, dynamic>{};
    if (projectId != null && projectId.trim().isNotEmpty) {
      params['project_id'] = projectId.trim();
    }
    if (limit != null) params['limit'] = limit;

    final capabilities = this.capabilities;
    if (_unsupported ||
        (capabilities != null && capabilities.isUnsupported(_method))) {
      throw AssetsUnsupportedException(
        _method,
        'This gateway does not support $_method',
      );
    }

    final Map<String, dynamic> response;
    try {
      response = await _call(_method, params);
    } catch (error) {
      capabilities?.recordFailure(_method, error);
      rethrow;
    }

    final error = response['error'];
    if (error != null) {
      final rpcError = error is Map
          ? JsonRpcError.fromGateway(
              _method,
              error,
              fallbackMessage: 'Gateway assets call failed',
            )
          : JsonRpcError(_method, 'Gateway assets call failed');
      capabilities?.recordFailure(_method, rpcError);
      if (_isUnknownMethod(rpcError)) {
        _unsupported = true;
        throw AssetsUnsupportedException(_method, rpcError.message);
      }
      throw rpcError;
    }

    capabilities?.recordSuccess(_method);
    final result = response['result'];
    return AssetsView.fromJson(
      result is Map ? Map<String, dynamic>.from(result) : const {},
    );
  }

  static bool _isUnknownMethod(JsonRpcError error) {
    if (error.code == _unknownMethodCode) return true;
    final message = error.message.toLowerCase();
    return message.contains('unknown method') ||
        message.contains('method not found');
  }
}
