import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/session_search_hit.dart';
import '../services/connection_manager.dart';
import '../services/desktop_gateway_client.dart';
import '../services/gateway_turn_application_controller.dart';
import '../services/session_search_client.dart';
import '../services/session_search_preferences.dart';
import '../services/ws_client.dart';
import 'chat_screen.dart';
import 'settings_screen.dart';
import 'memory_screen.dart';
import 'cron_screen.dart';
import 'skills_screen.dart';

Future<String?> showSessionNameDialog({
  required BuildContext context,
  required String title,
  required String initialValue,
  required String actionLabel,
}) async {
  var draft = initialValue;
  final result = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: TextFormField(
        initialValue: initialValue,
        autofocus: true,
        maxLength: 120,
        decoration: const InputDecoration(border: OutlineInputBorder()),
        onChanged: (value) => draft = value,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, draft.trim()),
          child: Text(actionLabel),
        ),
      ],
    ),
  );
  return result?.trim().isEmpty == true ? null : result;
}

class SessionListScreen extends StatefulWidget {
  final SavedConnection connection;
  final GatewayTurnApplicationController turnApplicationController;

  const SessionListScreen({
    required this.connection,
    required this.turnApplicationController,
    super.key,
  });

  @override
  State<SessionListScreen> createState() => _SessionListScreenState();
}

class _SessionListScreenState extends State<SessionListScreen> {
  /// Debounce window before a typed query is sent to the dashboard. Local
  /// search filters in-memory on every keystroke; server search must not.
  static const _searchDebounce = Duration(milliseconds: 350);

  late final ApiClient _client;
  DesktopGatewayClient? _desktopGateway;
  final _searchController = TextEditingController();
  List<SavedConnection> _profiles = const [];
  List<Session> _sessions = [];
  bool _loading = true;
  String? _error;
  bool _healthOk = false;
  final Set<String> _deletingSessionIds = {};
  final Set<String> _branchingSessionIds = {};

  SessionSearchPreferences? _searchPreferences;
  SessionSearchMode _searchMode = SessionSearchMode.local;
  DashboardClient? _searchDashboard;
  SessionSearchClient? _searchClient;
  Timer? _searchDebounceTimer;

  /// Query currently reflected by [_serverResults]; guards against an earlier
  /// slow response overwriting the results of a newer query.
  String _serverQuery = '';
  List<SessionSearchHit>? _serverResults;
  bool _searching = false;
  String? _searchError;

  @override
  void initState() {
    super.initState();
    _client = ApiClient(
      baseUrl: widget.connection.baseUrl,
      apiKey: widget.connection.apiKey,
      pathPrefix: widget.connection.gatewayPrefix ?? '',
    );
    if (widget.connection.desktopGatewayUrl?.trim().isNotEmpty == true) {
      try {
        _desktopGateway = DesktopGatewayClient.fromConnection(
          widget.connection,
        );
      } on ArgumentError {
        _desktopGateway = null;
      }
    }
    _loadProfiles();
    _loadSearchPreferences();
    _checkHealth();
  }

  /// Restores the saved search mode for this connection.
  ///
  /// Failing to read preferences must not break the session list, so any
  /// error leaves the local default in place.
  Future<void> _loadSearchPreferences() async {
    try {
      final preferences = await SessionSearchPreferences.open();
      if (!mounted) return;
      setState(() {
        _searchPreferences = preferences;
        _searchMode = preferences.readMode(
          connectionIdentity: _searchConnectionIdentity,
        );
      });
    } catch (_) {
      // Keep SessionSearchMode.local.
    }
  }

  /// Namespaces stored search preferences, matching the chat model override
  /// convention so two connections to the same host stay independent.
  String get _searchConnectionIdentity =>
      '${widget.connection.baseUrl}|'
      '${widget.connection.gatewayPrefix ?? ''}|'
      '${widget.connection.desktopGatewayUrl ?? ''}';

  /// Server search reaches the dashboard, which the gateway connection alone
  /// does not guarantee is reachable.
  bool get _serverSearchAvailable =>
      widget.connection.host.trim().isNotEmpty;

