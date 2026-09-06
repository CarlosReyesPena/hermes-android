import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:hermes_android/core/screens/cron_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';

SavedConnection _connection() => SavedConnection(
      id: 'conn-1',
      label: 'Miniserver',
      host: 'hermes.local',
      port: 8642,
      apiKey: 'test-key',
    );

/// A factory whose client answers `cron/jobs` from [jobsJson] and fails
/// loudly on anything else, so a test proves the screen reads exactly the
/// documented endpoint.
CronDashboardClientFactory _clientFactory(String jobsJson) {
  return (_) => DashboardClient(
        host: 'hermes.local',
        port: 9119,
        proxied: true,
        httpClient: MockClient((request) async {
          if (request.url.path == '/api/cron/jobs') {
            return http.Response(jobsJson, 200,
                headers: {'content-type': 'application/json'});
          }
          return http.Response('not found', 404);
        }),
      );
}

Future<void> _pump(WidgetTester tester, String jobsJson) async {
  await tester.pumpWidget(
    MaterialApp(
      home: CronScreen(
        connection: _connection(),
        clientFactory: _clientFactory(jobsJson),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('CronScreen attention rendering', () {
    testWidgets('shows the banner when a job is failing', (tester) async {
      await _pump(
        tester,
        jsonEncode([
          {
            'id': 'failing-1',
            'name': 'Backup',
            'last_status': 'error',
            'last_error': 'API key expired',
            'last_run_at': '2026-09-06T10:00:00Z',
            'next_run_at': '2026-09-07T10:00:00Z',
          },
          {
            'id': 'ok-1',
            'name': 'Digest',
            'last_status': 'success',
            'last_run_at': '2026-09-06T08:00:00Z',
          },
        ]),
      );

      expect(find.text('1 cron job needs attention'), findsOneWidget);
      expect(find.text('failed'), findsOneWidget);
      expect(find.textContaining('API key expired'), findsOneWidget);
      expect(find.text('Backup'), findsOneWidget);
      expect(find.text('Digest'), findsOneWidget);
    });

    testWidgets('pluralises the banner for several failing jobs',
        (tester) async {
      await _pump(
        tester,
        jsonEncode([
          {
            'id': 'f-1',
            'name': 'One',
            'last_status': 'error',
            'last_error': 'boom',
            'last_run_at': '2026-09-06T10:00:00Z',
          },
          {
            'id': 'f-2',
            'name': 'Two',
            'last_status': 'error',
            'last_error': 'boom',
            'last_run_at': '2026-09-06T09:00:00Z',
          },
        ]),
      );

      expect(find.text('2 cron jobs need attention'), findsOneWidget);
      expect(find.text('failed'), findsNWidgets(2));
    });

    testWidgets('hides the banner and badge when every job is healthy',
        (tester) async {
      await _pump(
        tester,
        jsonEncode([
          {
            'id': 'ok-1',
            'name': 'Digest',
            'last_status': 'success',
            'last_run_at': '2026-09-06T08:00:00Z',
          },
        ]),
      );

      expect(find.textContaining('need attention'), findsNothing);
      expect(find.text('failed'), findsNothing);
      expect(find.text('Digest'), findsOneWidget);
    });

    testWidgets('ranks failing jobs above healthy ones in the list',
        (tester) async {
      await _pump(
        tester,
        jsonEncode([
          {
            'id': 'ok-1',
            'name': 'Digest',
            'last_status': 'success',
            'last_run_at': '2026-09-06T08:00:00Z',
          },
          {
            'id': 'failing-1',
            'name': 'Backup',
            'last_status': 'error',
            'last_error': 'disk full',
            'last_run_at': '2026-09-06T10:00:00Z',
          },
        ]),
      );

      final backupY = tester.getTopLeft(find.text('Backup')).dy;
      final digestY = tester.getTopLeft(find.text('Digest')).dy;
      expect(backupY, lessThan(digestY));
    });

    testWidgets('shows a readable relative last-run line instead of raw ISO',
        (tester) async {
      await _pump(
        tester,
        jsonEncode([
          {
            'id': 'failing-1',
            'name': 'Backup',
            'last_status': 'error',
            'last_run_at': DateTime.now()
                .subtract(const Duration(minutes: 30))
                .toUtc()
                .toIso8601String(),
          },
        ]),
      );

      // Raw ISO blobs are gone; a friendly "Failed: 30m ago" style line is
      // shown instead. Just now is acceptable for a very fresh run.
      expect(
        find.textContaining(RegExp(r'^Failed: (\d+m ago|just now)$')),
        findsOneWidget,
      );
    });

    testWidgets('shows the loading spinner before the read completes',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: CronScreen(
            connection: _connection(),
            clientFactory: (_) => DashboardClient(
              host: 'hermes.local',
              port: 9119,
              proxied: true,
              httpClient: MockClient((request) async {
                await Future<void>.delayed(const Duration(milliseconds: 50));
                return http.Response('[]', 200);
              }),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 10));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.pumpAndSettle();
    });
  });
}
