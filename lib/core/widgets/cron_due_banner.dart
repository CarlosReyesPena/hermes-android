import 'package:flutter/material.dart';

import '../theme/hermes_theme.dart';
import '../utils/cron_health.dart';
import '../utils/relative_time.dart';
import 'hermes_components.dart';

/// Reads the scheduled cron jobs whose run is overdue.
///
/// Injectable so widget tests can substitute a fake; the real implementation
/// reads `/api/cron/jobs` through a `DashboardClient` and passes the payload
/// to [selectOverdueCronJobs].
///
/// Contract: the loader returns an empty list (never throws) when the dashboard
/// is unreachable. A `null` loader means the connection has no dashboard to ask
/// at all — the banner then draws nothing rather than claiming nothing is due
/// on a question it never asked.
typedef CronDueLoader = Future<List<OverdueCronJob>> Function();

/// A compact attention banner naming scheduled cron work that has not run.
///
/// This is the *due-task* source of the action Inbox, deliberately separate
/// from [CronFailuresBanner]: a job whose last run errored is a failure, while
/// a job whose next run simply never happened is a stalled schedule. The pure
/// [selectOverdueCronJobs] helper keeps them disjoint, so the same job can
/// never be reported twice under two different reasons.
///
/// Renders only from an authoritative server answer; it never invents a row.
class CronDueBanner extends StatefulWidget {
  const CronDueBanner({
    required this.loadDueJobs,
    required this.onOpenCron,
    super.key,
  });

  /// `null` when this connection cannot be asked (no dashboard configured).
  final CronDueLoader? loadDueJobs;

  final VoidCallback onOpenCron;

  @override
  State<CronDueBanner> createState() => CronDueBannerState();
}

class CronDueBannerState extends State<CronDueBanner> {
  List<OverdueCronJob> _due = const [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    refresh();
  }

  /// Re-reads the overdue jobs. Public so a host can refresh the banner after
  /// the user visits Cron and runs or repauses a job.
  Future<void> refresh() async {
    final loader = widget.loadDueJobs;
    if (loader == null) {
      if (!mounted) return;
      setState(() {
        _due = const [];
        _loaded = false;
      });
      return;
    }
    List<OverdueCronJob> due;
    try {
      due = await loader();
    } catch (_) {
      // A dashboard that is configured but unreachable must not turn the
      // Inbox into an error screen.
      due = const [];
    }
    if (!mounted) return;
    setState(() {
      _due = due;
      _loaded = true;
    });
  }

  /// "3h ago" / "42m ago" through the one canonical formatter, so a late run
  /// reads the same here as everywhere else in the app.
  String _lateness(OverdueCronJob job) =>
      formatRelativeAge(job.dueAt, job.dueAt.add(job.overdueBy));

  @override
  Widget build(BuildContext context) {
    if (!_loaded || _due.isEmpty) return const SizedBox.shrink();
    final tokens = HermesTokens.of(context);
    final color = tokens.colorForStatus(HermesStatus.blocked);

    final String headline;
    final String detail;
    if (_due.length == 1) {
      final job = _due.single;
      headline = '1 scheduled job has not run';
      detail = '${job.name} · due ${_lateness(job)}';
    } else {
      headline = '${_due.length} scheduled jobs have not run';
      detail = _due.map((j) => j.name).join(' · ');
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        HermesSpacing.lg,
        HermesSpacing.lg,
        HermesSpacing.lg,
        0,
      ),
      child: HermesCard(
        status: HermesStatus.blocked,
        padding: const EdgeInsets.symmetric(
          horizontal: HermesSpacing.md,
          vertical: HermesSpacing.sm,
        ),
        onTap: widget.onOpenCron,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(Icons.schedule, size: 20, color: color),
            ),
            const SizedBox(width: HermesSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    headline,
                    style: tokens.typography.section.copyWith(color: color),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    detail,
                    style: tokens.typography.label,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: HermesSpacing.sm),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(Icons.chevron_right, size: 20, color: color),
            ),
          ],
        ),
      ),
    );
  }
}
