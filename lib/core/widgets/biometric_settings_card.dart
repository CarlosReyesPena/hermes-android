import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/biometric_authenticator.dart';
import '../services/biometric_lock_store.dart';

/// Security card that lets the user opt into the app-wide biometric lock.
///
/// Enabling is conditional: the OS must report both a supported sensor and an
/// enrolled biometric, otherwise the toggle refuses with an explanation
/// instead of creating a lock nobody can open. The lock itself lives above
/// the whole Navigator (`BiometricLockGate`) and takes effect on the next app
/// launch or foreground return — this card only owns the preference.
class BiometricSettingsCard extends StatefulWidget {
  const BiometricSettingsCard({
    required this.preferences,
    required this.authenticator,
    super.key,
  });

  final SharedPreferences preferences;
  final BiometricAuthenticator authenticator;

  @override
  State<BiometricSettingsCard> createState() => _BiometricSettingsCardState();
}

class _BiometricSettingsCardState extends State<BiometricSettingsCard> {
  late final BiometricLockStore _store;
  bool _enabled = false;
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    _store = BiometricLockStore(widget.preferences);
    _enabled = _store.enabled;
    _busy = false;
  }

  Future<void> _setEnabled(bool value) async {
    if (value) {
      // Refuse to arm a lock the user could never open.
      final capabilities = await widget.authenticator.capabilities();
      if (!mounted) return;
      if (!capabilities.canPrompt) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              capabilities.supported
                  ? 'No fingerprint or face is enrolled on this device. '
                        'Add one in Android Settings first.'
                  : 'This device does not support biometric unlock.',
            ),
          ),
        );
        return;
      }
    }

    setState(() => _busy = true);
    await _store.setEnabled(value);
    if (!mounted) return;
    setState(() {
      _enabled = value;
      _busy = false;
    });
    if (value) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Biometric lock is on. It will ask for your fingerprint or face '
            'the next time you open the app.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: SwitchListTile(
        secondary: Icon(
          Icons.lock_outline,
          color: _enabled ? theme.colorScheme.primary : null,
        ),
        title: const Text('Biometric lock'),
        subtitle: Text(
          _enabled
              ? 'Hermes asks for your fingerprint or face before opening.'
              : 'Lock chats and connections behind your fingerprint or face.',
        ),
        value: _enabled,
        onChanged: _busy ? null : _setEnabled,
      ),
    );
  }
}
