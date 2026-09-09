import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../utils/diff_block.dart';

/// Renders a unified/git diff with coloured line treatment instead of raw
/// monospace prose. The whole block still scrolls horizontally so long lines
/// are reachable, and the header offers the same copy affordance as a normal
/// code block.
class DiffBlock extends StatefulWidget {
  final String diff;

  const DiffBlock({super.key, required this.diff});

  @override
  State<DiffBlock> createState() => _DiffBlockState();
}

class _DiffBlockState extends State<DiffBlock> {
  bool _wrap = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.diff));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('Diff copied'),
          duration: Duration(seconds: 2),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final lines = parseDiffLines(widget.diff);

    final background = isDark
        ? const Color(0xFF141414)
        : const Color(0xFFF7F7F7);
    final header = isDark ? const Color(0xFF232323) : const Color(0xFFE9E9E9);

    final linesWidget = _Column(lines: lines, isDark: isDark);
    // In wrap mode each line wraps to the block width. In scroll mode the
    // column is bounded to its widest line so `stretch` can still fill the
    // per-line background while the whole block scrolls horizontally.
    final body = _wrap
        ? linesWidget
        : SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: IntrinsicWidth(child: linesWidget),
          );

    return Container(
      key: const Key('diff-block'),
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
            color: header,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'diff',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.primary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (_wrap)
                  Tooltip(
                    message: 'Scroll horizontally',
                    child: IconButton(
                      icon: const Icon(Icons.swap_horiz, size: 18),
                      onPressed: () => setState(() => _wrap = false),
                      constraints: const BoxConstraints.tightFor(
                        width: 40,
                        height: 40,
                      ),
                    ),
                  ),
                Tooltip(
                  message: 'Wrap lines',
                  child: IconButton(
                    icon: const Icon(Icons.wrap_text, size: 18),
                    onPressed: () => setState(() => _wrap = true),
                    constraints: const BoxConstraints.tightFor(
                      width: 40,
                      height: 40,
                    ),
                  ),
                ),
                Tooltip(
                  message: 'Copy diff',
                  child: IconButton(
                    icon: const Icon(Icons.copy_outlined, size: 18),
                    onPressed: _copy,
                    constraints: const BoxConstraints.tightFor(
                      width: 40,
                      height: 40,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: body,
          ),
        ],
      ),
    );
  }
}

class _Column extends StatelessWidget {
  final List<DiffLine> lines;
  final bool isDark;

  const _Column({required this.lines, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [for (final line in lines) _row(line)],
    );
  }

  Widget _row(DiffLine line) {
    final Color foreground;
    final Color? background;
    switch (line.kind) {
      case DiffLineKind.addition:
        foreground = isDark ? const Color(0xFF4ADE80) : const Color(0xFF15803D);
        background = isDark ? const Color(0xFF0D2818) : const Color(0xFFE6F4EA);
      case DiffLineKind.deletion:
        foreground = isDark ? const Color(0xFFF87171) : const Color(0xFFB91C1C);
        background = isDark ? const Color(0xFF2A1215) : const Color(0xFFFDEBEC);
      case DiffLineKind.hunk:
        foreground = isDark ? const Color(0xFF93C5FD) : const Color(0xFF1D4ED8);
        background = isDark ? const Color(0xFF12233B) : const Color(0xFFE8F0FE);
      case DiffLineKind.meta:
        foreground = isDark ? const Color(0xFFA5B4FC) : const Color(0xFF4F46E5);
        background = null;
      case DiffLineKind.context:
        foreground = isDark ? Colors.white70 : Colors.black87;
        background = null;
    }

    return Container(
      color: background,
      padding: const EdgeInsets.symmetric(vertical: 0.5),
      child: Text(
        line.text.isEmpty ? ' ' : line.text,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 12.5,
          height: 1.45,
          color: foreground,
        ),
      ),
    );
  }
}
