// lib/widgets/diff_widget.dart
import 'dart:math';

import 'package:flutter/material.dart';

enum _LineType { added, removed, context }

class _DiffLine {
  const _DiffLine(this.type, this.text, {this.counterpart});
  final _LineType type;
  final String text;

  /// For paired removed↔added lines: the opposite side's text for intra-line diff.
  final String? counterpart;
}

class _Span {
  const _Span(this.text, {required this.changed});
  final String text;
  final bool changed;
}

/// Renders a before/after text comparison as a VS Code–style unified diff.
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
  final String? title;
  final String? type;

  @override
  State<DiffWidget> createState() => _DiffWidgetState();
}

class _DiffWidgetState extends State<DiffWidget> {
  bool _expanded = true;

  // ── LCS ──────────────────────────────────────────────────────────────────

  static List<T> _lcsOf<T>(List<T> a, List<T> b) {
    final m = a.length, n = b.length;
    final dp = List.generate(m + 1, (_) => List.filled(n + 1, 0));
    for (var i = 1; i <= m; i++) {
      for (var j = 1; j <= n; j++) {
        dp[i][j] = a[i - 1] == b[j - 1]
            ? dp[i - 1][j - 1] + 1
            : max(dp[i - 1][j], dp[i][j - 1]);
      }
    }
    final result = <T>[];
    var i = m, j = n;
    while (i > 0 && j > 0) {
      if (a[i - 1] == b[j - 1]) {
        result.add(a[i - 1]);
        i--;
        j--;
      } else if (dp[i - 1][j] >= dp[i][j - 1]) {
        i--;
      } else {
        j--;
      }
    }
    return result.reversed.toList();
  }

  // ── Line-level diff ───────────────────────────────────────────────────────

  static List<_DiffLine> _lineDiff(String before, String after) {
    final old = before.isEmpty ? <String>[] : before.split('\n');
    final neu = after.isEmpty ? <String>[] : after.split('\n');
    final m = old.length, n = neu.length;

    final dp = List.generate(m + 1, (_) => List.filled(n + 1, 0));
    for (var i = 1; i <= m; i++) {
      for (var j = 1; j <= n; j++) {
        dp[i][j] = old[i - 1] == neu[j - 1]
            ? dp[i - 1][j - 1] + 1
            : max(dp[i - 1][j], dp[i][j - 1]);
      }
    }

    final raw = <(String, _LineType)>[];
    var i = m, j = n;
    while (i > 0 || j > 0) {
      if (i > 0 && j > 0 && old[i - 1] == neu[j - 1]) {
        raw.add((old[i - 1], _LineType.context));
        i--;
        j--;
      } else if (j > 0 && (i == 0 || dp[i][j - 1] >= dp[i - 1][j])) {
        raw.add((neu[j - 1], _LineType.added));
        j--;
      } else {
        raw.add((old[i - 1], _LineType.removed));
        i--;
      }
    }
    final ops = raw.reversed.toList();

    // Pair adjacent removed+added lines for intra-line diff.
    final result = <_DiffLine>[];
    var k = 0;
    while (k < ops.length) {
      final (text, type) = ops[k];
      if (type == _LineType.removed &&
          k + 1 < ops.length &&
          ops[k + 1].$2 == _LineType.added) {
        result.add(_DiffLine(_LineType.removed, text, counterpart: ops[k + 1].$1));
        result.add(_DiffLine(_LineType.added, ops[k + 1].$1, counterpart: text));
        k += 2;
      } else {
        result.add(_DiffLine(type, text));
        k++;
      }
    }
    return result;
  }

  // ── Intra-line word diff ─────────────────────────────────────────────────

  static List<String> _tokenise(String line) {
    final tokens = <String>[];
    for (final m in RegExp(r'\w+|[^\w]').allMatches(line)) {
      tokens.add(m.group(0)!);
    }
    return tokens;
  }

  /// Returns spans for [source] showing which tokens differ from [other].
  static List<_Span> _wordDiff(String source, String other) {
    final srcTok = _tokenise(source);
    final othTok = _tokenise(other);
    final common = _lcsOf(srcTok, othTok);

    final spans = <_Span>[];
    var ci = 0;
    for (final tok in srcTok) {
      if (ci < common.length && tok == common[ci]) {
        spans.add(_Span(tok, changed: false));
        ci++;
      } else {
        spans.add(_Span(tok, changed: true));
      }
    }

    // Merge consecutive same-changed spans.
    final merged = <_Span>[];
    for (final s in spans) {
      if (merged.isNotEmpty && merged.last.changed == s.changed) {
        merged[merged.length - 1] =
            _Span(merged.last.text + s.text, changed: s.changed);
      } else {
        merged.add(s);
      }
    }
    return merged;
  }

