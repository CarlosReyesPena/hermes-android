import 'package:flutter/material.dart';

class SessionOrganizerSettings {
  final bool aiEnabled;
  final String provider;
  final String model;

  const SessionOrganizerSettings({
    required this.aiEnabled,
    required this.provider,
    required this.model,
  });

  factory SessionOrganizerSettings.fromJson(Map<String, dynamic> json) {
    return SessionOrganizerSettings(
      aiEnabled: json['ai_enabled'] == true,
      provider: json['provider'] as String? ?? '',
      model: json['model'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'ai_enabled': aiEnabled,
    'provider': provider,
    'model': model,
  };
}

class SessionOrganizerSettingsCard extends StatefulWidget {
  final SessionOrganizerSettings initialSettings;
  final Map<String, List<String>> providerModels;
  final Future<void> Function(SessionOrganizerSettings settings) onSave;

  const SessionOrganizerSettingsCard({
    required this.initialSettings,
    required this.providerModels,
    required this.onSave,
    super.key,
  });

  @override
  State<SessionOrganizerSettingsCard> createState() =>
      _SessionOrganizerSettingsCardState();
}

class _SessionOrganizerSettingsCardState
    extends State<SessionOrganizerSettingsCard> {
  late bool _enabled;
  late String _provider;
  late String _model;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _enabled = widget.initialSettings.aiEnabled;
    _provider = _effectiveProvider(widget.initialSettings.provider);
    _model = _effectiveModel(_provider, widget.initialSettings.model);
  }

  String _effectiveProvider(String preferred) {
    if (widget.providerModels.containsKey(preferred)) return preferred;
    return widget.providerModels.keys.isEmpty
        ? ''
        : widget.providerModels.keys.first;
  }

  String _effectiveModel(String provider, String preferred) {
    final models = widget.providerModels[provider] ?? const <String>[];
    if (models.contains(preferred)) return preferred;
    return models.isEmpty ? '' : models.first;
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(
        SessionOrganizerSettings(
          aiEnabled: _enabled,
          provider: _provider,
          model: _model,
        ),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('AI curator settings saved')),
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not save AI curator settings');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final models = widget.providerModels[_provider] ?? const <String>[];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('AI project curator'),
              subtitle: Text(
                _enabled
                    ? 'On — the selected AI classifies finished conversations.'
                    : 'Off — fast deterministic matching remains active.',
              ),
              value: _enabled,
              onChanged: (value) => setState(() => _enabled = value),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: _provider.isEmpty ? null : _provider,
              decoration: const InputDecoration(
                labelText: 'AI provider',
                border: OutlineInputBorder(),
              ),
              items: widget.providerModels.keys
                  .map(
                    (provider) => DropdownMenuItem(
                      value: provider,
                      child: Text(provider),
                    ),
                  )
                  .toList(),
              onChanged: _enabled
                  ? (provider) {
                      if (provider == null) return;
                      setState(() {
                        _provider = provider;
                        _model = _effectiveModel(provider, '');
                      });
                    }
                  : null,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: ValueKey('organizer-model-$_provider'),
              initialValue: models.contains(_model) ? _model : null,
              decoration: const InputDecoration(
                labelText: 'AI model',
                border: OutlineInputBorder(),
              ),
              items: models
                  .map(
                    (model) =>
                        DropdownMenuItem(value: model, child: Text(model)),
                  )
                  .toList(),
              onChanged: _enabled
                  ? (model) {
                      if (model != null) setState(() => _model = model);
                    }
                  : null,
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _saving || (_enabled && _model.isEmpty)
                    ? null
                    : _save,
                icon: _saving
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save),
                label: const Text('Save AI curator settings'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
