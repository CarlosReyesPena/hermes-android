import 'connection_manager.dart';
import 'gateway_turn_journal.dart';

/// The chat a tapped turn notification should open.
///
/// [sessionId] is the server-owned session the completed turn belongs to.
/// When it is `null`, only the connection could be resolved (the recovery
/// journal had no entry for the tap), so the caller opens that connection's
/// workspace home instead of a specific chat.
class TurnNotificationRoute {
  final SavedConnection connection;
  final String? sessionId;

  const TurnNotificationRoute({required this.connection, this.sessionId});
}

/// Resolves a tapped turn-notification payload into the chat to open.
///
/// The notification payload is the turn id [TurnNotificationService] posted
/// when the turn completed. The durable recovery journal maps that turn id to
/// a session binding, and the binding names both the connection and the
/// stored session id. Resolving through the journal is therefore exact: the
/// tap opens the one chat whose turn finished, not merely the last connection.
///
/// A legacy REST connection never writes a journal binding, so its taps fall
/// back to the last-used connection (no session id). A tap with no connections
/// at all is a deliberate no-op: there is nowhere meaningful to navigate.
class TurnNotificationRouter {
  final GatewayTurnJournal _journal;

  TurnNotificationRouter({GatewayTurnJournal? journal})
    : _journal = journal ?? GatewayTurnJournal();

  /// Resolves [turnId] (the notification payload) to a route.
  ///
  /// [connections] is the live saved-connection list; [lastConnectionId] is
  /// the connection the app last navigated into. Resolution order: journal
  /// binding first (exact chat), then last-used connection (workspace home),
  /// then `null` (safe no-op).
  Future<TurnNotificationRoute?> resolve({
    required String turnId,
    required List<SavedConnection> connections,
    required String? lastConnectionId,
  }) async {
    final fromJournal = await _resolveFromJournal(turnId, connections);
    if (fromJournal != null) return fromJournal;

    final fallback = _lastUsedConnection(connections, lastConnectionId);
    if (fallback == null) return null;
    return TurnNotificationRoute(connection: fallback);
  }

  Future<TurnNotificationRoute?> _resolveFromJournal(
    String turnId,
    List<SavedConnection> connections,
  ) async {
    GatewayTurnJournalSnapshot snapshot;
    try {
      snapshot = await _journal.loadSnapshot();
    } catch (_) {
      // An unreadable journal (secure storage unavailable) degrades to the
      // last-used connection rather than failing the tap.
      return null;
    }

    final entry = snapshot.entries
        .where((candidate) => candidate.turnId == turnId)
        .firstOrNull;
    if (entry == null) return null;

    final binding = snapshot.bindings
        .where(
          (candidate) => candidate.bindingIdentity == entry.bindingIdentity,
        )
        .firstOrNull;
    if (binding == null) return null;

    final connection = connections
        .where((candidate) => candidate.id == binding.connectionId)
        .firstOrNull;
    if (connection == null) return null;

    return TurnNotificationRoute(
      connection: connection,
      sessionId: binding.storedSessionId,
    );
  }

  SavedConnection? _lastUsedConnection(
    List<SavedConnection> connections,
    String? lastConnectionId,
  ) {
    final preferred = connections
        .where((connection) => connection.id == lastConnectionId)
        .firstOrNull;
    return preferred ?? (connections.length == 1 ? connections.single : null);
  }
}
