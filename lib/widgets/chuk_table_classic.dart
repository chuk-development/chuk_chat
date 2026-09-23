// lib/widgets/chuk_table_classic.dart
//
// Upstream chuk_chat's table, kept verbatim for the build without
// FEATURE_AGENTS. The Agents build renders tables with the reworked
// [ChukTable] (pinned first column, column kinds, the copy button); chuk_chat
// must look exactly like upstream, so its chat keeps this one. The parse
// ([ParsedTable], [parseTable]) is shared and lives in chuk_table.dart.
//
// When upstream changes its chuk_table.dart widget, mirror the change here.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:chuk_chat/widgets/chuk_table.dart' show ParsedTable;
import 'package:chuk_chat/widgets/icons/icon_map.dart';

/// Upstream's rounded-card table: a shaded, bold header row, thin row
/// separators, first-column emphasis, accent chips for fully-bold cells, a
/// copy-the-table button and horizontal scrolling.
class ChukTableClassic extends StatefulWidget {
  const ChukTableClassic({
    super.key,
    required this.table,
    required this.textColor,
    required this.accentColor,
    this.fontFamily,
    this.fontSize = 13.5,
  });

  final ParsedTable table;
  final Color textColor;
  final Color accentColor;
  final String? fontFamily;
  final double fontSize;

  @override
  State<ChukTableClassic> createState() => _ChukTableClassicState();
}

/// Height kept free under the table body for the horizontal scrollbar.
const double _kScrollbarLane = 12;

class _ChukTableClassicState extends State<ChukTableClassic> {
  bool _copied = false;

  /// Shared by the horizontal Scrollbar and its SingleChildScrollView so the
  /// scrollbar thumb is draggable and the two stay in sync.
  final ScrollController _hCtrl = ScrollController();

  @override
  void dispose() {
    _hCtrl.dispose();
    super.dispose();
  }

