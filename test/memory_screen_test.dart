/// Memory screen app bar must expose a TalkBack tooltip on its refresh button.
///
/// Part of the daily-driver a11y pass: Settings and Skills both label their
/// refresh icon for screen readers, but Memory did not — the button was an
/// unlabelled icon to TalkBack.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:hermes_android/core/screens/memory_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';

SavedConnection _connection() => SavedConnection(
  id: 'conn-1',
  label: 'Miniserver',
  host: 'hermes.local',
  port: 8642,
  apiKey: 'k',
);

MemoryDashboardClientFactory _factory() =>
    (_) => DashboardClient(
      host: 'hermes.local',
      port: 9119,
      proxied: true,
      httpClient: MockClient((request) async {
        if (request.url.path == '/api/memory') {
          return http.Response(
            '{"entries":[]}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('not found', 404);
      }),
    );

void main() {
  testWidgets('refresh button exposes a TalkBack tooltip', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MemoryScreen(
          connection: _connection(),
          clientFactory: _factory(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('Refresh'), findsOneWidget);
  });
}
