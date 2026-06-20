// lib/widgets/diff_widget.dart
import 'dart:math';

import 'package:flutter/material.dart';

enum _LineType { added, removed, context }

class _DiffLine {
  const _DiffLine(this.type, this.text, {this.counterpart});
  final _LineType type;
  final String text;

  /// For paired removed/added lines: the opposite side's text (for intra-line diff).
  final String? counterpart;
}

/// A token-level diff segment within a single line.
class _Span {
  const _Span(this.text, {required this.changed});
  final String text;
  final bool changed;
}

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

  /// Semantic type label: 'user_info', 'memory', 'soul', 'artifact', etc.
  final String? type;

  @override
  State<DiffWidget> createState() => _DiffWidgetState();
}

class _DiffWidgetState extends State<DiffWidget> {
  bool _expanded = true;

  // ── LCS helpers ──────────────────────────────────────────────────────────

  static List<T> _lcs<T>(List<T> a, List<T> b) {
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

    // Collect raw diff operations: removed / added / context
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

    // Pair up adjacent removed/added lines for intra-line diff.
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

  // ── Word-level intra-line diff ───────────────────────────────────────────

  static List<String> _tokenise(String line) {
    // Split on word boundaries but keep punctuation/spaces as own tokens.
    final tokens = <String>[];
    final re = RegExp(r'\w+|[^\w]');
    for (final m in re.allMatches(line)) {
      tokens.add(m.group(0)!);
    }
    return tokens;
  }

  static List<_Span> _intraLineDiff(String a, String b, bool isRemoved) {
    final aTokens = _tokenise(a);
    final bTokens = _tokenise(b);
    final sourceTokens = isRemoved ? aTokens : bTokens;
    final otherTokens = isRemoved ? bTokens : aTokens;
    final commonSeq = _lcs(sourceTokens, otherTokens);

    final spans = <_Span>[];
    var commonIdx = 0;
    for (final tok in sourceTokens) {
      if (commonIdx < commonSeq.length && tok == commonSeq[commonIdx]) {
        spans.add(_Span(tok, changed: false));
        commonIdx++;
      } else {
        spans.add(_Span(tok, changed: true));
      }
    }
    // Merge consecutive same-changed spans for cleaner output.
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

  // ── UI ────────────────────────────────────────────────────────────────────

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
    final lines = _lineDiff(widget.before, widget.after);
    final addedCount = lines.where((l) => l.type == _LineType.added).length;
    final removedCount = lines.where((l) => l.type == _LineType.removed).length;

    final bgColor = isDark ? const Color(0xFF1B2030) : const Color(0xFFF6F8FA);
    final borderColor =
        isDark ? const Color(0xFF2D3748) : const Color(0xFFD0D7DE);
    final headerBg =
        isDark ? const Color(0xFF242B3D) : const Color(0xFFEFF2F5);
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
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration:
                  BoxDecoration(color: headerBg, borderRadius: topRadius),
              child: Row(
                children: [
                  Icon(Icons.difference_rounded,
                      size: 14, color: colorScheme.primary),
                  const SizedBox(width: 6),
                  Text(
                    widget.title ?? _typeLabel(),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: colorScheme.onSurface,
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
                  bottom: Radius.circular(7)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: lines
                    .map((l) => _buildLine(l, isDark))
                    .toList(),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildLine(_DiffLine line, bool isDark) {
    final Color bg;
    final Color baseText;
    final String prefix;

    switch (line.type) {
      case _LineType.added:
        bg = isDark ? const Color(0xFF0D2F1A) : const Color(0xFFE6FFEC);
        baseText =
            isDark ? const Color(0xFF7EE787) : const Color(0xFF1A7F37);
        prefix = '+';
        break;
      case _LineType.removed:
        bg = isDark ? const Color(0xFF2D0F0F) : const Color(0xFFFFEBE9);
        baseText =
            isDark ? const Color(0xFFFF7B72) : const Color(0xFFCF222E);
        prefix = '-';
        break;
      case _LineType.context:
        bg = Colors.transparent;
        baseText =
            isDark ? const Color(0xFFADBBC4) : const Color(0xFF57606A);
        prefix = ' ';
        break;
    }

    // For paired changed lines, show intra-line word diff.
    final hasPair = line.counterpart != null &&
        line.type != _LineType.context;
    final spans = hasPair
        ? _intraLineDiff(
            line.text, line.counterpart!, line.type == _LineType.removed)
        : null;

    final highlightBg = line.type == _LineType.added
        ? (isDark ? const Color(0xFF1A4F1A) : const Color(0xFFACF2BD))
        : (isDark ? const Color(0xFF5C1414) : const Color(0xFFFFA5A5));

    return Container(
      color: bg,
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$prefix ',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: baseText,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (spans == null)
              TextSpan(
                text: line.text,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: baseText,
                ),
              )
            else
              for (final span in spans)
                TextSpan(
                  text: span.text,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: baseText,
                    backgroundColor:
                        span.changed ? highlightBg : Colors.transparent,
                    fontWeight:
                        span.changed ? FontWeight.w700 : FontWeight.normal,
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
