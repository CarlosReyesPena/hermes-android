import 'dart:async';

import 'package:flutter/material.dart';

import '../models/hermes_project.dart';
import '../models/session.dart';
import '../models/session_search_hit.dart';
import '../services/ai_search_query_rewriter.dart';
import '../services/session_search_client.dart';
import '../services/session_search_controller.dart';
import '../services/session_search_preferences.dart';
import '../theme/hermes_theme.dart';
import '../utils/relative_time.dart';
import '../widgets/hermes_components.dart';
import '../widgets/session_name_dialog.dart';

const kWorkspaceSessionSearchKey = Key('workspace-session-search');

enum WorkspaceSessionView { all, unassigned, archivedQuick, search }

/// The chip filters the Chats browser offers (decision #4 of the final UI
/// spec): every conversation, pinned, recent activity, unassigned, and
/// archived.
enum WorkspaceChatsFilter {
  all('All'),
  pinned('Pinned'),
  recent('Recent'),
  unassigned('Unassigned'),
  archived('Archived');

  final String label;
  const WorkspaceChatsFilter(this.label);
}

/// How recently a conversation was last active, for date group headers.
enum ChatDateBucket {
  today('Today'),
  yesterday('Yesterday'),
  thisWeek('This week'),
  earlier('Earlier');

  final String label;
  const ChatDateBucket(this.label);
}

/// How long "Recent" means in the Chats browser.
const Duration kRecentChatsWindow = Duration(days: 7);

/// Assigns a conversation to its date bucket, by calendar day.
ChatDateBucket chatDateBucket(DateTime now, double lastActiveSeconds) {
  final activity = DateTime.fromMillisecondsSinceEpoch(
    (lastActiveSeconds * 1000).round(),
  );
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(activity.year, activity.month, activity.day);
  final diff = today.difference(day).inDays;
  if (diff <= 0) return ChatDateBucket.today;
  if (diff == 1) return ChatDateBucket.yesterday;
  if (diff < 7) return ChatDateBucket.thisWeek;
  return ChatDateBucket.earlier;
}

/// Filters and sorts the Chats browser list for one chip filter.
///
/// Sorting is always by most recent activity, so a conversation moving up in
/// the list is the honest signal that it changed. [now] is injectable so the
/// "Recent" window and date buckets are deterministic in tests.
List<Session> filterChats({
  required List<Session> sessions,
  required WorkspaceChatsFilter filter,
  Set<String> claimedSessionIds = const {},
  Set<String> archivedQuickChatIds = const {},
  String query = '',
  DateTime? now,
}) {
  final current = now ?? DateTime.now();
  final normalized = query.trim().toLowerCase();
  final recentCutoff =
      current.subtract(kRecentChatsWindow).millisecondsSinceEpoch / 1000.0;

  final filtered = [
    for (final session in sessions)
      if (switch (filter) {
            WorkspaceChatsFilter.all => true,
            // A pin is an explicit "keep this reachable", so this view is
            // deliberately not narrowed by archive state: an archived pin is
            // still the row the user asked to keep in reach.
            WorkspaceChatsFilter.pinned => session.pinned,
            WorkspaceChatsFilter.recent => session.lastActive >= recentCutoff,
            WorkspaceChatsFilter.unassigned => !claimedSessionIds.contains(
              session.id,
            ),
            WorkspaceChatsFilter.archived =>
              session.archived || archivedQuickChatIds.contains(session.id),
          } &&
          (normalized.isEmpty ||
              session.title.toLowerCase().contains(normalized) ||
              session.preview.toLowerCase().contains(normalized) ||
              session.id.toLowerCase().contains(normalized) ||
              session.model.toLowerCase().contains(normalized)))
        session,
  ]..sort((a, b) => b.lastActive.compareTo(a.lastActive));
  return filtered;
}

/// Groups conversations into date buckets, newest bucket first.
List<MapEntry<ChatDateBucket, List<Session>>> groupChatsByDate(
  DateTime now,
  List<Session> sessions,
) {
  final buckets = <ChatDateBucket, List<Session>>{
    for (final bucket in ChatDateBucket.values) bucket: <Session>[],
  };
  for (final session in sessions) {
    buckets[chatDateBucket(now, session.lastActive)]!.add(session);
  }
  return [
    for (final bucket in ChatDateBucket.values)
      if (buckets[bucket]!.isNotEmpty)
        MapEntry(bucket, List.unmodifiable(buckets[bucket]!)),
  ];
}

class WorkspaceSessionsData {
  final List<Session> sessions;
  final Set<String> claimedSessionIds;
  final Set<String> archivedQuickChatIds;

  /// Best-effort session id → project label mapping.
  ///
  /// Built from the server `projects.tree` preview rows; a conversation whose
  /// project is unknown stays honest as "Unassigned" in the UI.
  final Map<String, String> projectLabels;

  /// Best-effort session id → project id mapping used to restore each original
  /// destination when a batch Move is undone.
  final Map<String, String?> projectIds;

  const WorkspaceSessionsData({
    this.sessions = const [],
    this.claimedSessionIds = const {},
    this.archivedQuickChatIds = const {},
    this.projectLabels = const {},
    this.projectIds = const {},
  });
}

