import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Persists a half-typed composer prompt per connection and chat so it
/// survives closing/reopening the chat and process death.
///
/// The encoded namespace avoids leaking gateway URLs into preference keys
/// while still preventing identical session IDs from colliding across
/// connections, matching [ChatModelOverrideStore].
///
/// Scope is a single composer text string. Attachment drafts are deliberately
/// NOT persisted here: they reference app-private temp files that the OS may
/// reclaim at any time, so restoring them after process death would point at
/// files that no longer exist. Making them durable would require copying
/// arbitrary media into app storage with no cheap, safe lifecycle — out of
/// scope for this store.
class ComposerDraftStore {
  static const _prefix = 'composer_draft';

  final SharedPreferences _preferences;

  ComposerDraftStore(this._preferences);

  static Future<ComposerDraftStore> open() async {
    return ComposerDraftStore(await SharedPreferences.getInstance());
  }

  /// The stored draft for a chat, or null when none was saved.
  String? read({required String connectionId, required String sessionId}) {
    final raw = _preferences.getString(_key(connectionId, sessionId));
    if (raw == null || raw.isEmpty) return null;
    return raw;
  }

  /// Saves [text] as the draft. A blank (whitespace-only) value clears the
  /// draft instead of persisting it, so an emptied composer never resurrects.
  Future<void> write({
    required String connectionId,
    required String sessionId,
    required String text,
  }) async {
    final key = _key(connectionId, sessionId);
    if (text.trim().isEmpty) {
      await _preferences.remove(key);
      return;
    }
    await _preferences.setString(key, text);
  }

  /// Removes the draft for a chat, e.g. after a successful send.
  Future<void> clear({
    required String connectionId,
    required String sessionId,
  }) async {
    await _preferences.remove(_key(connectionId, sessionId));
  }

  String _key(String connectionId, String sessionId) {
    final normalizedConnection = connectionId.trim();
    final normalizedSession = sessionId.trim();
    if (normalizedConnection.isEmpty) {
      throw ArgumentError.value(
        connectionId,
        'connectionId',
        'must not be blank',
      );
    }
    if (normalizedSession.isEmpty) {
      throw ArgumentError.value(sessionId, 'sessionId', 'must not be blank');
    }
    final namespace = base64Url
        .encode(utf8.encode('$normalizedConnection\u0000$normalizedSession'))
        .replaceAll('=', '');
    return '$_prefix.$namespace';
  }
}
