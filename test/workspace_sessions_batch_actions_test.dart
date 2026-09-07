import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/hermes_project.dart';
import 'package:hermes_android/core/models/session.dart';
import 'package:hermes_android/core/screens/workspace_sessions_screen.dart';
import 'package:hermes_android/core/theme/hermes_theme.dart';

Session session(
  String id,
  String title, {
  bool pinned = false,
  bool archived = false,
}) => Session(
  id: id,
  title: title,
  model: 'test-model',
  source: 'gateway',
  messageCount: 1,
  isActive: false,
  preview: 'preview $title',
  startedAt: 1750000000,
  lastActive: 1750000000,
  pinned: pinned,
  archived: archived,
);

Future<void> enterSelection(WidgetTester tester, String title) async {
  await tester.longPress(find.text(title));
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(ListTile, 'Select'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('batch Pin updates selected chats and Undo restores each state', (
    tester,
  ) async {
    final calls = <(String, bool?, bool?)>[];
    final chats = [
      session('s1', 'First'),
      session('s2', 'Second', pinned: true),
    ];

    await tester.pumpWidget(
      MaterialApp(
        theme: hermesTheme(Brightness.dark),
        home: Scaffold(
          body: WorkspaceSessionsScreen(
            title: 'Chats',
            view: WorkspaceSessionView.all,
            embedded: true,
            load: () async => WorkspaceSessionsData(sessions: chats),
            onOpenSession: (_) {},
            onUpdateFlags: (chat, {pinned, archived}) async {
              calls.add((chat.id, pinned, archived));
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await enterSelection(tester, 'First');
    await tester.tap(find.byKey(const Key('select-session-s2')));
    await tester.pump();
    expect(find.text('2 selected'), findsOneWidget);

    await tester.tap(find.byTooltip('Pin selected'));
    await tester.pumpAndSettle();
    expect(calls, [('s1', true, null), ('s2', true, null)]);
    expect(find.text('Pinned 2 conversations'), findsOneWidget);

    await tester.tap(find.widgetWithText(SnackBarAction, 'Undo'));
    await tester.pumpAndSettle();
    expect(calls, [
      ('s1', true, null),
      ('s2', true, null),
      ('s1', false, null),
      ('s2', true, null),
    ]);
  });

  testWidgets('batch Move can undo to each original Project', (tester) async {
    final calls = <(String, String?)>[];
    final chats = [session('s1', 'First'), session('s2', 'Second')];

    await tester.pumpWidget(
      MaterialApp(
        theme: hermesTheme(Brightness.dark),
        home: Scaffold(
          body: WorkspaceSessionsScreen(
            title: 'Chats',
            view: WorkspaceSessionView.all,
            embedded: true,
            load: () async => WorkspaceSessionsData(
              sessions: chats,
              projectIds: const {'s1': 'p-old'},
              projectLabels: const {'s1': 'Old'},
            ),
            onOpenSession: (_) {},
            onMoveSession: (chat, projectId) async {
              calls.add((chat.id, projectId));
            },
            projects: const [
              HermesProject(id: 'p-old', slug: 'old', name: 'Old'),
              HermesProject(id: 'p-new', slug: 'new', name: 'New'),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await enterSelection(tester, 'First');
    await tester.tap(find.byKey(const Key('select-session-s2')));
    await tester.pump();
    await tester.tap(find.byTooltip('Move selected'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'New'));
    await tester.pumpAndSettle();

    expect(calls, [('s1', 'p-new'), ('s2', 'p-new')]);
    await tester.tap(find.widgetWithText(SnackBarAction, 'Undo'));
    await tester.pumpAndSettle();
    expect(calls, [
      ('s1', 'p-new'),
      ('s2', 'p-new'),
      ('s1', 'p-old'),
      ('s2', null),
    ]);
  });

  testWidgets(
    'batch Move resolves non-preview Project membership before Undo',
    (tester) async {
      final moves = <(String, String?)>[];
      final resolved = <String>[];
      final chat = session('s-old', 'Older filed chat');

      await tester.pumpWidget(
        MaterialApp(
          theme: hermesTheme(Brightness.dark),
          home: Scaffold(
            body: WorkspaceSessionsScreen(
              title: 'Chats',
              view: WorkspaceSessionView.all,
              embedded: true,
              load: () async => WorkspaceSessionsData(
                sessions: [chat],
                claimedSessionIds: const {'s-old'},
              ),
              onOpenSession: (_) {},
              onMoveSession: (session, projectId) async {
                moves.add((session.id, projectId));
              },
              resolveProjectIds: (sessions) async {
                resolved.addAll(sessions.map((session) => session.id));
                return const {'s-old': 'p-original'};
              },
              projects: const [
                HermesProject(id: 'p-new', slug: 'new', name: 'New'),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await enterSelection(tester, 'Older filed chat');
      await tester.tap(find.byTooltip('Move selected'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, 'New'));
      await tester.pumpAndSettle();

      expect(resolved, ['s-old']);
      expect(moves, [('s-old', 'p-new')]);
      await tester.tap(find.widgetWithText(SnackBarAction, 'Undo'));
      await tester.pumpAndSettle();
      expect(moves, [('s-old', 'p-new'), ('s-old', 'p-original')]);
    },
  );

  testWidgets('batch Archive updates every selected conversation', (
    tester,
  ) async {
    final calls = <(String, bool?, bool?)>[];
    final chats = [session('s1', 'First'), session('s2', 'Second')];

    await tester.pumpWidget(
      MaterialApp(
        theme: hermesTheme(Brightness.dark),
        home: Scaffold(
          body: WorkspaceSessionsScreen(
            title: 'Chats',
            view: WorkspaceSessionView.all,
            embedded: true,
            load: () async => WorkspaceSessionsData(sessions: chats),
            onOpenSession: (_) {},
            onUpdateFlags: (chat, {pinned, archived}) async {
              calls.add((chat.id, pinned, archived));
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await enterSelection(tester, 'First');
    await tester.tap(find.byKey(const Key('select-session-s2')));
    await tester.pump();
    await tester.tap(find.byTooltip('Archive selected'));
    await tester.pumpAndSettle();

    expect(calls, [('s1', null, true), ('s2', null, true)]);
    expect(find.text('Archived 2 conversations'), findsOneWidget);
  });
}
