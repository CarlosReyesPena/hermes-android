import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/utils/relative_time.dart';

void main() {
  final now = DateTime(2026, 9, 6, 12, 0, 0);

  group('formatRelativeAge', () {
    test('under a minute reads as now', () {
      expect(
        formatRelativeAge(now.subtract(const Duration(seconds: 59)), now),
        'now',
      );
    });

    test('a clock skewed into the future still reads as now', () {
      expect(formatRelativeAge(now.add(const Duration(minutes: 5)), now), 'now');
    });

    test('minutes use the m ago form', () {
      expect(
        formatRelativeAge(now.subtract(const Duration(minutes: 7)), now),
        '7m ago',
      );
    });

    test('hours use the h ago form', () {
      expect(
        formatRelativeAge(now.subtract(const Duration(hours: 3)), now),
        '3h ago',
      );
    });

    test('days under a week use the d ago form', () {
      expect(
        formatRelativeAge(now.subtract(const Duration(days: 2)), now),
        '2d ago',
      );
    });

    test('older than a week falls back to a full local date', () {
      expect(
        formatRelativeAge(DateTime(2026, 8, 3, 10), now),
        '03/08/2026',
      );
    });
  });

  group('formatRelativeTime (seconds since epoch wrapper)', () {
    test('delegates to the same wording as the canonical formatter', () {
      final seconds =
          now.subtract(const Duration(minutes: 7)).millisecondsSinceEpoch /
          1000.0;
      expect(formatRelativeTime(now, seconds), '7m ago');
    });
  });
}
