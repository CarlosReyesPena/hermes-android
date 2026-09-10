import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/gateway_turn_contract.dart';
import 'package:hermes_android/core/screens/workspace_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/gateway_turn_application_controller.dart';
import 'package:hermes_android/core/services/gateway_turn_journal.dart';
import 'package:hermes_android/core/services/gateway_turn_recovery.dart';
import 'package:hermes_android/core/services/turn_notification_router.dart';
import 'package:hermes_android/core/services/turn_notification_service.dart';
import 'package:hermes_android/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/inert_turn_application_session.dart';
import 'support/memory_turn_journal_store.dart';
import 'support/recording_turn_notification_sink.dart';

const _digest =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _mobile = '11111111-1111-4111-8111-111111111111';
const _client = '33333333-3333-4333-8333-333333333333';
final _baseMs = DateTime.now().millisecondsSinceEpoch;

class _MemoryCredentialStore implements CredentialStore {
  final Map<String, String> values = <String, String>{};
  final Map<String, String> _cache = <String, String>{};

  @override
  Future<void> delete(String key) async => values.remove(key);

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

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<ConnectionManager> managerWithConnection() async {
    final prefs = await SharedPreferences.getInstance();
    final manager = await ConnectionManager.create(
      prefs,
      credentialStore: _MemoryCredentialStore(),
    );
    await manager.saveConnection('Miniserver', 'host', 8642, 'key');
    return manager;
  }

  GatewayTurnJournal seededJournal(String connectionId) {
    final store = MemoryTurnJournalStore();
    final journal = GatewayTurnJournal(store: store);
    final binding = GatewayTurnJournalBinding(
      connectionId: connectionId,
      endpointDigest: _digest,
      localSessionId: 'local-session-1',
      mobileSessionId: _mobile,
      storedSessionId: 'server-session-1',
      bindingVersion: 1,
      updatedAtEpochMs: _baseMs,
    );
    journal.upsertBinding(binding);
    journal.upsert(
      GatewayTurnJournalEntry(
        bindingIdentity: binding.bindingIdentity,
        clientTurnId: _client,
        turnId: 'server-turn',
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
      ),
    );
    return journal;
  }

  GatewayTurnApplicationController controller() =>
      GatewayTurnApplicationController(
        sessionFactory: (_) => InertTurnApplicationSession(),
      );

  testWidgets('a warm-start tap routes to the exact chat', (tester) async {
    final manager = await managerWithConnection();
    final connectionId = manager.getConnections().single.id;
    final turnController = controller();
    addTearDown(turnController.close);

    final sink = RecordingTurnNotificationSink();
    final notifications = TurnNotificationService(sink: sink);
    await notifications.ensureInitialized();

    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          connManager: manager,
          turnApplicationController: turnController,
          turnNotifications: notifications,
          turnNotificationRouter: TurnNotificationRouter(
            journal: seededJournal(connectionId),
          ),
        ),
      ),
    );
    await tester.pump();

    // The platform delivers the tapped notification's payload.
    sink.fireTap('server-turn');
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    final workspace = tester.widget<WorkspaceScreen>(
      find.byType(WorkspaceScreen),
    );
    expect(workspace.connection.id, connectionId);
    expect(workspace.initialSessionId, 'server-session-1');
  });

  testWidgets('a cold-start launch payload routes to the exact chat', (
    tester,
  ) async {
    final manager = await managerWithConnection();
    final connectionId = manager.getConnections().single.id;
    final turnController = controller();
    addTearDown(turnController.close);

    final sink = RecordingTurnNotificationSink()..launchPayload = 'server-turn';
    final notifications = TurnNotificationService(sink: sink);
    await notifications.ensureInitialized();

    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          connManager: manager,
          turnApplicationController: turnController,
          turnNotifications: notifications,
          turnNotificationRouter: TurnNotificationRouter(
            journal: seededJournal(connectionId),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final workspace = tester.widget<WorkspaceScreen>(
      find.byType(WorkspaceScreen),
    );
    expect(workspace.connection.id, connectionId);
    expect(workspace.initialSessionId, 'server-session-1');
  });

  testWidgets('a tap with no connections is a safe no-op', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    final manager = await ConnectionManager.create(
      prefs,
      credentialStore: _MemoryCredentialStore(),
    );
    final turnController = controller();
    addTearDown(turnController.close);

    final sink = RecordingTurnNotificationSink();
    final notifications = TurnNotificationService(sink: sink);
    await notifications.ensureInitialized();

    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          connManager: manager,
          turnApplicationController: turnController,
          turnNotifications: notifications,
          turnNotificationRouter: TurnNotificationRouter(
            journal: GatewayTurnJournal(store: MemoryTurnJournalStore()),
          ),
        ),
      ),
    );
    await tester.pump();

    sink.fireTap('server-turn');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(WorkspaceScreen), findsNothing);
  });
}
