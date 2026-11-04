// lib/widgets/diff_widget.dart
import 'dart:math';

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/widgets/icons/icon_map.dart';


enum _LineType { added, removed, context }

class _DiffLine {
  _DiffLine(this.type, this.text, {this.counterpart, this.oldNo, this.newNo});
  final _LineType type;
  final String text;

  /// For paired removed↔added lines: the opposite side's text for word diff.
  final String? counterpart;

  /// 1-based line numbers in the old / new document (null if N/A).
  final int? oldNo;
  final int? newNo;

  /// Word-level spans, computed once on first paint and then reused.
  List<_Span>? _spans;
  bool _spansDone = false;
}

class _Span {
  const _Span(this.text, {required this.changed});
  final String text;
  final bool changed;
}

/// Placeholder for rows of a coarse diff that are not drawn.
class _Truncated {
  const _Truncated(this.count, this.type);
  final int count;
  final _LineType type;
}

/// Number of unchanged context lines kept around each change before folding.
const int _kContextLines = 3;

/// Above this many lines in the changed region the widget skips the LCS and
/// shows the region as one remove-all/add-all block.
@visibleForTesting
const int kDiffMaxChangedLines = 256;

/// Above this many LCS cells (old lines × new lines in the changed region)
/// the widget skips the LCS, whatever the line count.
@visibleForTesting
const int kDiffMaxLcsCells = 4000000;

/// In a coarse diff, at most this many rows per side are drawn.
const int _kCoarseRowsPerSide = 120;

/// Word diff runs only when tokens(a) × tokens(b) stays below this budget.
const int _kMaxWordCells = 250000;

/// A diff card draws at most this many rows before "Show all" (harness
/// `DiffBlock`: 9 rows, then fold). Folded-context markers count as rows.
@visibleForTesting
const int kDiffCollapsedRows = 9;

/// Lines added and removed between [before] and [after], counted the way
/// the diff card counts them. Memoised: a collapsed tool row asks for the
/// same pair on every repaint.
({int added, int removed}) diffChangeCount(String before, String after) {
  final String key = '${before.hashCode}:${after.hashCode}:'
      '${before.length}:${after.length}';
  final cached = _changeCountCache[key];
  if (cached != null) return cached;
  final r = _DiffWidgetState._computeDiff(before, after);
  if (_changeCountCache.length > 64) _changeCountCache.clear();
  return _changeCountCache[key] = (added: r.added, removed: r.removed);
}

final Map<String, ({int added, int removed})> _changeCountCache =
    <String, ({int added, int removed})>{};

final RegExp _resultDiffRegex = RegExp(
  r'<\s*diff\s*>([\s\S]*?)<\s*/\s*diff\s*>',
  caseSensitive: false,
);

/// The summed change count of every `<diff>{before, after}</diff>` block in a
/// tool result, or null when the result carries none.
({int added, int removed})? diffChangeCountInResult(String? result) {
  if (result == null || !result.contains('diff')) return null;
  int added = 0;
  int removed = 0;
  bool any = false;
  for (final RegExpMatch match in _resultDiffRegex.allMatches(result)) {
    try {
      final Object? data = jsonDecode(match.group(1)!);
      if (data is! Map) continue;
      final counts = diffChangeCount(
        data['before'] as String? ?? '',
        data['after'] as String? ?? '',
      );
      added += counts.added;
      removed += counts.removed;
      any = true;
    } catch (_) {}
  }
  return any ? (added: added, removed: removed) : null;
}

/// Result of one diff run. Computed once per (before, after) pair.
class _DiffResult {
  _DiffResult({
    required this.lines,
    required this.entries,
    required this.added,
    required this.removed,
    required this.coarse,
  });

  final List<_DiffLine> lines;

  /// Rows to draw: a `_DiffLine`, an `int` (folded unchanged lines) or a
  /// `_Truncated` (rows of a coarse block that are not drawn).
  final List<Object> entries;
  final int added;
  final int removed;

  /// True when the LCS was skipped (changed region too large).
  final bool coarse;
}

