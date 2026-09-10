import 'package:flutter/material.dart';

import '../theme/hermes_theme.dart';
import 'hermes_components.dart';

/// Reads the count of failing cron jobs. Injectable so widget tests can
/// substitute a fake; the real implementation reads `/api/cron/jobs` through
/// a `DashboardClient`.
///
/// Contract: the loader returns `0` (never throws) when the dashboard is
/// unreachable or absent — an Inbox must never show an error state for a
/// control-plane source that is simply not configured.
typedef CronFailuresLoader = Future<int> Function();

/// A compact red attention banner for the action Inbox.
///
/// Renders nothing unless the loader reports at least one failing cron job:
/// an Inbox row is only ever drawn from an authoritative server answer, never
/// invented. Tapping opens the Cron screen where the failing jobs are ranked
/// first with their error detail.
class CronFailuresBanner extends StatefulWidget {
  const CronFailuresBanner({
    required this.loadFailures,
    required this.onOpenCron,
    super.key,
  });

  final CronFailuresLoader loadFailures;
  final VoidCallback onOpenCron;

  @override
  State<CronFailuresBanner> createState() => CronFailuresBannerState();
}

class CronFailuresBannerState extends State<CronFailuresBanner> {
  int _failing = 0;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    refresh();
  }

  /// Re-reads the failing count. Public so a host can refresh the banner after
  /// the user visits Cron and fixes a job.
  Future<void> refresh() async {
    int count;
    try {
      count = await widget.loadFailures();
    } catch (_) {
      count = 0;
    }
    if (!mounted) return;
    setState(() {
      _failing = count;
      _loaded = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded || _failing == 0) return const SizedBox.shrink();
    final tokens = HermesTokens.of(context);
    final color = tokens.colorForStatus(HermesStatus.failed);
    final label = _failing == 1
        ? '1 cron job needs attention'
        : '$_failing cron jobs need attention';

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        HermesSpacing.lg,
        HermesSpacing.lg,
        HermesSpacing.lg,
        0,
      ),
      child: HermesCard(
        status: HermesStatus.failed,
        padding: const EdgeInsets.symmetric(
          horizontal: HermesSpacing.md,
          vertical: HermesSpacing.sm,
        ),
        onTap: widget.onOpenCron,
        child: Row(
          children: [
            Icon(Icons.warning_amber_rounded, size: 20, color: color),
            const SizedBox(width: HermesSpacing.sm),
            Expanded(
              child: Text(
                label,
                style: tokens.typography.section.copyWith(color: color),
              ),
            ),
            Icon(Icons.chevron_right, size: 20, color: color),
          ],
        ),
      ),
    );
  }
}
