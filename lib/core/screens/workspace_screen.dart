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

import '../models/connection.dart';
import '../services/chat_space_store.dart';
import '../services/desktop_gateway_client.dart';
import '../services/projects_repository.dart';
import '../theme/hermes_theme.dart';
import '../widgets/hermes_components.dart';
import '../widgets/hermes_shell.dart';
import '../widgets/projects_pane.dart';

/// Builds the Projects repository for a connection. Injectable for tests.
typedef ProjectsRepositoryFactory =
    ProjectsRepository Function(SavedConnection connection);

class WorkspaceScreen extends StatefulWidget {
  final SavedConnection connection;

  /// Overrides repository construction. When provided, the caller keeps
  /// ownership of the repository lifecycle and this screen will not close it.
  final ProjectsRepositoryFactory? repositoryFactory;

  /// Called when the user opens a project.
  final ValueChanged<String>? onOpenProject;

  const WorkspaceScreen({
    required this.connection,
    this.repositoryFactory,
    this.onOpenProject,
    super.key,
  });

  @override
  State<WorkspaceScreen> createState() => _WorkspaceScreenState();
}

class _WorkspaceScreenState extends State<WorkspaceScreen> {
  ProjectsRepository? _repository;
  DesktopGatewayClient? _ownedGateway;
  ChatSpaceStore? _spaceStore;
  bool _ownsRepository = false;
  bool _initialized = false;

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
        return const EmptyState(
          icon: Icons.home_outlined,
          title: 'Home — Coming next',
          message:
              'This becomes the attention dashboard: what needs you, what is '
              'running, and what to continue.',
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
        return const EmptyState(
          icon: Icons.more_horiz,
          title: 'More — Coming next',
          message:
              'Files, assets, search, cron, skills, memory, and settings will '
              'be reachable from here.',
        );
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
