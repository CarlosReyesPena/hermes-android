/// A single navigable step in the Files breadcrumb trail.
class FileBreadcrumbStep {
  final String path;
  final String label;

  const FileBreadcrumbStep({required this.path, required this.label});
}

/// Splits [currentPath] into clickable steps from [rootPath] down to the
/// current directory.
///
/// The root is always the first step (labelled by its basename, or "/" for the
/// filesystem root). If [currentPath] is not under [rootPath] (e.g. a manually
/// entered initial path), the trail degrades to the single current directory
/// rather than fabricating an intermediate path.
List<FileBreadcrumbStep> buildFileBreadcrumb(
  String rootPath,
  String currentPath,
) {
  String trim(String p) =>
      p.endsWith('/') && p.length > 1 ? p.substring(0, p.length - 1) : p;
  final root = trim(rootPath);
  final current = trim(currentPath);

  final rootLabel = root == '/'
      ? '/'
      : root.split('/').where((s) => s.isNotEmpty).last;

  if (current == root) {
    return [FileBreadcrumbStep(path: root, label: rootLabel)];
  }
  if (!current.startsWith('$root/') && root != '/') {
    final currentLabel = current == '/'
        ? '/'
        : current.split('/').where((s) => s.isNotEmpty).last;
    return [FileBreadcrumbStep(path: current, label: currentLabel)];
  }

  // Walk up from the current directory to the root, then reverse so the trail
  // reads root → … → current.
  final steps = <FileBreadcrumbStep>[];
  var cursor = current;
  while (true) {
    final label = cursor == '/'
        ? '/'
        : cursor.split('/').where((s) => s.isNotEmpty).last;
    steps.add(FileBreadcrumbStep(path: cursor, label: label));
    if (cursor == root) break;
    final separator = cursor.lastIndexOf('/');
    cursor = separator <= 0 ? '/' : cursor.substring(0, separator);
  }
  return steps.reversed.toList(growable: false);
}

/// Canonical item-count label for the Files browser: "1 item" / "26 items".
String formatItemCount(int count) => '$count item${count == 1 ? '' : 's'}';
