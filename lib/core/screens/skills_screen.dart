// Skills browser — list installed skills with enabled/disabled status.
import 'package:flutter/material.dart';
import '../services/connection_manager.dart';

/// Creates the dashboard client for a connection. Injectable so widget tests
/// can substitute a mock transport without reaching the network.
typedef SkillsDashboardClientFactory =
    DashboardClient Function(SavedConnection connection);

DashboardClient _defaultSkillsDashboardClient(SavedConnection connection) {
  return DashboardClient(
    host: connection.host,
    port: connection.dashboardPort,
    pathPrefix: connection.dashboardPrefix ?? '',
    proxied: connection.dashboardProxied,
    useHttps: connection.useHttps,
    username: connection.dashboardUsername,
    password: connection.dashboardPassword,
  );
}

class SkillsScreen extends StatefulWidget {
  final SavedConnection connection;

  /// Overrides client construction for tests.
  final SkillsDashboardClientFactory? clientFactory;

  const SkillsScreen({required this.connection, this.clientFactory, super.key});

  @override
  State<SkillsScreen> createState() => _SkillsScreenState();
}

class _SkillsScreenState extends State<SkillsScreen> {
  late DashboardClient _client;
  List<Map<String, dynamic>> _skills = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    final factory = widget.clientFactory ?? _defaultSkillsDashboardClient;
    _client = factory(widget.connection);
    _load();
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final raw = await _client.getSkills();
      if (!mounted) return;
      setState(() {
        _skills = raw.whereType<Map<String, dynamic>>().toList();
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

  @override
  Widget build(BuildContext context) {
    // The count only means something once data has loaded — showing "(0)"
    // during load or on error would report a false "0 skills".
    final count = _loading || _error != null ? '' : ' (${_skills.length})';
    return Scaffold(
      appBar: AppBar(
        title: Text('Skills$count'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.orange),
              const SizedBox(height: 16),
              Text(
                'Failed to load skills',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                _error!,
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              ElevatedButton(onPressed: _load, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }
    if (_skills.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.extension_off, size: 48, color: Colors.grey[600]),
            const SizedBox(height: 16),
            Text(
              'No skills found',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _skills.length,
        itemBuilder: (_, i) {
          final skill = _skills[i];
          final name = skill['name'] as String? ?? '';
          final enabled = skill['enabled'] as bool? ?? false;
          final description = skill['description'] as String? ?? '';
          return Card(
            margin: const EdgeInsets.only(bottom: 6),
            child: ListTile(
              dense: true,
              title: Text(
                name,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              ),
              subtitle: description.isNotEmpty
                  ? Text(
                      description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    )
                  : null,
              trailing: Icon(
                enabled ? Icons.check_circle : Icons.block,
                color: enabled ? Colors.green : Colors.orange,
                size: 18,
              ),
            ),
          );
        },
      ),
    );
  }
}
