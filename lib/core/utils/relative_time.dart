/// Canonical relative time shared by every screen that says "how long ago".
///
/// Before this helper existed, three screens each formatted elapsed time with
/// slightly different words ("now" vs "just now", "5m" vs "5m ago", different
/// date fallbacks), so the same event read differently depending on where it
/// was shown. This is the single formatter: `now` under a minute, then
/// `5m ago` / `3h ago` / `2d ago`, and a full local date past one week.
///
/// `now` is an explicit parameter so window boundaries stay deterministic in
/// widget tests.
String formatRelativeAge(DateTime updatedAt, DateTime now) {
  final elapsed = now.difference(updatedAt);
  if (elapsed.isNegative || elapsed.inMinutes < 1) return 'now';
  if (elapsed.inHours < 1) return '${elapsed.inMinutes}m ago';
  if (elapsed.inDays < 1) return '${elapsed.inHours}h ago';
  if (elapsed.inDays < 7) return '${elapsed.inDays}d ago';
  final local = updatedAt.toLocal();
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  return '$day/$month/${local.year}';
}

/// Compact relative time for Gateway timestamps (seconds since the epoch).
///
/// Kept as a thin wrapper over [formatRelativeAge] so conversation rows and
/// project lists share the exact same wording as Activity and Cron.
String formatRelativeTime(DateTime now, double lastActiveSeconds) {
  final activity = DateTime.fromMillisecondsSinceEpoch(
    (lastActiveSeconds * 1000).round(),
  );
  return formatRelativeAge(activity, now);
}

/// File modification time as an epoch-seconds value, rendered through the one
/// canonical relative formatter. Returns an empty string for an unknown mtime
/// (0 or negative), so a caller never prints a misleading "1970" date.
String formatModifiedAt(double epochSeconds, DateTime now) {
  if (epochSeconds <= 0) return '';
  final modified = DateTime.fromMillisecondsSinceEpoch(
    (epochSeconds * 1000).round(),
  );
  return formatRelativeAge(modified, now);
}

/// Message timestamp from the raw Gateway message map.
///
/// The API server stores a `timestamp` epoch-seconds column on every message
/// row; the message maps the Android app renders carry it through. Older or
/// third-party gateways may omit it, so the bubble falls back to no label
/// rather than guessing.
double? messageTimestampSeconds(Map<String, dynamic> metadata) {
  final raw = metadata['timestamp'];
  if (raw is num) return raw.toDouble();
  if (raw is String) {
    final parsed = double.tryParse(raw);
    if (parsed != null) return parsed;
    final asDate = DateTime.tryParse(raw);
    if (asDate != null) return asDate.millisecondsSinceEpoch / 1000.0;
  }
  return null;
}
