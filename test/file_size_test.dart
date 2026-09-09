import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/utils/file_size.dart';

void main() {
  test('returns an empty string for directories and unknown sizes', () {
    expect(formatFileSize(0), '');
    expect(formatFileSize(-1), '');
  });

  test('formats bytes without a fractional part', () {
    expect(formatFileSize(1), '1 B');
    expect(formatFileSize(512), '512 B');
    expect(formatFileSize(1023), '1023 B');
  });

  test('formats kilobytes with two significant decimals', () {
    expect(formatFileSize(1024), '1.00 KB');
    expect(formatFileSize(3 * 1024 + 256), '3.25 KB');
  });

  test('formats megabytes and gigabytes', () {
    expect(formatFileSize(1500 * 1024), '1.46 MB');
    expect(formatFileSize(2 * 1024 * 1024), '2.00 MB');
    expect(formatFileSize(3 * 1024 * 1024 * 1024), '3.00 GB');
  });
}
