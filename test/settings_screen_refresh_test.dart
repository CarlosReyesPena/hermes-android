/// The Settings toolbar refresh button must refresh the WHOLE screen, not
/// just the model section.
///
/// Regression pin for the daily-driver gap where a transient failure of the
/// session-project-organizer plugin left "AI curator settings are
/// unavailable" stuck forever — the only way to retry was leaving and
/// re-entering the screen. Tapping refresh must retry every server-backed
/// section, including Conversation organization.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_android/core/screens/settings_screen.dart';
import 'package:hermes_android/core/services/biometric_authenticator.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/main.dart';

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

class _NoBiometricsAuthenticator implements BiometricAuthenticator {
  @override
  Future<BiometricCapabilities> capabilities() async =>
      const BiometricCapabilities(supported: false, enrolled: false);

  @override
  Future<bool> authenticate() async => false;
}

const _modelOptionsJson = '''
{"providers": [{"slug": "openrouter", "models": ["model-a"]}]}
''';
const _modelInfoJson = '''
{"model": "model-a", "provider": "openrouter"}
''';
const _organizerOkJson = '''
{"assignment_mode": "dry-run", "ai_enabled": false, "provider": "openrouter", "model": "model-a"}
''';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'refresh retries the organizer section after a transient failure',
    (tester) async {
      tester.view.physicalSize = const Size(600, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      var organizerShouldFail = true;

      SettingsDashboardClientFactory clientFactory() =>
          (_) => DashboardClient(
            host: 'hermes.local',
            port: 9119,
            proxied: true,
            httpClient: MockClient((request) async {
              final path = request.url.path;
              if (path == '/api/model/info') {
                return http.Response(
                  _modelInfoJson,
                  200,
                  headers: {'content-type': 'application/json'},
                );
              }
              if (path == '/api/model/options') {
                return http.Response(
                  _modelOptionsJson,
                  200,
                  headers: {'content-type': 'application/json'},
                );
              }
              if (path == '/api/plugins/session-project-organizer/settings') {
                if (organizerShouldFail) {
                  return http.Response('plugin disabled', 503);
                }
                return http.Response(
                  _organizerOkJson,
                  200,
                  headers: {'content-type': 'application/json'},
                );
              }
              return http.Response('not found', 404);
            }),
          );

      final prefs = await SharedPreferences.getInstance();
      final manager = await ConnectionManager.create(
        prefs,
        credentialStore: _MemoryCredentialStore(),
      );
      await manager.saveConnection('Miniserver', 'hermes.local', 9119, 'key');

      await tester.pumpWidget(
        HermesApp(
          connManager: manager,
          biometricAuthenticator: _NoBiometricsAuthenticator(),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final context = tester.element(find.byType(Navigator).first);
      final navigator = Navigator.of(context);
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => SettingsScreen(
            connection: manager.getConnections().single,
            clientFactory: clientFactory(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // First load: organizer plugin is down.
      expect(find.text('AI curator settings are unavailable'), findsOneWidget);

      // The plugin comes back online — a real-world transient recovery.
      organizerShouldFail = false;

      await tester.tap(find.byTooltip('Refresh'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Refresh must have retried the organizer section too, not just the
      // model section — the unavailable card must be gone and the real
      // settings card must render.
      expect(find.text('AI curator settings are unavailable'), findsNothing);
      expect(find.text('Automatic project assignment'), findsOneWidget);
    },
  );
}
