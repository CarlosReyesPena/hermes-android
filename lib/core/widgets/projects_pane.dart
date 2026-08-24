/// The Projects destination pane.
///
/// First screen built entirely on the design system: it renders server-owned
/// Projects through [ProjectsRepository], shows the cache immediately while a
/// live refresh runs, and expresses every situation — loading, empty, offline,
/// unsupported gateway, failure — as a designed state rather than a spinner or
/// a crash. See `docs/ANDROID_DAILY_DRIVER_ROADMAP.md`.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../models/hermes_project.dart';
import '../services/projects_repository.dart';
import '../theme/hermes_theme.dart';
import 'hermes_components.dart';

class ProjectsPane extends StatefulWidget {
  final ProjectsRepository repository;
  final ValueChanged<String>? onProjectSelected;

  const ProjectsPane({
    required this.repository,
    this.onProjectSelected,
    super.key,
  });

  @override
  State<ProjectsPane> createState() => _ProjectsPaneState();
}

class _ProjectsPaneState extends State<ProjectsPane> {
  StreamSubscription<ProjectsView>? _subscription;
  ProjectsView? _view;

  @override
  void initState() {
    super.initState();
    _subscription = widget.repository.changes.listen((view) {
      if (mounted) setState(() => _view = view);
    });
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  /// Show the cache first so the pane opens with content, then reconcile.
  Future<void> _bootstrap() async {
    final cached = await widget.repository.loadCached();
    if (cached.projects.isEmpty && cached.archived.isEmpty) {
      // Nothing worth showing: keep the skeleton until the live read lands.
      if (mounted) setState(() => _view = null);
    }
    await widget.repository.refresh();
  }

  Future<void> _refresh() => widget.repository.refresh();

  Future<void> _createProject() async {
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => const _CreateProjectDialog(),
    );
    if (name == null || !mounted) return;

    try {
      await widget.repository.create(name);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not create the project: $error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = HermesTokens.of(context);
    final view = _view;

    if (view == null) {
      return const Padding(
        padding: EdgeInsets.only(top: HermesSpacing.lg),
        child: LoadingSkeleton(rows: 4),
      );
    }

    if (view.support == ProjectsSupport.unsupported) {
      return const ErrorState.unsupported(
        title: 'Projects unavailable',
        message:
            'This Hermes gateway does not support server-side projects yet. '
            'Update Hermes to organize chats across your devices.',
      );
    }

    if (view.projects.isEmpty && view.error != null) {
      return ErrorState(
        title: 'Could not reach Hermes',
        message:
            'Check that the gateway is running and reachable, then try again.',
        onRetry: _refresh,
      );
    }

    if (view.projects.isEmpty) {
      return RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          children: [
            SizedBox(height: MediaQuery.sizeOf(context).height * 0.12),
            EmptyState(
              icon: Icons.folder_outlined,
              title: 'No projects yet',
              message:
                  'Projects group related chats, files, and activity, and stay '
                  'in sync with Hermes on your computer.',
              actionLabel: 'Create a project',
              onAction: _createProject,
            ),
          ],
        ),
      );
    }

    return Scaffold(
      backgroundColor: tokens.surface,
      floatingActionButton: FloatingActionButton(
        onPressed: _createProject,
        tooltip: 'New project',
        child: const Icon(Icons.add),
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 96),
          children: [
            if (view.isStale) _OfflineBanner(error: view.error),
            SectionHeader(title: 'Projects', count: view.projects.length),
            for (final project in view.projects)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  HermesSpacing.lg,
                  0,
                  HermesSpacing.lg,
                  HermesSpacing.md,
                ),
                child: _ProjectCard(
                  project: project,
                  isActive: project.id == view.activeId,
                  onTap: () => widget.onProjectSelected?.call(project.id),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _OfflineBanner extends StatelessWidget {
  final Object? error;

  const _OfflineBanner({this.error});

  @override
  Widget build(BuildContext context) {
    final tokens = HermesTokens.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        HermesSpacing.lg,
        HermesSpacing.lg,
        HermesSpacing.lg,
        0,
      ),
      child: HermesCard(
        status: HermesStatus.idle,
        padding: const EdgeInsets.all(HermesSpacing.md),
        child: Row(
          children: [
            Icon(Icons.cloud_off_outlined, size: 18, color: tokens.muted),
            const SizedBox(width: HermesSpacing.sm),
            Expanded(
              child: Text(
                'Offline — showing the last known projects.',
                style: tokens.typography.label.copyWith(color: tokens.muted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProjectCard extends StatelessWidget {
  final HermesProject project;
  final bool isActive;
  final VoidCallback onTap;

  const _ProjectCard({
    required this.project,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = HermesTokens.of(context);
    final path = project.workingDirectory;

    return HermesCard(
      onTap: onTap,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: tokens.accent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(HermesRadius.sm),
            ),
            child: Icon(Icons.folder_rounded, size: 20, color: tokens.accent),
          ),
          const SizedBox(width: HermesSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  project.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: tokens.typography.section.copyWith(
                    color: tokens.onSurface,
                  ),
                ),
                if (project.description != null) ...[
                  const SizedBox(height: HermesSpacing.xs),
                  Text(
                    project.description!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: tokens.typography.body.copyWith(color: tokens.muted),
                  ),
                ],
                if (path != null) ...[
                  const SizedBox(height: HermesSpacing.xs),
                  Text(
                    path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: tokens.typography.mono.copyWith(color: tokens.muted),
                  ),
                ],
              ],
            ),
          ),
          if (isActive) ...[
            const SizedBox(width: HermesSpacing.sm),
            const StatusChip(status: HermesStatus.running, label: 'Active'),
          ],
        ],
      ),
    );
  }
}

class _CreateProjectDialog extends StatefulWidget {
  const _CreateProjectDialog();

  @override
  State<_CreateProjectDialog> createState() => _CreateProjectDialogState();
}

class _CreateProjectDialogState extends State<_CreateProjectDialog> {
  String _draft = '';
  String? _error;

  void _submit() {
    final name = _draft.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Enter a name');
      return;
    }
    Navigator.pop(context, name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New project'),
      content: TextField(
        key: const Key('project-name'),
        autofocus: true,
        maxLength: 80,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(labelText: 'Name', errorText: _error),
        onChanged: (value) => _draft = value,
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Create')),
      ],
    );
  }
}
