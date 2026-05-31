/// Connection model for remote Hermes Gateway API Server (port 8642).
class NormalizedConnectionHost {
  final String host;
  final int port;

  const NormalizedConnectionHost({required this.host, required this.port});
}

class SavedConnection {
  final String id;
  final String label;
  final String host;
  final int port;
  final String apiKey;

  SavedConnection({
    required this.id,
    required this.label,
    required this.host,
    required this.port,
    required this.apiKey,
  });

  String get baseUrl => 'http://$host:$port';

  static NormalizedConnectionHost normalizeHostAndPort(
    String input,
    int fallbackPort,
  ) {
    var raw = input.trim();
    if (raw.isEmpty) {
      return NormalizedConnectionHost(host: raw, port: fallbackPort);
    }

    if (!raw.contains('://')) raw = 'http://$raw';
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.host.isEmpty) {
      return NormalizedConnectionHost(host: input.trim(), port: fallbackPort);
    }

    return NormalizedConnectionHost(
      host: uri.host,
      port: uri.hasPort ? uri.port : fallbackPort,
    );
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'label': label,
    'host': host,
    'port': port,
    'api_key': apiKey,
  };

  factory SavedConnection.fromMap(Map<String, dynamic> map) {
    return SavedConnection(
      id: map['id'] as String,
      label: map['label'] as String,
      host: map['host'] as String,
      port: (map['port'] as int?) ?? 8642,
      apiKey: (map['api_key'] as String?) ?? '',
    );
  }
}
