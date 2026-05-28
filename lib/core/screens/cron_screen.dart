/// Cron job browser screen — list and manage Hermes scheduled cron jobs.
import 'package:flutter/material.dart';
import '../services/connection_manager.dart';

class CronScreen extends StatefulWidget {
  final SavedConnection connection;
  const CronScreen({required this.connection, super.key});

  @override
  State<CronScreen> createState() => _CronScreenState();
}

class _CronScreenState extends State<CronScreen> {
  late ApiClient _client;
  List<Map<String, dynamic>> _jobs = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _client = ApiClient();
    _loadJobs();
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }

  Future<void> _loadJobs() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final data = await _client.apiGet(widget.connection.baseUrl, 'cron');
      final jobs = data['jobs'] as List? ?? [];
      setState(() {
        _jobs = jobs.cast<Map<String, dynamic>>();
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _toggleJob(Map<String, dynamic> job) async {
    final jobId = job['id'] as String? ?? '';
    final isPaused = job['paused'] == true;
    final action = isPaused ? 'resume' : 'pause';

    try {
      await _client.apiPost(widget.connection.baseUrl, 'cron/$jobId/$action', {});
      setState(() {
        job['paused'] = !isPaused;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(isPaused ? 'Job resumed' : 'Job paused')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: $e'), backgroundColor: Colors.orange),
        );
      }
    }
  }

  Future<void> _deleteJob(Map<String, dynamic> job) async {
    final jobId = job['id'] as String? ?? '';
    final name = job['name'] as String? ?? jobId;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Cron Job'),
        content: Text('Delete "$name"? This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await _client.apiPost(widget.connection.baseUrl, 'cron/$jobId/remove', {});
      setState(() => _jobs.removeWhere((j) => j['id'] == jobId));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Deleted "$name"')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Delete failed: $e'), backgroundColor: Colors.orange),
        );
      }
    }
  }

  Future<void> _runJob(Map<String, dynamic> job) async {
    final jobId = job['id'] as String? ?? '';
    try {
      await _client.apiPost(widget.connection.baseUrl, 'cron/$jobId/run', {});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Job triggered')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: $e'), backgroundColor: Colors.orange),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cron Jobs'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _loadJobs,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.orange),
              const SizedBox(height: 16),
              Text('Failed to load cron jobs',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(_error!, style: Theme.of(context).textTheme.bodySmall,
                  textAlign: TextAlign.center),
              const SizedBox(height: 24),
              ElevatedButton(onPressed: _loadJobs, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }

    if (_jobs.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.schedule, size: 48, color: Colors.grey),
            const SizedBox(height: 16),
            Text('No cron jobs',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              'Cron jobs run scheduled tasks on the Hermes instance',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadJobs,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _jobs.length,
        itemBuilder: (context, index) {
          final job = _jobs[index];
          final name = job['name'] as String? ?? job['id'] as String? ?? 'Untitled';
          final schedule = job['schedule'] as String? ?? '';
          final isPaused = job['paused'] == true;
          final lastRun = job['last_run'] as String?;
          final nextRun = job['next_run'] as String?;

          return Dismissible(
            key: Key('${job['id']}-$index'),
            direction: DismissDirection.endToStart,
            background: Container(
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 20),
              color: Colors.red,
              child: const Icon(Icons.delete, color: Colors.white),
            ),
            confirmDismiss: (_) async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Delete Cron Job'),
                  content: Text('Delete "$name"?'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                    FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      style: FilledButton.styleFrom(backgroundColor: Colors.red),
                      child: const Text('Delete'),
                    ),
                  ],
                ),
              );
              return confirmed ?? false;
            },
            onDismissed: (_) => _deleteJob(job),
            child: Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          isPaused ? Icons.pause_circle : Icons.play_circle,
                          color: isPaused ? Colors.orange : Colors.green,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            name,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.play_arrow, size: 20),
                              onPressed: () => _runJob(job),
                              tooltip: 'Run now',
                            ),
                            IconButton(
                              icon: Icon(isPaused ? Icons.play_arrow : Icons.pause, size: 20),
                              onPressed: () => _toggleJob(job),
                              tooltip: isPaused ? 'Resume' : 'Pause',
                            ),
                          ],
                        ),
                      ],
                    ),
                    if (schedule.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text('Schedule: $schedule',
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            color: Colors.grey,
                          )),
                    ],
                    if (lastRun != null) ...[
                      const SizedBox(height: 2),
                      Text('Last: $lastRun', style: const TextStyle(fontSize: 11, color: Colors.grey)),
                    ],
                    if (nextRun != null) ...[
                      Text('Next: $nextRun', style: const TextStyle(fontSize: 11, color: Colors.grey)),
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
