import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/biometric_authenticator.dart';
import 'package:hermes_android/core/services/biometric_lock_store.dart';
import 'package:hermes_android/core/widgets/biometric_lock_gate.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeAuthenticator implements BiometricAuthenticator {
  _FakeAuthenticator({
    this.supported = true,
    this.enrolled = true,
    this.result = true,
  });

  bool supported;
  bool enrolled;
  bool result;
  int authenticateCalls = 0;
  bool autoApprove = false;

  @override
  Future<BiometricCapabilities> capabilities() async =>
      BiometricCapabilities(supported: supported, enrolled: enrolled);

  @override
  Future<bool> authenticate() async {
    authenticateCalls++;
    if (autoApprove) return true;
    return result;
  }
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
  bool result = true,
}) async {
  final prefs = await _prefs(enabled: enabled);
  final auth = _FakeAuthenticator(
    supported: supported,
    enrolled: enrolled,
    result: result,
  );
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: BiometricLockGate(
          store: BiometricLockStore(prefs),
          authenticator: auth,
          child: const Text('SECRET HOME'),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return auth;
}

void main() {
  group('BiometricLockGate', () {
    testWidgets('shows the child immediately when the lock is disabled', (
      tester,
    ) async {
      await _pump(tester, enabled: false);

      expect(find.text('SECRET HOME'), findsOneWidget);
      expect(find.text('Hermes is locked'), findsNothing);
    });

    testWidgets('locks the child when the lock is enabled', (tester) async {
      await _pump(tester, enabled: true);

      expect(find.text('Hermes is locked'), findsOneWidget);
      expect(find.text('Unlock'), findsOneWidget);
      // The child stays mounted under the opaque overlay (so an open chat
      // survives a re-lock) but must not be reachable by the user.
      expect(find.text('SECRET HOME').hitTestable(), findsNothing);
    });

    testWidgets('does not offer unauthenticated disable when biometrics work', (
      tester,
    ) async {
      await _pump(tester, enabled: true, supported: true, enrolled: true);

      expect(find.text('Unlock'), findsOneWidget);
      expect(find.textContaining('Disable lock'), findsNothing);
      expect(find.text('SECRET HOME').hitTestable(), findsNothing);
    });

    testWidgets('reveals the child after a successful unlock', (tester) async {
      final auth = await _pump(tester, enabled: true, result: true);

      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();

      expect(auth.authenticateCalls, 1);
      expect(find.text('SECRET HOME'), findsOneWidget);
      expect(find.text('Hermes is locked'), findsNothing);
    });

    testWidgets('keeps the lock and shows an error on a failed unlock', (
      tester,
    ) async {
      await _pump(tester, enabled: true, result: false);

      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();

      expect(find.text('Authentication failed. Try again.'), findsOneWidget);
      expect(find.text('Hermes is locked'), findsOneWidget);
      expect(find.text('SECRET HOME'), findsNothing);
    });

    testWidgets('offers disable lock instead of a prompt when no biometrics '
        'are enrolled', (tester) async {
      await _pump(tester, enabled: true, supported: true, enrolled: false);

      expect(find.text('Hermes is locked'), findsOneWidget);
      expect(
        find.text('Biometrics are not set up on this device'),
        findsOneWidget,
      );
      expect(find.text('Unlock'), findsNothing);
      expect(find.textContaining('Disable lock'), findsOneWidget);
      expect(find.text('SECRET HOME'), findsNothing);
    });

    testWidgets('offers disable lock on an unsupported device', (tester) async {
      await _pump(tester, enabled: true, supported: false, enrolled: false);

      expect(find.textContaining('Disable lock'), findsOneWidget);
    });

    testWidgets('disable lock reveals the child and clears the preference', (
      tester,
    ) async {
      final prefs = await _prefs(enabled: true);
      final auth = _FakeAuthenticator(supported: false, enrolled: false);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BiometricLockGate(
              store: BiometricLockStore(prefs),
              authenticator: auth,
              child: const Text('SECRET HOME'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.textContaining('Disable lock'));
      await tester.pumpAndSettle();

      expect(find.text('SECRET HOME'), findsOneWidget);
      expect(BiometricLockStore(prefs).enabled, isFalse);
    });

    testWidgets('re-locks when the app returns from the background', (
      tester,
    ) async {
      await _pump(tester, enabled: true, result: true);

      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();
      expect(find.text('SECRET HOME'), findsOneWidget);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(find.text('Hermes is locked'), findsOneWidget);
      // The previously open child is preserved under the overlay.
      expect(find.text('SECRET HOME').hitTestable(), findsNothing);
    });

    testWidgets('locks on resume when the preference was enabled mid-session', (
      tester,
    ) async {
      final prefs = await _prefs(enabled: false);
      final auth = _FakeAuthenticator();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BiometricLockGate(
              store: BiometricLockStore(prefs),
              authenticator: auth,
              child: const Text('SECRET HOME'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('SECRET HOME'), findsOneWidget);

      // User enables the lock from Settings while the app is open, then the
      // app goes to the background and returns.
      await BiometricLockStore(prefs).setEnabled(true);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(find.text('Hermes is locked'), findsOneWidget);
      expect(find.text('SECRET HOME'), findsNothing);
    });

    testWidgets('does not re-lock after unlocking when never backgrounded', (
      tester,
    ) async {
      await _pump(tester, enabled: true, result: true);

      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();
      expect(find.text('SECRET HOME'), findsOneWidget);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      // inactive-only transitions (e.g. the OS prompt overlaying the app)
      // must not count as backgrounding, otherwise the prompt itself would
      // trigger a lock loop.
      expect(find.text('SECRET HOME'), findsOneWidget);
    });
  });
}
