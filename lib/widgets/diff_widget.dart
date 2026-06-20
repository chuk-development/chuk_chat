// lib/widgets/diff_widget.dart
import 'dart:math';

import 'package:flutter/material.dart';

enum _LineType { added, removed, context }

class _DiffLine {
  const _DiffLine(this.type, this.text);
  final _LineType type;
  final String text;
}

/// Renders a before/after text comparison as a unified diff with colored lines.
class DiffWidget extends StatefulWidget {
  const DiffWidget({
    super.key,
    required this.before,
    required this.after,
    this.title,
    this.type,
  });

  final String before;
  final String after;

  /// Optional human-readable title shown in the header.
  final String? title;

  /// Semantic type: 'user_info', 'memory', 'soul', 'artifact', etc.
  final String? type;

  @override
  State<DiffWidget> createState() => _DiffWidgetState();
}

class _DiffWidgetState extends State<DiffWidget> {
  bool _expanded = true;

  static List<_DiffLine> _computeLineDiff(String before, String after) {
    final oldLines = before.isEmpty ? const <String>[] : before.split('\n');
    final newLines = after.isEmpty ? const <String>[] : after.split('\n');
    final m = oldLines.length;
    final n = newLines.length;

    final lcs = List.generate(m + 1, (_) => List.filled(n + 1, 0));
    for (var i = 1; i <= m; i++) {
      for (var j = 1; j <= n; j++) {
        if (oldLines[i - 1] == newLines[j - 1]) {
          lcs[i][j] = lcs[i - 1][j - 1] + 1;
        } else {
          lcs[i][j] = max(lcs[i - 1][j], lcs[i][j - 1]);
        }
      }
    }

    final result = <_DiffLine>[];
    var i = m, j = n;
    while (i > 0 || j > 0) {
      if (i > 0 && j > 0 && oldLines[i - 1] == newLines[j - 1]) {
        result.add(_DiffLine(_LineType.context, oldLines[i - 1]));
        i--;
        j--;
      } else if (j > 0 && (i == 0 || lcs[i][j - 1] >= lcs[i - 1][j])) {
        result.add(_DiffLine(_LineType.added, newLines[j - 1]));
        j--;
      } else {
        result.add(_DiffLine(_LineType.removed, oldLines[i - 1]));
        i--;
      }
    }
    return result.reversed.toList();
  }

  String _typeLabel() {
    switch (widget.type) {
      case 'user_info':
        return 'User Info';
      case 'memory':
        return 'Memory';
      case 'soul':
        return 'Soul';
      case 'artifact':
        return 'Artifact';
      default:
        return 'Diff';
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;
    final lines = _computeLineDiff(widget.before, widget.after);
    final addedCount = lines.where((l) => l.type == _LineType.added).length;
    final removedCount = lines.where((l) => l.type == _LineType.removed).length;

    final bgColor =
        isDark ? const Color(0xFF1B2030) : const Color(0xFFF6F8FA);
    final borderColor =
        isDark ? const Color(0xFF2D3748) : const Color(0xFFD0D7DE);
    final headerBg =
        isDark ? const Color(0xFF242B3D) : const Color(0xFFEFF2F5);

    final title = widget.title ?? _typeLabel();
    final topRadius = _expanded
        ? const BorderRadius.vertical(top: Radius.circular(7))
        : BorderRadius.circular(7);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: topRadius,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: headerBg,
                borderRadius: topRadius,
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.difference_rounded,
                    size: 14,
                    color: colorScheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (addedCount > 0)
                    _StatChip(
                      label: '+$addedCount',
                      color: const Color(0xFF2EA043),
                    ),
                  if (removedCount > 0) ...[
                    const SizedBox(width: 4),
                    _StatChip(
                      label: '-$removedCount',
                      color: const Color(0xFFCF222E),
                    ),
                  ],
                  if (addedCount == 0 && removedCount == 0)
                    Text(
                      'no changes',
                      style: TextStyle(
                        fontSize: 11,
                        color: colorScheme.onSurface.withValues(alpha: 0.5),
                      ),
                    ),
                  const Spacer(),
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: 16,
                    color: colorScheme.onSurface.withValues(alpha: 0.45),
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
            Divider(height: 1, thickness: 1, color: borderColor),
            ClipRRect(
              borderRadius: const BorderRadius.vertical(
                bottom: Radius.circular(7),
              ),
              child: _buildDiffLines(lines, isDark),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDiffLines(List<_DiffLine> lines, bool isDark) {
    if (lines.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Text(
          '(empty)',
          style: TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: lines.map((l) => _buildLine(l, isDark)).toList(),
    );
  }

  Widget _buildLine(_DiffLine line, bool isDark) {
    final Color bg;
    final Color textColor;
    final String prefix;

    switch (line.type) {
      case _LineType.added:
        bg = isDark ? const Color(0xFF0D2F1A) : const Color(0xFFE6FFEC);
        textColor =
            isDark ? const Color(0xFF7EE787) : const Color(0xFF1A7F37);
        prefix = '+';
        break;
      case _LineType.removed:
        bg = isDark ? const Color(0xFF2D0F0F) : const Color(0xFFFFEBE9);
        textColor =
            isDark ? const Color(0xFFFF7B72) : const Color(0xFFCF222E);
        prefix = '-';
        break;
      case _LineType.context:
        bg = Colors.transparent;
        textColor =
            isDark ? const Color(0xFFADBBC4) : const Color(0xFF57606A);
        prefix = ' ';
        break;
    }

    return Container(
      color: bg,
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: prefix,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: textColor,
                fontWeight: line.type == _LineType.context
                    ? FontWeight.normal
                    : FontWeight.w600,
              ),
            ),
            TextSpan(
              text: ' ${line.text}',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: textColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  const _StatChip({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
          fontFamily: 'monospace',
        ),
      ),
    );
  }
}