  SessionSearchClient _ensureSearchClient() {
    final existing = _searchClient;
    if (existing != null) return existing;

    final dashboard = DashboardClient(
      host: widget.connection.host,
      port: widget.connection.dashboardPort,
      pathPrefix: widget.connection.dashboardPrefix ?? '',
      proxied: widget.connection.dashboardProxied,
      useHttps: widget.connection.useHttps,
      username: widget.connection.dashboardUsername,
      password: widget.connection.dashboardPassword,
    );
    final created = SessionSearchClient(
      baseUrl: dashboard.baseUrl,
      headers: dashboard.authHeaders,
    );
    _searchDashboard = dashboard;
    _searchClient = created;
    return created;
  }

  Future<void> _setSearchMode(SessionSearchMode mode) async {
    if (mode == _searchMode) return;
    setState(() {
      _searchMode = mode;
      _serverResults = null;
      _searchError = null;
      _serverQuery = '';
    });
    await _searchPreferences?.saveMode(
      connectionIdentity: _searchConnectionIdentity,
      mode: mode,
    );
    if (mode == SessionSearchMode.server) {
      _onSearchChanged(_searchController.text);
    }
  }

  /// Handles a keystroke in the search bar.
  ///
  /// Local mode only needs a rebuild. Server mode debounces so typing a word
  /// issues one request instead of one per character.
  void _onSearchChanged(String raw) {
    setState(() {});
    if (_searchMode != SessionSearchMode.server) return;

    _searchDebounceTimer?.cancel();
    final query = raw.trim();
    if (query.isEmpty) {
      setState(() {
        _serverResults = null;
        _searchError = null;
        _searching = false;
        _serverQuery = '';
      });
      return;
    }
    _searchDebounceTimer = Timer(_searchDebounce, () => _runServerSearch(query));
  }

  Future<void> _runServerSearch(String query) async {
    if (!mounted || query.isEmpty) return;
    setState(() {
      _searching = true;
      _searchError = null;
    });

    try {
      final hits = await _ensureSearchClient().search(query);
      // A slower earlier request must not overwrite newer results.
      if (!mounted || _searchController.text.trim() != query) return;
      setState(() {
        _serverResults = hits;
        _serverQuery = query;
        _searching = false;
      });
    } on SessionSearchException catch (error) {
      if (!mounted || _searchController.text.trim() != query) return;
      setState(() {
        _searchError = error.message;
        _serverResults = null;
        _searching = false;
      });
    } catch (error) {
      if (!mounted || _searchController.text.trim() != query) return;
      setState(() {
        _searchError = 'Session search failed: $error';
        _serverResults = null;
        _searching = false;
      });
    }
  }