typedef WorkspaceSessionsLoader = Future<WorkspaceSessionsData> Function();
typedef WorkspaceSessionPromoter = Future<void> Function(Session session);

/// Moves one conversation into a Project (or back to Unassigned when
/// [projectId] is null). Mirrors `ProjectSessionMover` so the Chats browser
/// can file a chat from where the user sees it, not only from inside a Project.
typedef WorkspaceSessionMover =
    Future<void> Function(Session session, String? projectId);

/// Resolves original Project ids for selected conversations not present in the
/// cheap overview previews. Used only before a batch move so Undo never guesses.
typedef WorkspaceSessionProjectResolver =
    Future<Map<String, String?>> Function(List<Session> sessions);

/// Updates one conversation's durable flags (pin / archive) server-side. The
/// gateway persists each flag across the session's compression lineage.
typedef WorkspaceSessionFlagUpdater =
    Future<void> Function(Session session, {bool? pinned, bool? archived});

/// Renames one conversation to a user-supplied title.
typedef WorkspaceSessionRenamer =
    Future<void> Function(Session session, String title);

/// Deletes one conversation irreversibly (server-authoritative `DELETE`).
///
/// The UI asks for explicit confirmation before invoking this because the
/// action cannot be undone: archiving keeps the content, deletion removes it.
typedef WorkspaceSessionDeleter = Future<void> Function(Session session);

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

  /// When non-null, each row gains a "Move conversation" action backed by this
  /// callback. [projects] supplies the move destinations (Unassigned plus each
  /// non-archived Project).
  final WorkspaceSessionMover? onMoveSession;
  final WorkspaceSessionProjectResolver? resolveProjectIds;
  final List<HermesProject> projects;

  /// When non-null, each row gains a long-press menu with Pin/Unpin and
  /// Archive/Unarchive, backed by this callback (single-session `PATCH`).
  final WorkspaceSessionFlagUpdater? onUpdateFlags;

  /// When non-null, the long-press menu also offers Rename, backed by this
  /// callback. The legacy session list exposed rename; the new Chats browser
  /// must not silently lose it.
  final WorkspaceSessionRenamer? onRenameSession;

  /// When non-null, the long-press menu also offers Delete, backed by this
  /// callback. Destructive and irreversible: the row asks for confirmation
  /// before calling it, and a deleted conversation disappears for good.
  final WorkspaceSessionDeleter? onDeleteSession;

  /// When non-null, the search bar gains the three search modes (on-device,
  /// full-text, AI + full-text) and the network modes use this controller.
  ///
  /// Kept optional so callers that already built a controller (the standalone
  /// Search route) can hand it in directly.
  final SessionSearchController? searchController;

  /// Lazily builds the controller the first time this screen appears, so the
  /// embedded Chats browser can offer the same AI/full-text modes as the
  /// standalone Search route without the parent having to construct a gateway
  /// controller synchronously. Ignored when [searchController] is provided.
  final SessionSearchControllerFactory? searchControllerFactory;

  /// Clock injection for deterministic filter/date tests. When null the
  /// screen uses `DateTime.now()`.
  final DateTime? now;

  const WorkspaceSessionsScreen({
    required this.title,
    required this.view,
    required this.load,
    required this.onOpenSession,
    this.onPromote,
    this.embedded = false,
    this.onMoveSession,
    this.resolveProjectIds,
    this.projects = const [],
    this.onUpdateFlags,
    this.onRenameSession,
    this.onDeleteSession,
    this.searchController,
    this.searchControllerFactory,
    this.now,
    super.key,
  });

  @override
  State<WorkspaceSessionsScreen> createState() =>
      _WorkspaceSessionsScreenState();
}

class _WorkspaceSessionsScreenState extends State<WorkspaceSessionsScreen> {
  /// Debounce window before a typed query hits the network. Local search
  /// filters on every keystroke; the server modes must not.
  static const _searchDebounce = Duration(milliseconds: 350);

  WorkspaceSessionsData? _data;
  Object? _error;
  String _query = '';
  final Set<String> _promoting = {};
  final Set<String> _moving = {};
  final Set<String> _updatingFlags = {};
  final Set<String> _selectedSessionIds = {};
  bool _batchActionRunning = false;

  /// The active chip filter in the embedded Chats browser.
  WorkspaceChatsFilter _filter = WorkspaceChatsFilter.all;

  // ── Search mode state (only used when a controller is supplied) ─────────
  SessionSearchMode _searchMode = SessionSearchMode.local;
  AiSearchModel? _aiSearchModel;
  List<SessionSearchHit>? _serverResults;
  bool _searching = false;
  bool _loadingAiModels = false;
  String? _searchError;
  String? _aiRewrittenQuery;
  String _serverQuery = '';
  Timer? _searchDebounceTimer;
  int _searchRequestGeneration = 0;

  /// Whether the network search modes are available for this screen.
  ///
  /// True when the caller handed in a ready controller (standalone Search) or
  /// when this screen lazily built one from [WorkspaceSessionsScreen.searchControllerFactory]
  /// (embedded Chats browser).
  bool get _hasSearchController => _effectiveSearchController != null;

  /// The controller to use: a caller-supplied one wins over a lazily built one.
  SessionSearchController? get _effectiveSearchController =>
      widget.searchController ?? _ownedSearchController;

