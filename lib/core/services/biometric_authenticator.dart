import 'package:local_auth/local_auth.dart';

/// Result of probing what the OS can offer for biometric unlock.
class BiometricCapabilities {
  const BiometricCapabilities({
    required this.supported,
    required this.enrolled,
  });

  /// The device has a biometric sensor the OS can prompt with.
  final bool supported;

  /// The user has enrolled at least one biometric (fingerprint/face).
  final bool enrolled;

  /// Whether a real unlock prompt can be shown.
  bool get canPrompt => supported && enrolled;
}

/// Thin seam over the OS biometric prompt so widget tests can substitute a
/// deterministic fake instead of driving the platform channel.
abstract class BiometricAuthenticator {
  /// Asks the OS whether this device can prompt for biometrics and whether
  /// the user has enrolled one. Never throws: any platform failure reports an
  /// unsupported device so the caller can degrade gracefully.
  Future<BiometricCapabilities> capabilities();

  /// Shows the OS unlock prompt. Returns true only on a successful,
  /// user-confirmed biometric match.
  Future<bool> authenticate();
}

/// Real implementation backed by `local_auth`.
class LocalAuthBiometricAuthenticator implements BiometricAuthenticator {
  LocalAuthBiometricAuthenticator({LocalAuthentication? auth})
    : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  @override
  Future<BiometricCapabilities> capabilities() async {
    try {
      final supported =
          await _auth.isDeviceSupported() && await _auth.canCheckBiometrics;
      final enrolled = supported
          ? (await _auth.getAvailableBiometrics()).isNotEmpty
          : false;
      return BiometricCapabilities(supported: supported, enrolled: enrolled);
    } catch (_) {
      return const BiometricCapabilities(supported: false, enrolled: false);
    }
  }

  @override
  Future<bool> authenticate() async {
    try {
      return await _auth.authenticate(
        localizedReason: 'Unlock Hermes to see your chats and connections',
        biometricOnly: true,
        // Keep the prompt alive if the OS backgrounds the app while the
        // system dialog is up (e.g. an incoming call), instead of failing.
        persistAcrossBackgrounding: true,
      );
    } catch (_) {
      return false;
    }
  }
}