/// Renders a before/after comparison as a VS Code–style unified diff:
/// line numbers in the gutter, only changed hunks (+ a little context),
/// long unchanged runs folded away, and word-level highlighting with
/// strikethrough on removed text.
///
/// The diff is computed once per input pair (not in `build`). A changed
/// region larger than [kDiffMaxChangedLines] lines or [kDiffMaxLcsCells]
/// LCS cells is shown as a coarse remove-all/add-all block, so a huge diff
/// cannot freeze the UI.
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

  /// Test hook: computes the diff like the widget does and reports whether
  /// the coarse path was taken, plus the +/- counts.
  @visibleForTesting
  static ({bool coarse, int added, int removed}) debugDiffStats(
    String before,
    String after,
  ) {
    final r = _DiffWidgetState._computeDiff(before, after);
    return (coarse: r.coarse, added: r.added, removed: r.removed);
  }

  @override
  State<DiffWidget> createState() => _DiffWidgetState();
}

class _DiffWidgetState extends State<DiffWidget> {
  bool _expanded = true;

  /// The reader asked for every row, past [kDiffCollapsedRows].
  bool _showAll = false;
  late _DiffResult _diff;

  @override
  void initState() {
    super.initState();
    _diff = _computeDiff(widget.before, widget.after);
  }

