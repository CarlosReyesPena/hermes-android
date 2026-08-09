import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Build N1 has the exact release identity and an upgrade-safe code', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match = RegExp(
      r'^version:\s*([^\s+]+)\+(\d+)\s*$',
      multiLine: true,
    ).firstMatch(pubspec);

    expect(match, isNotNull);
    expect(match!.group(1), '1.0.15-hermesapk.15');
    expect(int.parse(match.group(2)!), 2127);
    expect(int.parse(match.group(2)!), greaterThan(2126));
  });

  test('Gradle and CI enforce the accepted APK upgrade floor', () {
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();
    final buildWorkflow = File(
      '.github/workflows/build-apk.yml',
    ).readAsStringSync();
    final qualityWorkflow = File(
      '.github/workflows/pr-quality.yml',
    ).readAsStringSync();

    expect(gradle, contains('minimumInstalledVersionCode = 2126'));
    expect(
      gradle,
      contains('check(flutter.versionCode > minimumInstalledVersionCode)'),
    );
    expect(buildWorkflow, contains("MINIMUM_INSTALLED_VERSION_CODE: '2126'"));
    expect(buildWorkflow, contains('GITHUB_REF_TYPE'));
    expect(buildWorkflow, contains('Refuse an unsigned tagged release'));
    expect(buildWorkflow, contains("env.HAS_RELEASE_KEYSTORE == 'true'"));
    expect(qualityWorkflow, contains("MINIMUM_INSTALLED_VERSION_CODE: '2126'"));
  });
}