  /// Built from the factory after the first frame, when the caller supplied
  /// one (embedded Chats browser without a ready controller).
  SessionSearchController? _ownedSearchController;

  bool _searchControllerBuildRequested = false;

  /// Injectable clock for deterministic tests.
  DateTime get _now => widget.now ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    final controller = widget.searchController;
    if (controller != null) {
      controller.restore();
      _searchMode = controller.mode;
      _aiSearchModel = controller.aiModel;
    } else if (widget.searchControllerFactory != null) {
      unawaited(_buildOwnedSearchController());
    }
    unawaited(_load());
  }

  /// Builds the network-search controller once the factory resolves.
  ///
  /// The embedded Chats browser shows local-only filtering on its first frame
  /// and upgrades to the full AI/full-text modes as soon as the gateway-backed
  /// controller is ready — no parent plumbing needed.
  Future<void> _buildOwnedSearchController() async {
    final factory = widget.searchControllerFactory;
    if (factory == null || _searchControllerBuildRequested) return;
    _searchControllerBuildRequested = true;
    try {
      final controller = await factory();
      if (!mounted || _effectiveSearchController != null) return;
      controller.restore();
      setState(() {
        _ownedSearchController = controller;
        if (_searchMode == SessionSearchMode.local) {
          _searchMode = controller.mode;
        }
        _aiSearchModel = controller.aiModel;
      });
    } catch (_) {
      // A gateway that cannot build a search controller degrades to the
      // local-only filter this screen already had; nothing to surface.
    }
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
            projectLabels: data.projectLabels,
            projectIds: data.projectIds,
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

  Future<void> _moveSession(Session session, _MoveTarget target) async {
    final move = widget.onMoveSession;
    if (move == null || _moving.contains(session.id)) return;
    setState(() => _moving.add(session.id));
    try {
      await move(session, target.projectId);
      if (!mounted) return;
      setState(() => _moving.remove(session.id));
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Moved to ${target.label}')));
    } catch (_) {
      if (!mounted) return;
      setState(() => _moving.remove(session.id));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Couldn’t move conversation'),
          action: SnackBarAction(
            label: 'Retry',
            onPressed: () => unawaited(_moveSession(session, target)),
          ),
        ),
      );
    }
  }

  Future<void> _chooseMoveDestination(Session session) async {
    final target = await showModalBottomSheet<_MoveTarget>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(
                HermesSpacing.lg,
                HermesSpacing.lg,
                HermesSpacing.lg,
                HermesSpacing.sm,
              ),
              child: Text('Move conversation'),
            ),
            ListTile(
              leading: const Icon(Icons.inbox_outlined),
              title: const Text('Unassigned'),
              onTap: () => Navigator.pop(
                context,
                const _MoveTarget(projectId: null, label: 'Unassigned'),
              ),
            ),
            for (final project in widget.projects)
              if (!project.archived)
                ListTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(project.name),
                  onTap: () => Navigator.pop(
                    context,
                    _MoveTarget(projectId: project.id, label: project.name),
                  ),
                ),
          ],
        ),
      ),
    );
    if (target == null || !mounted) return;
    await _moveSession(session, target);
  }

  Future<void> _chooseBatchMoveDestination() async {
    if (_selectedSessionIds.isEmpty || widget.onMoveSession == null) return;
    final target = await showModalBottomSheet<_MoveTarget>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(
                HermesSpacing.lg,
                HermesSpacing.lg,
                HermesSpacing.lg,
                HermesSpacing.sm,
              ),
              child: Text('Move selected conversations'),
            ),
            ListTile(
              leading: const Icon(Icons.inbox_outlined),
              title: const Text('Unassigned'),
              onTap: () => Navigator.pop(
                context,
                const _MoveTarget(projectId: null, label: 'Unassigned'),
              ),
            ),
            for (final project in widget.projects)
              if (!project.archived)
                ListTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(project.name),
                  onTap: () => Navigator.pop(
                    context,
                    _MoveTarget(projectId: project.id, label: project.name),
                  ),
                ),
          ],
        ),
      ),
    );
    if (target == null || !mounted) return;
    await _moveSelected(target);
  }

  List<Session> get _selectedSessions {
    final data = _data;
    if (data == null) return const [];
    return [
      for (final session in data.sessions)
        if (_selectedSessionIds.contains(session.id)) session,
    ];
  }

  void _startSelection(Session session) {
    setState(() => _selectedSessionIds.add(session.id));
  }

  void _toggleSelection(Session session) {
    if (_batchActionRunning) return;
    setState(() {
      if (!_selectedSessionIds.add(session.id)) {
        _selectedSessionIds.remove(session.id);
      }
    });
  }

  void _clearSelection() {
    if (_batchActionRunning) return;
    setState(_selectedSessionIds.clear);
  }

  Future<void> _updateSelectedFlag({
    required bool pinned,
    required bool archived,
  }) async {
    final update = widget.onUpdateFlags;
    final selected = _selectedSessions;
    if (update == null || selected.isEmpty || _batchActionRunning) return;
    final originals = {
      for (final session in selected)
        session.id: (pinned: session.pinned, archived: session.archived),
    };
    setState(() => _batchActionRunning = true);
    try {
      await Future.wait([
        for (final session in selected)
          update(
            session,
            pinned: pinned ? true : null,
            archived: archived ? true : null,
          ),
      ]);
      if (!mounted) return;
      setState(() {
        _batchActionRunning = false;
        _selectedSessionIds.clear();
      });
      await _load();
      if (!mounted) return;
      final verb = pinned ? 'Pinned' : 'Archived';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$verb ${selected.length} conversations'),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => unawaited(
              _restoreSelectedFlags(
                selected,
                originals,
                restorePinned: pinned,
                restoreArchived: archived,
              ),
            ),
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _batchActionRunning = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Couldn’t update selected conversations')),
      );
    }
  }

  Future<void> _restoreSelectedFlags(
    List<Session> sessions,
    Map<String, ({bool pinned, bool archived})> originals, {
    required bool restorePinned,
    required bool restoreArchived,
  }) async {
    final update = widget.onUpdateFlags;
    if (update == null) return;
    try {
      await Future.wait([
        for (final session in sessions)
          update(
            session,
            pinned: restorePinned ? originals[session.id]!.pinned : null,
            archived: restoreArchived ? originals[session.id]!.archived : null,
          ),
      ]);
      await _load();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Couldn’t undo batch action')),
      );
    }
  }

  Future<void> _moveSelected(_MoveTarget target) async {
    final move = widget.onMoveSession;
    final data = _data;
    final selected = _selectedSessions;
    if (move == null ||
        data == null ||
        selected.isEmpty ||
        _batchActionRunning) {
      return;
    }
    setState(() => _batchActionRunning = true);
    try {
      final originalProjectIds = <String, String?>{};
      final unresolved = <Session>[];
      for (final session in selected) {
        if (data.projectIds.containsKey(session.id)) {
          originalProjectIds[session.id] = data.projectIds[session.id];
        } else if (!data.claimedSessionIds.contains(session.id)) {
          originalProjectIds[session.id] = null;
        } else {
          unresolved.add(session);
        }
      }
      if (unresolved.isNotEmpty) {
        final resolver = widget.resolveProjectIds;
        if (resolver == null) {
          throw StateError('Original Project destinations are unavailable');
        }
        final resolved = await resolver(unresolved);
        for (final session in unresolved) {
          if (!resolved.containsKey(session.id)) {
            throw StateError('Could not resolve ${session.id}');
          }
          originalProjectIds[session.id] = resolved[session.id];
        }
      }
      await Future.wait([
        for (final session in selected) move(session, target.projectId),
      ]);
      if (!mounted) return;
      setState(() {
        _batchActionRunning = false;
        _selectedSessionIds.clear();
      });
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Moved ${selected.length} conversations to ${target.label}',
          ),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () =>
                unawaited(_restoreMovedSessions(selected, originalProjectIds)),
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _batchActionRunning = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Couldn’t move selected conversations')),
      );
    }
  }

  Future<void> _restoreMovedSessions(
    List<Session> sessions,
    Map<String, String?> projectIds,
  ) async {
    final move = widget.onMoveSession;
    if (move == null) return;
    try {
      await Future.wait([
        for (final session in sessions) move(session, projectIds[session.id]),
      ]);
      await _load();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Couldn’t undo batch move')));
    }
  }

  Future<void> _updateFlag(
    Session session, {
    bool? pinned,
    bool? archived,
  }) async {
    final update = widget.onUpdateFlags;
    if (update == null || _updatingFlags.contains(session.id)) return;
    setState(() => _updatingFlags.add(session.id));
    try {
      await update(session, pinned: pinned, archived: archived);
      if (!mounted) return;
      setState(() => _updatingFlags.remove(session.id));
      await _load();
    } catch (_) {
      if (!mounted) return;
      setState(() => _updatingFlags.remove(session.id));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Couldn’t update conversation')),
      );
    }
  }

  Future<void> _showSessionMenu(Session session) async {
    final update = widget.onUpdateFlags;
    final rename = widget.onRenameSession;
    final supportsBatch = update != null || widget.onMoveSession != null;
    if (update == null &&
        rename == null &&
        widget.onDeleteSession == null &&
        !supportsBatch) {
      return;
    }
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (supportsBatch)
              ListTile(
                leading: const Icon(Icons.checklist),
                title: const Text('Select'),
                onTap: () => Navigator.pop(context, 'select'),
              ),
            if (update != null)
              ListTile(
                leading: Icon(
                  session.pinned ? Icons.push_pin_outlined : Icons.push_pin,
                ),
                title: Text(session.pinned ? 'Unpin' : 'Pin'),
                onTap: () => Navigator.pop(context, 'pin'),
              ),
            if (update != null)
              ListTile(
                leading: const Icon(Icons.archive_outlined),
                title: Text(session.archived ? 'Unarchive' : 'Archive'),
                onTap: () => Navigator.pop(context, 'archive'),
              ),
            if (rename != null)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Rename'),
                onTap: () => Navigator.pop(context, 'rename'),
              ),
            if (widget.onDeleteSession != null)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Delete'),
                titleTextStyle: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                ),
                onTap: () => Navigator.pop(context, 'delete'),
              ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    if (action == 'select') {
      _startSelection(session);
      return;
    }
    if (action == 'rename') {
      await _renameSession(session);
      return;
    }
    if (action == 'delete') {
      await _deleteSession(session);
      return;
    }
    if (action == 'pin') {
      await _updateFlag(session, pinned: !session.pinned);
    } else if (action == 'archive') {
      await _updateFlag(session, archived: !session.archived);
    }
  }

  /// Confirms and performs the irreversible deletion of [session].
  Future<void> _deleteSession(Session session) async {
    final deleter = widget.onDeleteSession;
    if (deleter == null || _updatingFlags.contains(session.id)) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete this conversation?'),
        content: Text(
          '“${session.title}” and its full history will be permanently '
          'removed. Archiving keeps it; deleting cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _updatingFlags.add(session.id));
    try {
      await deleter(session);
      if (!mounted) return;
      setState(() => _updatingFlags.remove(session.id));
      await _load();
    } catch (_) {
      if (!mounted) return;
      setState(() => _updatingFlags.remove(session.id));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Couldn’t delete conversation')),
      );
    }
  }

  Future<void> _renameSession(Session session) async {
    final rename = widget.onRenameSession;
    if (rename == null || _updatingFlags.contains(session.id)) return;
    final title = await showSessionNameDialog(
      context: context,
      title: 'Rename chat',
      initialValue: session.title,
      actionLabel: 'Rename',
    );
    if (title == null || title == session.title || !mounted) return;
    setState(() => _updatingFlags.add(session.id));
    try {
      await rename(session, title);
      if (!mounted) return;
      setState(() => _updatingFlags.remove(session.id));
      await _load();
    } catch (_) {
      if (!mounted) return;
      setState(() => _updatingFlags.remove(session.id));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Couldn’t rename conversation')),
      );
    }
  }

  Future<void> _setSearchMode(SessionSearchMode mode) async {
    final controller = _effectiveSearchController;
    if (controller == null || mode == _searchMode) return;
    if (mode == SessionSearchMode.ai && _aiSearchModel == null) {
      final selected = await _showAiModelSelector();
      if (selected == null) return;
    }
    setState(() {
      _searchRequestGeneration++;
      _searchMode = mode;
      _serverResults = null;
      _searchError = null;
      _serverQuery = '';
      _aiRewrittenQuery = null;
    });
    await controller.setMode(mode);
    if (mode != SessionSearchMode.local) {
      _onSearchChanged(_query);
    }
  }

  void _onSearchChanged(String raw) {
    setState(() => _query = raw);
    if (!_hasSearchController || _searchMode == SessionSearchMode.local) {
      return;
    }

    _searchDebounceTimer?.cancel();
    final query = raw.trim();
    if (query.isEmpty) {
      setState(() {
        _searchRequestGeneration++;
        _serverResults = null;
        _searchError = null;
        _searching = false;
        _serverQuery = '';
        _aiRewrittenQuery = null;
      });
      return;
    }
    _searchDebounceTimer = Timer(
      _searchDebounce,
      () => _runServerSearch(query),
    );
  }

  Future<void> _runServerSearch(String query) async {
    final controller = _effectiveSearchController;
    if (!mounted || controller == null || query.isEmpty) return;
    final requestGeneration = ++_searchRequestGeneration;
    setState(() {
      _searching = true;
      _searchError = null;
    });

    bool requestIsCurrent() =>
        mounted &&
        requestGeneration == _searchRequestGeneration &&
        _query.trim() == query;

    try {
      final result = await controller.resolve(query);
      if (!requestIsCurrent()) return;
      setState(() {
        _serverResults = result.hits;
        _serverQuery = query;
        _aiRewrittenQuery = result.rewrittenQuery;
        _searching = false;
      });
    } on AiSearchRewriteException catch (error) {
      if (!requestIsCurrent()) return;
      setState(() {
        _searchError = error.message;
        _serverResults = null;
        _searching = false;
      });
    } on SessionSearchException catch (error) {
      if (!requestIsCurrent()) return;
      setState(() {
        _searchError = error.message;
        _serverResults = null;
        _searching = false;
      });
    } catch (error) {
      if (!requestIsCurrent()) return;
      setState(() {
        _searchError = 'Session search failed: $error';
        _serverResults = null;
        _searching = false;
      });
    }
  }

  Future<AiSearchModel?> _showAiModelSelector() async {
    final controller = _effectiveSearchController;
    if (controller == null || _loadingAiModels) return null;
    setState(() => _loadingAiModels = true);
    try {
      final choices = await controller.availableModels();
      if (choices.isEmpty) {
        throw StateError('Hermes returned no configured selectable models.');
      }

      if (!mounted) return null;
      final selection = await showModalBottomSheet<AiSearchModel>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (sheetContext) => SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(sheetContext).height * 0.75,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'AI search model',
                        style: Theme.of(sheetContext).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'The model only rewrites your question into a short '
                        'full-text query. Hermes uses the provider credentials '
                        'already configured on the host.',
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView.builder(
                    itemCount: choices.length,
                    itemBuilder: (_, index) {
                      final choice = choices[index];
                      final isSelected =
                          _aiSearchModel?.provider == choice.provider &&
                          _aiSearchModel?.model == choice.model;
                      return ListTile(
                        leading: Icon(
                          choice.isRecommended
                              ? Icons.savings_outlined
                              : Icons.smart_toy_outlined,
                        ),
                        title: Text(choice.model),
                        subtitle: Text(
                          choice.isRecommended
                              ? '${choice.provider} • Recommended: small and inexpensive'
                              : choice.provider,
                        ),
                        trailing: isSelected
                            ? const Icon(Icons.check_circle)
                            : null,
                        onTap: () => Navigator.pop(sheetContext, choice),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      if (selection == null || !mounted) return null;
      setState(() => _aiSearchModel = selection);
      await controller.setAiModel(selection);
      if (_searchMode == SessionSearchMode.ai && _query.trim().isNotEmpty) {
        unawaited(_runServerSearch(_query.trim()));
      }
      return selection;
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not load AI search models: $error')),
        );
      }
      return null;
    } finally {
      if (mounted) setState(() => _loadingAiModels = false);
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
    final tokens = HermesTokens.of(context);
    final serverMode =
        _hasSearchController && _searchMode != SessionSearchMode.local;
    final aiMode = _hasSearchController && _searchMode == SessionSearchMode.ai;
    final serverHitsCurrent = serverMode && _serverQuery == _query.trim()
        ? _serverResults
        : null;

    final sessions = serverMode
        ? (serverHitsCurrent?.map((hit) => hit.session).toList() ??
              const <Session>[])
        : widget.embedded
        ? filterChats(
            sessions: data.sessions,
            filter: _filter,
            claimedSessionIds: data.claimedSessionIds,
            archivedQuickChatIds: data.archivedQuickChatIds,
            query: _query,
            now: _now,
          )
        : filterWorkspaceSessions(
            sessions: data.sessions,
            view: widget.view,
            claimedSessionIds: data.claimedSessionIds,
            archivedQuickChatIds: data.archivedQuickChatIds,
            query: _query,
          );

    final snippetsBySession = <String, String>{
      for (final hit in serverHitsCurrent ?? const <SessionSearchHit>[])
        hit.session.id: hit.snippet,
    };

    final groups = widget.embedded
        ? groupChatsByDate(_now, sessions)
        : [
            MapEntry(
              ChatDateBucket.today,
              List<Session>.unmodifiable(sessions),
            ),
          ];

    // The standalone Search route and the embedded Chats browser both gain the
    // mode menu once a controller is available. The old embedded gate existed
    // only because the Chats destination never supplied a controller; with the
    // lazy factory it does, so the browser offers the same AI search its users
    // expect from the standalone route.
    final showSearchModes = _hasSearchController;

    return RefreshIndicator(
      onRefresh: serverMode && _query.trim().isNotEmpty
          ? () => _runServerSearch(_query.trim())
          : _load,
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
            autofocus: widget.view == WorkspaceSessionView.search,
            decoration: InputDecoration(
              hintText: aiMode
                  ? 'Ask AI to find a conversation'
                  : serverMode
                  ? 'Search all message content'
                  : 'Search conversations',
              prefixIcon: _searching
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : const Icon(Icons.search),
              suffixIcon: _query.isEmpty && !showSearchModes
                  ? null
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_query.isNotEmpty)
                          IconButton(
                            tooltip: 'Clear search',
                            onPressed: () {
                              _searchDebounceTimer?.cancel();
                              setState(() {
                                _query = '';
                                _searchRequestGeneration++;
                                _serverResults = null;
                                _searchError = null;
                                _serverQuery = '';
                                _aiRewrittenQuery = null;
                                _searching = false;
                              });
                            },
                            icon: const Icon(Icons.clear),
                          ),
                        if (aiMode)
                          IconButton(
                            tooltip: 'Change AI search model',
                            onPressed: _loadingAiModels
                                ? null
                                : _showAiModelSelector,
                            icon: _loadingAiModels
                                ? const SizedBox.square(
                                    dimension: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.tune),
                          ),
                        if (showSearchModes)
                          PopupMenuButton<SessionSearchMode>(
                            tooltip: 'Search mode',
                            icon: Icon(
                              aiMode
                                  ? Icons.auto_awesome
                                  : serverMode
                                  ? Icons.manage_search
                                  : Icons.phone_android,
                            ),
                            onSelected: _setSearchMode,
                            itemBuilder: (_) => [
                              CheckedPopupMenuItem(
                                value: SessionSearchMode.local,
                                checked: !serverMode,
                                child: const ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  leading: Icon(Icons.phone_android),
                                  title: Text('On-device'),
                                  subtitle: Text(
                                    'Titles, previews, and models',
                                  ),
                                ),
                              ),
                              CheckedPopupMenuItem(
                                value: SessionSearchMode.server,
                                checked:
                                    _searchMode == SessionSearchMode.server,
                                child: const ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  leading: Icon(Icons.manage_search),
                                  title: Text('Full-text'),
                                  subtitle: Text('All stored message content'),
                                ),
                              ),
                              CheckedPopupMenuItem(
                                value: SessionSearchMode.ai,
                                checked: aiMode,
                                child: ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  leading: const Icon(Icons.auto_awesome),
                                  title: const Text('AI + full-text'),
                                  subtitle: Text(
                                    _aiSearchModel == null
                                        ? 'Choose a small model to rewrite queries'
                                        : '${_aiSearchModel!.provider} • ${_aiSearchModel!.model}',
                                  ),
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
            ),
            onChanged: _onSearchChanged,
            onSubmitted: (value) {
              _searchDebounceTimer?.cancel();
              if (serverMode && value.trim().isNotEmpty) {
                _runServerSearch(value.trim());
              }
            },
          ),
          if (widget.embedded) ...[
            const SizedBox(height: HermesSpacing.md),
            _buildChips(),
          ],
          if (_selectedSessionIds.isNotEmpty) ...[
            const SizedBox(height: HermesSpacing.md),
            _buildBatchToolbar(),
          ],
          if (aiMode && _aiRewrittenQuery != null) ...[
            const SizedBox(height: HermesSpacing.sm),
            Row(
              children: [
                Icon(Icons.auto_awesome, size: 16, color: tokens.muted),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'AI searched for: $_aiRewrittenQuery',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: tokens.typography.label.copyWith(
                      color: tokens.muted,
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (_searchError != null) ...[
            const SizedBox(height: HermesSpacing.sm),
            _buildSearchError(tokens),
          ],
          const SizedBox(height: HermesSpacing.lg),
          if (serverMode &&
              _query.trim().isNotEmpty &&
              !_searching &&
              _searchError == null &&
              serverHitsCurrent != null &&
              serverHitsCurrent.isEmpty)
            EmptyState(
              icon: Icons.search_off,
              title: 'No message-content matches',
              message: 'Try a different phrase, or switch to on-device search.',
            )
          else if (sessions.isEmpty)
            EmptyState(
              icon: _emptyIcon,
              title: _query.isEmpty ? 'Nothing here' : 'No matches',
              message: _emptyMessage,
            )
          else
            for (final group in groups) ...[
              Padding(
                padding: const EdgeInsets.only(
                  top: HermesSpacing.xs,
                  bottom: HermesSpacing.sm,
                ),
                child: Text(
                  widget.embedded ? group.key.label : widget.title,
                  style: HermesTokens.of(context).typography.section,
                ),
              ),
              for (final session in group.value)
                Padding(
                  padding: const EdgeInsets.only(bottom: HermesSpacing.sm),
                  child: _buildSessionRow(
                    session,
                    data,
                    snippet: snippetsBySession[session.id],
                  ),
                ),
            ],
        ],
      ),
    );
  }

  Widget _buildBatchToolbar() {
    final tokens = HermesTokens.of(context);
    return Material(
      color: tokens.raised,
      borderRadius: BorderRadius.circular(HermesRadius.md),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: HermesSpacing.sm,
          vertical: HermesSpacing.xs,
        ),
        child: Row(
          children: [
            IconButton(
              tooltip: 'Cancel selection',
              onPressed: _batchActionRunning ? null : _clearSelection,
              icon: const Icon(Icons.close),
            ),
            Expanded(
              child: Text(
                '${_selectedSessionIds.length} selected',
                style: tokens.typography.label,
              ),
            ),
            if (_batchActionRunning)
              const Padding(
                padding: EdgeInsets.all(HermesSpacing.sm),
                child: SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else ...[
              if (widget.onUpdateFlags != null)
                IconButton(
                  tooltip: 'Pin selected',
                  onPressed: () => unawaited(
                    _updateSelectedFlag(pinned: true, archived: false),
                  ),
                  icon: const Icon(Icons.push_pin_outlined),
                ),
              if (widget.onMoveSession != null)
                IconButton(
                  tooltip: 'Move selected',
                  onPressed: () => unawaited(_chooseBatchMoveDestination()),
                  icon: const Icon(Icons.drive_file_move_outline),
                ),
              if (widget.onUpdateFlags != null)
                IconButton(
                  tooltip: 'Archive selected',
                  onPressed: () => unawaited(
                    _updateSelectedFlag(pinned: false, archived: true),
                  ),
                  icon: const Icon(Icons.archive_outlined),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSearchError(HermesTokens tokens) {
    return Material(
      color: tokens.raised,
      borderRadius: BorderRadius.circular(HermesRadius.md),
      child: Padding(
        padding: const EdgeInsets.all(HermesSpacing.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, color: tokens.danger),
            const SizedBox(width: HermesSpacing.sm),
            Expanded(
              child: Text(
                _searchError!,
                style: tokens.typography.body.copyWith(color: tokens.danger),
              ),
            ),
            TextButton(
              onPressed: () => _setSearchMode(SessionSearchMode.local),
              child: const Text('Use on-device'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChips() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final filter in WorkspaceChatsFilter.values)
            Padding(
              padding: const EdgeInsets.only(right: HermesSpacing.sm),
              child: ChoiceChip(
                label: Text(filter.label),
                selected: _filter == filter,
                onSelected: (_) => setState(() => _filter = filter),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSessionRow(
    Session session,
    WorkspaceSessionsData data, {
    String? snippet,
  }) {
    final tokens = HermesTokens.of(context);
    final projectLabel = data.projectLabels[session.id];
    final showPromote =
        widget.view == WorkspaceSessionView.archivedQuick &&
        widget.onPromote != null;
    final showMove = widget.onMoveSession != null;
    final showActions =
        widget.onUpdateFlags != null ||
        widget.onMoveSession != null ||
        widget.onRenameSession != null ||
        widget.onDeleteSession != null;
    final selectionActive = _selectedSessionIds.isNotEmpty;
    final selected = _selectedSessionIds.contains(session.id);
    return HermesCard(
      onTap: selectionActive
          ? () => _toggleSelection(session)
          : () => widget.onOpenSession(session),
      onLongPress: selectionActive
          ? () => _toggleSelection(session)
          : showActions
          ? () => unawaited(_showSessionMenu(session))
          : null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (selectionActive) ...[
            Checkbox(
              key: Key('select-session-${session.id}'),
              value: selected,
              onChanged: _batchActionRunning
                  ? null
                  : (_) => _toggleSelection(session),
            ),
            const SizedBox(width: HermesSpacing.xs),
          ],
          Icon(
            session.pinned
                ? Icons.push_pin_outlined
                : Icons.chat_bubble_outline,
            size: 20,
            color: session.pinned ? tokens.accent : tokens.muted,
          ),
          const SizedBox(width: HermesSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  session.title.isEmpty ? 'Untitled chat' : session.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (snippet != null && snippet.isNotEmpty)
                  Text(
                    snippet,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: tokens.muted),
                  )
                else if (session.preview.isNotEmpty)
                  Text(
                    session.preview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: tokens.muted),
                  ),
                const SizedBox(height: HermesSpacing.xs),
                Wrap(
                  spacing: HermesSpacing.sm,
                  runSpacing: HermesSpacing.xs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    StatusChip(
                      status: session.isActive
                          ? HermesStatus.running
                          : HermesStatus.completed,
                      label: session.isActive ? 'Running' : 'Done',
                    ),
                    if (projectLabel != null)
                      _MetaChip(
                        label: projectLabel,
                        icon: Icons.folder_outlined,
                      )
                    else
                      _MetaChip(
                        label: 'Unassigned',
                        icon: Icons.inbox_outlined,
                      ),
                    Text(
                      _relativeTime(_now, session.lastActive),
                      style: tokens.typography.label.copyWith(
                        color: tokens.muted,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (showMove && !selectionActive)
            _moving.contains(session.id)
                ? const SizedBox.square(
                    dimension: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : IconButton(
                    key: Key('move-session-${session.id}'),
                    tooltip: 'Move conversation',
                    onPressed: () => unawaited(_chooseMoveDestination(session)),
                    icon: const Icon(Icons.drive_file_move_outline),
                  ),
          if (showPromote && !selectionActive)
            _promoting.contains(session.id)
                ? const SizedBox.square(
                    dimension: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : IconButton(
                    tooltip: 'Promote to project',
                    onPressed: () => unawaited(_promote(session)),
                    icon: const Icon(Icons.drive_file_move_outline),
                  ),
        ],
      ),
    );
  }

  IconData get _emptyIcon {
    if (widget.embedded) {
      return switch (_filter) {
        WorkspaceChatsFilter.unassigned => Icons.inbox_outlined,
        WorkspaceChatsFilter.archived => Icons.archive_outlined,
        WorkspaceChatsFilter.recent => Icons.history_outlined,
        WorkspaceChatsFilter.pinned => Icons.push_pin_outlined,
        WorkspaceChatsFilter.all => Icons.search_off,
      };
    }
    return widget.view == WorkspaceSessionView.unassigned
        ? Icons.inbox_outlined
        : Icons.search_off;
  }

  String get _emptyMessage {
    if (widget.embedded) {
      return switch (_filter) {
        WorkspaceChatsFilter.unassigned =>
          'Every conversation is already assigned to a Project.',
        WorkspaceChatsFilter.archived => 'Archived conversations appear here.',
        WorkspaceChatsFilter.pinned =>
          'Pinned conversations appear here. Long-press a chat and choose '
              'Pin to keep it in reach.',
        WorkspaceChatsFilter.recent =>
          'Nothing changed in the last seven days.',
        WorkspaceChatsFilter.all => 'No conversation matches this view.',
      };
    }
    return switch (widget.view) {
      WorkspaceSessionView.unassigned =>
        'Every conversation is already assigned to a Project.',
      WorkspaceSessionView.archivedQuick =>
        'Quick chats appear here after their retention period.',
      WorkspaceSessionView.all ||
      WorkspaceSessionView.search => 'No conversation matches this view.',
    };
  }

  /// Compact relative time: "now", "5m", "2h", "3d", else a date.
  String _relativeTime(DateTime now, double lastActiveSeconds) =>
      formatRelativeTime(now, lastActiveSeconds);
}

/// A small neutral label under a conversation row (project, unassigned).
class _MetaChip extends StatelessWidget {
  final String label;
  final IconData icon;

  const _MetaChip({required this.label, required this.icon});

  @override
  Widget build(BuildContext context) {
    final tokens = HermesTokens.of(context);
    return Semantics(
      label: label,
      container: true,
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: HermesSpacing.sm,
            vertical: HermesSpacing.xs,
          ),
          decoration: BoxDecoration(
            color: tokens.raised,
            borderRadius: BorderRadius.circular(HermesRadius.sm),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 12, color: tokens.muted),
              const SizedBox(width: 4),
              Text(label, style: tokens.typography.label),
            ],
          ),
        ),
      ),
    );
  }
}

class _MoveTarget {
  final String? projectId;
  final String label;

  const _MoveTarget({required this.projectId, required this.label});
}
