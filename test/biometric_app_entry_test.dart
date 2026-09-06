/// Integration pin: the biometric lock is wired at the real app boundary.
///
/// The lock lives in `MaterialApp.builder`, so a unit test of `BiometricLockGate`
/// alone cannot catch a wiring regression where HermesApp stops wrapping the
/// Navigator. This test pumps the real `HermesApp` with the lock enabled and
/// asserts the launch shows the lock, not the connection list.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/biometric_authenticator.dart';
import 'package:hermes_android/core/services/biometric_lock_store.dart';
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

class _LockAuthenticator implements BiometricAuthenticator {
  _LockAuthenticator({this.approve = true});

  bool approve;

  @override
  Future<BiometricCapabilities> capabilities() async =>
      const BiometricCapabilities(supported: true, enrolled: true);

  @override
  Future<bool> authenticate() async => approve;
}

Future<ConnectionManager> _manager(SharedPreferences prefs) {
  return ConnectionManager.create(
    prefs,
    credentialStore: _MemoryCredentialStore(),
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('HermesApp shows the biometric lock before the connection list '
      'when the lock is enabled', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    await BiometricLockStore(prefs).setEnabled(true);

    final manager = await _manager(prefs);
    await manager.saveConnection('Miniserver', 'host', 8642, 'key');

    await tester.pumpWidget(
      HermesApp(
        connManager: manager,
        biometricAuthenticator: _LockAuthenticator(approve: true),
      ),
    );
    // Bounded pumps: the connection list may start network work once the lock
    // lifts, and an unbounded pumpAndSettle would wait on it forever.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // Lock first: the connection list must not be reachable yet.
    expect(find.text('Hermes is locked'), findsOneWidget);
    expect(find.text('Miniserver').hitTestable(), findsNothing);
  });

  testWidgets('HermesApp unlocks into the connection list', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    await BiometricLockStore(prefs).setEnabled(true);

    final manager = await _manager(prefs);
    await manager.saveConnection('Miniserver', 'host', 8642, 'key');

    await tester.pumpWidget(
      HermesApp(
        connManager: manager,
        biometricAuthenticator: _LockAuthenticator(approve: true),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.text('Unlock'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Hermes is locked'), findsNothing);
    expect(find.text('Miniserver'), findsOneWidget);
  });

  testWidgets('HermesApp shows the connection list directly when the lock is '
      'disabled', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    final manager = await _manager(prefs);
    await manager.saveConnection('Miniserver', 'host', 8642, 'key');

    await tester.pumpWidget(
      HermesApp(
        connManager: manager,
        biometricAuthenticator: _LockAuthenticator(approve: true),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Hermes is locked'), findsNothing);
    expect(find.text('Miniserver'), findsOneWidget);
  });
}
