import 'package:flutter/material.dart';

import '../services/biometric_authenticator.dart';
import '../services/biometric_lock_store.dart';
import '../theme/hermes_theme.dart';

/// App-wide biometric lock.
///
/// Wraps the whole Navigator (via `MaterialApp.builder`) so no pushed route —
/// a chat, the workspace, a settings page — can appear above the lock. When
/// the user has opted in, [child] stays hidden behind an unlock screen until
/// the OS biometric prompt succeeds.
///
/// Two behaviours are deliberate:
///
/// 1. **The lock never traps the user.** If the store says "enabled" but the
///    device has no usable biometrics (unsupported or nothing enrolled), the
///    screen offers *Disable lock* instead of an impossible prompt.
/// 2. **Returning to a backgrounded app re-locks.** Passing through
///    `paused`/`hidden` marks the app as backgrounded; the next `resumed`
///    shows the lock again. Transitions caused by the OS biometric prompt
///    itself are ignored while an authentication is in flight, so the prompt
///    cannot trigger a lock/unlock loop.
class BiometricLockGate extends StatefulWidget {
  final BiometricLockStore store;
  final BiometricAuthenticator authenticator;
  final Widget child;

  const BiometricLockGate({
    required this.store,
    required this.authenticator,
    required this.child,
    super.key,
  });

  @override
  State<BiometricLockGate> createState() => _BiometricLockGateState();
}

class _BiometricLockGateState extends State<BiometricLockGate>
    with WidgetsBindingObserver {
  bool _enabled = false;
  bool _locked = false;
  bool _canPrompt = true;
  bool _authenticating = false;
  bool _backgrounded = false;
  bool _busy = true;

  /// True once the user has unlocked at least once this process. A cold-start
  /// lock renders alone (nothing beneath to preserve or load); a re-lock
  /// after backgrounding overlays the live Navigator instead.
  bool _everUnlocked = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // SharedPreferences is already in memory, so read the preference
    // synchronously: when the lock is off (the default) the child is shown
    // from the very first frame — no blank flash while probing the device.
    _enabled = widget.store.enabled;
    if (!_enabled) {
      _busy = false;
      _locked = false;
    } else {
      _probeCapabilities();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _probeCapabilities() async {
    // A locked device with no usable biometrics must stay locked (never
    // silently show the content), but offer the escape hatch instead of an
    // impossible prompt.
    final capabilities = await widget.authenticator.capabilities();
    if (!mounted) return;
    setState(() {
      _canPrompt = capabilities.canPrompt;
      _locked = true;
      _error = capabilities.canPrompt
          ? null
          : 'Biometrics are not set up on this device';
      _busy = false;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      if (!_authenticating) _backgrounded = true;
    } else if (state == AppLifecycleState.resumed && _backgrounded) {
      _backgrounded = false;
      // Re-read the preference so a lock enabled mid-session (from Settings)
      // takes effect on the next foreground return without an app restart.
      final enabled = widget.store.enabled;
      if (mounted && enabled && !_locked) {
        setState(() {
          _locked = true;
          _error = null;
        });
      }
    }
  }

  Future<void> _unlock() async {
    setState(() {
      _authenticating = true;
      _error = null;
    });
    final ok = await widget.authenticator.authenticate();
    if (!mounted) return;
    setState(() {
      _authenticating = false;
      if (ok) {
        _everUnlocked = true;
        _locked = false;
      } else {
        _error = 'Authentication failed. Try again.';
      }
    });
  }

  Future<void> _disableLock() async {
    await widget.store.setEnabled(false);
    if (!mounted) return;
    setState(() {
      _enabled = false;
      _everUnlocked = true;
      _locked = false;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_busy && _enabled) return const SizedBox.shrink();

    final lockOverlay = _buildLockScreen(context);
    if (_locked) {
      // Cold start: nothing is mounted beneath the lock yet, so no session
      // state to preserve — and no network traffic to leak behind the lock.
      if (!_everUnlocked) return lockOverlay;
      // Re-lock after backgrounding: overlay the live Navigator so an open
      // chat survives the cycle without losing its state.
      return Stack(fit: StackFit.expand, children: [widget.child, lockOverlay]);
    }
    return widget.child;
  }

  Widget _buildLockScreen(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.lock_outline,
                  size: 72,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(height: HermesSpacing.lg),
                Text(
                  'Hermes is locked',
                  style: theme.textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: HermesSpacing.sm),
                Text(
                  'Unlock with your fingerprint or face to continue.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
                if (_error != null) ...[
                  const SizedBox(height: HermesSpacing.md),
                  Text(
                    _error!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
                const SizedBox(height: HermesSpacing.lg),
                if (_canPrompt)
                  FilledButton.icon(
                    onPressed: _authenticating ? null : _unlock,
                    icon: _authenticating
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.fingerprint),
                    label: Text(_authenticating ? 'Checking…' : 'Unlock'),
                  ),
                if (!_canPrompt) ...[
                  const SizedBox(height: HermesSpacing.md),
                  TextButton(
                    onPressed: _authenticating ? null : _disableLock,
                    child: const Text('Disable lock and continue'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
