import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/biometric_authenticator.dart';
import 'package:hermes_android/core/services/biometric_lock_store.dart';
import 'package:hermes_android/core/widgets/biometric_settings_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeAuthenticator implements BiometricAuthenticator {
  _FakeAuthenticator({this.supported = true, this.enrolled = true});

  bool supported;
  bool enrolled;
  int capabilityChecks = 0;

  @override
  Future<BiometricCapabilities> capabilities() async {
    capabilityChecks++;
    return BiometricCapabilities(supported: supported, enrolled: enrolled);
  }

  @override
  Future<bool> authenticate() async => true;
}

Future<SharedPreferences> _prefs({bool enabled = false}) async {
  SharedPreferences.setMockInitialValues({
    if (enabled) BiometricLockStore.preferenceKey: true,
  });
  return SharedPreferences.getInstance();
}

Future<_FakeAuthenticator> _pump(
  WidgetTester tester, {
  bool enabled = false,
  bool supported = true,
  bool enrolled = true,
}) async {
  final prefs = await _prefs(enabled: enabled);
  final auth = _FakeAuthenticator(supported: supported, enrolled: enrolled);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: BiometricSettingsCard(preferences: prefs, authenticator: auth),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return auth;
}

void main() {
  group('BiometricSettingsCard', () {
    testWidgets('shows the current state from the store', (tester) async {
      await _pump(tester, enabled: false);
      expect(find.text('Biometric lock'), findsOneWidget);
      final tile = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
      expect(tile.value, isFalse);
    });

    testWidgets('reflects an enabled preference from the store', (
      tester,
    ) async {
      await _pump(tester, enabled: true);
      final onTile = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
      expect(onTile.value, isTrue);
    });

    testWidgets('enabling persists the preference when biometrics exist', (
      tester,
    ) async {
      final prefs = await _prefs(enabled: false);
      final auth = _FakeAuthenticator();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BiometricSettingsCard(
              preferences: prefs,
              authenticator: auth,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();

      expect(BiometricLockStore(prefs).enabled, isTrue);
      final tile = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
      expect(tile.value, isTrue);
    });

    testWidgets('disabling clears the preference', (tester) async {
      final prefs = await _prefs(enabled: true);
      final auth = _FakeAuthenticator();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BiometricSettingsCard(
              preferences: prefs,
              authenticator: auth,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();

      expect(BiometricLockStore(prefs).enabled, isFalse);
      final tile = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
      expect(tile.value, isFalse);
    });

    testWidgets('refuses to enable when nothing is enrolled on the device', (
      tester,
    ) async {
      final prefs = await _prefs(enabled: false);
      final auth = _FakeAuthenticator(supported: true, enrolled: false);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BiometricSettingsCard(
              preferences: prefs,
              authenticator: auth,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();

      expect(BiometricLockStore(prefs).enabled, isFalse);
      expect(
        find.textContaining('No fingerprint or face is enrolled'),
        findsOneWidget,
      );
    });

    testWidgets('refuses to enable on an unsupported device', (tester) async {
      final prefs = await _prefs(enabled: false);
      final auth = _FakeAuthenticator(supported: false, enrolled: false);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BiometricSettingsCard(
              preferences: prefs,
              authenticator: auth,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();

      expect(BiometricLockStore(prefs).enabled, isFalse);
      expect(
        find.textContaining('does not support biometric unlock'),
        findsOneWidget,
      );
    });
  });
}
