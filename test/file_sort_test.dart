import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/remote_files_client.dart';
import 'package:hermes_android/core/utils/file_sort.dart';

void main() {
  const dirA = RemoteFileEntry(
    name: 'a_dir',
    path: '/p/a_dir',
    isDirectory: true,
    modifiedAt: 100,
  );
  const dirZ = RemoteFileEntry(
    name: 'z_dir',
    path: '/p/z_dir',
    isDirectory: true,
    modifiedAt: 200,
  );
  const small = RemoteFileEntry(
    name: 'a.txt',
    path: '/p/a.txt',
    isDirectory: false,
    size: 10,
    modifiedAt: 300,
  );
  const big = RemoteFileEntry(
    name: 'b.txt',
    path: '/p/b.txt',
    isDirectory: false,
    size: 100,
    modifiedAt: 50,
  );

  test('sorts directories first, then by name case-insensitively', () {
    final sorted = sortFileEntries([big, dirZ, small, dirA]);
    expect(sorted.map((e) => e.name), ['a_dir', 'z_dir', 'a.txt', 'b.txt']);
  });

  test('sorts by size descending, directories still first', () {
    final sorted = sortFileEntries([small, big, dirA], key: FileSortKey.size);
    expect(sorted.map((e) => e.name), ['a_dir', 'b.txt', 'a.txt']);
  });

  test('sorts by modified time descending, directories still first', () {
    final sorted = sortFileEntries([
      small,
      big,
      dirZ,
      dirA,
    ], key: FileSortKey.modified);
    expect(sorted.map((e) => e.name), ['z_dir', 'a_dir', 'a.txt', 'b.txt']);
  });

  test('never mutates the caller list', () {
    final input = [big, small];
    sortFileEntries(input, key: FileSortKey.size);
    expect(input.map((e) => e.name), ['b.txt', 'a.txt']);
  });
}
