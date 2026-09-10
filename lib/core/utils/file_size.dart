/// Canonical byte-size formatter shared by any surface that shows a file size.
///
/// Renders a compact, human-readable size: `512 B`, `3.2 KB`, `1.4 MB`,
/// `2.0 GB`. Directories and unknown sizes pass `0` (or negative) and return
/// an empty string so callers can render nothing rather than a misleading
/// "0 B" beside a folder.
String formatFileSize(int bytes) {
  if (bytes <= 0) return '';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  final suffix = units[unit];
  if (unit == 0) return '${value.round()} $suffix';
  final digits = value >= 100 ? 0 : (value >= 10 ? 1 : 2);
  return '${value.toStringAsFixed(digits)} $suffix';
}
