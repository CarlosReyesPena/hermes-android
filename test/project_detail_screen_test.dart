/// The project detail screen: what a project card opens into.
///
/// `ProjectsRepository.projectSessions` and the `projects.project_sessions`
/// contract under it were both delivered, but nothing rendered them — a
/// project card had nowhere to go. This is that screen, and the rules pinned
/// here are the ones the roadmap's Phase 1 acceptance depends on:
///
/// - the four designed states (skeleton, empty, offline, retryable error) are
///   expressed the same way `HomePane` and `ActivityPane` express them, so the
///   three panes never disagree about the same failure;
/// - a *first* read that fails is retryable, while a *later* failure keeps the
///   chats already on screen behind an offline notice — losing the network
///   must never blank a screen the user is reading;
/// - a gateway that predates the drill-in explains itself instead of showing a
///   dead end, and never claims the project is empty;
/// - Overview reports what the server counted, never what the lanes happen to
///   hold, so a hydrated-empty tier cannot make a project read as zero chats;
/// - opening a chat reports the session the server sent, so the existing chat
///   route is reused rather than a second one invented.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/project_sessions_tree.dart';
import 'package:hermes_android/core/models/session.dart';
import 'package:hermes_android/core/services/projects_repository.dart';
import 'package:hermes_android/core/theme/hermes_theme.dart';
import 'package:hermes_android/core/widgets/hermes_components.dart';
import 'package:hermes_android/core/widgets/project_detail_screen.dart';

Session _session({
  String id = 's1',
  String title = 'Ship the Files browser',
  double startedAt = 1750000000,
}) => Session(
  id: id,
  title: title,
  model: 'claude-opus-5',
  preview: 'Ran flutter analyze',
  startedAt: startedAt,
  source: 'cli',
  messageCount: 3,
  isActive: true,
);

ProjectSessionsTree _tree({
  String id = 'p1',
  String label = 'Hermes Android',
  List<Session> sessions = const [],
  int? sessionCount,
}) => ProjectSessionsTree(
  id: id,
  label: label,
  path: '/home/carlos/dev/hermes-android',
  sessionCount: sessionCount ?? sessions.length,
  lastActive: 1750000900,
  repos: [
    ProjectRepo(
      id: '/home/carlos/dev/hermes-android',
      label: 'hermes-android',
      path: '/home/carlos/dev/hermes-android',
      sessionCount: sessions.length,
      lanes: [
        ProjectLane(
          id: 'main',
          label: 'main',
          isMain: true,
          sessions: sessions,
        ),
      ],
    ),
  ],
);

/// Pumps the screen with a scripted loader, so every state is deterministic.
Future<void> _pump(
  WidgetTester tester, {
  required Future<ProjectSessionsView> Function({required bool refresh}) load,
  String projectId = 'p1',
  String projectName = 'Hermes Android',
  ValueChanged<Session>? onOpenSession,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: hermesTheme(Brightness.dark),
      home: ProjectDetailScreen(
        projectId: projectId,
        projectName: projectName,
        loadSessions: load,
        onOpenSession: onOpenSession,
      ),
    ),
  );
}

