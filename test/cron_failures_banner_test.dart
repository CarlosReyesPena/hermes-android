import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/hermes_theme.dart';
import 'package:hermes_android/core/widgets/cron_failures_banner.dart';
import 'package:hermes_android/core/widgets/hermes_components.dart';

void main() {
  Future<void> pump(
    WidgetTester tester, {
    required CronFailuresLoader loader,
    VoidCallback? onOpenCron,
  }) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: hermesTheme(Brightness.light),
        home: Scaffold(
          body: Column(
            children: [
              CronFailuresBanner(
                loadFailures: loader,
                onOpenCron: onOpenCron ?? () {},
              ),
              const Expanded(child: SizedBox()),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('CronFailuresBanner', () {
    testWidgets('shows nothing when no job is failing', (tester) async {
      await pump(tester, loader: () async => 0);

      expect(find.textContaining('cron job'), findsNothing);
    });

    testWidgets('hides a non-zero-but-stale count? no — zero hides', (
      tester,
    ) async {
      await pump(tester, loader: () async => 0);
      expect(find.byType(CronFailuresBanner), findsOneWidget);
      expect(
        tester.widget<CronFailuresBanner>(find.byType(CronFailuresBanner)),
        isNotNull,
      );
      // The banner widget is always in the tree (it owns the async load), but
      // its body must collapse to nothing when the count is zero.
      expect(
        find.descendant(
          of: find.byType(CronFailuresBanner),
          matching: find.byType(HermesCard),
        ),
        findsNothing,
      );
    });

    testWidgets('shows a singular banner for one failing job', (tester) async {
      await pump(tester, loader: () async => 1);

      expect(find.text('1 cron job needs attention'), findsOneWidget);
    });

    testWidgets('shows a plural banner for several failing jobs', (
      tester,
    ) async {
      await pump(tester, loader: () async => 3);

      expect(find.text('3 cron jobs need attention'), findsOneWidget);
    });

    testWidgets('tapping opens the Cron screen through the callback', (
      tester,
    ) async {
      var opened = 0;
      await pump(tester, loader: () async => 2, onOpenCron: () => opened++);

      await tester.tap(find.text('2 cron jobs need attention'));
      await tester.pump();

      expect(opened, 1);
    });

    testWidgets('a throwing loader hides the banner (capability-gated)', (
      tester,
    ) async {
      await pump(tester, loader: () async => throw Exception('no dashboard'));

      expect(
        find.descendant(
          of: find.byType(CronFailuresBanner),
          matching: find.byType(HermesCard),
        ),
        findsNothing,
      );
    });

    testWidgets('refresh re-reads the count', (tester) async {
      var count = 1;
      await pump(tester, loader: () async => count);

      expect(find.text('1 cron job needs attention'), findsOneWidget);

      count = 0;
      final state = tester.state<CronFailuresBannerState>(
        find.byType(CronFailuresBanner),
      );
      await state.refresh();
      await tester.pumpAndSettle();

      expect(find.textContaining('cron job'), findsNothing);
    });
  });
}
