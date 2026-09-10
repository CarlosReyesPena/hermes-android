/// Skills browser title must not show a bogus count while loading or on error.
///
/// Regression pin for the "coherent count" lens of the daily-driver goal: the
/// app bar rendered `Skills (0)` while the list was still loading and when the
/// dashboard was unreachable, reporting "0 skills" before any data existed.
/// The count must only appear once data is actually loaded.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:hermes_android/core/screens/skills_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';

SavedConnection _connection() => SavedConnection(
  id: 'conn-1',
  label: 'Miniserver',
  host: 'hermes.local',
  port: 8642,
  apiKey: 'k',
);

void main() {
  testWidgets('title omits the count while loading, then shows it after load', (
    tester,
  ) async {
    final gate = Completer<http.Response>();

    SkillsDashboardClientFactory clientFactory() =>
        (_) => DashboardClient(
          host: 'hermes.local',
          port: 9119,
          proxied: true,
          httpClient: MockClient((request) async {
            if (request.url.path == '/api/skills') return gate.future;
            return http.Response('not found', 404);
          }),
        );

    await tester.pumpWidget(
      MaterialApp(
        home: SkillsScreen(
          connection: _connection(),
          clientFactory: clientFactory(),
        ),
      ),
    );

    // Still loading: the title is bare "Skills" — no false "(0)".
    await tester.pump();
    expect(find.text('Skills'), findsOneWidget);
    expect(find.textContaining('Skills (0)'), findsNothing);

    // Resolve the load.
    gate.complete(
      http.Response(
        '[{"name":"a","enabled":true},{"name":"b","enabled":false}]',
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Skills (2)'), findsOneWidget);
  });

  testWidgets('refresh button exposes a TalkBack tooltip', (tester) async {
    SkillsDashboardClientFactory clientFactory() =>
        (_) => DashboardClient(
          host: 'hermes.local',
          port: 9119,
          proxied: true,
          httpClient: MockClient((request) async {
            if (request.url.path == '/api/skills') {
              return http.Response(
                '[]',
                200,
                headers: {'content-type': 'application/json'},
              );
            }
            return http.Response('not found', 404);
          }),
        );

    await tester.pumpWidget(
      MaterialApp(
        home: SkillsScreen(
          connection: _connection(),
          clientFactory: clientFactory(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('Refresh'), findsOneWidget);
  });
}
