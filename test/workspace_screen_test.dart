import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/models/session.dart';
import 'package:hermes_android/core/screens/workspace_screen.dart';
import 'package:hermes_android/core/services/chat_space_store.dart';
import 'package:hermes_android/core/services/projects_gateway_client.dart';
import 'package:hermes_android/core/services/projects_repository.dart';
import 'package:hermes_android/core/theme/hermes_theme.dart';
import 'package:hermes_android/core/utils/home_digest.dart';
import 'package:hermes_android/core/widgets/hermes_components.dart';
import 'package:hermes_android/core/widgets/hermes_shell.dart';
import 'package:hermes_android/core/widgets/home_pane.dart';
import 'package:hermes_android/core/widgets/more_pane.dart';
import 'package:hermes_android/core/widgets/projects_pane.dart';
import 'package:shared_preferences/shared_preferences.dart';

Session _session({required String id, required String title}) {
  return Session(
    id: id,
    title: title,
    model: 'claude-opus-5',
    source: 'gateway',
    messageCount: 4,
    isActive: true,
    preview: 'preview',
    startedAt: DateTime.now().millisecondsSinceEpoch / 1000.0,
  );
}

SavedConnection _connection({
  String? desktopGatewayUrl,
  String host = 'hermes-miniserver.example',
}) {
  return SavedConnection(
    id: 'conn-1',
    label: 'Miniserver',
    host: host,
    port: 8642,
    apiKey: 'key',
    desktopGatewayUrl: desktopGatewayUrl,
  );
}

Map<String, dynamic> _projectJson({required String id, required String name}) =>
    {
      'id': id,
      'slug': name.toLowerCase(),
      'name': name,
      'archived': false,
      'created_at': 1750000000,
      'folders': const [],
    };

Future<ProjectsRepository> _repository(
  List<Map<String, dynamic>> projects,
) async {
  return ProjectsRepository(
    client: ProjectsGatewayClient((method, params) async {
      if (method == 'projects.list') {
        return {
          'jsonrpc': '2.0',
          'id': 1,
          'result': {'projects': projects, 'active_id': null},
        };
      }
      return {'jsonrpc': '2.0', 'id': 1, 'result': const {}};
    }),
    preferences: await SharedPreferences.getInstance(),
    connectionId: 'conn-1',
  );
}

