import 'package:shared_preferences/shared_preferences.dart';

/// Stores whether the user has opted into the biometric app lock.
///
/// Non-secret by design: this only records a preference. The decision to
/// allow or deny a given unlock attempt is made by the OS biometric prompt,
/// never by this flag. Stored app-wide, not per connection, because the lock
/// guards the whole app surface (credentials and chats live across every
/// connection).
class BiometricLockStore {
  BiometricLockStore(this._preferences);

  static const String preferenceKey = 'biometric_lock_enabled';

  final SharedPreferences _preferences;

  bool get enabled => _preferences.getBool(preferenceKey) ?? false;

  Future<void> setEnabled(bool value) =>
      _preferences.setBool(preferenceKey, value);
}
