/// The Hermes workspace: the navigation shell bound to one saved connection.
///
/// This is the entry point of the new information architecture — Home,
/// Projects, Activity, More — wired to real server-owned Projects. It is
/// additive: the existing session-list flow is untouched, so the app keeps
/// working while the remaining destinations are built out.
///
/// See `docs/ANDROID_DAILY_DRIVER_ROADMAP.md`.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/chat_space_store.dart';
import '../services/connection_manager.dart';
import '../services/desktop_gateway_client.dart';
import '../services/gateway_turn_application_controller.dart';
import '../services/projects_repository.dart';
import '../theme/hermes_theme.dart';
import '../widgets/hermes_components.dart';
import '../widgets/hermes_shell.dart';
import '../widgets/home_pane.dart';
import '../widgets/more_pane.dart';
import '../widgets/projects_pane.dart';
import 'chat_screen.dart';
import 'cron_screen.dart';
import 'memory_screen.dart';
import 'settings_screen.dart';
import 'skills_screen.dart';

/// Builds the Projects repository for a connection. Injectable for tests.
typedef ProjectsRepositoryFactory =
    ProjectsRepository Function(SavedConnection connection);

/// Opens the authenticated Hermes dashboard for a URL. Injectable for tests so
/// the fallback can be asserted without launching a real browser.
typedef DashboardLauncher = Future<void> Function(String url);

/// Builds the screen a Home row opens. Injectable so the navigation contract
/// can be asserted without constructing a live chat transport.
typedef WorkspaceSessionScreenBuilder = Widget Function(Session session);

/// The chat screen a Home row opens by default.
///
/// Exposed so a test can assert what actually ships rather than only the
/// injected stand-in. [turnApplicationController] is threaded through
/// deliberately: it owns durable turn recovery above the Navigator, so a chat
/// opened from Home must resume exactly like one opened from the session list.
Widget buildWorkspaceChatScreen({
  required SavedConnection connection,
  required Session session,
  GatewayTurnApplicationController? turnApplicationController,
}) {
  return ChatScreen(
    connection: connection,
    session: session,
    turnApplicationController: turnApplicationController,
  );
}

class WorkspaceScreen extends StatefulWidget {
  final SavedConnection connection;

  /// Overrides repository construction. When provided, the caller keeps
  /// ownership of the repository lifecycle and this screen will not close it.
  final ProjectsRepositoryFactory? repositoryFactory;

  /// Called when the user opens a project.
  final ValueChanged<String>? onOpenProject;

  /// Called when the user opens a chat from the Home digest. When null, this
  /// screen pushes the chat itself, so the shell is never a dead end.
  final ValueChanged<Session>? onOpenSession;

  /// Owns durable turn recovery above this screen's lifetime. Passed to every
  /// chat opened from Home so a turn survives leaving the chat.
  final GatewayTurnApplicationController? turnApplicationController;

  /// Overrides how Home reads the sessions it ranks. Injectable for tests so
  /// the digest can be asserted without a live gateway.
  final HomeSessionsLoader? sessionsLoader;

  /// Overrides the screen a Home row opens.
  final WorkspaceSessionScreenBuilder? sessionScreenBuilder;

  /// Overrides how the Hermes dashboard fallback is opened.
  final DashboardLauncher? onOpenDashboard;

  const WorkspaceScreen({
    required this.connection,
    this.repositoryFactory,
    this.onOpenProject,
    this.onOpenSession,
    this.turnApplicationController,
    this.sessionsLoader,
    this.sessionScreenBuilder,
    this.onOpenDashboard,
    super.key,
  });

  @override
  State<WorkspaceScreen> createState() => _WorkspaceScreenState();
}

class _WorkspaceScreenState extends State<WorkspaceScreen> {
  ProjectsRepository? _repository;
  DesktopGatewayClient? _ownedGateway;
  ChatSpaceStore? _spaceStore;
  ApiClient? _sessionsApi;
  bool _ownsRepository = false;
  bool _initialized = false;

  /// Reaches the live Home pane so it can be refreshed after a chat closes.
  final _homeKey = GlobalKey<HomePaneState>();

  /// Home reads the same REST session list the session list screen uses; the
  /// injected loader wins so tests never touch a transport.
  late final HomeSessionsLoader _loadSessions =
      widget.sessionsLoader ?? _loadSessionsFromGateway;

  Future<List<Session>> _loadSessionsFromGateway() {
    final connection = widget.connection;
    final api =
        _sessionsApi ??= ApiClient(
          baseUrl: connection.baseUrl,
          apiKey: connection.apiKey,
          pathPrefix: connection.gatewayPrefix ?? '',
        );
    return api.getSessions();
  }

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  @override
  void dispose() {
    // Only tear down what this screen created; an injected repository stays
    // owned by whoever supplied it.
    if (_ownsRepository) {
      unawaited(_repository?.close());
      _ownedGateway?.close();
    }
    super.dispose();
  }

