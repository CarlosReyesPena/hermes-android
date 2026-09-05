import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/hermes_project.dart';
import 'package:hermes_android/core/models/session.dart';
import 'package:hermes_android/core/screens/workspace_sessions_screen.dart';
import 'package:hermes_android/core/services/ai_search_query_rewriter.dart';
import 'package:hermes_android/core/services/session_search_client.dart';
import 'package:hermes_android/core/services/session_search_controller.dart';
import 'package:hermes_android/core/services/session_search_preferences.dart';
import 'package:hermes_android/core/theme/hermes_theme.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response _jsonOk(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: const {'content-type': 'application/json'},
);

Session _session(
  String id,
  String title, {
  double? lastActive,
  bool archived = false,
  bool isActive = false,
  bool pinned = false,
}) => Session(
  id: id,
  title: title,
  model: 'claude-opus-5',
  source: 'gateway',
  messageCount: 1,
  isActive: isActive,
  preview: 'preview $title',
  startedAt: 1750000000,
  lastActive: lastActive ?? 1750000000,
  archived: archived,
  pinned: pinned,
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

  group('WorkspaceChatsFilter', () {
    test('declares the four validated chip filters in order', () {
      expect(WorkspaceChatsFilter.values, [
        WorkspaceChatsFilter.all,
        WorkspaceChatsFilter.recent,
        WorkspaceChatsFilter.unassigned,
        WorkspaceChatsFilter.archived,
      ]);
      for (final filter in WorkspaceChatsFilter.values) {
        expect(filter.label, isNotEmpty);
      }
    });

    test('All keeps every session', () {
      final result = filterChats(
        sessions: [_session('s1', 'A'), _session('s2', 'B')],
        filter: WorkspaceChatsFilter.all,
        now: DateTime.fromMillisecondsSinceEpoch(1750000000 * 1000),
      );
      expect(result.map((s) => s.id), ['s1', 's2']);
    });

    test('Recent keeps only sessions active within seven days', () {
      final now = DateTime.fromMillisecondsSinceEpoch(1750000000 * 1000);
      final recent = _session('s1', 'Fresh', lastActive: 1750000000);
      final old = _session('s2', 'Stale', lastActive: 1745000000);

      final result = filterChats(
        sessions: [old, recent],
        filter: WorkspaceChatsFilter.recent,
        now: now,
      );

      expect(result.map((s) => s.id), ['s1']);
    });

    test('Unassigned excludes claimed sessions', () {
      final result = filterChats(
        sessions: [_session('s1', 'Filed'), _session('s2', 'Inbox')],
        filter: WorkspaceChatsFilter.unassigned,
        claimedSessionIds: const {'s1'},
        now: DateTime.fromMillisecondsSinceEpoch(1750000000 * 1000),
      );
      expect(result.map((s) => s.id), ['s2']);
    });

    test('Archived merges server-archived and quick-chat archived ids', () {
      final server = _session('s1', 'Server archived', archived: true);
      final quick = _session('s2', 'Quick archived');
      final live = _session('s3', 'Live');

      final result = filterChats(
        sessions: [live, server, quick],
        filter: WorkspaceChatsFilter.archived,
        archivedQuickChatIds: const {'s2'},
        now: DateTime.fromMillisecondsSinceEpoch(1750000000 * 1000),
      );

      expect(result.map((s) => s.id).toSet(), {'s1', 's2'});
    });

    test('query narrows the active filter', () {
      final result = filterChats(
        sessions: [_session('s1', 'Migration'), _session('s2', 'Taxes')],
        filter: WorkspaceChatsFilter.all,
        query: 'migration',
        now: DateTime.fromMillisecondsSinceEpoch(1750000000 * 1000),
      );
      expect(result.map((s) => s.id), ['s1']);
    });
  });

  group('chatDateBucket', () {
    final now = DateTime.fromMillisecondsSinceEpoch(1750000000 * 1000);
    final today = now.millisecondsSinceEpoch / 1000.0;
    final yesterday =
        now.subtract(const Duration(days: 1)).millisecondsSinceEpoch / 1000.0;
    final thisWeek =
        now.subtract(const Duration(days: 3)).millisecondsSinceEpoch / 1000.0;
    final earlier =
        now.subtract(const Duration(days: 20)).millisecondsSinceEpoch / 1000.0;

    test('buckets by age', () {
      expect(chatDateBucket(now, today), ChatDateBucket.today);
      expect(chatDateBucket(now, yesterday), ChatDateBucket.yesterday);
      expect(chatDateBucket(now, thisWeek), ChatDateBucket.thisWeek);
      expect(chatDateBucket(now, earlier), ChatDateBucket.earlier);
    });

    test('groupChatsByDate returns buckets in order with labels', () {
      final groups = groupChatsByDate(now, [
        _session('s1', 'old', lastActive: earlier),
        _session('s2', 'fresh', lastActive: today),
      ]);
      expect(groups.length, 2);
      expect(groups[0].key, ChatDateBucket.today);
      expect(groups[0].value.map((s) => s.id), ['s2']);
      expect(groups[1].key, ChatDateBucket.earlier);
      expect(groups[1].value.map((s) => s.id), ['s1']);
    });

    test('bucket labels are human readable', () {
      expect(ChatDateBucket.today.label, 'Today');
      expect(ChatDateBucket.yesterday.label, 'Yesterday');
      expect(ChatDateBucket.thisWeek.label, 'This week');
      expect(ChatDateBucket.earlier.label, 'Earlier');
    });
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

  group('the Chats chip filters', () {
    final now = DateTime.fromMillisecondsSinceEpoch(1750000000 * 1000);
    final recent = _session('s1', 'Fresh', lastActive: 1750000000);
    final old = _session('s2', 'Stale', lastActive: 1745000000);
    final claimed = _session('s3', 'Filed');
    final quickArchived = _session('s4', 'Quick archived');

    Future<void> pumpChats(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: hermesTheme(Brightness.dark),
          home: WorkspaceSessionsScreen(
            title: 'Chats',
            view: WorkspaceSessionView.all,
            embedded: true,
            now: now,
            load: () async => WorkspaceSessionsData(
              sessions: [recent, old, claimed, quickArchived],
              claimedSessionIds: const {'s3'},
              archivedQuickChatIds: const {'s4'},
            ),
            onOpenSession: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('offers the four validated chips in embedded mode', (
      tester,
    ) async {
      await pumpChats(tester);

      for (final filter in WorkspaceChatsFilter.values) {
        expect(find.widgetWithText(ChoiceChip, filter.label), findsOneWidget);
      }
    });

    testWidgets('Recent shows only sessions active within the window', (
      tester,
    ) async {
      await pumpChats(tester);

      await tester.tap(find.widgetWithText(ChoiceChip, 'Recent'));
      await tester.pumpAndSettle();

      expect(find.text('Fresh'), findsOneWidget);
      expect(find.text('Stale'), findsNothing);
    });

    testWidgets('Unassigned shows only non-claimed sessions', (tester) async {
      await pumpChats(tester);

      await tester.tap(find.widgetWithText(ChoiceChip, 'Unassigned'));
      await tester.pumpAndSettle();

      expect(find.text('Filed'), findsNothing);
      expect(find.text('Fresh'), findsOneWidget);
    });

    testWidgets('Archived shows quick-archived sessions', (tester) async {
      await pumpChats(tester);

      await tester.tap(find.widgetWithText(ChoiceChip, 'Archived'));
      await tester.pumpAndSettle();

      expect(find.text('Quick archived'), findsOneWidget);
      expect(find.text('Fresh'), findsNothing);
    });

    testWidgets('groups rows under date headers', (tester) async {
      await pumpChats(tester);

      expect(find.text(ChatDateBucket.today.label), findsOneWidget);
      expect(find.text(ChatDateBucket.earlier.label), findsOneWidget);
    });
  });

  group('the conversation rows', () {
    final now = DateTime.fromMillisecondsSinceEpoch(1750000000 * 1000);

    Future<void> pumpRows(
      WidgetTester tester, {
      List<Session> sessions = const [],
      Map<String, String> projectLabels = const {},
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: hermesTheme(Brightness.dark),
          home: WorkspaceSessionsScreen(
            title: 'Chats',
            view: WorkspaceSessionView.all,
            embedded: true,
            now: now,
            load: () async => WorkspaceSessionsData(
              sessions: sessions,
              projectLabels: projectLabels,
            ),
            onOpenSession: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('marks a running session and a finished one', (tester) async {
      await pumpRows(
        tester,
        sessions: [
          _session('s1', 'Building', isActive: true, lastActive: 1750000000),
          _session('s2', 'Finished', lastActive: 1749990000),
        ],
      );

      expect(find.text('Running'), findsOneWidget);
      expect(find.text('Done'), findsOneWidget);
    });

    testWidgets('labels the project when known, Unassigned otherwise', (
      tester,
    ) async {
      await pumpRows(
        tester,
        sessions: [
          _session('s1', 'In project', lastActive: 1750000000),
          _session('s2', 'Loose', lastActive: 1749990000),
        ],
        projectLabels: const {'s1': 'Hermes Android'},
      );

      expect(find.text('Hermes Android'), findsOneWidget);
      // The Unassigned chip plus the row meta-chip are both present; the
      // row-level marker is the inbox icon.
      expect(find.byIcon(Icons.inbox_outlined), findsOneWidget);
      expect(find.byIcon(Icons.folder_outlined), findsOneWidget);
    });

    testWidgets('shows the pinned marker', (tester) async {
      await pumpRows(
        tester,
        sessions: [
          _session('s1', 'Pinned chat', lastActive: 1750000000, pinned: true),
        ],
      );

      expect(find.byIcon(Icons.push_pin_outlined), findsOneWidget);
    });

    testWidgets('moves a conversation into a Project from the Chats browser', (
      tester,
    ) async {
      final moves = <(String, String?)>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: hermesTheme(Brightness.dark),
          home: Scaffold(
            body: WorkspaceSessionsScreen(
              title: 'Chats',
              view: WorkspaceSessionView.all,
              embedded: true,
              now: now,
              load: () async => WorkspaceSessionsData(
                sessions: [_session('s1', 'Unfiled research')],
              ),
              onOpenSession: (_) {},
              onMoveSession: (session, projectId) async {
                moves.add((session.id, projectId));
              },
              projects: const [
                HermesProject(id: 'p-tuk', slug: 'tuk', name: 'Tuk-tuk'),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Move conversation'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(ListTile, 'Unassigned'), findsOneWidget);
      expect(find.widgetWithText(ListTile, 'Tuk-tuk'), findsOneWidget);

      await tester.tap(find.widgetWithText(ListTile, 'Tuk-tuk'));
      await tester.pumpAndSettle();

      expect(moves, [('s1', 'p-tuk')]);
    });

    testWidgets('moves a conversation back to Unassigned', (tester) async {
      final moves = <(String, String?)>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: hermesTheme(Brightness.dark),
          home: Scaffold(
            body: WorkspaceSessionsScreen(
              title: 'Chats',
              view: WorkspaceSessionView.all,
              embedded: true,
              now: now,
              load: () async => WorkspaceSessionsData(
                sessions: [_session('s1', 'Filed chat')],
              ),
              onOpenSession: (_) {},
              onMoveSession: (session, projectId) async {
                moves.add((session.id, projectId));
              },
              projects: const [
                HermesProject(id: 'p-tuk', slug: 'tuk', name: 'Tuk-tuk'),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Move conversation'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, 'Unassigned'));
      await tester.pumpAndSettle();

      expect(moves, [('s1', null)]);
    });

    testWidgets('archived Projects are not offered as move destinations', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: hermesTheme(Brightness.dark),
          home: Scaffold(
            body: WorkspaceSessionsScreen(
              title: 'Chats',
              view: WorkspaceSessionView.all,
              embedded: true,
              now: now,
              load: () async => WorkspaceSessionsData(
                sessions: [_session('s1', 'Unfiled research')],
              ),
              onOpenSession: (_) {},
              onMoveSession: (_, _) async {},
              projects: const [
                HermesProject(id: 'p-arch', slug: 'arch', name: 'Old', archived: true),
                HermesProject(id: 'p-tuk', slug: 'tuk', name: 'Tuk-tuk'),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Move conversation'));
      await tester.pumpAndSettle();

      expect(find.text('Old'), findsNothing);
      expect(find.text('Tuk-tuk'), findsOneWidget);
    });
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

  group('search modes with a controller', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    Future<SessionSearchController> buildController() async {
      final preferences = await SharedPreferences.getInstance();
      return SessionSearchController(
        client: SessionSearchClient(
          baseUrl: 'http://dashboard.example:9119',
          headers: () async => const {'Cookie': 'session=abc'},
          httpClient: MockClient(
            (_) async => _jsonOk({
              'results': [
                {
                  'id': 's-tuk',
                  'title': 'Electric tuk-tuk build',
                  'snippet': 'the [tuk-tuk] prototype',
                },
              ],
            }),
          ),
        ),
        rewriter: AiSearchQueryRewriter(
          baseUrl: 'http://gateway.example:8642',
          apiKey: 'key',
          httpClient: MockClient(
            (_) async => _jsonOk({'query': 'electric vehicle'}),
          ),
        ),
        preferences: SessionSearchPreferences(preferences),
        connectionIdentity: 'conn',
        loadModelOptions: () async => {'providers': <dynamic>[]},
      );
    }

    Future<void> pumpSearch(
      WidgetTester tester,
      SessionSearchController controller,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: hermesTheme(Brightness.dark),
          home: WorkspaceSessionsScreen(
            title: 'Search',
            view: WorkspaceSessionView.search,
            load: () async =>
                WorkspaceSessionsData(sessions: [_session('s1', 'Local chat')]),
            onOpenSession: (_) {},
            searchController: controller,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('offers the search-mode selector in the search view', (
      tester,
    ) async {
      await pumpSearch(tester, await buildController());

      expect(find.byTooltip('Search mode'), findsOneWidget);
      expect(find.byIcon(Icons.phone_android), findsOneWidget);
    });

    testWidgets('full-text mode replaces local filtering with server hits', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        'session_search.conn.mode': 'server',
      });
      final controller = await buildController();

      await pumpSearch(tester, controller);

      await tester.enterText(
        find.byKey(kWorkspaceSessionSearchKey),
        'tuk',
      );
      // Let the debounce fire, then settle the network result.
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(find.text('Electric tuk-tuk build'), findsOneWidget);
      expect(find.text('the [tuk-tuk] prototype'), findsOneWidget);
      expect(find.text('Local chat'), findsNothing);
    });

    testWidgets('AI mode reveals the rewritten query', (tester) async {
      // Pre-seed AI mode + model so the screen restores straight into AI mode.
      SharedPreferences.setMockInitialValues({
        'session_search.conn.mode': 'ai',
        'session_search.conn.ai_provider': 'openrouter',
        'session_search.conn.ai_model': 'gpt-oss-20b',
      });
      final controller = await buildController();

      await pumpSearch(tester, controller);

      expect(find.byIcon(Icons.auto_awesome), findsOneWidget);

      await tester.enterText(
        find.byKey(kWorkspaceSessionSearchKey),
        'tuk tuk project',
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(find.text('AI searched for: electric vehicle'), findsOneWidget);
      expect(find.text('Electric tuk-tuk build'), findsOneWidget);
    });
  });
}
