import '../services/remote_files_client.dart';

/// Sort key for the Files browser. Folders always sort before files within a
/// directory; the key only orders entries within those two groups.
enum FileSortKey { name, size, modified }

/// Canonical sort for the Files browser. Directories are always listed first
/// (a real file manager never interleaves folders and files), then the chosen
/// key is applied: name ascending (case-insensitive), size descending,
/// or last-modified descending. Never mutates the caller's list.
List<RemoteFileEntry> sortFileEntries(
  List<RemoteFileEntry> entries, {
  FileSortKey key = FileSortKey.name,
}) {
  final sorted = List<RemoteFileEntry>.of(entries);
  sorted.sort((left, right) {
    if (left.isDirectory != right.isDirectory) {
      return left.isDirectory ? -1 : 1;
    }
    final comparison = switch (key) {
      FileSortKey.name => left.name.toLowerCase().compareTo(
        right.name.toLowerCase(),
      ),
      FileSortKey.size => right.size.compareTo(left.size),
      FileSortKey.modified => right.modifiedAt.compareTo(left.modifiedAt),
    };
    if (comparison != 0) return comparison;
    // Stable tie-break by name so equal sizes/mtimes never look shuffled.
    return left.name.toLowerCase().compareTo(right.name.toLowerCase());
  });
  return sorted;
}