  // ── Label ────────────────────────────────────────────────────────────────

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

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;
    final lines = _lineDiff(widget.before, widget.after);
    final addedCount = lines.where((l) => l.type == _LineType.added).length;
    final removedCount = lines.where((l) => l.type == _LineType.removed).length;

    final borderColor =
        isDark ? const Color(0xFF2D3748) : const Color(0xFFD0D7DE);
    final headerBg =
        isDark ? const Color(0xFF1E2433) : const Color(0xFFF0F3F6);
    final topRadius = _expanded
        ? const BorderRadius.vertical(top: Radius.circular(7))
        : BorderRadius.circular(7);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: topRadius,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: headerBg,
                borderRadius: topRadius,
              ),
              child: Row(
                children: [
                  Text(
                    widget.title ?? _typeLabel(),
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: colorScheme.onSurface.withValues(alpha: 0.7),
                      letterSpacing: 0.2,
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (addedCount > 0)
                    _Chip('+$addedCount', const Color(0xFF2EA043)),
                  if (removedCount > 0) ...[
                    const SizedBox(width: 4),
                    _Chip('-$removedCount', const Color(0xFFCF222E)),
                  ],
                  if (addedCount == 0 && removedCount == 0)
                    Text(
                      'unchanged',
                      style: TextStyle(
                        fontSize: 11,
                        color: colorScheme.onSurface.withValues(alpha: 0.4),
                      ),
                    ),
                  const Spacer(),
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: 14,
                    color: colorScheme.onSurface.withValues(alpha: 0.4),
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
            Divider(height: 1, thickness: 1, color: borderColor),
            ClipRRect(
              borderRadius: const BorderRadius.vertical(
                  bottom: Radius.circular(7)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: lines.map((l) => _buildLine(l, isDark)).toList(),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildLine(_DiffLine line, bool isDark) {
    final Color lineBg;
    final Color baseColor;
    final String prefix;

    switch (line.type) {
      case _LineType.added:
        // VS Code: light green bg
        lineBg = isDark ? const Color(0xFF0F2318) : const Color(0xFFE6FFEC);
        baseColor =
            isDark ? const Color(0xFF7EE787) : const Color(0xFF1A7F37);
        prefix = '+';
        break;
      case _LineType.removed:
        // VS Code: light red bg
        lineBg = isDark ? const Color(0xFF290D0D) : const Color(0xFFFFEBE9);
        baseColor =
            isDark ? const Color(0xFFFF7B72) : const Color(0xFFCF222E);
        prefix = '-';
        break;
      case _LineType.context:
        lineBg = Colors.transparent;
        baseColor =
            isDark ? const Color(0xFF8B9BB4) : const Color(0xFF57606A);
        prefix = ' ';
        break;
    }

    // Intra-line word diff for paired removed/added lines.
    final hasPair = line.counterpart != null && line.type != _LineType.context;
    final spans = hasPair ? _wordDiff(line.text, line.counterpart!) : null;

    // VS Code highlight: darker bg on changed words
    final wordHighlight = line.type == _LineType.added
        ? (isDark ? const Color(0xFF1A5C2A) : const Color(0xFFABF2BC))
        : (isDark ? const Color(0xFF5C1414) : const Color(0xFFFFBBBB));

    return Container(
      color: lineBg,
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
      child: Text.rich(
        TextSpan(
          children: [
            // Prefix gutter
            TextSpan(
              text: '$prefix ',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: baseColor,
              ),
            ),
            // Line content
            if (spans == null)
              TextSpan(
                text: line.text,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: baseColor,
                ),
              )
            else
              for (final span in spans)
                TextSpan(
                  text: span.text,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: baseColor,
                    backgroundColor:
                        span.changed ? wordHighlight : Colors.transparent,
                    // VS Code: strikethrough on removed words
                    decoration: (span.changed &&
                            line.type == _LineType.removed)
                        ? TextDecoration.lineThrough
                        : TextDecoration.none,
                    decorationColor: baseColor,
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.label, this.color);
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.25)),
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
