import 'package:flutter_test/flutter_test.dart';

import 'package:hermes_android/core/utils/cron_health.dart';

Map<String, dynamic> _job({
  String? lastStatus,
  String? lastRunAt,
  String? lastError,
  String? nextRunAt,
  bool paused = false,
  String name = 'job',
}) {
  return {
    'id': name,
    'name': name,
    'last_status': lastStatus,
    'last_run_at': lastRunAt,
    'last_error': lastError,
    'next_run_at': nextRunAt,
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

  group('selectOverdueCronJobs', () {
    final now = DateTime.utc(2026, 9, 7, 12);

    String at(Duration offset) => now.add(offset).toIso8601String();

    test('a scheduled job past its next run is overdue', () {
      final due = selectOverdueCronJobs(
        jobs: [
          _job(
            name: 'nightly',
            lastStatus: 'ok',
            nextRunAt: at(const Duration(hours: -3)),
          ),
        ],
        now: now,
      );

      expect(due, hasLength(1));
      expect(due.single.id, 'nightly');
      expect(due.single.name, 'nightly');
      expect(due.single.overdueBy, const Duration(hours: 3));
    });

    test('a job whose next run is still ahead is not overdue', () {
      final due = selectOverdueCronJobs(
        jobs: [
          _job(name: 'later', nextRunAt: at(const Duration(hours: 2))),
        ],
        now: now,
      );

      expect(due, isEmpty);
    });

    test('a run barely late is inside the grace window, not overdue', () {
      final due = selectOverdueCronJobs(
        jobs: [
          _job(
            name: 'jitter',
            nextRunAt: at(-kCronOverdueGrace + const Duration(minutes: 1)),
          ),
        ],
        now: now,
      );

      expect(due, isEmpty);
    });

    test('the grace boundary itself has not elapsed yet', () {
      final due = selectOverdueCronJobs(
        jobs: [_job(name: 'edge', nextRunAt: at(-kCronOverdueGrace))],
        now: now,
      );

      expect(due, isEmpty);
    });

    test('a paused job is never overdue however old its next run is', () {
      final due = selectOverdueCronJobs(
        jobs: [
          _job(
            name: 'paused',
            paused: true,
            nextRunAt: at(const Duration(days: 120)) ,
          ),
          _job(
            name: 'disabled',
            nextRunAt: at(const Duration(days: -120)),
          )..['enabled'] = false,
          _job(name: 'stopped', nextRunAt: at(const Duration(days: -120)))
            ..['state'] = 'paused',
        ],
        now: now,
      );

      expect(due, isEmpty);
    });

    test('a failing job is left to the failures banner, never doubled here', () {
      final due = selectOverdueCronJobs(
        jobs: [
          _job(
            name: 'broken',
            lastStatus: 'error',
            nextRunAt: at(const Duration(hours: -5)),
          ),
        ],
        now: now,
      );

      expect(due, isEmpty);
    });

    test('a job with no next run reports nothing rather than guessing', () {
      final due = selectOverdueCronJobs(
        jobs: [_job(name: 'unscheduled')],
        now: now,
      );

      expect(due, isEmpty);
    });

    test('an unparseable next run is dropped, never treated as overdue', () {
      final due = selectOverdueCronJobs(
        jobs: [
          _job(name: 'garbage', nextRunAt: 'not-a-date'),
          _job(name: 'blank', nextRunAt: '   '),
        ],
        now: now,
      );

      expect(due, isEmpty);
    });

    test('an offset timestamp is compared as an instant, not as wall clock', () {
      // 09:00+02:00 is 07:00Z — five hours before `now` — so it is overdue
      // even though its wall-clock text reads earlier than noon.
      final due = selectOverdueCronJobs(
        jobs: [_job(name: 'zoned', nextRunAt: '2026-09-07T09:00:00+02:00')],
        now: now,
      );

      expect(due, hasLength(1));
      expect(due.single.overdueBy, const Duration(hours: 5));
    });

    test('the most overdue job is reported first', () {
      final due = selectOverdueCronJobs(
        jobs: [
          _job(name: 'recent', nextRunAt: at(const Duration(hours: -1))),
          _job(name: 'ancient', nextRunAt: at(const Duration(days: -2))),
          _job(name: 'middle', nextRunAt: at(const Duration(hours: -6))),
        ],
        now: now,
      );

      expect(due.map((j) => j.id), ['ancient', 'middle', 'recent']);
    });

    test('the list is capped and reports how many it did not show', () {
      final due = selectOverdueCronJobs(
        jobs: [
          for (var i = 0; i < 10; i++)
            _job(name: 'j$i', nextRunAt: at(Duration(hours: -1 - i))),
        ],
        now: now,
        cap: 3,
      );

      expect(due, hasLength(3));
      expect(due.map((j) => j.id), ['j9', 'j8', 'j7']);
    });

    test('a cap of zero throws rather than silently reporting nothing', () {
      expect(
        () => selectOverdueCronJobs(
          jobs: [_job(name: 'a', nextRunAt: at(const Duration(days: -1)))],
          now: now,
          cap: 0,
        ),
        throwsArgumentError,
      );
    });

    test('a job with no usable name falls back to its id, never to blank', () {
      final due = selectOverdueCronJobs(
        jobs: [
          {
            'id': 'abc123',
            'name': '  ',
            'next_run_at': at(const Duration(hours: -2)),
          },
        ],
        now: now,
      );

      expect(due.single.name, 'abc123');
    });

    test('a job with no id is dropped: it could only be a dead row', () {
      final due = selectOverdueCronJobs(
        jobs: [
          {'name': 'nameless', 'next_run_at': at(const Duration(hours: -2))},
        ],
        now: now,
      );

      expect(due, isEmpty);
    });

    test('does not mutate or reorder the caller list', () {
      final jobs = [
        _job(name: 'recent', nextRunAt: at(const Duration(hours: -1))),
        _job(name: 'ancient', nextRunAt: at(const Duration(days: -2))),
      ];
      selectOverdueCronJobs(jobs: jobs, now: now);

      expect(jobs.map((j) => j['name']), ['recent', 'ancient']);
    });
  });
}