Future<void> _pump(
  WidgetTester tester, {
  required SavedConnection connection,
  ProjectsRepository? repository,
  List<String>? openedProjects,
  List<String>? openedDashboards,
  List<String>? openedSessions,
  List<Session>? sessions,
  Object? sessionsError,
  Size size = const Size(400, 800),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: hermesTheme(Brightness.dark),
      home: WorkspaceScreen(
        connection: connection,
        repositoryFactory: repository == null ? null : (_) => repository,
        onOpenProject: openedProjects?.add,
        onOpenSession: openedSessions == null
            ? null
            : (session) => openedSessions.add(session.id),
        sessionsLoader: sessions == null && sessionsError == null
            ? null
            : () async {
                if (sessionsError != null) throw sessionsError;
                return sessions ?? const <Session>[];
              },
        onOpenDashboard: openedDashboards == null
            ? null
            : (url) async => openedDashboards.add(url),
      ),
    ),
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('surfaces the local spaces still waiting to be migrated', (
    tester,
  ) async {
    final preferences = await SharedPreferences.getInstance();
    await ChatSpaceStore(
      preferences,
      connectionId: 'conn-1',
    ).createSpace('Hermes Android');

    await _pump(
      tester,
      connection: _connection(desktopGatewayUrl: 'https://host:8642'),
      repository: await _repository([
        _projectJson(id: 'p1', name: 'Hermes Android'),
      ]),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text(HermesDestination.projects.label).last);
    await tester.pumpAndSettle();

    expect(find.text('Review local spaces'), findsOneWidget);
  });

  testWidgets('opens on Home inside the four-destination shell', (
    tester,
  ) async {
    await _pump(
      tester,
      connection: _connection(desktopGatewayUrl: 'https://host:8642'),
      repository: await _repository([]),
    );
    await tester.pumpAndSettle();

    expect(find.byType(HermesShell), findsOneWidget);
    for (final destination in HermesDestination.values) {
      expect(find.text(destination.label), findsWidgets);
    }
  });

  testWidgets('names the connection so multi-gateway users stay oriented', (
    tester,
  ) async {
    await _pump(
      tester,
      connection: _connection(desktopGatewayUrl: 'https://host:8642'),
      repository: await _repository([]),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Miniserver'), findsWidgets);
  });

  testWidgets('the Projects destination renders live projects', (tester) async {
    await _pump(
      tester,
      connection: _connection(desktopGatewayUrl: 'https://host:8642'),
      repository: await _repository([
        _projectJson(id: 'p1', name: 'Hermes Android'),
      ]),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Projects').last);
    await tester.pumpAndSettle();

    expect(find.byType(ProjectsPane), findsOneWidget);
    expect(find.text('Hermes Android'), findsOneWidget);
  });

  testWidgets('opening a project reports it to the host', (tester) async {
    final opened = <String>[];
    await _pump(
      tester,
      connection: _connection(desktopGatewayUrl: 'https://host:8642'),
      repository: await _repository([
        _projectJson(id: 'p1', name: 'Hermes Android'),
      ]),
      openedProjects: opened,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Projects').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hermes Android'));
    await tester.pumpAndSettle();

    expect(opened, ['p1']);
  });

  testWidgets('a legacy connection explains why projects are unavailable', (
    tester,
  ) async {
    await _pump(tester, connection: _connection());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Projects').last);
    await tester.pumpAndSettle();

    expect(find.byType(ErrorState), findsOneWidget);
    expect(find.textContaining('Desktop Gateway'), findsOneWidget);
    expect(find.byType(ProjectsPane), findsNothing);
  });

  testWidgets('Activity is honest about not shipping yet', (tester) async {
    await _pump(
      tester,
      connection: _connection(desktopGatewayUrl: 'https://host:8642'),
      repository: await _repository([]),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text(HermesDestination.activity.label).last);
    await tester.pumpAndSettle();
    expect(find.byType(EmptyState), findsOneWidget);
    expect(find.textContaining('Coming'), findsOneWidget);
  });

  testWidgets('Home renders the attention digest instead of a placeholder', (
    tester,
  ) async {
    await _pump(
      tester,
      connection: _connection(desktopGatewayUrl: 'https://host:8642'),
      repository: await _repository([]),
      sessions: [
        _session(id: 's1', title: 'Roadmap slice'),
      ],
    );
    await tester.pumpAndSettle();

    expect(find.byType(HomePane), findsOneWidget);
    expect(find.text(HomeSectionKind.continueWorking.title), findsOneWidget);
    expect(find.text('Roadmap slice'), findsOneWidget);
    // The placeholder it replaces must be gone, not merely pushed down.
    expect(find.textContaining('Home — Coming next'), findsNothing);
  });

  testWidgets('opening a Home row reports the session to the host', (
    tester,
  ) async {
    final opened = <String>[];
    await _pump(
      tester,
      connection: _connection(desktopGatewayUrl: 'https://host:8642'),
      repository: await _repository([]),
      sessions: [_session(id: 's1', title: 'Roadmap slice')],
      openedSessions: opened,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Roadmap slice'));
    await tester.pumpAndSettle();

    expect(opened, ['s1']);
  });

  testWidgets('a Home read failure stays recoverable rather than fatal', (
    tester,
  ) async {
    await _pump(
      tester,
      connection: _connection(desktopGatewayUrl: 'https://host:8642'),
      repository: await _repository([]),
      sessionsError: Exception('offline'),
    );
    await tester.pumpAndSettle();

    expect(find.byType(ErrorState), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the More destination lists every capability', (tester) async {
    await _pump(
      tester,
      connection: _connection(desktopGatewayUrl: 'https://host:8642'),
      repository: await _repository([]),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text(HermesDestination.more.label).last);
    await tester.pumpAndSettle();

    expect(find.byType(MorePane), findsOneWidget);
    expect(find.text('Cron'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Settings'),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Settings'), findsOneWidget);
  });

  testWidgets('More offers the embedded dashboard fallback', (tester) async {
    final opened = <String>[];
    await _pump(
      tester,
      connection: _connection(desktopGatewayUrl: 'https://host:8642'),
      repository: await _repository([]),
      openedDashboards: opened,
      size: const Size(400, 1600),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text(HermesDestination.more.label).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open the Hermes dashboard'));
    await tester.pumpAndSettle();

    expect(opened, hasLength(1));
    // The fallback must target the dashboard, not the gateway chat port.
    expect(opened.single, contains('hermes-miniserver.example'));
    expect(opened.single, contains('9119'));
  });

  testWidgets('More disables dashboard entries without a reachable host', (
    tester,
  ) async {
    final opened = <String>[];
    await _pump(
      tester,
      connection: _connection(
        desktopGatewayUrl: 'https://host:8642',
        host: '   ',
      ),
      repository: await _repository([]),
      openedDashboards: opened,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text(HermesDestination.more.label).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cron'), warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(opened, isEmpty);
    expect(find.textContaining('Needs a reachable Hermes dashboard'),
        findsWidgets);
  });

  testWidgets('switching destinations keeps the projects state alive', (
    tester,
  ) async {
    await _pump(
      tester,
      connection: _connection(desktopGatewayUrl: 'https://host:8642'),
      repository: await _repository([
        _projectJson(id: 'p1', name: 'Hermes Android'),
      ]),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Projects').last);
    await tester.pumpAndSettle();
    expect(find.text('Hermes Android'), findsOneWidget);

    await tester.tap(find.text('Home').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Projects').last);
    await tester.pumpAndSettle();

    expect(find.text('Hermes Android'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('uses the tablet rail on a wide screen', (tester) async {
    await _pump(
      tester,
      connection: _connection(desktopGatewayUrl: 'https://host:8642'),
      repository: await _repository([]),
      size: const Size(900, 700),
    );
    await tester.pumpAndSettle();

    expect(find.byType(NavigationRail), findsOneWidget);
  });

  testWidgets('disposing the screen does not leak the repository stream', (
    tester,
  ) async {
    final repository = await _repository([]);
    await _pump(
      tester,
      connection: _connection(desktopGatewayUrl: 'https://host:8642'),
      repository: repository,
    );
    await tester.pumpAndSettle();

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pumpAndSettle();

    // A screen that owns an injected repository must not close it: the host
    // still owns that lifecycle.
    await expectLater(repository.refresh(), completes);
    expect(tester.takeException(), isNull);
  });
}
