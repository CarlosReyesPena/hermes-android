/// Pins the production entry path that opens the new navigation shell.
///
/// `WorkspaceScreen` owns a chat route of its own, and that route only
/// resumes durable turns if it is handed the application-scoped
/// [GatewayTurnApplicationController]. The app's real launch path is
/// `HomeScreen` (the saved-connection list): tapping a connection pushes
/// `WorkspaceScreen` with the same controller the whole app was built with.
/// If `HomeScreen` ever drops that controller, every chat opened from the
/// shell silently loses turn recovery — a regression no `WorkspaceScreen`
/// test can catch, because the shell would still look correct in isolation.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/workspace_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/gateway_turn_application_controller.dart';
import 'package:hermes_android/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/inert_turn_application_session.dart';

class _MemoryCredentialStore implements CredentialStore {
  final Map<String, String> values = <String, String>{};
  final Map<String, String> _cache = <String, String>{};

  @override
  Future<void> delete(String key) async {
    values.remove(key);
    _cache.remove(key);
  }

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

  testWidgets('the workspace shell inherits the turn recovery owner', (
    tester,
  ) async {
    final controller = GatewayTurnApplicationController(
      sessionFactory: (_) => InertTurnApplicationSession(),
    );
    addTearDown(controller.close);

    final prefs = await SharedPreferences.getInstance();
    final manager = await ConnectionManager.create(
      prefs,
      credentialStore: _MemoryCredentialStore(),
    );
    await manager.saveConnection('Miniserver', 'host', 8642, 'key');

    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          connManager: manager,
          turnApplicationController: controller,
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Miniserver'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final workspace = tester.widget<WorkspaceScreen>(
      find.byType(WorkspaceScreen),
    );
    expect(workspace.turnApplicationController, same(controller));
  });
}
