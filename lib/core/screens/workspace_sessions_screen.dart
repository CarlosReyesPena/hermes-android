import 'dart:async';

import 'package:flutter/material.dart';

import '../models/session.dart';
import '../theme/hermes_theme.dart';
import '../widgets/hermes_components.dart';

const kWorkspaceSessionSearchKey = Key('workspace-session-search');

enum WorkspaceSessionView { all, unassigned, archivedQuick, search }

class WorkspaceSessionsData {
  final List<Session> sessions;
  final Set<String> claimedSessionIds;
  final Set<String> archivedQuickChatIds;

  const WorkspaceSessionsData({
    this.sessions = const [],
    this.claimedSessionIds = const {},
    this.archivedQuickChatIds = const {},
  });
}

typedef WorkspaceSessionsLoader = Future<WorkspaceSessionsData> Function();
typedef WorkspaceSessionPromoter = Future<void> Function(Session session);

class QuickChatPromotionCancelled implements Exception {
  const QuickChatPromotionCancelled();
}

List<Session> filterWorkspaceSessions({
  required List<Session> sessions,
  required WorkspaceSessionView view,
  Set<String> claimedSessionIds = const {},
  Set<String> archivedQuickChatIds = const {},
  String query = '',
}) {
  final normalized = query.trim().toLowerCase();
  return [
    for (final session in sessions)
      if (switch (view) {
            WorkspaceSessionView.unassigned => !claimedSessionIds.contains(
              session.id,
            ),
            WorkspaceSessionView.archivedQuick => archivedQuickChatIds.contains(
              session.id,
            ),
            WorkspaceSessionView.all || WorkspaceSessionView.search => true,
          } &&
          (normalized.isEmpty ||
              session.title.toLowerCase().contains(normalized) ||
              session.preview.toLowerCase().contains(normalized) ||
              session.id.toLowerCase().contains(normalized) ||
              session.model.toLowerCase().contains(normalized)))
        session,
  ];
}

class WorkspaceSessionsScreen extends StatefulWidget {
  final String title;
  final WorkspaceSessionView view;
  final WorkspaceSessionsLoader load;
  final ValueChanged<Session> onOpenSession;
  final WorkspaceSessionPromoter? onPromote;
  final bool embedded;

  const WorkspaceSessionsScreen({
    required this.title,
    required this.view,
    required this.load,
    required this.onOpenSession,
    this.onPromote,
    this.embedded = false,
    super.key,
  });

  @override
  State<WorkspaceSessionsScreen> createState() =>
      _WorkspaceSessionsScreenState();
}

class _WorkspaceSessionsScreenState extends State<WorkspaceSessionsScreen> {
  WorkspaceSessionsData? _data;
  Object? _error;
  String _query = '';
  final Set<String> _promoting = {};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final data = await widget.load();
      if (mounted) {
        setState(() {
          _data = data;
          _error = null;
        });
      }
    } catch (error) {
      debugPrint('[workspace-sessions] load failed: $error');
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _promote(Session session) async {
    final promote = widget.onPromote;
    if (promote == null || _promoting.contains(session.id)) return;
    setState(() => _promoting.add(session.id));
    try {
      await promote(session);
      if (!mounted) return;
      final data = _data;
      if (data != null) {
        setState(() {
          _data = WorkspaceSessionsData(
            sessions: data.sessions,
            claimedSessionIds: data.claimedSessionIds,
            archivedQuickChatIds: {
              for (final id in data.archivedQuickChatIds)
                if (id != session.id) id,
            },
          );
          _promoting.remove(session.id);
        });
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Promoted to a Project')));
    } catch (error) {
      if (!mounted) return;
      setState(() => _promoting.remove(session.id));
      if (error is QuickChatPromotionCancelled) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Couldn’t promote conversation'),
          action: SnackBarAction(
            label: 'Retry',
            onPressed: () => unawaited(_promote(session)),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    final body = data == null
        ? _error == null
              ? const Padding(
                  padding: EdgeInsets.only(top: HermesSpacing.lg),
                  child: LoadingSkeleton(rows: 5),
                )
              : ErrorState(
                  title: 'Could not load conversations',
                  message: 'Check the connection and try again.',
                  onRetry: _load,
                )
        : _buildLoaded(data);
    if (widget.embedded) {
      return Material(color: Colors.transparent, child: body);
    }
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: body,
    );
  }

  Widget _buildLoaded(WorkspaceSessionsData data) {
    final sessions = filterWorkspaceSessions(
      sessions: data.sessions,
      view: widget.view,
      claimedSessionIds: data.claimedSessionIds,
      archivedQuickChatIds: data.archivedQuickChatIds,
      query: _query,
    );
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(
          HermesSpacing.lg,
          HermesSpacing.md,
          HermesSpacing.lg,
          HermesSpacing.xl,
        ),
        children: [
          TextField(
            key: kWorkspaceSessionSearchKey,
            decoration: InputDecoration(
              hintText: 'Search conversations',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear search',
                      onPressed: () => setState(() => _query = ''),
                      icon: const Icon(Icons.clear),
                    ),
            ),
            onChanged: (value) => setState(() => _query = value),
          ),
          const SizedBox(height: HermesSpacing.lg),
          if (sessions.isEmpty)
            EmptyState(
              icon: widget.view == WorkspaceSessionView.unassigned
                  ? Icons.inbox_outlined
                  : Icons.search_off,
              title: _query.isEmpty ? 'Nothing here' : 'No matches',
              message: _emptyMessage,
            )
          else
            for (final session in sessions)
              Padding(
                padding: const EdgeInsets.only(bottom: HermesSpacing.sm),
                child: HermesCard(
                  onTap: () => widget.onOpenSession(session),
                  child: Row(
                    children: [
                      const Icon(Icons.chat_bubble_outline),
                      const SizedBox(width: HermesSpacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              session.title.isEmpty
                                  ? 'Untitled chat'
                                  : session.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (session.preview.isNotEmpty)
                              Text(
                                session.preview,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: HermesTokens.of(context).muted,
                                ),
                              ),
                          ],
                        ),
                      ),
                      if (widget.view == WorkspaceSessionView.archivedQuick &&
                          widget.onPromote != null)
                        _promoting.contains(session.id)
                            ? const SizedBox.square(
                                dimension: 24,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : IconButton(
                                tooltip: 'Promote to project',
                                onPressed: () => unawaited(_promote(session)),
                                icon: const Icon(Icons.drive_file_move_outline),
                              ),
                    ],
                  ),
                ),
              ),
        ],
      ),
    );
  }

  String get _emptyMessage => switch (widget.view) {
    WorkspaceSessionView.unassigned =>
      'Every conversation is already assigned to a Project.',
    WorkspaceSessionView.archivedQuick =>
      'Quick chats appear here after their retention period.',
    WorkspaceSessionView.all ||
    WorkspaceSessionView.search => 'No conversation matches this view.',
  };
}