  Future<void> _loadProfiles() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _profiles = ConnectionManager(prefs).getConnections());
  }

  Future<void> _switchProfile(String profileId) async {
    if (profileId == widget.connection.id) return;
    final profile = _profiles.where((item) => item.id == profileId).firstOrNull;
    if (profile == null) return;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('last_connection_id', profile.id);
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => SessionListScreen(
          connection: profile,
          turnApplicationController: widget.turnApplicationController,
        ),
      ),
    );
  }

  PopupMenuButton<String> _buildProfileSelector() {
    return PopupMenuButton<String>(
      tooltip: 'Switch profile',
      icon: const Icon(Icons.account_tree_outlined),
      onSelected: _switchProfile,
      itemBuilder: (context) => [
        const PopupMenuItem<String>(
          enabled: false,
          child: Text('Profile', style: TextStyle(fontWeight: FontWeight.w700)),
        ),
        ..._profiles.map(
          (profile) => PopupMenuItem<String>(
            value: profile.id,
            child: Row(
              children: [
                Icon(
                  profile.id == widget.connection.id
                      ? Icons.check_circle
                      : Icons.circle_outlined,
                  size: 18,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(profile.label, overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _checkHealth() async {
    final ok = await _client.healthCheck();
    setState(() => _healthOk = ok);
    if (ok) _fetchSessions();
  }

  @override
  void dispose() {
    _searchDebounceTimer?.cancel();
    _searchClient?.close();
    _searchDashboard?.close();
    _searchController.dispose();
    _desktopGateway?.close();
    _client.close();
    super.dispose();
  }

  Future<String?> _askForName({
    required String title,
    required String initialValue,
    required String actionLabel,
  }) => showSessionNameDialog(
    context: context,
    title: title,
    initialValue: initialValue,
    actionLabel: actionLabel,
  );

  Future<void> _renameSession(Session session) async {
    final gateway = _desktopGateway;
    if (gateway == null) return;
    final title = await _askForName(
      title: 'Rename chat',
      initialValue: session.title,
      actionLabel: 'Rename',
    );
    if (title == null || !mounted) return;
    try {
      await gateway.renameSession(sessionId: session.id, title: title);
      await _fetchSessions();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not rename chat: $error')));
    }
  }

  Future<void> _branchSession(Session session) async {
    final gateway = _desktopGateway;
    if (gateway == null || _branchingSessionIds.contains(session.id)) return;
    final knownSessionIds = _sessions.map((item) => item.id).toSet();
    String? requestedName;
    setState(() => _branchingSessionIds.add(session.id));
    try {
      final name = await _askForName(
        title: 'Branch chat',
        initialValue: '${session.title} branch',
        actionLabel: 'Create branch',
      );
      if (name == null || !mounted) return;
      requestedName = name;
      await gateway.branchSession(sessionId: session.id, name: name);
      await _fetchSessions();
      if (!mounted) return;
      _showBranchCreated();
    } catch (error) {
      if (!mounted) return;
      await _fetchSessions();
      if (!mounted) return;
      final branchAppeared = _sessions.any(
        (item) =>
            !knownSessionIds.contains(item.id) &&
            requestedName != null &&
            item.title.trim().toLowerCase() ==
                requestedName.trim().toLowerCase(),
      );
      if (branchAppeared) {
        _showBranchCreated();
        return;
      }
      final message = error is JsonRpcError && error.code == 4008
          ? 'This chat has no messages available in the Desktop session yet.'
          : 'Could not branch chat: $error';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) {
        setState(() => _branchingSessionIds.remove(session.id));
      }
    }
  }

  void _showBranchCreated() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Branch created in Hermes history.')),
    );
  }

  Future<void> _handleSessionAction(String action, Session session) async {
    // PopupMenuButton invokes this while its route is still being removed.
    // Defer route-producing actions so Flutter has completed that teardown.
    await Future<void>.delayed(kThemeAnimationDuration);
    if (!mounted) return;
    switch (action) {
      case 'rename':
        await _renameSession(session);
      case 'branch':
        await _branchSession(session);
      case 'delete':
        await _confirmDeleteSession(session);
    }
  }

  Future<void> _fetchSessions() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final sessions = await _client.getSessions();
      if (!mounted) return;
      final prefs = await SharedPreferences.getInstance();
      final key = 'excluded_session_sources_${widget.connection.id}';
      final excluded = prefs.getStringList(key) ?? [];
      final filtered = sessions
          .where((s) => !excluded.contains(s.source))
          .toList();
      if (!mounted) return;
      setState(() {
        _sessions = filtered;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _confirmDeleteSession(Session session) async {
    final title = session.title.trim().isEmpty
        ? 'Untitled session'
        : session.title;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete session?'),
        content: Text(
          'Delete "$title" from the remote Hermes history? This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _deleteSession(session);
    }
  }

  Future<void> _deleteSession(Session session) async {
    if (_deletingSessionIds.contains(session.id)) return;
    setState(() => _deletingSessionIds.add(session.id));

    try {
      await _client.deleteSession(session.id);
      if (!mounted) return;
      setState(() {
        _sessions.removeWhere((item) => item.id == session.id);
        _deletingSessionIds.remove(session.id);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Session deleted from remote Hermes.')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _deletingSessionIds.remove(session.id));
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not delete session: $e')));
    }
  }

  void _createNewSession() {
    final sessionId = GatewayChatClient.generateSessionId();
    final session = Session(
      id: sessionId,
      title: 'New Chat',
      model: 'hermes-agent',
      source: 'mobile',
      messageCount: 0,
      isActive: true,
      preview: '',
      startedAt: DateTime.now().millisecondsSinceEpoch.toDouble() / 1000,
    );
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          connection: widget.connection,
          session: session,
          turnApplicationController: widget.turnApplicationController,
        ),
      ),
    );
  }

  String _formatTime(double ts) {
    final dt = DateTime.fromMillisecondsSinceEpoch((ts * 1000).toInt());
    final now = DateTime.now();
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    return '${dt.day}/${dt.month}';
  }

  void _openScreen(Widget screen) {
    Navigator.pop(context); // close drawer
    Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'HERMES',
          style: TextStyle(fontFamily: 'Cinzel', 
            fontWeight: FontWeight.w700,
            letterSpacing: 6,
            fontSize: 22,
          ),
        ),
        centerTitle: true,
        actions: [
          _buildProfileSelector(),
          if (!_healthOk)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: Icon(Icons.warning_amber, color: Colors.orange, size: 20),
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _fetchSessions,
          ),
        ],
      ),
      drawer: _buildDrawer(),
      floatingActionButton: FloatingActionButton(
        tooltip: 'New Chat',
        onPressed: _createNewSession,
        child: const Icon(Icons.chat, color: Colors.black),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildDrawer() {
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            // Brand header in drawer
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
              color: Colors.black,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'HERMES',
                    style: TextStyle(fontFamily: 'Cinzel', 
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: const Color(0xFFD4AF37),
                      letterSpacing: 4,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    widget.connection.label,
                    style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                  ),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.memory),
              title: const Text('Memory'),
              onTap: () =>
                  _openScreen(MemoryScreen(connection: widget.connection)),
            ),
            ListTile(
              leading: const Icon(Icons.schedule),
              title: const Text('Cron Jobs'),
              onTap: () =>
                  _openScreen(CronScreen(connection: widget.connection)),
            ),
            ListTile(
              leading: const Icon(Icons.auto_awesome),
              title: const Text('Skills'),
              onTap: () =>
                  _openScreen(SkillsScreen(connection: widget.connection)),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.settings),
              title: const Text('Settings'),
              onTap: () =>
                  _openScreen(SettingsScreen(connection: widget.connection)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (!_healthOk) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 48,
              height: 48,
              child: CircularProgressIndicator(),
            ),
            const SizedBox(height: 16),
            Text(
              'Connecting to ${widget.connection.baseUrl}...',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Make sure the Gateway API Server is running\n(hermes gateway status)',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 24),
            ElevatedButton(onPressed: _checkHealth, child: const Text('Retry')),
          ],
        ),
      );
    }

    if (_loading) return const Center(child: CircularProgressIndicator());

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: Colors.orange),
            const SizedBox(height: 16),
            Text(
              'Connection issue',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                _error!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _fetchSessions,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    if (_sessions.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.chat_bubble_outline, size: 48, color: Colors.grey),
            const SizedBox(height: 16),
            Text(
              'No sessions yet',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              'Tap the + button to start a new chat',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      );
    }

    final rawQuery = _searchController.text.trim();
    final localQuery = rawQuery.toLowerCase();
    final serverMode = _searchMode == SessionSearchMode.server;
    final serverHitsCurrent =
        serverMode && _serverQuery == rawQuery ? _serverResults : null;
    final visibleSessions = rawQuery.isEmpty
        ? _sessions
        : serverMode
        ? (serverHitsCurrent?.map((hit) => hit.session).toList() ?? const [])
        : _sessions
              .where(
                (session) =>
                    session.title.toLowerCase().contains(localQuery) ||
                    session.preview.toLowerCase().contains(localQuery) ||
                    session.model.toLowerCase().contains(localQuery),
              )
              .toList();
    final snippetsBySession = <String, SessionSearchHit>{
      for (final hit in serverHitsCurrent ?? const <SessionSearchHit>[])
        hit.session.id: hit,
    };

    return RefreshIndicator(
      onRefresh: rawQuery.isNotEmpty && serverMode
          ? () => _runServerSearch(rawQuery)
          : _fetchSessions,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: visibleSessions.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SearchBar(
                    controller: _searchController,
                    leading: _searching
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : const Icon(Icons.search),
                    hintText: serverMode
                        ? 'Search all message content'
                        : 'Search loaded chats',
                    trailing: [
                      if (rawQuery.isNotEmpty)
                        IconButton(
                          tooltip: 'Clear search',
                          icon: const Icon(Icons.close),
                          onPressed: () {
                            _searchDebounceTimer?.cancel();
                            _searchController.clear();
                            setState(() {
                              _serverResults = null;
                              _searchError = null;
                              _serverQuery = '';
                              _searching = false;
                            });
                          },
                        ),
                      PopupMenuButton<SessionSearchMode>(
                        tooltip: 'Search mode',
                        icon: Icon(
                          serverMode ? Icons.manage_search : Icons.phone_android,
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
                              subtitle: Text('Titles, previews, and models'),
                            ),
                          ),
                          CheckedPopupMenuItem(
                            value: SessionSearchMode.server,
                            enabled: _serverSearchAvailable,
                            checked: serverMode,
                            child: const ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(Icons.manage_search),
                              title: Text('Full-text'),
                              subtitle: Text('All stored message content'),
                            ),
                          ),
                        ],
                      ),
                    ],
                    onChanged: _onSearchChanged,
                    onSubmitted: (value) {
                      _searchDebounceTimer?.cancel();
                      if (serverMode && value.trim().isNotEmpty) {
                        _runServerSearch(value.trim());
                      }
                    },
                  ),
                  if (_searchError != null) ...[
                    const SizedBox(height: 8),
                    Material(
                      color: Theme.of(context).colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              Icons.error_outline,
                              color: Theme.of(
                                context,
                              ).colorScheme.onErrorContainer,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                _searchError!,
                                style: TextStyle(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onErrorContainer,
                                ),
                              ),
                            ),
                            TextButton(
                              onPressed: () => _setSearchMode(
                                SessionSearchMode.local,
                              ),
                              child: const Text('Use on-device'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                  if (serverMode &&
                      rawQuery.isNotEmpty &&
                      !_searching &&
                      _searchError == null &&
                      serverHitsCurrent != null &&
                      serverHitsCurrent.isEmpty) ...[
                    const SizedBox(height: 16),
                    const Center(child: Text('No message-content matches')),
                  ],
                ],
              ),
            );
          }
          final session = visibleSessions[index - 1];
          final searchHit = snippetsBySession[session.id];
          final isDeleting = _deletingSessionIds.contains(session.id);
          final isBranching = _branchingSessionIds.contains(session.id);
          return Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              enabled: !isDeleting && !isBranching,
              leading: Icon(
                session.isActive ? Icons.chat : Icons.chat_bubble_outline,
                color: session.isActive ? const Color(0xFFD4AF37) : Colors.grey,
              ),
              trailing: isDeleting || isBranching
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : PopupMenuButton<String>(
                      tooltip: 'Chat actions',
                      onSelected: (action) =>
                          _handleSessionAction(action, session),
                      itemBuilder: (_) => [
                        if (_desktopGateway != null)
                          const PopupMenuItem(
                            value: 'rename',
                            child: ListTile(
                              leading: Icon(Icons.edit_outlined),
                              title: Text('Rename'),
                            ),
                          ),
                        if (_desktopGateway != null)
                          const PopupMenuItem(
                            value: 'branch',
                            child: ListTile(
                              leading: Icon(Icons.call_split_outlined),
                              title: Text('Branch'),
                            ),
                          ),
                        const PopupMenuItem(
                          value: 'delete',
                          child: ListTile(
                            leading: Icon(Icons.delete_outline),
                            title: Text('Delete'),
                          ),
                        ),
                      ],
                    ),
              title: Text(
                session.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${session.messageCount} msgs \u2022 ${session.model} \u2022 ${_formatTime(session.startedAt)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (searchHit?.snippet.isNotEmpty == true)
                    Text(
                      searchHit!.snippet,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    )
                  else if (session.preview.isNotEmpty)
                    Text(
                      session.preview,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: Colors.grey[500]),
                    ),
                ],
              ),
              isThreeLine:
                  searchHit?.snippet.isNotEmpty == true || session.preview.isNotEmpty,
              onLongPress: isDeleting ? null : () => _renameSession(session),
              onTap: isDeleting
                  ? null
                  : () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ChatScreen(
                            connection: widget.connection,
                            session: session,
                            turnApplicationController:
                                widget.turnApplicationController,
                          ),
                        ),
                      );
                    },
            ),
          );
        },
      ),
    );
  }
}