  String _asMarkdown() {
    final ParsedTable t = widget.table;
    String pipe(List<String> cells) => '| ${cells.join(' | ')} |';
    final String sep =
        '| ${List<String>.filled(t.columnCount, '---').join(' | ')} |';
    final List<String> out = <String>[pipe(t.header), sep];
    for (final List<String> r in t.rows) {
      out.add(pipe(r));
    }
    return out.join('\n');
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _asMarkdown()));
    if (!mounted) return;
    setState(() => _copied = true);
    Future<void>.delayed(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final ParsedTable t = widget.table;
    final Color border = widget.textColor.withValues(alpha: 0.12);
    final Color headerBg = widget.accentColor.withValues(alpha: 0.10);
    final Color rowAlt = widget.textColor.withValues(alpha: 0.03);

    final List<TableRow> rows = <TableRow>[
      TableRow(
        decoration: BoxDecoration(color: headerBg),
        children: List<Widget>.generate(
          t.columnCount,
          (c) => _cell(
            t.header[c],
            align: t.alignments[c],
            header: true,
            firstCol: c == 0,
          ),
        ),
      ),
    ];
    for (int r = 0; r < t.rows.length; r++) {
      final List<String> row = t.rows[r];
      rows.add(
        TableRow(
          decoration: BoxDecoration(
            color: r.isOdd ? rowAlt : Colors.transparent,
          ),
          children: List<Widget>.generate(
            t.columnCount,
            (c) => _cell(
              row[c],
              align: t.alignments[c],
              header: false,
              firstCol: c == 0,
            ),
          ),
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      width: double.infinity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // Fill the full message width when the table fits, but fall back to
          // horizontal scrolling when it is genuinely wider than the column —
          // so a wide table scrolls left/right inside its card instead of
          // cramming every cell.
          LayoutBuilder(
            builder: (context, constraints) {
              final double maxW = constraints.maxWidth;
              final bool fits =
                  !maxW.isFinite || _estimatedNaturalWidth(t) <= maxW;

              final Widget table = Table(
                columnWidths: fits ? _flexColumnWidths(t) : null,
                defaultColumnWidth: fits
                    ? const FlexColumnWidth()
                    : const IntrinsicColumnWidth(),
                defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                border: TableBorder(
                  horizontalInside: BorderSide(color: border, width: 1),
                ),
                children: rows,
              );

              final Widget card = Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: border, width: 1),
                ),
                clipBehavior: Clip.antiAlias,
                child: table,
              );

              if (fits) return card;
              // Too wide: the card sizes to the table's intrinsic width
              // (wider than maxW) inside the horizontal scroller. Enable mouse
              // drag as a scroll device and a draggable, always-visible
              // scrollbar — otherwise on desktop there is no way to pan a wide
              // table left/right (the wheel scrolls the page vertically).
              return ScrollConfiguration(
                behavior: ScrollConfiguration.of(context).copyWith(
                  dragDevices: <PointerDeviceKind>{
                    PointerDeviceKind.touch,
                    PointerDeviceKind.mouse,
                    PointerDeviceKind.trackpad,
                    PointerDeviceKind.stylus,
                  },
                  scrollbars: false,
                ),
                child: Scrollbar(
                  controller: _hCtrl,
                  thumbVisibility: true,
                  interactive: true,
                  child: SingleChildScrollView(
                    controller: _hCtrl,
                    scrollDirection: Axis.horizontal,
                    // The scrollbar is drawn over the bottom edge of the
                    // viewport, so the table keeps a lane free below itself.
                    // Without it the thumb lies across the last row.
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: _kScrollbarLane),
                      child: card,
                    ),
                  ),
                ),
              );
            },
          ),
          // Copy control sits below the table, right-aligned, instead of
          // floating over the top-right corner where it covered header text.
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Align(
              alignment: Alignment.centerRight,
              child: _CopyButton(
                copied: _copied,
                color: widget.textColor,
                accent: widget.accentColor,
                onTap: _copy,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Column widths proportional to the longest visible cell in each column,
  /// clamped so one very long cell can't starve the rest and a tiny column
  /// still gets a sane share. Using flex widths makes the table fill the full
  /// available width rather than sitting at its intrinsic content width.
  Map<int, TableColumnWidth> _flexColumnWidths(ParsedTable t) {
    final Map<int, TableColumnWidth> widths = <int, TableColumnWidth>{};
    for (int c = 0; c < t.columnCount; c++) {
      int maxLen = _visibleLen(c < t.header.length ? t.header[c] : '');
      for (final List<String> row in t.rows) {
        if (c < row.length) {
          final int l = _visibleLen(row[c]);
          if (l > maxLen) maxLen = l;
        }
      }
      widths[c] = FlexColumnWidth(maxLen.clamp(3, 40).toDouble());
    }
    return widths;
  }

  /// Rough on-screen length of a cell: drop the inline markdown markers so
  /// `**bold**` / `` `code` `` don't inflate a column's weight.
  int _visibleLen(String raw) =>
      raw.replaceAll(RegExp(r'[*_`]'), '').trim().length;

  /// Rough natural pixel width of the table if every cell sat on one line.
  /// Used only to decide between filling the width (flex columns) and
  /// horizontal scrolling (intrinsic columns) — a slight misestimate near the
  /// boundary is harmless since either layout reads fine there.
  double _estimatedNaturalWidth(ParsedTable t) {
    const double cellPadding = 26; // 12 + 12 from _cell, plus a little slack.
    final double charWidth = widget.fontSize * 0.58; // avg glyph advance.
    double total = 0;
    for (int c = 0; c < t.columnCount; c++) {
      int maxLen = _visibleLen(c < t.header.length ? t.header[c] : '');
      for (final List<String> row in t.rows) {
        if (c < row.length) {
          final int l = _visibleLen(row[c]);
          if (l > maxLen) maxLen = l;
        }
      }
      total += maxLen * charWidth + cellPadding;
    }
    return total;
  }

  Widget _cell(
    String raw, {
    required TextAlign align,
    required bool header,
    required bool firstCol,
  }) {
    final String trimmed = raw.trim();
    // A fully-bold cell is a highlight: strip the ** and draw an accent chip.
    final bool highlight =
        !header &&
        trimmed.length >= 4 &&
        trimmed.startsWith('**') &&
        trimmed.endsWith('**') &&
        trimmed.substring(2, trimmed.length - 2).trim().isNotEmpty;

    final TextStyle base = TextStyle(
      color: widget.textColor,
      fontSize: widget.fontSize,
      height: 1.35,
      fontFamily: widget.fontFamily,
      fontWeight: header || firstCol ? FontWeight.w600 : FontWeight.w400,
    );

    Widget content;
    if (highlight) {
      content = Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: widget.accentColor.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(7),
        ),
        child: Text.rich(
          _inlineSpans(
            trimmed.substring(2, trimmed.length - 2),
            base.copyWith(
              color: widget.accentColor,
              fontWeight: FontWeight.w700,
            ),
          ),
          textAlign: align,
        ),
      );
    } else {
      content = Text.rich(_inlineSpans(trimmed, base), textAlign: align);
    }

    Alignment boxAlign = Alignment.centerLeft;
    if (align == TextAlign.center) boxAlign = Alignment.center;
    if (align == TextAlign.right) boxAlign = Alignment.centerRight;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
      child: Align(alignment: boxAlign, child: content),
    );
  }

  /// Minimal inline markdown for cells: **bold**, *italic*, `code`, [t](url).
  /// Links render as accent-coloured text (non-tappable here to keep the table
  /// selectable and simple); everything else falls back to plain text.
  TextSpan _inlineSpans(String text, TextStyle base) {
    final List<InlineSpan> spans = <InlineSpan>[];
    final RegExp pattern = RegExp(
      r'(\*\*(?<b>[^*]+)\*\*)'
      r'|(__(?<b2>[^_]+)__)'
      r'|(`(?<c>[^`]+)`)'
      r'|(\[(?<lt>[^\]]+)\]\((?<lu>[^)]+)\))'
      r'|(\*(?<i>[^*]+)\*)'
      r'|(_(?<i2>[^_]+)_)',
    );
    int last = 0;
    for (final RegExpMatch mtch in pattern.allMatches(text)) {
      if (mtch.start > last) {
        spans.add(TextSpan(text: text.substring(last, mtch.start), style: base));
      }
      final String? b = mtch.namedGroup('b') ?? mtch.namedGroup('b2');
      final String? code = mtch.namedGroup('c');
      final String? link = mtch.namedGroup('lt');
      final String? italic = mtch.namedGroup('i') ?? mtch.namedGroup('i2');
      if (b != null) {
        spans.add(TextSpan(
          text: b,
          style: base.copyWith(fontWeight: FontWeight.w700),
        ));
      } else if (code != null) {
        spans.add(TextSpan(
          text: code,
          style: base.copyWith(
            fontFamily: 'monospace',
            fontSize: base.fontSize! - 0.5,
            color: widget.accentColor,
          ),
        ));
      } else if (link != null) {
        spans.add(TextSpan(
          text: link,
          style: base.copyWith(color: widget.accentColor),
        ));
      } else if (italic != null) {
        spans.add(TextSpan(
          text: italic,
          style: base.copyWith(fontStyle: FontStyle.italic),
        ));
      }
      last = mtch.end;
    }
    if (last < text.length) {
      spans.add(TextSpan(text: text.substring(last), style: base));
    }
    if (spans.isEmpty) spans.add(TextSpan(text: text, style: base));
    return TextSpan(children: spans);
  }
}

class _CopyButton extends StatelessWidget {
  const _CopyButton({
    required this.copied,
    required this.color,
    required this.accent,
    required this.onTap,
  });

  final bool copied;
  final Color color;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: AppIcon(
            copied ? Icons.check_rounded : Icons.copy_rounded,
            size: 15,
            color: copied ? accent : color.withValues(alpha: 0.55),
          ),
        ),
      ),
    );
  }
}
