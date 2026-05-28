/// Session model for Hermes dashboard sessions.
class Session {
  final String id;
  final String title;
  final String model;
  final int messageCount;
  final bool isActive;
  final String preview;
  final String createdAt;

  const Session({
    required this.id,
    required this.title,
    required this.model,
    required this.messageCount,
    required this.isActive,
    required this.preview,
    required this.createdAt,
  });

  factory Session.fromJson(Map<String, dynamic> json) {
    // API fields: id, source, model, title, started_at, ended_at,
    // end_reason, message_count, preview, ...
    final started = json['started_at'] ?? json['created_at'] ?? '';
    return Session(
      id: json['id'] ?? '',
      title: json['title'] ?? 'Untitled',
      model: json['model'] ?? 'Default',
      messageCount: json['message_count'] ?? 0,
      isActive: json['is_active'] == true || json['ended_at'] == null,
      preview: json['preview'] ?? 'Tap to view session...',
      createdAt: started,
    );
  }
}
