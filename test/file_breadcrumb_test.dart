import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/utils/file_breadcrumb.dart';

void main() {
  test('root only yields a single step', () {
    final steps = buildFileBreadcrumb('/srv/project', '/srv/project');
    expect(steps.map((s) => s.path), ['/srv/project']);
    expect(steps.single.label, 'project');
  });

  test('nested directory yields root → … → current', () {
    final steps = buildFileBreadcrumb('/srv/project', '/srv/project/lib/core');
    expect(steps.map((s) => s.path), [
      '/srv/project',
      '/srv/project/lib',
      '/srv/project/lib/core',
    ]);
    expect(steps.map((s) => s.label), ['project', 'lib', 'core']);
  });

  test('filesystem root is labelled as "/"', () {
    final steps = buildFileBreadcrumb('/', '/home/carlos');
    expect(steps.map((s) => s.label), ['/', 'home', 'carlos']);
  });

  test('a path outside the root degrades to the current directory', () {
    final steps = buildFileBreadcrumb('/srv/project', '/other/dir');
    expect(steps.map((s) => s.path), ['/other/dir']);
    expect(steps.single.label, 'dir');
  });

  test('item count is singular-aware', () {
    expect(formatItemCount(1), '1 item');
    expect(formatItemCount(0), '0 items');
    expect(formatItemCount(26), '26 items');
  });
}
