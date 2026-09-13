// lib/widgets/chuk_table.dart
//
// Native, on-brand rendering for GFM markdown tables. Replaces the flat
// `markdown_widget` table with a rounded card: a shaded, bold header row, thin
// horizontal row separators, first-column emphasis, per-cell highlighting for
// fully-bold cells, a copy-the-table button, and horizontal scrolling so a wide
// table scrolls inside itself instead of overflowing the message column.
//
// The model emphasises a cell by making its whole content bold (`**value**`);
// that cell renders as an accent-tinted chip. This is the "highlight what
// matters" convention — no new tag or syntax, just bold.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'package:chuk_chat/ui/expressive/huge_icon.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:flutter/services.dart';

/// One parsed markdown table plus the metadata needed to render it.
class ParsedTable {
  ParsedTable({
    required this.header,
    required this.rows,
    required this.alignments,
  });

  final List<String> header;
  final List<List<String>> rows;
  final List<TextAlign> alignments;

  int get columnCount => header.length;
}

/// Splits a single row of raw cell text on unescaped `|`, dropping the empty
/// cells created by leading/trailing pipes.
List<String> _splitRow(String line) {
  final List<String> cells = <String>[];
  final StringBuffer current = StringBuffer();
  bool escaped = false;
  for (int i = 0; i < line.length; i++) {
    final String ch = line[i];
    if (escaped) {
      current.write(ch);
      escaped = false;
      continue;
    }
    if (ch == r'\') {
      escaped = true;
      current.write(ch);
      continue;
    }
    if (ch == '|') {
      cells.add(current.toString().trim());
      current.clear();
      continue;
    }
    current.write(ch);
  }
  cells.add(current.toString().trim());

  // A row written as `| a | b |` yields ['', 'a', 'b', ''] — trim the empties
  // that the surrounding pipes create, but keep genuinely empty interior cells.
  if (cells.isNotEmpty && cells.first.isEmpty) cells.removeAt(0);
  if (cells.isNotEmpty && cells.last.isEmpty) cells.removeLast();
  return cells;
}

/// Public wrapper around row splitting, used by the markdown splitter to count
/// a candidate header's columns.
List<String> splitTableRow(String line) => _splitRow(line);

final RegExp _delimiterCell = RegExp(r'^\s*:?-{1,}:?\s*$');

TextAlign _alignmentOf(String delimiter) {
  final String d = delimiter.trim();
  final bool left = d.startsWith(':');
  final bool right = d.endsWith(':');
  if (left && right) return TextAlign.center;
  if (right) return TextAlign.right;
  return TextAlign.left;
}

/// Returns true if [line] is a valid GFM delimiter row (`| --- | :-: |`).
bool isTableDelimiterRow(String line) {
  if (!line.contains('|') && !line.contains('-')) return false;
  final List<String> cells = _splitRow(line);
  if (cells.isEmpty) return false;
  return cells.every((c) => _delimiterCell.hasMatch(c));
}

/// Parses a block of lines (header, delimiter, body rows) into a [ParsedTable].
/// Returns null if the block is not a well-formed table.
ParsedTable? parseTable(List<String> lines) {
  if (lines.length < 2) return null;
  final List<String> header = _splitRow(lines[0]);
  final List<String> delimiterCells = _splitRow(lines[1]);
  if (header.isEmpty || !isTableDelimiterRow(lines[1])) return null;

  final int cols = header.length;
  final List<TextAlign> alignments = List<TextAlign>.generate(
    cols,
    (i) => i < delimiterCells.length
        ? _alignmentOf(delimiterCells[i])
        : TextAlign.left,
  );

  final List<List<String>> rows = <List<String>>[];
  for (int i = 2; i < lines.length; i++) {
    final List<String> cells = _splitRow(lines[i]);
    // Normalise ragged rows to the header column count.
    final List<String> normalised = List<String>.generate(
      cols,
      (c) => c < cells.length ? cells[c] : '',
    );
    rows.add(normalised);
  }
  return ParsedTable(header: header, rows: rows, alignments: alignments);
}

/// Under this much room a table that does not fit is stacked instead of
/// scrolled. A phone message column is around 340-400 logical pixels.
const double kChukTableStackBelowWidth = 560;

