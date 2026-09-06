import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/hermes_theme.dart';
import 'package:hermes_android/core/utils/pending_approval_probe.dart';
import 'package:hermes_android/core/widgets/hermes_components.dart';
import 'package:hermes_android/core/widgets/pending_approvals_banner.dart';

PendingApprovalSummary _summary({
  String sessionId = 'chat',
  String? title = 'Deploy script',
  String command = 'rm -rf build',
  String description = 'Hermes wants to clear the build directory.',
}) {
  return PendingApprovalSummary(
    sessionId: sessionId,
    title: title,
    command: command,
    description: description,
  );
}

void main() {
  Future<void> pump(
    WidgetTester tester, {
    required PendingApprovalsLoader? loader,
    ValueChanged<PendingApprovalSummary>? onOpen,
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
              PendingApprovalsBanner(
                loadApprovals: loader,
                onOpenApproval: onOpen ?? (_) {},
              ),
              const Expanded(child: SizedBox()),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('PendingApprovalsBanner', () {
    testWidgets('draws nothing when the gateway reports no pending approval', (
      tester,
    ) async {
      await pump(tester, loader: () async => const []);

      expect(
        find.descendant(
          of: find.byType(PendingApprovalsBanner),
          matching: find.byType(HermesCard),
        ),
        findsNothing,
      );
    });

    testWidgets('draws nothing at all when the capability is absent', (
      tester,
    ) async {
      // A legacy REST connection has no Desktop Gateway, so there is no
      // `approval.pending` to ask: the Inbox must stay silent rather than
      // claim nothing is pending on a question it never asked.
      await pump(tester, loader: null);

      expect(
        find.descendant(
          of: find.byType(PendingApprovalsBanner),
          matching: find.byType(HermesCard),
        ),
        findsNothing,
      );
    });

    testWidgets('names the chat and the command that is waiting', (
      tester,
    ) async {
      await pump(tester, loader: () async => [_summary()]);

      expect(find.text('1 approval is waiting'), findsOneWidget);
      expect(find.textContaining('Deploy script'), findsOneWidget);
      expect(find.textContaining('rm -rf build'), findsOneWidget);
    });

    testWidgets('counts several waiting approvals in the plural', (
      tester,
    ) async {
      await pump(
        tester,
        loader: () async => [
          _summary(sessionId: 'a'),
          _summary(sessionId: 'b', title: 'Migrate database'),
        ],
      );

      expect(find.text('2 approvals are waiting'), findsOneWidget);
    });

    testWidgets('labels an untitled chat honestly', (tester) async {
      await pump(
        tester,
        loader: () async => [_summary(title: null, command: 'ls')],
      );

      expect(find.textContaining('Untitled chat'), findsOneWidget);
    });

    testWidgets('opens the chat that will replay the real dialog', (
      tester,
    ) async {
      final opened = <String>[];
      await pump(
        tester,
        loader: () async => [_summary()],
        onOpen: (approval) => opened.add(approval.sessionId),
      );

      await tester.tap(find.textContaining('Deploy script'));
      await tester.pump();

      expect(opened, ['chat']);
    });

    testWidgets('a probe that throws hides the banner instead of erroring', (
      tester,
    ) async {
      await pump(tester, loader: () async => throw Exception('socket down'));

      expect(
        find.descendant(
          of: find.byType(PendingApprovalsBanner),
          matching: find.byType(HermesCard),
        ),
        findsNothing,
      );
    });

    testWidgets('refresh re-reads and clears a resolved approval', (
      tester,
    ) async {
      var approvals = [_summary()];
      await pump(tester, loader: () async => approvals);

      expect(find.text('1 approval is waiting'), findsOneWidget);

      approvals = [];
      final state = tester.state<PendingApprovalsBannerState>(
        find.byType(PendingApprovalsBanner),
      );
      await state.refresh();
      await tester.pumpAndSettle();

      expect(find.textContaining('approval'), findsNothing);
    });

    testWidgets('stays readable at 200% text scale', (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          theme: hermesTheme(Brightness.light),
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
            child: Scaffold(
              body: Column(
                children: [
                  PendingApprovalsBanner(
                    loadApprovals: () async => [
                      _summary(sessionId: 'a'),
                      _summary(sessionId: 'b', title: 'Migrate database'),
                    ],
                    onOpenApproval: (_) {},
                  ),
                  const Expanded(child: SizedBox()),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('2 approvals are waiting'), findsOneWidget);
    });
  });
}