  @override
  void didUpdateWidget(covariant DiffWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.before != widget.before || oldWidget.after != widget.after) {
      _diff = _computeDiff(widget.before, widget.after);
    }
  }

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

  // ── Line-level diff with line numbers ─────────────────────────────────────

  static _DiffResult _computeDiff(String before, String after) {
    final old = before.isEmpty ? <String>[] : before.split('\n');
    final neu = after.isEmpty ? <String>[] : after.split('\n');

    // Trim the common head and tail first: cheap, and it keeps the LCS to
    // the region that really changed.
    var head = 0;
    while (head < old.length && head < neu.length && old[head] == neu[head]) {
      head++;
    }
    var tail = 0;
    while (tail < old.length - head &&
        tail < neu.length - head &&
        old[old.length - 1 - tail] == neu[neu.length - 1 - tail]) {
      tail++;
    }
    final midOld = old.sublist(head, old.length - tail);
    final midNew = neu.sublist(head, neu.length - tail);

    final coarse =
        midOld.length + midNew.length > kDiffMaxChangedLines ||
        midOld.length * midNew.length > kDiffMaxLcsCells;

    final ops = <(String, _LineType)>[
      for (var k = 0; k < head; k++) (old[k], _LineType.context),
      if (coarse) ...[
        for (final l in midOld) (l, _LineType.removed),
        for (final l in midNew) (l, _LineType.added),
      ] else
        ..._lcsOps(midOld, midNew),
      for (var k = old.length - tail; k < old.length; k++)
        (old[k], _LineType.context),
    ];

    final lines = _numberLines(ops, pairWords: !coarse);
    var added = 0, removed = 0;
    for (final l in lines) {
      if (l.type == _LineType.added) added++;
      if (l.type == _LineType.removed) removed++;
    }
    var entries = _foldContext(lines);
    if (coarse) entries = _truncateCoarse(entries);
    return _DiffResult(
      lines: lines,
      entries: entries,
      added: added,
      removed: removed,
      coarse: coarse,
    );
  }

  static List<(String, _LineType)> _lcsOps(List<String> old, List<String> neu) {
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
    return raw.reversed.toList();
  }

  /// Assigns line numbers and, when [pairWords] is set, pairs adjacent
  /// removed/added lines for the word diff.
  static List<_DiffLine> _numberLines(
    List<(String, _LineType)> ops, {
    required bool pairWords,
  }) {
    final result = <_DiffLine>[];
    var oldNo = 0, newNo = 0;
    var k = 0;
    while (k < ops.length) {
      final (text, type) = ops[k];
      if (type == _LineType.context) {
        oldNo++;
        newNo++;
        result.add(_DiffLine(type, text, oldNo: oldNo, newNo: newNo));
        k++;
      } else if (pairWords &&
          type == _LineType.removed &&
          k + 1 < ops.length &&
          ops[k + 1].$2 == _LineType.added) {
        oldNo++;
        newNo++;
        result.add(
          _DiffLine(
            _LineType.removed,
            text,
            counterpart: ops[k + 1].$1,
            oldNo: oldNo,
          ),
        );
        result.add(
          _DiffLine(
            _LineType.added,
            ops[k + 1].$1,
            counterpart: text,
            newNo: newNo,
          ),
        );
        k += 2;
      } else if (type == _LineType.removed) {
        oldNo++;
        result.add(_DiffLine(type, text, oldNo: oldNo));
        k++;
      } else {
        newNo++;
        result.add(_DiffLine(type, text, newNo: newNo));
        k++;
      }
    }
    return result;
  }

  /// Limits each removed/added run of a coarse diff to a fixed number of
  /// drawn rows; the rest becomes a `_Truncated` entry.
  static List<Object> _truncateCoarse(List<Object> entries) {
    final out = <Object>[];
    var runType = _LineType.context;
    var runLen = 0;
    var hidden = 0;
    void flush() {
      if (hidden > 0) out.add(_Truncated(hidden, runType));
      hidden = 0;
    }

    for (final e in entries) {
      if (e is _DiffLine && e.type != _LineType.context) {
        if (e.type != runType) {
          flush();
          runType = e.type;
          runLen = 0;
        }
        runLen++;
        if (runLen > _kCoarseRowsPerSide) {
          hidden++;
          continue;
        }
      } else {
        flush();
        runType = _LineType.context;
        runLen = 0;
      }
      out.add(e);
    }
    flush();
    return out;
  }

  /// Marks which lines should be visible (changes + context). Returns a list
  /// where entries are either a `_DiffLine` or an `int` = number of folded
  /// unchanged lines.
  static List<Object> _foldContext(List<_DiffLine> lines) {
    final keep = List<bool>.filled(lines.length, false);
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].type != _LineType.context) {
        final lo = max(0, i - _kContextLines);
        final hi = min(lines.length - 1, i + _kContextLines);
        for (var j = lo; j <= hi; j++) {
          keep[j] = true;
        }
      }
    }

    final out = <Object>[];
    var i = 0;
    while (i < lines.length) {
      if (keep[i]) {
        out.add(lines[i]);
        i++;
      } else {
        var folded = 0;
        while (i < lines.length && !keep[i]) {
          folded++;
          i++;
        }
        out.add(folded);
      }
    }
    return out;
  }

  // ── Word-level diff ───────────────────────────────────────────────────────

  static List<String> _tokenise(String line) {
    final tokens = <String>[];
    for (final m in RegExp(r'\w+|[^\w]').allMatches(line)) {
      tokens.add(m.group(0)!);
    }
    return tokens;
  }

  /// Spans for [source] highlighting tokens that differ from [other].
  /// Returns null when the lines are too long for a word diff.
  static List<_Span>? _wordDiff(String source, String other) {
    final srcTok = _tokenise(source);
    final othTok = _tokenise(other);
    if (srcTok.length * othTok.length > _kMaxWordCells) return null;
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

    final merged = <_Span>[];
    for (final s in spans) {
      if (merged.isNotEmpty && merged.last.changed == s.changed) {
        merged[merged.length - 1] = _Span(
          merged.last.text + s.text,
          changed: s.changed,
        );
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
        return 'Page';
      default:
        return 'Diff';
    }
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;
    final folded = _diff.entries;
    final addedCount = _diff.added;
    final removedCount = _diff.removed;

    final borderColor = isDark
        ? const Color(0xFF2D3748)
        : const Color(0xFFD0D7DE);
    // No tinted header — keep it flat so it blends with the surrounding
    // tool card instead of adding a colored (blue) bar.
    const headerBg = Colors.transparent;
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
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: topRadius,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
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
                  AppIcon(
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
                bottom: Radius.circular(7),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_diff.coarse)
                    _buildNote(
                      'Large change, shown without line matching',
                      isDark,
                    ),
                  for (final entry
                      in _showAll || folded.length <= kDiffCollapsedRows
                          ? folded
                          : folded.take(kDiffCollapsedRows))
                    if (entry is int)
                      _buildFold(entry, isDark)
                    else if (entry is _Truncated)
                      _buildNote(
                        '⋯ ${entry.count} more '
                        '${entry.type == _LineType.added ? 'added' : 'removed'} '
                        'line${entry.count == 1 ? '' : 's'}',
                        isDark,
                      )
                    else
                      _buildLine(entry as _DiffLine, isDark),
                  if (!_showAll && folded.length > kDiffCollapsedRows)
                    _buildShowAll(folded.length, isDark),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// The row under a cut card: "Show all 24 rows".
  Widget _buildShowAll(int total, bool isDark) {
    final l10n = AppLocalizations.of(context);
    final String label =
        l10n?.toolActivityText('diffShowAll').replaceAll('{n}', '$total') ??
        'Show all $total rows';
    final Color fg = Theme.of(context).colorScheme.onSurface.withValues(
      alpha: 0.7,
    );
    return InkWell(
      key: const ValueKey<String>('diff-show-all'),
      onTap: () => setState(() => _showAll = true),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIcon(Icons.keyboard_arrow_down, size: 14, color: fg),
            const SizedBox(width: 4),
            Text(
              label.startsWith('toolActivity_') ? 'Show all $total rows' : label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: fg,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFold(int count, bool isDark) =>
      _buildNote('⋯ $count unchanged line${count == 1 ? '' : 's'}', isDark);

  Widget _buildNote(String text, bool isDark) {
    final fg = isDark ? const Color(0xFF5A6678) : const Color(0xFF8C959F);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Text(
        text,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 11,
          color: fg,
          fontStyle: FontStyle.italic,
        ),
      ),
    );
  }

  Widget _buildLine(_DiffLine line, bool isDark) {
    final Color lineBg;
    final Color baseColor;
    final String prefix;

    switch (line.type) {
      case _LineType.added:
        lineBg = isDark ? const Color(0xFF0F2318) : const Color(0xFFE6FFEC);
        baseColor = isDark ? const Color(0xFF7EE787) : const Color(0xFF1A7F37);
        prefix = '+';
        break;
      case _LineType.removed:
        lineBg = isDark ? const Color(0xFF290D0D) : const Color(0xFFFFEBE9);
        baseColor = isDark ? const Color(0xFFFF7B72) : const Color(0xFFCF222E);
        prefix = '-';
        break;
      case _LineType.context:
        lineBg = Colors.transparent;
        baseColor = isDark ? const Color(0xFF8B9BB4) : const Color(0xFF57606A);
        prefix = ' ';
        break;
    }

    final gutterColor = isDark
        ? const Color(0xFF566072)
        : const Color(0xFF8C959F);

    final hasPair = line.counterpart != null && line.type != _LineType.context;
    if (hasPair && !line._spansDone) {
      line._spans = _wordDiff(line.text, line.counterpart!);
      line._spansDone = true;
    }
    final spans = hasPair ? line._spans : null;

    final wordHighlight = line.type == _LineType.added
        ? (isDark ? const Color(0xFF1A5C2A) : const Color(0xFFABF2BC))
        : (isDark ? const Color(0xFF5C1414) : const Color(0xFFFFBBBB));

    return Container(
      color: lineBg,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Old line number gutter
          SizedBox(
            width: 26,
            child: Text(
              line.oldNo?.toString() ?? '',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: gutterColor,
              ),
            ),
          ),
          const SizedBox(width: 6),
          // New line number gutter
          SizedBox(
            width: 26,
            child: Text(
              line.newNo?.toString() ?? '',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: gutterColor,
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Content
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '$prefix ',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: baseColor,
                    ),
                  ),
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
                          backgroundColor: span.changed
                              ? wordHighlight
                              : Colors.transparent,
                          decoration:
                              (span.changed && line.type == _LineType.removed)
                              ? TextDecoration.lineThrough
                              : TextDecoration.none,
                          decorationColor: baseColor,
                        ),
                      ),
                ],
              ),
            ),
          ),
        ],
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
