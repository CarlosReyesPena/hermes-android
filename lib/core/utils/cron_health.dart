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

/// How late a scheduled run may be before it is worth telling the user.
///
/// The scheduler fires on its own cadence and a run that started seconds ago
/// has not yet written a new `next_run_at`, so a small window of lateness is
/// normal operation rather than a fault. Reporting inside it would make the
/// Inbox flicker a row on every ordinary tick.
const Duration kCronOverdueGrace = Duration(minutes: 15);

/// Default number of overdue jobs an Inbox row may name.
const int kCronOverdueCap = 5;

/// One scheduled cron job whose run is late, as the Inbox needs it.
class OverdueCronJob {
  const OverdueCronJob({
    required this.id,
    required this.name,
    required this.dueAt,
    required this.overdueBy,
  });

  /// The job's server id.
  final String id;

  /// A human label. Falls back to the id rather than ever being blank.
  final String name;

  /// The instant the server said the job should have run.
  final DateTime dueAt;

  /// How long ago that instant passed.
  final Duration overdueBy;
}

/// Selects the scheduled cron jobs whose `next_run_at` has passed.
///
/// This is the *due-task* half of the Inbox and is deliberately disjoint from
/// [classifyCronJobHealth]'s failure half: a job whose last run errored is
/// already reported by the failures banner, so reporting it here as well would
/// show the same job twice under two different reasons. Only healthy scheduled
/// jobs that simply have not run can be overdue.
///
/// Never infers a due task from missing data: a job with no `next_run_at`, or
/// with one that cannot be parsed, is dropped rather than assumed late —
/// claiming work is overdue on a guess is worse than staying quiet.
///
/// [now] is required so the rule is testable without a wall clock. The caller's
/// list is never mutated or reordered.
List<OverdueCronJob> selectOverdueCronJobs({
  required List<Map<String, dynamic>> jobs,
  required DateTime now,
  int cap = kCronOverdueCap,
}) {
  if (cap <= 0) {
    throw ArgumentError.value(cap, 'cap', 'must be positive');
  }

  final due = <OverdueCronJob>[];
  for (final job in jobs) {
    // Paused work is a deliberate stop, and a failing job belongs to the
    // failures banner: neither is a due task.
    if (classifyCronJobHealth(job) != CronJobHealth.ok) continue;

    final id = (job['id'] as String?)?.trim() ?? '';
    if (id.isEmpty) continue;

    final rawNext = (job['next_run_at'] as String?)?.trim() ?? '';
    if (rawNext.isEmpty) continue;
    final next = DateTime.tryParse(rawNext);
    if (next == null) continue;

    // Compare as instants: the server sends offset-aware timestamps.
    final overdueBy = now.toUtc().difference(next.toUtc());
    if (overdueBy <= kCronOverdueGrace) continue;

    final rawName = (job['name'] as String?)?.trim() ?? '';
    due.add(
      OverdueCronJob(
        id: id,
        name: rawName.isEmpty ? id : rawName,
        dueAt: next,
        overdueBy: overdueBy,
      ),
    );
  }

  due.sort((a, b) => b.overdueBy.compareTo(a.overdueBy));
  return due.length <= cap ? due : due.sublist(0, cap);
}
