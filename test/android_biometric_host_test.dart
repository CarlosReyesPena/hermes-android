/// Guards the Android host Activity contract required by `local_auth`.
///
/// `local_auth` drives the AndroidX `BiometricPrompt`, which can only attach
/// to a `FragmentActivity`. If `MainActivity` extends plain `FlutterActivity`
/// the platform channel throws `no_fragment_activity`, the OS prompt never
/// appears, and the app lock degrades to a permanent "Authentication failed"
/// — the lock is enabled but unusable.
///
/// This is a source-level guard because the failure lives in Kotlin, outside
/// what a Flutter widget test can exercise.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final mainActivity = File(
    'android/app/src/main/kotlin/com/hermesagent/hermes_android/MainActivity.kt',
  );

  test('MainActivity exists at the expected path', () {
    expect(mainActivity.existsSync(), isTrue);
  });

  test('MainActivity extends FlutterFragmentActivity for local_auth', () {
    final source = mainActivity.readAsStringSync();
    expect(
      source,
      contains('class MainActivity : FlutterFragmentActivity()'),
      reason:
          'local_auth needs a FragmentActivity host; plain FlutterActivity '
          'makes the biometric prompt throw no_fragment_activity.',
    );
  });

  test('MainActivity imports FlutterFragmentActivity, not FlutterActivity', () {
    final source = mainActivity.readAsStringSync();
    expect(
      source,
      contains('import io.flutter.embedding.android.FlutterFragmentActivity'),
    );
    expect(
      source,
      isNot(contains('import io.flutter.embedding.android.FlutterActivity')),
      reason: 'a stale FlutterActivity import invites a regression',
    );
  });
}
