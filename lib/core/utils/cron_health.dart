/// Cron job health classification.
///
/// The dashboard's cron jobs carry a per-run outcome on the job itself:
/// ``last_status`` is ``"error"`` when the most recent run failed (the
/// scheduler also persists ``last_error`` prose and ``last_run_at``), and
/// ``"success"`` (or similar) when it completed. A job that has never run has
/// no ``last_run_at`` at all. Paused jobs are excluded from failure
/// reporting — pausing is a deliberate stop, not a fault.
///
/// Keeping this decision in a pure helper makes the ranking rules testable
/// without pumping a widget and keeps the screen free of policy.
library;

/// The health state of one cron job for display and ranking.
enum CronJobHealth {
  /// The last run failed and the job is not paused: it needs the user.
  failing,

  /// Paused — deliberately stopped, never reported as a failure.
  paused,

  /// Scheduled and healthy (last run succeeded, or it has simply never run).
  ok;

  bool get needsAttention => this == CronJobHealth.failing;
}

/// Classifies a raw dashboard cron job payload.
///
/// A job is *failing* only when the server says the last run errored AND the
/// job is not paused. Never infers failure from an absent status: no
/// ``last_status`` plus no ``last_run_at`` means "never run", which is a
/// healthy scheduled state, not a fault.
CronJobHealth classifyCronJobHealth(Map<String, dynamic> job) {
  final paused =
      job['paused_at'] != null ||
      job['state'] == 'paused' ||
      job['enabled'] == false;
  if (paused) return CronJobHealth.paused;

  final lastStatus = (job['last_status'] as String?)?.toLowerCase() ?? '';
  if (lastStatus == 'error' || lastStatus == 'failed') {
    return CronJobHealth.failing;
  }
  return CronJobHealth.ok;
}

/// Stable ordering: failing jobs first (most recently failed first), then
/// paused, then the healthy remainder. Ties keep server order.
List<Map<String, dynamic>> rankCronJobs(List<Map<String, dynamic>> jobs) {
  final ranked = List<Map<String, dynamic>>.of(jobs);
  int rankOf(Map<String, dynamic> job) {
    switch (classifyCronJobHealth(job)) {
      case CronJobHealth.failing:
        return 0;
      case CronJobHealth.paused:
        return 1;
      case CronJobHealth.ok:
        return 2;
    }
  }

  ranked.sort((a, b) {
    final byHealth = rankOf(a).compareTo(rankOf(b));
    if (byHealth != 0) return byHealth;
    // Within failing, most recently failed first; newest first otherwise.
    final aRun = DateTime.tryParse(a['last_run_at'] as String? ?? '');
    final bRun = DateTime.tryParse(b['last_run_at'] as String? ?? '');
    if (aRun == null && bRun == null) return 0;
    if (aRun == null) return 1;
    if (bRun == null) return -1;
    return bRun.compareTo(aRun);
  });
  return ranked;
}

/// The server's error prose for a failing job, trimmed for a list row, or
/// `null` when there is nothing worth showing.
String? cronFailureDetail(Map<String, dynamic> job) {
  final raw = (job['last_error'] as String?)?.trim() ?? '';
  if (raw.isEmpty) return null;
  if (raw.length <= 200) return raw;
  return '${raw.substring(0, 200)}…';
}
