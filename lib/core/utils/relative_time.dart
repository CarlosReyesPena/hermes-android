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
