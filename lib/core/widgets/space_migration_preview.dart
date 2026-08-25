/// The read-only Spaces → Projects migration preview.
///
/// The roadmap requires the local Spaces prototype to be migrated onto
/// server-owned Projects *only* after the user has seen exactly what would
/// happen. This widget renders [SpaceMigrationPlan] — which never writes
/// anything — so the preview is honest by construction: it shows matches,
/// the projects that would have to be created, and how many chats are
/// involved, while stating plainly that nothing has moved.
///
/// See `docs/ANDROID_DAILY_DRIVER_ROADMAP.md` ("Migration of the current
/// Spaces prototype").
library;

import 'package:flutter/material.dart';

import '../services/projects_repository.dart';
import '../theme/hermes_theme.dart';
import 'hermes_components.dart';

class SpaceMigrationPreview extends StatelessWidget {
  final SpaceMigrationPlan plan;
  final VoidCallback? onDismiss;

  const SpaceMigrationPreview({required this.plan, this.onDismiss, super.key});

  static String _chats(int count) => count == 1 ? '1 chat' : '$count chats';

  String get _summary {
    final spaces = plan.entries.length == 1
        ? '1 space'
        : '${plan.entries.length} spaces';
    final toCreate = plan.projectsToCreate;
    final projects = switch (toCreate) {
      0 => 'no new projects needed',
      1 => '1 project to create',
      _ => '$toCreate projects to create',
    };
    return '$spaces · ${_chats(plan.sessionsToLink)} · $projects';
  }

  @override
  Widget build(BuildContext context) {
    final tokens = HermesTokens.of(context);

    if (plan.isEmpty) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const EmptyState(
            icon: Icons.swap_horiz_rounded,
            title: 'Nothing to migrate',
            message:
                'No local spaces were found for this connection, so Projects '
                'are already the only organization in use here.',
          ),
          if (onDismiss != null)
            TextButton(onPressed: onDismiss, child: const Text('Close')),
        ],
      );
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: HermesSpacing.xl),
      children: [
        const SectionHeader(title: 'Migration preview'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: HermesSpacing.lg),
          child: Text(
            _summary,
            style: tokens.typography.body.copyWith(color: tokens.onSurface),
          ),
        ),
        const SizedBox(height: HermesSpacing.sm),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: HermesSpacing.lg),
          child: Text(
            'Nothing has moved yet — this is only what a migration would do.',
            style: tokens.typography.label.copyWith(color: tokens.muted),
          ),
        ),
        const SizedBox(height: HermesSpacing.md),
        for (final entry in plan.entries)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              HermesSpacing.lg,
              0,
              HermesSpacing.lg,
              HermesSpacing.md,
            ),
            child: _EntryCard(entry: entry),
          ),
        if (onDismiss != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: HermesSpacing.lg),
            child: TextButton(
              onPressed: onDismiss,
              child: const Text('Close'),
            ),
          ),
      ],
    );
  }
}

class _EntryCard extends StatelessWidget {
  final SpaceMigrationEntry entry;

  const _EntryCard({required this.entry});

  @override
  Widget build(BuildContext context) {
    final tokens = HermesTokens.of(context);
    final matched = entry.matchedProject;
    final assigned = entry.sessionCount == 1
        ? '1 assigned chat'
        : '${entry.sessionCount} assigned chats';

    return HermesCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  entry.space.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: tokens.typography.section.copyWith(
                    color: tokens.onSurface,
                  ),
                ),
              ),
              const SizedBox(width: HermesSpacing.sm),
              StatusChip(
                status: matched == null
                    ? HermesStatus.blocked
                    : HermesStatus.completed,
                label: matched == null ? 'New project' : 'Matched',
              ),
            ],
          ),
          const SizedBox(height: HermesSpacing.xs),
          Text(
            matched == null
                ? 'No server project matches this name · $assigned'
                : 'Matches ${matched.name} · $assigned',
            style: tokens.typography.body.copyWith(color: tokens.muted),
          ),
        ],
      ),
    );
  }
}
