import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/hermes_theme.dart';
import 'package:hermes_android/core/utils/cron_health.dart';
import 'package:hermes_android/core/widgets/cron_due_banner.dart';
import 'package:hermes_android/core/widgets/hermes_components.dart';

OverdueCronJob _due({
  String id = 'job',
  String? name,
  Duration overdueBy = const Duration(hours: 3),
}) {
  final now = DateTime.utc(2026, 9, 7, 12);
  return OverdueCronJob(
    id: id,
    name: name ?? id,
    dueAt: now.subtract(overdueBy),
    overdueBy: overdueBy,
  );
}

void main() {
  Future<void> pump(
    WidgetTester tester, {
    required CronDueLoader? loader,
    VoidCallback? onOpenCron,
    double textScale = 1.0,
    Size size = const Size(400, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: hermesTheme(Brightness.light),
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
            child: Column(
              children: [
                CronDueBanner(
                  loadDueJobs: loader,
                  onOpenCron: onOpenCron ?? () {},
                ),
                const Expanded(child: SizedBox()),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder bannerCard() => find.descendant(
    of: find.byType(CronDueBanner),
    matching: find.byType(HermesCard),
  );

  group('CronDueBanner', () {
    testWidgets('draws nothing when no job is overdue', (tester) async {
      await pump(tester, loader: () async => const <OverdueCronJob>[]);

      expect(bannerCard(), findsNothing);
    });

    testWidgets('a null loader draws nothing rather than claiming none', (
      tester,
    ) async {
      // A connection with no dashboard cannot be asked. Rendering "nothing is
      // due" would state an answer to a question that was never asked.
      await pump(tester, loader: null);

      expect(bannerCard(), findsNothing);
      expect(find.byType(CronDueBanner), findsOneWidget);
    });

    testWidgets('a throwing loader hides the banner instead of erroring', (
      tester,
    ) async {
      await pump(tester, loader: () async => throw Exception('offline'));

      expect(bannerCard(), findsNothing);
    });

    testWidgets('names a single overdue job and how late it is', (tester) async {
      await pump(
        tester,
        loader: () async => [
          _due(name: 'Nightly backup', overdueBy: const Duration(hours: 3)),
        ],
      );

      expect(find.textContaining('Nightly backup'), findsOneWidget);
      expect(find.textContaining('3h'), findsOneWidget);
    });

    testWidgets('summarises several overdue jobs with a count', (tester) async {
      await pump(
        tester,
        loader: () async => [
          _due(id: 'a', name: 'Backup'),
          _due(id: 'b', name: 'Digest'),
          _due(id: 'c', name: 'Sync'),
        ],
      );

      expect(find.textContaining('3 scheduled jobs'), findsOneWidget);
    });

    testWidgets('uses the singular form for exactly one job', (tester) async {
      await pump(tester, loader: () async => [_due(name: 'Backup')]);

      expect(find.textContaining('scheduled jobs'), findsNothing);
      expect(find.textContaining('scheduled job'), findsOneWidget);
    });

    testWidgets('tapping opens Cron through the callback', (tester) async {
      var opened = 0;
      await pump(
        tester,
        loader: () async => [_due(name: 'Backup')],
        onOpenCron: () => opened++,
      );

      await tester.tap(bannerCard());
      await tester.pump();

      expect(opened, 1);
    });

    testWidgets('refresh re-reads and can drop the banner', (tester) async {
      var jobs = [_due(name: 'Backup')];
      await pump(tester, loader: () async => jobs);

      expect(bannerCard(), findsOneWidget);

      jobs = [];
      final state = tester.state<CronDueBannerState>(
        find.byType(CronDueBanner),
      );
      await state.refresh();
      await tester.pumpAndSettle();

      expect(bannerCard(), findsNothing);
    });

    testWidgets('a job overdue by minutes states minutes, not zero hours', (
      tester,
    ) async {
      await pump(
        tester,
        loader: () async => [
          _due(name: 'Digest', overdueBy: const Duration(minutes: 42)),
        ],
      );

      expect(find.textContaining('42m'), findsOneWidget);
    });

    testWidgets('renders without overflow at 200% text scale on a 320dp phone', (
      tester,
    ) async {
      await pump(
        tester,
        loader: () async => [
          _due(name: 'A very long scheduled job name that wraps', id: 'a'),
          _due(id: 'b', name: 'Second'),
        ],
        textScale: 2.0,
        size: const Size(320, 900),
      );

      expect(tester.takeException(), isNull);
      expect(bannerCard(), findsOneWidget);
    });
  });
}