void main() {
  testWidgets('holds a skeleton until the first read lands', (tester) async {
    final gate = Completer<ProjectSessionsView>();
    await _pump(tester, load: ({required refresh}) => gate.future);
    await tester.pump();

    expect(find.byType(LoadingSkeleton), findsOneWidget);
    expect(find.byType(EmptyState), findsNothing);

    gate.complete(
      ProjectSessionsView(
        projectId: 'p1',
        tree: _tree(sessions: [_session()]),
        sessions: [_session()],
        support: ProjectsSupport.native,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(LoadingSkeleton), findsNothing);
    expect(find.text('Ship the Files browser'), findsOneWidget);
  });

  testWidgets('a project with no chats states so instead of looking broken', (
    tester,
  ) async {
    await _pump(
      tester,
      load: ({required refresh}) async => ProjectSessionsView(
        projectId: 'p1',
        tree: _tree(),
        support: ProjectsSupport.native,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(EmptyState), findsOneWidget);
    expect(find.textContaining('No chats'), findsOneWidget);
  });

  testWidgets('a failed first read is retryable', (tester) async {
    var attempts = 0;
    await _pump(
      tester,
      load: ({required refresh}) async {
        attempts++;
        if (attempts == 1) {
          return ProjectSessionsView(
            projectId: 'p1',
            support: ProjectsSupport.native,
            error: Exception('socket closed'),
          );
        }
        return ProjectSessionsView(
          projectId: 'p1',
          tree: _tree(sessions: [_session()]),
          sessions: [_session()],
          support: ProjectsSupport.native,
        );
      },
    );
    await tester.pumpAndSettle();

    expect(find.byType(ErrorState), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.text('Ship the Files workspace'), findsNothing);
    expect(find.text('Ship the Files browser'), findsOneWidget);
    expect(attempts, 2);
  });

  testWidgets('a later failure keeps the chats behind an offline notice', (
    tester,
  ) async {
    var attempts = 0;
    await _pump(
      tester,
      load: ({required refresh}) async {
        attempts++;
        if (attempts == 1) {
          return ProjectSessionsView(
            projectId: 'p1',
            tree: _tree(sessions: [_session()]),
            sessions: [_session()],
            support: ProjectsSupport.native,
          );
        }
        return ProjectSessionsView(
          projectId: 'p1',
          tree: _tree(sessions: [_session()]),
          sessions: [_session()],
          support: ProjectsSupport.native,
          isStale: true,
          error: Exception('offline'),
        );
      },
    );
    await tester.pumpAndSettle();

    await tester.drag(find.byType(CustomScrollView), const Offset(0, 320));
    await tester.pumpAndSettle();

    // The chat the user was reading survives the failed refresh.
    expect(find.text('Ship the Files browser'), findsOneWidget);
    expect(find.byType(ErrorState), findsNothing);
    expect(find.textContaining('Offline'), findsOneWidget);
  });

  testWidgets('an older gateway explains itself and claims nothing', (
    tester,
  ) async {
    await _pump(
      tester,
      load: ({required refresh}) async => const ProjectSessionsView(
        projectId: 'p1',
        support: ProjectsSupport.unsupported,
      ),
    );
    await tester.pumpAndSettle();

    // Never the empty state: "no chats" would be a claim this gateway cannot
    // support, and a red error would blame the user for an old server.
    expect(find.byType(EmptyState), findsNothing);
    expect(find.byType(ErrorState), findsOneWidget);
    expect(find.textContaining('does not support'), findsOneWidget);
  });

  testWidgets('Overview reports the counts the server sent', (tester) async {
    await _pump(
      tester,
      load: ({required refresh}) async => ProjectSessionsView(
        projectId: 'p1',
        // The server counts 12 chats but hydrated only the two lanes rows.
        tree: _tree(sessions: [_session()], sessionCount: 12),
        sessions: [_session()],
        support: ProjectsSupport.native,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Overview'));
    await tester.pumpAndSettle();

    // Deriving the count from the rows on screen would report 1.
    expect(find.text('12'), findsOneWidget);
    expect(find.textContaining('hermes-android'), findsWidgets);
  });

  testWidgets('opening a chat reports the session the server sent', (
    tester,
  ) async {
    Session? opened;
    await _pump(
      tester,
      load: ({required refresh}) async => ProjectSessionsView(
        projectId: 'p1',
        tree: _tree(sessions: [_session(id: 's-42')]),
        sessions: [_session(id: 's-42')],
        support: ProjectsSupport.native,
      ),
      onOpenSession: (session) => opened = session,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Ship the Files browser'));
    await tester.pumpAndSettle();

    expect(opened, isNotNull);
    expect(opened!.id, 's-42');
  });

  testWidgets('pull to refresh forces a live read', (tester) async {
    final refreshes = <bool>[];
    await _pump(
      tester,
      load: ({required refresh}) async {
        refreshes.add(refresh);
        return ProjectSessionsView(
          projectId: 'p1',
          tree: _tree(sessions: [_session()]),
          sessions: [_session()],
          support: ProjectsSupport.native,
        );
      },
    );
    await tester.pumpAndSettle();

    expect(refreshes, [false]);

    await tester.fling(find.byType(CustomScrollView), const Offset(0, 400), 800);
    await tester.pumpAndSettle();

    // The first open may use the cache; an explicit pull must not.
    expect(refreshes, [false, true]);
  });
}
