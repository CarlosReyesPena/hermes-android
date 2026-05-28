/// Memory browser screen — view, add, and delete Hermes memory entries.
import 'package:flutter/material.dart';
import '../services/connection_manager.dart';

class MemoryScreen extends StatefulWidget {
  final SavedConnection connection;
  const MemoryScreen({required this.connection, super.key});

  @override
  State<MemoryScreen> createState() => _MemoryScreenState();
}

class _MemoryScreenState extends State<MemoryScreen> {
  late ApiClient _client;
  List<Map<String, dynamic>> _entries = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _client = ApiClient();
    _loadMemory();
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }

  Future<void> _loadMemory() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final data = await _client.getConfig(widget.connection.baseUrl);
      // Memory entries may be in config or at /api/memory
      // Try to fetch from /api/memory first, fall back to config.memory
      try {
        final memData = await _client.apiGet(
          widget.connection.baseUrl, 'memory',
        );
        final items = memData['entries'] as List? ?? memData['memory'] as List? ?? [];
        setState(() {
          _entries = items.cast<Map<String, dynamic>>();
          _loading = false;
        });
      } catch (_) {
        // Fallback: show memory from config
        final mem = data['memory'] as Map<String, dynamic>?;
        if (mem != null) {
          final entries = <Map<String, dynamic>>[];
          mem.forEach((key, value) {
            entries.add({'key': key, 'value': value.toString()});
          });
          setState(() {
            _entries = entries;
            _loading = false;
          });
        } else {
          setState(() {
            _entries = [];
            _loading = false;
          });
        }
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _addEntry() async {
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) => _MemoryFormDialog(),
    );
    if (result == null) return;

    // Optimistic add
    setState(() {
      _entries.insert(0, {'key': result['key'], 'value': result['value']});
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Memory added — refresh to sync with server')),
      );
    }
  }

  Future<void> _deleteEntry(int index) async {
    final entry = _entries[index];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Memory Entry'),
        content: Text('Delete "${entry['key']}"?'),
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

    setState(() => _entries.removeAt(index));

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Memory entry removed locally')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Memory'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: _loading ? null : _addEntry,
            tooltip: 'Add memory',
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _loadMemory,
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
              Text('Failed to load memory',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(_error!, style: Theme.of(context).textTheme.bodySmall,
                  textAlign: TextAlign.center),
              const SizedBox(height: 24),
              ElevatedButton(onPressed: _loadMemory, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }

    if (_entries.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.psychology, size: 48, color: Colors.grey),
            const SizedBox(height: 16),
            Text('No memory entries',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              'Memory entries are cross-session facts the agent remembers',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _addEntry,
              icon: const Icon(Icons.add),
              label: const Text('Add Entry'),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadMemory,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _entries.length,
        itemBuilder: (context, index) {
          final entry = _entries[index];
          final key = entry['key'] as String? ?? entry['target'] as String? ?? '';
          final value = entry['value'] as String? ?? entry['content'] as String? ?? '';
          return Dismissible(
            key: Key('$key-$index'),
            direction: DismissDirection.endToStart,
            background: Container(
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 20),
              color: Colors.red,
              child: const Icon(Icons.delete, color: Colors.white),
            ),
            onDismissed: (_) => _deleteEntry(index),
            child: Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(key, style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontFamily: 'monospace',
                      fontSize: 13,
                    )),
                    const SizedBox(height: 4),
                    Text(value, style: Theme.of(context).textTheme.bodyMedium),
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

class _MemoryFormDialog extends StatefulWidget {
  @override
  State<_MemoryFormDialog> createState() => _MemoryFormDialogState();
}

class _MemoryFormDialogState extends State<_MemoryFormDialog> {
  final _keyCtrl = TextEditingController();
  final _valueCtrl = TextEditingController();

  @override
  void dispose() {
    _keyCtrl.dispose();
    _valueCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add Memory Entry'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _keyCtrl,
            decoration: const InputDecoration(
              labelText: 'Key',
              hintText: 'e.g., user_preference',
            ),
            autofocus: true,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _valueCtrl,
            decoration: const InputDecoration(
              labelText: 'Value',
              hintText: 'e.g., Prefers dark mode',
            ),
            maxLines: 3,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final key = _keyCtrl.text.trim();
            final value = _valueCtrl.text.trim();
            if (key.isNotEmpty && value.isNotEmpty) {
              Navigator.pop(context, {'key': key, 'value': value});
            }
          },
          child: const Text('Add'),
        ),
      ],
    );
  }
}