  Future<void> _initialize() async {
    final factory = widget.repositoryFactory;
    // The legacy local Spaces store is read-only here: it exists so the
    // migration preview can show what still lives on the phone.
    final preferences = await SharedPreferences.getInstance();
    if (!mounted) return;
    final spaceStore = ChatSpaceStore(
      preferences,
      connectionId: widget.connection.id,
    );

    if (factory != null) {
      final repository = factory(widget.connection);
      if (!mounted) return;
      setState(() {
        _repository = repository;
        _spaceStore = spaceStore;
        _ownsRepository = false;
        _initialized = true;
      });
      return;
    }

    // Projects live on the Desktop Gateway JSON-RPC transport; a legacy REST
    // connection simply has nowhere to ask.
    final gatewayUrl = widget.connection.desktopGatewayUrl?.trim() ?? '';
    if (gatewayUrl.isEmpty) {
      if (mounted) setState(() => _initialized = true);
      return;
    }

    try {
      final gateway = DesktopGatewayClient.fromConnection(widget.connection);
      if (!mounted) {
        gateway.close();
        return;
      }
      setState(() {
        _ownedGateway = gateway;
        _repository = ProjectsRepository(
          client: gateway.projects,
          preferences: preferences,
          connectionId: widget.connection.id,
        );
        _spaceStore = spaceStore;
        _ownsRepository = true;
        _initialized = true;
      });
    } catch (_) {
      // A malformed gateway URL is a configuration problem, not a crash: fall
      // through to the same explanation a legacy connection gets.
      if (mounted) setState(() => _initialized = true);
    }
  }

  Widget _pane(BuildContext context, HermesDestination destination) {
    switch (destination) {
      case HermesDestination.projects:
        final repository = _repository;
        if (!_initialized) {
          return const Padding(
            padding: EdgeInsets.only(top: HermesSpacing.lg),
            child: LoadingSkeleton(rows: 4),
          );
        }
        if (repository == null) {
          return const ErrorState.unsupported(
            title: 'Projects unavailable',
            message:
                'Projects need a Desktop Gateway connection. Add the Desktop '
                'Gateway URL to this connection to organize chats across '
                'your devices.',
          );
        }
        return ProjectsPane(
          repository: repository,
          onProjectSelected: widget.onOpenProject,
          spaceStore: _spaceStore,
        );
      case HermesDestination.home:
        return HomePane(
          key: _homeKey,
          loadSessions: _loadSessions,
          onOpenSession: _openSession,
        );
      case HermesDestination.activity:
        return const EmptyState(
          icon: Icons.bolt_outlined,
          title: 'Activity — Coming next',
          message:
              'Running turns, pending approvals, failures, and completed work '
              'will land here.',
        );
      case HermesDestination.more:
        return MorePane(
          sections: buildMoreSections(dashboardReachable: _dashboardReachable),
          onSelect: _openMoreEntry,
        );
    }
  }

  /// The dashboard only exists when the connection names a host to reach it
  /// on. Without one, every dashboard-backed entry is disabled *with a reason*
  /// rather than hidden, per the roadmap's capability-discovery rule.
  bool get _dashboardReachable => widget.connection.host.trim().isNotEmpty;

  /// The dashboard origin, which is not the gateway chat origin: it has its
  /// own port and optional path prefix.
  String get _dashboardUrl {
    final connection = widget.connection;
    final scheme = connection.useHttps ? 'https' : 'http';
    return SavedConnection.joinBaseUrl(
      '$scheme://${connection.host}:${connection.dashboardPort}',
      connection.dashboardPrefix ?? '',
    );
  }

  Future<void> _openDashboard() async {
    final launcher = widget.onOpenDashboard;
    if (launcher != null) {
      await launcher(_dashboardUrl);
      return;
    }
    final uri = Uri.tryParse(_dashboardUrl);
    if (uri == null) return;
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (launched || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Could not open the Hermes dashboard.')),
    );
  }

  void _push(Widget screen) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => screen));
  }

  /// Opens a chat from the Home digest.
  ///
  /// A host that supplied [WorkspaceScreen.onOpenSession] owns navigation, so
  /// this screen must not also push a route underneath it. Otherwise it opens
  /// the chat itself and re-reads Home on return, because the reason a chat
  /// was blocked usually stops being true while the user is inside it.
  Future<void> _openSession(Session session) async {
    final report = widget.onOpenSession;
    if (report != null) {
      report(session);
      return;
    }

    final builder = widget.sessionScreenBuilder;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            builder?.call(session) ??
            buildWorkspaceChatScreen(
              connection: widget.connection,
              session: session,
              turnApplicationController: widget.turnApplicationController,
            ),
      ),
    );
    if (!mounted) return;
    unawaited(_homeKey.currentState?.refresh() ?? Future<void>.value());
  }

  void _openMoreEntry(MoreEntry entry) {
    final connection = widget.connection;
    switch (entry.id) {
      case 'cron':
        _push(CronScreen(connection: connection));
      case 'skills':
        _push(SkillsScreen(connection: connection));
      case 'memory':
        _push(MemoryScreen(connection: connection));
      case 'settings':
        _push(SettingsScreen(connection: connection));
      case 'dashboard':
        unawaited(_openDashboard());
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = HermesTokens.of(context);

    return Scaffold(
      backgroundColor: tokens.surface,
      appBar: AppBar(title: Text(widget.connection.label), centerTitle: false),
      body: HermesShell(
        initialDestination: HermesDestination.home,
        builder: _pane,
      ),
    );
  }
}
