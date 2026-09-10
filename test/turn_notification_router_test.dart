import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/gateway_turn_contract.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/gateway_turn_journal.dart';
import 'package:hermes_android/core/services/gateway_turn_recovery.dart';
import 'package:hermes_android/core/services/turn_notification_router.dart';

import 'support/memory_turn_journal_store.dart';

const _digest =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _mobile = '11111111-1111-4111-8111-111111111111';
const _client = '33333333-3333-4333-8333-333333333333';
final _baseMs = DateTime.now().millisecondsSinceEpoch;

SavedConnection _connection(String id) =>
    SavedConnection(id: id, label: id, host: 'host', port: 8642, apiKey: 'key');

GatewayTurnJournalBinding _binding({
  String connectionId = 'conn-1',
  String storedSessionId = 'server-session-1',
}) => GatewayTurnJournalBinding(
  connectionId: connectionId,
  endpointDigest: _digest,
  localSessionId: 'local-session-1',
  mobileSessionId: _mobile,
  storedSessionId: storedSessionId,
  bindingVersion: 1,
  updatedAtEpochMs: _baseMs,
);

/// A completed-turn entry carrying [turnId], bound to [binding].
GatewayTurnJournalEntry _entry(
  GatewayTurnJournalBinding binding, {
  String turnId = 'server-turn',
}) => GatewayTurnJournalEntry(
  bindingIdentity: binding.bindingIdentity,
  clientTurnId: _client,
  turnId: turnId,
  status: GatewayRecoveryTurnStatus.completed,
  lastSeq: 4,
  eventPayloadBytes: 0,
  terminalEventRecorded: true,
  terminalResult: GatewayTurnTerminalResult(
    messageId: 'message-1',
    assistantText: 'Done.',
  ),
  ackUncertain: false,
  updatedAtEpochMs: _baseMs,
);

void main() {
  late MemoryTurnJournalStore store;
  late GatewayTurnJournal journal;
  late TurnNotificationRouter router;

  setUp(() {
    store = MemoryTurnJournalStore();
    journal = GatewayTurnJournal(store: store);
    router = TurnNotificationRouter(journal: journal);
  });

  test('resolves the exact chat from the journal binding', () async {
    final binding = _binding();
    await journal.upsertBinding(binding);
    await journal.upsert(_entry(binding));

    final route = await router.resolve(
      turnId: 'server-turn',
      connections: [_connection('conn-1')],
      lastConnectionId: null,
    );

    expect(route, isNotNull);
    expect(route!.connection.id, 'conn-1');
    expect(route.sessionId, 'server-session-1');
  });

  test(
    'falls back to the last-used connection when the journal has no entry',
    () async {
      final route = await router.resolve(
        turnId: 'unknown-turn',
        connections: [_connection('conn-1'), _connection('conn-2')],
        lastConnectionId: 'conn-2',
      );

      expect(route, isNotNull);
      expect(route!.connection.id, 'conn-2');
      expect(route.sessionId, isNull);
    },
  );

  test('falls back to the only connection with no last-used id', () async {
    final route = await router.resolve(
      turnId: 'unknown-turn',
      connections: [_connection('conn-only')],
      lastConnectionId: null,
    );

    expect(route, isNotNull);
    expect(route!.connection.id, 'conn-only');
    expect(route.sessionId, isNull);
  });

  test('resolves to null when there are no connections to open', () async {
    final binding = _binding();
    await journal.upsertBinding(binding);
    await journal.upsert(_entry(binding));

    final route = await router.resolve(
      turnId: 'server-turn',
      connections: const [],
      lastConnectionId: null,
    );

    expect(route, isNull);
  });

  test(
    'degrades to a no-op when the bound connection no longer exists',
    () async {
      final binding = _binding(connectionId: 'conn-gone');
      await journal.upsertBinding(binding);
      await journal.upsert(_entry(binding));

      // Two live connections but no last-used id: no fallback, no match.
      final route = await router.resolve(
        turnId: 'server-turn',
        connections: [_connection('conn-1'), _connection('conn-2')],
        lastConnectionId: null,
      );

      expect(route, isNull);
    },
  );

  test('falls back to last-used when the journal cannot be read', () async {
    store.unavailable = true;

    final route = await router.resolve(
      turnId: 'server-turn',
      connections: [_connection('conn-1')],
      lastConnectionId: 'conn-1',
    );

    expect(route, isNotNull);
    expect(route!.connection.id, 'conn-1');
    expect(route.sessionId, isNull);
  });
}
