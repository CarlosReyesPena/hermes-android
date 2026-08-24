import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/projects_gateway_client.dart';
import 'package:hermes_android/core/services/projects_repository.dart';
import 'package:hermes_android/core/services/ws_client.dart';
import 'package:hermes_android/core/theme/hermes_theme.dart';
import 'package:hermes_android/core/widgets/hermes_components.dart';
import 'package:hermes_android/core/widgets/projects_pane.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _projectJson({
  required String id,
  required String name,
  bool archived = false,
}) => {
  'id': id,
  'slug': name.toLowerCase().replaceAll(' ', '-'),
  'name': name,
  'archived': archived,
  'created_at': 1750000000,
  'folders': const [],
};

class _FakeGateway {
  List<Map<String, dynamic>> projects;
  String? activeId;
  Object? failNext;
  int listCalls = 0;

  /// When set, `projects.list` waits on this before answering, so a test can
  /// observe the pane's loading state deterministically.
  Completer<void>? gate;

  _FakeGateway({List<Map<String, dynamic>>? projects, this.activeId})
    : projects = projects ?? [];

  Future<Map<String, dynamic>> call(
    String method,
    Map<String, dynamic> params,
  ) async {
    final failure = failNext;
    if (failure != null) {
      failNext = null;
      throw failure;
    }
    switch (method) {
      case 'projects.list':
        final pending = gate;
        if (pending != null) await pending.future;
        listCalls++;
        return _ok({'projects': projects, 'active_id': activeId});
      case 'projects.create':
        final created = _projectJson(
          id: 'srv-${projects.length + 1}',
          name: params['name'] as String,
        );
        projects = [...projects, created];
        return _ok({'project': created});
      case 'projects.set_active':
        activeId = params['id'] as String?;
        return _ok({'active_id': activeId});
      default:
        return _ok(const {});
    }
  }

  static Map<String, dynamic> _ok(Map<String, dynamic> result) => {
    'jsonrpc': '2.0',
    'id': 1,
    'result': result,
  };
}

Future<ProjectsRepository> _repo(
  _FakeGateway gateway, {
  String connectionId = 'gateway-a',
}) async {
  return ProjectsRepository(
    client: ProjectsGatewayClient(gateway.call),
    preferences: await SharedPreferences.getInstance(),
    connectionId: connectionId,
  );
}