/// Rough on-screen length of a cell: drop the inline markdown markers so
/// `**bold**` / `` `code` `` don't inflate a column's weight.
int chukVisibleLength(String raw) =>
    raw.replaceAll(RegExp(r'[*_`]'), '').trim().length;

/// Rough natural pixel width of [t] if every cell sat on one line.
double chukTableNaturalWidth(ParsedTable t, {double fontSize = 13.5}) {
  const double cellPadding = 26; // 12 + 12 from _cell, plus a little slack.
  final double charWidth = fontSize * 0.58; // avg glyph advance.
  double total = 0;
  for (int c = 0; c < t.columnCount; c++) {
    int maxLen = chukVisibleLength(c < t.header.length ? t.header[c] : '');
    for (final List<String> row in t.rows) {
      if (c < row.length) {
        final int l = chukVisibleLength(row[c]);
        if (l > maxLen) maxLen = l;
      }
    }
    total += maxLen * charWidth + cellPadding;
  }
  return total;
}

/// Whether [t] would be drawn as one card per row in [maxWidth] of room.
///
/// A stacked card is a paragraph of its own; a grid row is one line. Anything
/// that shows a PART of a table — the inline preview in a thread — has to know
/// which of the two it is about to draw before it decides how many rows it can
/// afford.
bool chukTableStacks(
  ParsedTable t, {
  required double maxWidth,
  double fontSize = 13.5,
}) {
  if (!maxWidth.isFinite || t.columnCount < 2) return false;
  if (maxWidth >= kChukTableStackBelowWidth) return false;
  return chukTableNaturalWidth(t, fontSize: fontSize) > maxWidth;
}

/// A rounded, scrollable, copyable rendering of a markdown table.
class ChukTable extends StatefulWidget {
  const ChukTable({
    super.key,
    required this.table,
    required this.textColor,
    required this.accentColor,
    this.fontFamily,
    this.fontSize = 13.5,
    this.onTapLink,
  });

  final ParsedTable table;
  final Color textColor;
  final Color accentColor;
  final String? fontFamily;
  final double fontSize;

  /// Opens a link from a cell. Null leaves links unopenable — they still read
  /// as links, they just do nothing, which is what a table with no host to ask
  /// gets. The chat passes its own confirm-then-open handler.
  final ValueChanged<String>? onTapLink;

  @override
  State<ChukTable> createState() => _ChukTableState();
}

class _ChukTableState extends State<ChukTable> {
  bool _copied = false;

  /// One recognizer per link span of the current build. Rebuilt with the
  /// spans and disposed with them: a recognizer outliving its span leaks the
  /// gesture arena entry it holds.
  final List<TapGestureRecognizer> _linkTaps = <TapGestureRecognizer>[];

  void _releaseLinkTaps() {
    for (final TapGestureRecognizer tap in _linkTaps) {
      tap.dispose();
    }
    _linkTaps.clear();
  }

  /// Shared by the horizontal Scrollbar and its SingleChildScrollView so the
  /// scrollbar thumb is draggable and the two stay in sync.
  final ScrollController _hCtrl = ScrollController();

