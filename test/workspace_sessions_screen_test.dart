import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/session.dart';
import 'package:hermes_android/core/screens/workspace_sessions_screen.dart';
import 'package:hermes_android/core/theme/hermes_theme.dart';

Session _session(String id, String title) => Session(
  id: id,
  title: title,
  model: 'claude-opus-5',
  source: 'gateway',
  messageCount: 1,
  isActive: false,
  preview: 'preview $title',
  startedAt: 1750000000,
);

void main() {
  test('Unassigned excludes every server-scoped session', () {
    final result = filterWorkspaceSessions(
      sessions: [_session('s1', 'Filed'), _session('s2', 'Inbox')],
      view: WorkspaceSessionView.unassigned,
      claimedSessionIds: const {'s1'},
    );
    expect(result.map((session) => session.id), ['s2']);
  });

  test(
    'Archived Quick shows only archived quick chats and stays searchable',
    () {
      final sessions = [
        _session('s1', 'Old research'),
        _session('s2', 'Current'),
      ];
      final result = filterWorkspaceSessions(
        sessions: sessions,
        view: WorkspaceSessionView.archivedQuick,
        archivedQuickChatIds: const {'s1'},
        query: 'research',
      );
      expect(result.map((session) => session.id), ['s1']);
    },
  );

  testWidgets('embedded mode reuses the browser without a nested scaffold', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: hermesTheme(Brightness.dark),
        home: WorkspaceSessionsScreen(
          title: 'Chats',
          view: WorkspaceSessionView.all,
          embedded: true,
          load: () async =>
              WorkspaceSessionsData(sessions: [_session('s1', 'Daily driver')]),
          onOpenSession: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(Scaffold), findsNothing);
    expect(find.byType(AppBar), findsNothing);
    expect(find.byKey(kWorkspaceSessionSearchKey), findsOneWidget);
    expect(find.text('Daily driver'), findsOneWidget);
  });

  testWidgets('search opens a result and Archived Quick offers Promote', (
    tester,
  ) async {
    final opened = <String>[];
    final promoted = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: hermesTheme(Brightness.dark),
        home: WorkspaceSessionsScreen(
          title: 'Archived Quick chats',
          view: WorkspaceSessionView.archivedQuick,
          load: () async => WorkspaceSessionsData(
            sessions: [_session('s1', 'Old research')],
            archivedQuickChatIds: const {'s1'},
          ),
          onOpenSession: (session) => opened.add(session.id),
          onPromote: (session) async => promoted.add(session.id),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Old research'), findsOneWidget);
    await tester.enterText(find.byKey(kWorkspaceSessionSearchKey), 'old');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Old research'));
    expect(opened, ['s1']);

    await tester.tap(find.byTooltip('Promote to project'));
    await tester.pumpAndSettle();
    expect(promoted, ['s1']);
    expect(find.text('Old research'), findsNothing);
  });
}
