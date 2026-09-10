/// Local Settings sections must survive a dashboard outage.
///
/// Regression pin for the P1 incoherence where the whole Settings screen was
/// replaced by "Failed to load settings" when the dashboard was unreachable —
/// which hid the purely local controls (biometric lock, text size, backup)
/// exactly when the network was the problem.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/settings_screen.dart';
import 'package:hermes_android/core/services/biometric_authenticator.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

class _NoBiometricsAuthenticator implements BiometricAuthenticator {
  @override
  Future<BiometricCapabilities> capabilities() async =>
      const BiometricCapabilities(supported: false, enrolled: false);

  @override
  Future<bool> authenticate() async => false;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('local Settings sections render when the dashboard is '
      'unreachable', (tester) async {
    tester.view.physicalSize = const Size(600, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final prefs = await SharedPreferences.getInstance();
    final manager = await ConnectionManager.create(
      prefs,
      credentialStore: _MemoryCredentialStore(),
    );
    await manager.saveConnection(
      'Broken',
      'dashboard-unreachable.invalid',
      9119,
      'key',
      dashboardUsername: 'user',
      dashboardPassword: 'pass',
    );

    await tester.pumpWidget(
      HermesApp(
        connManager: manager,
        biometricAuthenticator: _NoBiometricsAuthenticator(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final context = tester.element(find.byType(Navigator).first);
    final navigator = Navigator.of(context);
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsScreen(
          connection: manager.getConnections().single,
        ),
      ),
    );
    await tester.pump();
    // Give the dashboard call time to fail.
    await tester.pump(const Duration(milliseconds: 500));

    // The server-backed model section is unavailable, but the purely local
    // controls must still be reachable.
    expect(find.text('Model settings are unavailable'), findsOneWidget);
    expect(find.text('Appearance'), findsOneWidget);
    expect(find.text('Biometric lock'), findsOneWidget);
    expect(find.text('Backup & restore'), findsWidgets);
  });
}
