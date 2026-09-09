import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/utils/diff_block.dart';

void main() {
  group('isUnifiedDiff', () {
    test('detects a hunk header', () {
      expect(isUnifiedDiff('@@ -1,3 +1,4 @@\n-x\n+y'), isTrue);
    });

    test('detects a git diff header', () {
      expect(isUnifiedDiff('diff --git a/x.py b/x.py\n--- a/x.py'), isTrue);
    });

    test('rejects ordinary code', () {
      expect(isUnifiedDiff('def foo():\n    return 1'), isFalse);
    });

    test('rejects prose mentioning plus signs', () {
      expect(isUnifiedDiff('use a + b - c\nnot a diff'), isFalse);
    });
  });

  group('parseDiffLines', () {
    test('classifies additions, deletions, context, hunk, and meta', () {
      final diff = [
        'diff --git a/x.py b/x.py',
        'index 123..456 100644',
        '--- a/x.py',
        '+++ b/x.py',
        '@@ -1,3 +1,4 @@',
        ' context',
        '-removed',
        '+added',
        ' context',
      ].join('\n');

      final lines = parseDiffLines(diff);
      final kinds = lines.map((l) => l.kind).toList();

      expect(kinds, const [
        DiffLineKind.meta,
        DiffLineKind.meta,
        DiffLineKind.meta,
        DiffLineKind.meta,
        DiffLineKind.hunk,
        DiffLineKind.context,
        DiffLineKind.deletion,
        DiffLineKind.addition,
        DiffLineKind.context,
      ]);
    });

    test('keeps the exact source text per line', () {
      final lines = parseDiffLines('@@ -1 +1 @@\n+hello\n-world\n');
      expect(lines[0].text, '@@ -1 +1 @@');
      expect(lines[1].text, '+hello');
      expect(lines[2].text, '-world');
    });

    test('treats a bare plus-only line as addition, not meta', () {
      final lines = parseDiffLines('+++ b/x.py\n+ok\n+++not a file');
      expect(lines[0].kind, DiffLineKind.meta);
      expect(lines[1].kind, DiffLineKind.addition);
      // "+++not a file" is not a file header ("+++ b/" or "+++ a/"), so it is
      // treated as an addition line carrying two leading pluses.
      expect(lines[2].kind, DiffLineKind.addition);
    });

    test('classifies a blank line as context', () {
      final lines = parseDiffLines('@@ -1 +1 @@\n\n');
      expect(lines[1].kind, DiffLineKind.context);
    });

    test('never mutates or reorders input', () {
      const src = 'a\nb\nc';
      final lines = parseDiffLines(src);
      expect(lines.map((l) => l.text).join('\n'), src);
    });
  });
}
