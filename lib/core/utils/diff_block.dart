// Pure classification of unified/git diffs for the chat renderer.
//
// A raw unified diff is still a valid markdown fenced code block, so the
// renderer can always fall back to plain text. This module only exists to
// give a diff the coloured line treatment a developer expects, without
// pulling in a syntax-highlighting dependency.

/// The kind of a single line inside a diff.
enum DiffLineKind {
  /// A file header, index line, or the `---` / `+++` file markers.
  meta,

  /// An `@@ -a,b +c,d @@` hunk header.
  hunk,

  /// A line starting with `+` (added) — including `+++` lines that are not
  /// file markers, which cannot happen in a well-formed diff but must still
  /// classify as something.
  addition,

  /// A line starting with `-` (removed), excluding `---` file markers.
  deletion,

  /// Anything else: unchanged context lines and blank lines.
  context,
}

/// Whether [content] looks like a unified or git diff rather than ordinary
/// prose or code.
bool isUnifiedDiff(String content) {
  final trimmed = content.trimLeft();
  if (trimmed.startsWith('diff --git ')) return true;
  // A hunk header is the strongest signal: prose or code never contains a
  // line shaped exactly like `@@ -a,b +c,d @@`.
  final hunk = RegExp(r'^@@ -\d+(?:,\d+)? \+\d+(?:,\d+)? @@', multiLine: true);
  return hunk.hasMatch(content);
}

/// One classified line of a diff, with its exact source text preserved.
class DiffLine {
  final DiffLineKind kind;
  final String text;

  const DiffLine({required this.kind, required this.text});
}

/// Splits [diff] into classified lines without mutating or reordering it.
List<DiffLine> parseDiffLines(String diff) {
  final lines = diff.split('\n');
  return [
    for (final line in lines) DiffLine(kind: _classify(line), text: line),
  ];
}

DiffLineKind _classify(String line) {
  if (line.isEmpty) return DiffLineKind.context;
  if (line.startsWith('@@ ')) return DiffLineKind.hunk;
  if (line.startsWith('diff --git ') ||
      line.startsWith('index ') ||
      line.startsWith('--- ') ||
      line.startsWith('+++ ')) {
    return DiffLineKind.meta;
  }
  if (line.startsWith('+')) return DiffLineKind.addition;
  if (line.startsWith('-')) return DiffLineKind.deletion;
  return DiffLineKind.context;
}
