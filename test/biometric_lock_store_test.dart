import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/biometric_lock_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BiometricLockStore', () {
    test('defaults to disabled when nothing has been stored', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      expect(BiometricLockStore(prefs).enabled, isFalse);
    });

    test('persists an enabled choice', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      await BiometricLockStore(prefs).setEnabled(true);

      expect(BiometricLockStore(prefs).enabled, isTrue);
    });

    test('persists a disabled choice (turning it off again)', () async {
      SharedPreferences.setMockInitialValues({
        BiometricLockStore.preferenceKey: true,
      });
      final prefs = await SharedPreferences.getInstance();

      await BiometricLockStore(prefs).setEnabled(false);

      expect(BiometricLockStore(prefs).enabled, isFalse);
    });

    test('survives a store reload', () async {
      SharedPreferences.setMockInitialValues({
        BiometricLockStore.preferenceKey: true,
      });
      final prefs = await SharedPreferences.getInstance();
      expect(BiometricLockStore(prefs).enabled, isTrue);
    });
  });
}
