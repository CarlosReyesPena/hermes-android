import 'package:flutter/material.dart';

import '../models/gateway_activity.dart';

class GatewayActivityCard extends StatelessWidget {
  final List<GatewayToolActivity> activities;
  final bool verbose;

  const GatewayActivityCard({
    required this.activities,
    this.verbose = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final active = activities.any((activity) => !activity.isTerminal);
    final failures = activities.where((activity) => activity.isFailed).length;
    final subtitle = active
        ? 'Hermes is using ${activities.length == 1 ? 'a tool' : '${activities.length} tools'}'
        : failures > 0
        ? '$failures failed • ${activities.length} total'
        : '${activities.length} completed';

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        key: PageStorageKey<String>(
          'gateway-activity-${activities.map((item) => item.toolId ?? item.name).join('-')}',
        ),
        initiallyExpanded: active || verbose,
        leading: active
            ? const SizedBox.square(
                dimension: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(
                failures > 0 ? Icons.error_outline : Icons.check_circle_outline,
                color: failures > 0
                    ? Theme.of(context).colorScheme.error
                    : Theme.of(context).colorScheme.primary,
              ),
        title: const Text('Hermes activity'),
        subtitle: Text(subtitle),
        children: [
          const Divider(height: 1),
          for (final activity in activities)
            _GatewayActivityRow(activity: activity),
        ],
      ),
    );
  }
}

class _GatewayActivityRow extends StatelessWidget {
  final GatewayToolActivity activity;

  const _GatewayActivityRow({required this.activity});

  @override
  Widget build(BuildContext context) {
    final color = activity.isFailed
        ? Theme.of(context).colorScheme.error
        : activity.isTerminal
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.secondary;

    return Semantics(
      label: '${activity.displayName}: ${activity.statusLabel}',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: activity.isTerminal
                  ? Icon(
                      activity.isFailed
                          ? Icons.error_outline
                          : Icons.check_rounded,
                      size: 19,
                      color: color,
                    )
                  : SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: color,
                      ),
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${activity.emoji ?? _emojiFor(activity.name)} '
                    '${activity.displayName}',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    activity.statusLabel,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: color),
                  ),
                  if (activity.detail != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      activity.detail!,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _emojiFor(String name) {
    switch (name.toLowerCase()) {
      case 'browser_navigate':
      case 'browser_console':
      case 'browser':
        return '🌐';
      case 'read_file':
      case 'read':
        return '📄';
      case 'write_file':
      case 'write':
      case 'patch':
        return '✏️';
      case 'search':
      case 'search_files':
      case 'google_search':
        return '🔍';
      case 'execute':
      case 'shell':
      case 'terminal':
        return '💻';
      case 'think':
      case 'reasoning':
        return '🧠';
      default:
        return '🔧';
    }
  }
}
