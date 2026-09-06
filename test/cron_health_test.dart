import 'package:flutter_test/flutter_test.dart';

import 'package:hermes_android/core/utils/cron_health.dart';

Map<String, dynamic> _job({
  String? lastStatus,
  String? lastRunAt,
  String? lastError,
  bool paused = false,
  String name = 'job',
}) {
  return {
    'id': name,
    'name': name,
    'last_status': lastStatus,
    'last_run_at': lastRunAt,
    'last_error': lastError,
    if (paused) 'paused_at': '2026-09-01T00:00:00Z',
  };
}

void main() {
  group('classifyCronJobHealth', () {
    test('an errored last run on an active job is failing', () {
      expect(
        classifyCronJobHealth(_job(lastStatus: 'error')),
        CronJobHealth.failing,
      );
    });

    test('failed is treated like error', () {
      expect(
        classifyCronJobHealth(_job(lastStatus: 'failed')),
        CronJobHealth.failing,
      );
    });

    test('a paused job is paused, never failing, even with an old error', () {
      expect(
        classifyCronJobHealth(
          _job(lastStatus: 'error', paused: true),
        ),
        CronJobHealth.paused,
      );
    });

    test('an errored job reported paused via state or enabled=false is paused',
        () {
      expect(
        classifyCronJobHealth({
          'last_status': 'error',
          'state': 'paused',
        }),
        CronJobHealth.paused,
      );
      expect(
        classifyCronJobHealth({
          'last_status': 'error',
          'enabled': false,
        }),
        CronJobHealth.paused,
      );
    });

    test('successful, never-run, and unknown-status jobs are ok', () {
      expect(
        classifyCronJobHealth(_job(lastStatus: 'success')),
        CronJobHealth.ok,
      );
      expect(classifyCronJobHealth(_job()), CronJobHealth.ok);
      expect(
        classifyCronJobHealth(_job(lastStatus: 'weird')),
        CronJobHealth.ok,
      );
    });
  });

  group('rankCronJobs', () {
    test('failing jobs rank before paused and healthy ones', () {
      final jobs = [
        _job(name: 'healthy', lastStatus: 'success'),
        _job(name: 'failing', lastStatus: 'error'),
        _job(name: 'paused', lastStatus: 'success', paused: true),
      ];
      final ranked = rankCronJobs(jobs);
      expect(ranked.map((j) => j['name']), [
        'failing',
        'paused',
        'healthy',
      ]);
    });

    test('failing jobs are ordered most recently failed first', () {
      final jobs = [
        _job(name: 'older', lastStatus: 'error', lastRunAt: '2026-09-01T08:00:00Z'),
        _job(name: 'newer', lastStatus: 'error', lastRunAt: '2026-09-02T08:00:00Z'),
      ];
      final ranked = rankCronJobs(jobs);
      expect(ranked.map((j) => j['name']), ['newer', 'older']);
    });

    test('never-run jobs do not outrank healthy ones and stay stable', () {
      final jobs = [
        _job(name: 'a', lastStatus: 'success'),
        _job(name: 'never'),
        _job(name: 'b', lastStatus: 'success'),
      ];
      final ranked = rankCronJobs(jobs);
      expect(ranked.map((j) => j['name']), ['a', 'never', 'b']);
    });
  });

  group('cronFailureDetail', () {
    test('returns the trimmed error when present', () {
      expect(
        cronFailureDetail(_job(lastStatus: 'error', lastError: '  boom  ')),
        'boom',
      );
    });

    test('returns null without error prose', () {
      expect(cronFailureDetail(_job(lastStatus: 'error')), isNull);
      expect(cronFailureDetail(_job(lastError: '  ')), isNull);
    });

    test('truncates very long errors to 200 chars with an ellipsis', () {
      final long = 'x' * 500;
      final detail = cronFailureDetail(_job(lastError: long));
      expect(detail, isNotNull);
      expect(detail!.length, 201);
      expect(detail.endsWith('…'), isTrue);
    });
  });
}