Future<void> _pumpPane(
  WidgetTester tester,
  ProjectsRepository repository, {
  ValueChanged<String>? onProjectSelected,
  Brightness brightness = Brightness.dark,
  double textScale = 1.0,
}) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: hermesTheme(brightness),
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: ProjectsPane(
            repository: repository,
            onProjectSelected: onProjectSelected,
          ),
        ),
      ),
    ),
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('shows a loading skeleton before the first result', (
    tester,
  ) async {
    final gateway = _FakeGateway(
      projects: [_projectJson(id: 'p1', name: 'Hermes Android')],
    )..gate = Completer<void>();
    final repository = await _repo(gateway);

    await _pumpPane(tester, repository);
    await tester.pump();

    expect(find.byType(LoadingSkeleton), findsOneWidget);
    expect(find.text('Hermes Android'), findsNothing);

    gateway.gate!.complete();
    await tester.pumpAndSettle();

    expect(find.byType(LoadingSkeleton), findsNothing);
    expect(find.text('Hermes Android'), findsOneWidget);
  });

  testWidgets('lists the projects returned by the gateway', (tester) async {
    final repository = await _repo(
      _FakeGateway(
        projects: [
          _projectJson(id: 'p1', name: 'Hermes Android'),
          _projectJson(id: 'p2', name: 'ScriptHive'),
        ],
      ),
    );

    await _pumpPane(tester, repository);
    await tester.pumpAndSettle();

    expect(find.text('Hermes Android'), findsOneWidget);
    expect(find.text('ScriptHive'), findsOneWidget);
    expect(find.byType(HermesCard), findsNWidgets(2));
  });

  testWidgets('hides archived projects from the main list', (tester) async {
    final repository = await _repo(
      _FakeGateway(
        projects: [
          _projectJson(id: 'p1', name: 'Live'),
          _projectJson(id: 'p2', name: 'Retired', archived: true),
        ],
      ),
    );

    await _pumpPane(tester, repository);
    await tester.pumpAndSettle();

    expect(find.text('Live'), findsOneWidget);
    expect(find.text('Retired'), findsNothing);
  });

  testWidgets('marks the active project', (tester) async {
    final repository = await _repo(
      _FakeGateway(
        projects: [
          _projectJson(id: 'p1', name: 'Hermes Android'),
          _projectJson(id: 'p2', name: 'ScriptHive'),
        ],
        activeId: 'p1',
      ),
    );

    await _pumpPane(tester, repository);
    await tester.pumpAndSettle();

    expect(find.text('Active'), findsOneWidget);
  });

  testWidgets('reports the tapped project', (tester) async {
    final selected = <String>[];
    final repository = await _repo(
      _FakeGateway(
        projects: [_projectJson(id: 'p1', name: 'Hermes Android')],
      ),
    );

    await _pumpPane(tester, repository, onProjectSelected: selected.add);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Hermes Android'));
    await tester.pumpAndSettle();

    expect(selected, ['p1']);
  });

  testWidgets('offers a designed empty state with a create action', (
    tester,
  ) async {
    final gateway = _FakeGateway();
    final repository = await _repo(gateway);

    await _pumpPane(tester, repository);
    await tester.pumpAndSettle();

    expect(find.byType(EmptyState), findsOneWidget);
    expect(find.text('No projects yet'), findsOneWidget);

    await tester.tap(find.text('Create a project'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('project-name')), 'C-MAY');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    expect(find.text('C-MAY'), findsOneWidget);
    expect(gateway.projects.single['name'], 'C-MAY');
  });

  testWidgets('refuses to create a project with a blank name', (tester) async {
    final gateway = _FakeGateway();
    final repository = await _repo(gateway);

    await _pumpPane(tester, repository);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Create a project'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    expect(find.text('Enter a name'), findsOneWidget);
    expect(gateway.projects, isEmpty);
  });

  testWidgets('an old gateway shows a calm compatibility notice', (
    tester,
  ) async {
    final gateway = _FakeGateway()
      ..failNext = const ProjectsUnsupportedException(
        'projects.list',
        'unknown method',
      );
    final repository = await _repo(gateway);

    await _pumpPane(tester, repository);
    await tester.pumpAndSettle();

    expect(find.byType(ErrorState), findsOneWidget);
    expect(find.textContaining('does not support'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('a transport failure with no cache offers a retry', (
    tester,
  ) async {
    final gateway = _FakeGateway(
      projects: [_projectJson(id: 'p1', name: 'Hermes Android')],
    )..failNext = JsonRpcError('projects.list', 'closed');
    final repository = await _repo(gateway);

    await _pumpPane(tester, repository);
    await tester.pumpAndSettle();

    expect(find.text('Retry'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.text('Hermes Android'), findsOneWidget);
  });

  testWidgets('a cached list stays usable and is labelled offline', (
    tester,
  ) async {
    final gateway = _FakeGateway(
      projects: [_projectJson(id: 'p1', name: 'Hermes Android')],
    );
    final warm = await _repo(gateway);
    await warm.refresh();

    gateway.failNext = JsonRpcError('projects.list', 'closed');
    final repository = await _repo(gateway);

    await _pumpPane(tester, repository);
    await tester.pumpAndSettle();

    expect(find.text('Hermes Android'), findsOneWidget);
    expect(find.textContaining('Offline'), findsOneWidget);
  });

  testWidgets('pull to refresh asks the gateway again', (tester) async {
    final gateway = _FakeGateway(
      projects: [_projectJson(id: 'p1', name: 'Hermes Android')],
    );
    final repository = await _repo(gateway);

    await _pumpPane(tester, repository);
    await tester.pumpAndSettle();
    final before = gateway.listCalls;

    await tester.fling(find.text('Hermes Android'), const Offset(0, 300), 1000);
    await tester.pumpAndSettle();

    expect(gateway.listCalls, greaterThan(before));
  });

  testWidgets('renders in the light theme at a large text scale', (
    tester,
  ) async {
    final repository = await _repo(
      _FakeGateway(
        projects: [_projectJson(id: 'p1', name: 'Hermes Android')],
      ),
    );

    await _pumpPane(
      tester,
      repository,
      brightness: Brightness.light,
      textScale: 1.8,
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Hermes Android'), findsOneWidget);
  });
}