  @override
  void dispose() {
    _releaseLinkTaps();
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
    // The spans about to be built own the recognizers; the previous build's
    // are now unreachable.
    _releaseLinkTaps();
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

              // A phone column cannot hold a grid this wide. Sideways scrolling
              // there is not a reading experience: the right-hand columns are
              // off screen, and nothing on the card says they exist (bead
              // cowork-8vqt). Below the threshold the table becomes one card
              // per row, each field labelled by its header, so every value is
              // readable without panning.
              if (!fits && maxW < _stackBelowWidth && t.columnCount >= 2) {
                return _stacked(t, border: border, headerBg: headerBg);
              }

              final Widget table = Table(
                columnWidths: fits
                    ? _flexColumnWidths(t)
                    : {
                        for (var c = 0; c < t.columnCount; c++)
                          c: FixedColumnWidth(maxW < 500 ? 160 : 240),
                      },
                defaultColumnWidth: fits
                    ? const FlexColumnWidth()
                    : const FixedColumnWidth(160),
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
                  thickness: 3,
                  radius: const Radius.circular(6),
                  thumbVisibility: true,
                  interactive: true,
                  child: SingleChildScrollView(
                    controller: _hCtrl,
                    padding: const EdgeInsets.only(bottom: 10),
                    scrollDirection: Axis.horizontal,
                    child: card,
                  ),
                ),
              );
            },
          ),
          // Copy control sits below the table, flush with the card's right
          // edge, instead of floating over the top-right corner where it
          // covered header text. The gap clears the horizontal scrollbar the
          // wide layout draws under the card.
          Padding(
            padding: const EdgeInsets.only(top: 8),
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

  int _visibleLen(String raw) => chukVisibleLength(raw);

  static const double _stackBelowWidth = kChukTableStackBelowWidth;

  /// One card per data row: the first column is the card's title, every other
  /// column becomes a labelled field under it. No horizontal scrolling, so
  /// nothing is hidden off the right edge.
  Widget _stacked(
    ParsedTable t, {
    required Color border,
    required Color headerBg,
  }) {
    final TextStyle labelStyle = TextStyle(
      color: widget.textColor.withValues(alpha: 0.62),
      fontSize: widget.fontSize - 1.5,
      height: 1.3,
      fontFamily: widget.fontFamily,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.2,
    );

    final List<Widget> cards = <Widget>[];
    for (int r = 0; r < t.rows.length; r++) {
      final List<String> row = t.rows[r];
      final List<Widget> fields = <Widget>[];
      for (int c = 1; c < t.columnCount; c++) {
        final String value = c < row.length ? row[c] : '';
        if (value.trim().isEmpty) continue;
        fields.add(
          Padding(
            padding: EdgeInsets.only(top: fields.isEmpty ? 0 : 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  c < t.header.length ? _plain(t.header[c]) : '',
                  style: labelStyle,
                ),
                const SizedBox(height: 2),
                Align(
                  alignment: Alignment.centerLeft,
                  child: _cellContent(
                    value,
                    align: TextAlign.left,
                    header: false,
                    emphasis: false,
                  ),
                ),
              ],
            ),
          ),
        );
      }
      cards.add(
        Padding(
          padding: EdgeInsets.only(top: r == 0 ? 0 : 8),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: border, width: 1),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Container(
                  color: headerBg,
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _cellContent(
                      row.isEmpty ? '' : row[0],
                      align: TextAlign.left,
                      header: false,
                      emphasis: true,
                    ),
                  ),
                ),
                if (fields.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: fields,
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: cards,
    );
  }

  /// A header label with its inline markdown markers removed — a field label
  /// is drawn as plain text, never as a chip.
  String _plain(String raw) => raw.replaceAll(RegExp(r'[*_`]'), '').trim();

  /// Rough natural pixel width of the table if every cell sat on one line.
  /// Used only to decide between filling the width (flex columns) and
  /// horizontal scrolling (intrinsic columns) — a slight misestimate near the
  /// boundary is harmless since either layout reads fine there.
  double _estimatedNaturalWidth(ParsedTable t) =>
      chukTableNaturalWidth(t, fontSize: widget.fontSize);

  Widget _cell(
    String raw, {
    required TextAlign align,
    required bool header,
    required bool firstCol,
  }) {
    Alignment boxAlign = Alignment.centerLeft;
    if (align == TextAlign.center) boxAlign = Alignment.center;
    if (align == TextAlign.right) boxAlign = Alignment.centerRight;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
      child: Align(
        alignment: boxAlign,
        child: _cellContent(
          raw,
          align: align,
          header: header,
          emphasis: header || firstCol,
        ),
      ),
    );
  }

  /// The drawn content of one cell, with no cell padding of its own — the
  /// grid wraps it in [_cell], the stacked layout places it in a field.
  Widget _cellContent(
    String raw, {
    required TextAlign align,
    required bool header,
    required bool emphasis,
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
      fontWeight: emphasis ? FontWeight.w600 : FontWeight.w400,
    );

    if (highlight) {
      return Container(
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
    }
    return Text.rich(_inlineSpans(trimmed, base), textAlign: align);
  }

  /// Minimal inline markdown for cells: **bold**, *italic*, `code`, [t](url).
  /// A link reads as a link — accent colour AND an underline — and opens on a
  /// tap through [ChukTable.onTapLink]. It used to be accent-coloured text
  /// with no underline and no recognizer, so the source links the coworker
  /// puts in its comparison tables were dead (bead cowork-94s9).
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
        spans.add(
          TextSpan(text: text.substring(last, mtch.start), style: base),
        );
      }
      final String? b = mtch.namedGroup('b') ?? mtch.namedGroup('b2');
      final String? code = mtch.namedGroup('c');
      final String? link = mtch.namedGroup('lt');
      final String? italic = mtch.namedGroup('i') ?? mtch.namedGroup('i2');
      if (b != null) {
        spans.add(
          TextSpan(
            text: b,
            style: base.copyWith(fontWeight: FontWeight.w700),
          ),
        );
      } else if (code != null) {
        spans.add(
          TextSpan(
            text: code,
            style: base.copyWith(
              fontFamily: 'monospace',
              fontSize: base.fontSize! - 0.5,
              color: widget.accentColor,
            ),
          ),
        );
      } else if (link != null) {
        final String? href = mtch.namedGroup('lu');
        TapGestureRecognizer? tap;
        final ValueChanged<String>? onTap = widget.onTapLink;
        if (onTap != null && href != null && href.trim().isNotEmpty) {
          tap = TapGestureRecognizer()..onTap = () => onTap(href.trim());
          _linkTaps.add(tap);
        }
        spans.add(
          TextSpan(
            text: link,
            recognizer: tap,
            style: base.copyWith(
              color: widget.accentColor,
              decoration: TextDecoration.underline,
              decorationColor: widget.accentColor,
              decorationThickness: 1.2,
            ),
          ),
        );
      } else if (italic != null) {
        spans.add(
          TextSpan(
            text: italic,
            style: base.copyWith(fontStyle: FontStyle.italic),
          ),
        );
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

/// The copy control under a table.
///
/// It used to be a bare 15 px glyph with no container, no label and no target:
/// under the card's bottom-right corner it read as a stray mark rather than a
/// button. It is now a member of the one button family — [MorphTap], the same
/// surface every expressive button wraps — at the smallest of the app's target
/// heights (38; the 48 of the chrome is too heavy for a secondary action that
/// hangs under a card, and 38 still clears the touch minimum). Corners follow
/// [ExpressiveIconButton]'s formula, size × 0.34 at rest morphing to size ×
/// 0.20 while held, so it sits in the same shape family as the 12-radius card
/// above it. The press is the expressive spring; there is no glow and no
/// gradient.
///
/// The confirmation says the word: the glyph becomes a tick, the label becomes
/// "Copied" and the fill takes the accent for a moment, then it all goes back.
class _CopyButton extends StatelessWidget {
  const _CopyButton({
    required this.copied,
    required this.color,
    required this.accent,
    required this.onTap,
  });

  /// The app's smallest labelled target. Big enough to hit, small enough that
  /// it does not compete with the table it belongs to.
  static const double _height = 38;

  final bool copied;
  final Color color;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // The confirmation travels: fill and glyph move to the accent and back on
    // the expressive decelerate, rather than snapping between two states.
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: copied ? 1 : 0),
      duration: const Duration(milliseconds: 240),
      curve: kExpressiveDecelerate,
      builder: (BuildContext context, double t, Widget? _) {
        final Color fill = Color.lerp(
          color.withValues(alpha: 0.09),
          accent.withValues(alpha: 0.16),
          t,
        )!;
        final Color glyph = Color.lerp(
          color.withValues(alpha: 0.72),
          accent,
          t,
        )!;
        return Semantics(
          button: true,
          label: copied ? 'Table copied' : 'Copy table',
          child: Tooltip(
            message: 'Copy the table as markdown',
            child: MorphTap(
              onTap: onTap,
              color: fill,
              pressedColor: accent.withValues(alpha: 0.22),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(_height * 0.34),
              ),
              pressedShape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(_height * 0.20),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: SizedBox(
                height: _height,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    HugeIcon(
                      copied ? HugeIcons.tick02 : HugeIcons.copy01,
                      size: 16,
                      color: glyph,
                    ),
                    const SizedBox(width: 6),
                    // The label is wider when it says "Copied"; the button
                    // grows into it instead of jumping.
                    AnimatedSize(
                      duration: kExpressiveShort,
                      curve: kExpressiveDecelerate,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        copied ? 'Copied' : 'Copy',
                        style: TextStyle(
                          color: glyph,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.1,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
