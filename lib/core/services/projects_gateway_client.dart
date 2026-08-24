import '../models/hermes_project.dart';
import 'ws_client.dart';

/// Sends one JSON-RPC method call and returns the raw envelope.
///
/// Kept as a function type so the Projects client can sit on top of any
/// transport (the live [WsClient], a recovery socket, or a test double)
/// without owning connection state.
typedef GatewayRpcCall =
    Future<Map<String, dynamic>> Function(
      String method,
      Map<String, dynamic> params,
    );

/// Thrown when the connected Hermes Gateway predates the `projects.*` RPC.
///
/// This is a compatibility signal, not a failure: the caller should fall back
/// to local-only organization rather than showing an error.
class ProjectsUnsupportedException implements Exception {
  final String method;
  final String message;

  const ProjectsUnsupportedException(this.method, this.message);

  @override
  String toString() => 'ProjectsUnsupportedException($method): $message';
}

/// Read/write access to the server-owned Hermes Projects.
///
/// Every call goes through the gateway, so Projects created here are the same
/// records Hermes Desktop and the CLI see. Unknown-method errors are converted
/// into [ProjectsUnsupportedException] and remembered, so an old gateway is
/// probed at most once instead of on every screen build.
class ProjectsGatewayClient {
  static const _unknownMethodCode = -32601;

  final GatewayRpcCall _call;
  bool? _supported;

  ProjectsGatewayClient(this._call);

  /// Whether the gateway exposes `projects.*`.
  ///
  /// Only a definitive answer is cached: transport failures rethrow and leave
  /// the verdict unknown so a later reconnect can still discover support.
  Future<bool> isSupported() async {
    final known = _supported;
    if (known != null) return known;
    try {
      await list();
      return true;
    } on ProjectsUnsupportedException {
      return false;
    }
  }

  /// The last known support verdict without contacting the gateway.
  bool? get cachedSupport => _supported;

  Future<ProjectsSnapshot> list() async {
    final result = await _request('projects.list', const {});
    return ProjectsSnapshot.fromJson(result);
  }

  Future<HermesProject> get(String id) async {
    final result = await _request('projects.get', {'id': _requireId(id)});
    return _requireProject('projects.get', result);
  }

  Future<HermesProject> create({
    required String name,
    String? slug,
    String? description,
    String? primaryPath,
    List<String> folders = const [],
    bool use = false,
  }) async {
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) {
      throw ArgumentError.value(name, 'name', 'A project name is required');
    }
    final params = <String, dynamic>{'name': trimmedName};
    if (slug != null && slug.trim().isNotEmpty) params['slug'] = slug.trim();
    if (description != null && description.trim().isNotEmpty) {
      params['description'] = description.trim();
    }
    if (primaryPath != null && primaryPath.trim().isNotEmpty) {
      params['primary_path'] = primaryPath.trim();
    }
    if (folders.isNotEmpty) params['folders'] = folders;
    if (use) params['use'] = true;

    final result = await _request('projects.create', params);
    return _requireProject('projects.create', result);
  }

  Future<HermesProject> rename({
    required String id,
    required String name,
  }) async {
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) {
      throw ArgumentError.value(name, 'name', 'A project name is required');
    }
    final result = await _request('projects.update', {
      'id': _requireId(id),
      'name': trimmedName,
    });
    return _requireProject('projects.update', result);
  }

  /// Archives a project, or restores it when [restore] is true.
  ///
  /// Archiving is deliberately preferred over deletion in the mobile flows:
  /// it is reversible and never destroys server-side history.
  Future<ProjectsSnapshot> archive(String id, {bool restore = false}) async {
    final params = <String, dynamic>{'id': _requireId(id)};
    if (restore) params['restore'] = true;
    final result = await _request('projects.archive', params);
    return ProjectsSnapshot.fromJson(result);
  }

  Future<ProjectsSnapshot> delete(String id) async {
    final result = await _request('projects.delete', {'id': _requireId(id)});
    return ProjectsSnapshot.fromJson(result);
  }

  /// Selects [id] as the gateway's active project, or clears it when null.
  Future<String?> setActive(String? id) async {
    final params = <String, dynamic>{};
    if (id != null && id.trim().isNotEmpty) params['id'] = id.trim();
    final result = await _request('projects.set_active', params);
    final activeId = result['active_id'];
    return activeId is String && activeId.trim().isNotEmpty
        ? activeId.trim()
        : null;
  }

  Future<Map<String, dynamic>> _request(
    String method,
    Map<String, dynamic> params,
  ) async {
    final response = await _call(method, params);
    final error = response['error'];
    if (error != null) {
      final rpcError = error is Map
          ? JsonRpcError.fromGateway(
              method,
              error,
              fallbackMessage: 'Gateway projects call failed',
            )
          : JsonRpcError(method, 'Gateway projects call failed');
      if (_isUnknownMethod(rpcError)) {
        _supported = false;
        throw ProjectsUnsupportedException(method, rpcError.message);
      }
      // A real projects error still proves the RPC family exists.
      _supported = true;
      throw rpcError;
    }
    _supported = true;
    final result = response['result'];
    return result is Map
        ? Map<String, dynamic>.from(result)
        : <String, dynamic>{};
  }

  static bool _isUnknownMethod(JsonRpcError error) {
    if (error.code == _unknownMethodCode) return true;
    final message = error.message.toLowerCase();
    return message.contains('unknown method') ||
        message.contains('method not found');
  }

  static String _requireId(String id) {
    final trimmed = id.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(id, 'id', 'A project id is required');
    }
    return trimmed;
  }

  static HermesProject _requireProject(
    String method,
    Map<String, dynamic> result,
  ) {
    final project = result['project'];
    if (project is! Map) {
      throw JsonRpcError(method, 'Gateway returned no project record');
    }
    return HermesProject.fromJson(Map<String, dynamic>.from(project));
  }
}
