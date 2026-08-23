import 'package:shared_preferences/shared_preferences.dart';

/// How the session list search bar resolves a query.
enum SessionSearchMode {
  /// Filter the already-loaded session list on the device. Matches titles,
  /// previews, and model names only — no network call, no message bodies.
  local,

  /// Ask the dashboard's `GET /api/sessions/search` endpoint, which runs an
  /// FTS5 full-text query across stored message content and returns snippets.
  server,
}

extension SessionSearchModeCodec on SessionSearchMode {
  String get storageValue => switch (this) {
    SessionSearchMode.local => 'local',
    SessionSearchMode.server => 'server',
  };

  static SessionSearchMode fromStorage(String? raw) {
    return switch (raw?.trim()) {
      'server' => SessionSearchMode.server,
      _ => SessionSearchMode.local,
    };
  }
}

/// Persists the search mode chosen for each connection.
///
/// Search preferences are stored per connection rather than globally: a user
/// may run an open dashboard on one host and a locked-down gateway with no
/// dashboard on another, and only the former can serve full-text search.
///
/// [SessionSearchMode.local] stays the default so an upgrade never changes
/// search behaviour until the user opts in.
class SessionSearchPreferences {
  static const _prefix = 'session_search';

  final SharedPreferences _preferences;

  SessionSearchPreferences(this._preferences);

  static Future<SessionSearchPreferences> open() async {
    return SessionSearchPreferences(await SharedPreferences.getInstance());
  }

  SessionSearchMode readMode({required String connectionIdentity}) {
    return SessionSearchModeCodec.fromStorage(
      _preferences.getString(_key(connectionIdentity, 'mode')),
    );
  }

  Future<void> saveMode({
    required String connectionIdentity,
    required SessionSearchMode mode,
  }) async {
    await _preferences.setString(
      _key(connectionIdentity, 'mode'),
      mode.storageValue,
    );
  }

  Future<void> clear({required String connectionIdentity}) async {
    await _preferences.remove(_key(connectionIdentity, 'mode'));
  }

  /// Namespaces keys by connection so identical hosts across profiles cannot
  /// collide, without writing gateway URLs into preference key names.
  static String _key(String connectionIdentity, String field) {
    final namespace = Uri.encodeComponent(connectionIdentity);
    return '$_prefix.$namespace.$field';
  }
}
