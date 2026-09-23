// lib/widgets/chuk_table.dart
//
// A table that reads as a table, at 360 pixels and at 1300.
//
// The rule the format exists for: THE EYE MUST BE ABLE TO RUN DOWN A COLUMN.
// The same field of two different rows lands on the same x, or the thing on
// screen is a list of forms and not a table. Everything below follows from
// that one sentence.
//
//  * The header is printed ONCE, quietly, above a rule. A label repeated on
//    every row is the noise a header exists to remove.
//  * A row is ONE LINE. Three short cells are one line of text, so they take
//    one line of room: a uniform row height, computed from the resolved text
//    style and the reader's text scale, and every cell ellipsised at its
//    column edge. Two rows must never fill a phone.
//  * The FIRST column is the subject of the row and reads strongest; the rest
//    are the quieter colour. The source of a row is the least important thing
//    in it and is drawn as such.
//  * A value too long for its column is CUT, not wrapped. A cut cell carries
//    its whole text in a tooltip (hover on a desktop, a long press on a
//    phone), so nothing is lost silently.
//  * When even the narrowest honest columns do not fit, the table scrolls
//    sideways with the FIRST COLUMN PINNED and a visible scrollbar — never a
//    grid whose right half is off screen with nothing saying it is there.
//
// This replaced one card per row (bead cowork-8vqt). The card stacked a row
// into a labelled block, which fit, but no two rows lined up, so the one thing
// a table is for — comparing a field across rows — was impossible. Density was
// the other half: two rows were a screenful.
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

/// A whole cell that is nothing but one markdown link: `[label](url)`.
final RegExp _wholeCellLink = RegExp(r'^\[([^\]]+)\]\(([^)\s]+)\)$');

/// The label and target of a cell that is exactly one link, else null.
({String label, String href})? chukCellLink(String raw) {
  final RegExpMatch? m = _wholeCellLink.firstMatch(raw.trim());
  if (m == null) return null;
  final String label = (m.group(1) ?? '').trim();
  final String href = (m.group(2) ?? '').trim();
  if (label.isEmpty || href.isEmpty) return null;
  return (label: label, href: href);
}

/// The text a cell actually PAINTS, with the inline markdown taken off.
///
/// A link counts as its label, never as its target: `[instagram.com](https://
/// www.instagram.com/reel/DKx…/)` is thirteen characters on screen and was
/// being measured as sixty. That one mistake was enough to push every other
/// column off the right edge of a phone.
int chukVisibleLength(String raw) => chukVisibleText(raw).length;

/// The same thing as a string: markers dropped, a link reduced to its label.
String chukVisibleText(String raw) => raw
    .replaceAllMapped(
      RegExp(r'\[([^\]]+)\]\(([^)\s]+)\)'),
      (Match m) => m.group(1) ?? '',
    )
    .replaceAll(RegExp(r'[*_`]'), '')
    .trim();

/// A rounded, dense, copyable rendering of a markdown table.
class ChukTable extends StatefulWidget {
  const ChukTable({
    super.key,
    required this.table,
    required this.textColor,
    required this.accentColor,
    this.fontFamily,
    this.fontSize = 13.5,
    this.onTapLink,
    this.surfaceColor,
  });

  final ParsedTable table;
  final Color textColor;
  final Color accentColor;
  final String? fontFamily;
  final double fontSize;

  /// What the table sits on. Used for one thing only: the fade at the right
  /// edge of a table that scrolls sideways, which has to fade into whatever is
  /// behind it. Null leaves the fade out; the pinned rule and the scrollbar
  /// still say the table pans.
  final Color? surfaceColor;

  /// Opens a link from a cell. Null leaves links unopenable — and a cell that
  /// cannot be opened is NOT drawn as a link: it reads as the plain text it
  /// behaves like. A link either works or it does not claim to.
  final ValueChanged<String>? onTapLink;

  @override
  State<ChukTable> createState() => _ChukTableState();
}

/// Room a cell keeps on the outer edges of the table.
const double _kEdgePad = 12;

/// Half the gap between two neighbouring columns.
const double _kGutter = 7;

/// A column never narrows past this much room for its text. Below it a cell is
/// an ellipsis with a letter in front of it, which says nothing. It travels
/// with the reader's text scale: 46 pixels of 18-point text is two letters.
const double _kMinTextWidth = 46;

/// Room for the arrow of a collapsed action column: the glyph plus enough
/// around it to be worth aiming at.
const double _kActionGlyph = 30;

/// How many rows are read to decide column widths and column kinds. A table
/// may hold two thousand rows; the widest cell is almost always in the first
/// screenful, and measuring every one of them on every layout pass would cost
/// more than the pixel it buys. A row past this still draws, and still
/// ellipsises at its column edge.
const int _kRowsSampled = 200;

/// How much of its own header an action column will carry. Past this the
/// header ellipsises rather than the table giving up a readable column.
const double _kActionHeader = 54;

/// A single column never claims more than this much text room, so one long
/// title cannot starve the four columns next to it.
const double _kMaxTextWidth = 260;

/// Air above and below the text of a row.
const double _kRowPadY = 8;

/// How much of the width the pinned first column may take when a table has to
/// scroll. Past this the pinned column IS the table.
const double _kPinnedShare = 0.46;

/// The geometry of one drawn table: what each column gets, how tall a row is,
/// and whether the whole thing had to start panning.
class _Plan {
  const _Plan({
    required this.widths,
    required this.collapsed,
    required this.natural,
    required this.scrolls,
    required this.rowHeight,
    required this.headerHeight,
  });

  /// Per column, including that column's own left and right padding.
  final List<double> widths;

  /// Per column: drawn as one arrow instead of a repeated hostname.
  final List<bool> collapsed;

  /// What each column asked for before the squeeze, so a second pass can see
  /// which columns did not get it.
  final List<double> natural;
  final bool scrolls;
  final double rowHeight;
  final double headerHeight;

  double get total => widths.fold<double>(0, (double a, double b) => a + b);
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

  /// Per column: true when every filled cell is a link, they all paint the
  /// SAME label, and that label is only the host of the link.
  ///
  /// Such a column carries no information at all — "open.spotify.com" three
  /// times over — so its cells drop the repeated string and become the action
  /// they are. The header, printed once, already says which service it is.
  ///
  /// The host test is what keeps this honest: a host is what the app prints
  /// when the DOCUMENT gave it nothing better. A label the document wrote
  /// ("Suche öffnen") is the author talking, and it is kept, repeated or not.
  late List<bool> _collapsedLinkColumns;

  /// Per column: true when every filled cell is a link, whatever it is
  /// labelled with.
  late List<bool> _linkColumns;

  /// Per column: true when every filled cell is a link the APP labelled — the
  /// bare host, because the document gave nothing better. Those labels may be
  /// traded for an arrow when the width runs out. A label the document wrote
  /// never may be.
  late List<bool> _hostLinkColumns;

  /// The column that reads as the subject of the row: the first one that is
  /// not a column of links. A coworker that writes the reel URL first — and
  /// it does — must not end up with a table whose strongest column is a row
  /// of hostnames. The subject of that row is the song.
  late int _subjectColumn;

  @override
  void initState() {
    super.initState();
    _readColumns();
  }

  @override
  void didUpdateWidget(ChukTable old) {
    super.didUpdateWidget(old);
    if (!identical(old.table, widget.table)) _readColumns();
  }

  void _readColumns() {
    _linkColumns = _findLinkColumns(widget.table);
    _hostLinkColumns = _findHostLinkColumns(widget.table);
    _collapsedLinkColumns = _findCollapsedLinkColumns(widget.table);
    _subjectColumn = _linkColumns.indexOf(false);
    if (_subjectColumn < 0) _subjectColumn = 0;
  }

  static List<bool> _findLinkColumns(ParsedTable t) =>
      List<bool>.generate(t.columnCount, (int c) {
        int filled = 0;
        for (final List<String> row in t.rows.take(_kRowsSampled)) {
          final String raw = c < row.length ? row[c].trim() : '';
          if (raw.isEmpty) continue;
          if (chukCellLink(raw) == null) return false;
          filled++;
        }
        return filled > 0;
      });

  /// The host of [href] the way a cell would print it, or null.
  static String? _hostLabel(String href) {
    final Uri? uri = Uri.tryParse(href);
    if (uri == null || uri.host.isEmpty) return null;
    return uri.host.replaceFirst('www.', '');
  }

  static List<bool> _findHostLinkColumns(ParsedTable t) =>
      List<bool>.generate(t.columnCount, (int c) {
        int filled = 0;
        for (final List<String> row in t.rows.take(_kRowsSampled)) {
          final String raw = c < row.length ? row[c].trim() : '';
          if (raw.isEmpty) continue;
          final ({String label, String href})? link = chukCellLink(raw);
          if (link == null || link.label != _hostLabel(link.href)) return false;
          filled++;
        }
        return filled > 0;
      });

  static List<bool> _findCollapsedLinkColumns(ParsedTable t) {
    return List<bool>.generate(t.columnCount, (int c) {
      if (t.rows.length < 2) return false;
      final Set<String> labels = <String>{};
      int filled = 0;
      for (final List<String> row in t.rows.take(_kRowsSampled)) {
        final String raw = c < row.length ? row[c].trim() : '';
        if (raw.isEmpty) continue;
        filled++;
        final ({String label, String href})? link = chukCellLink(raw);
        if (link == null) return false;
        if (link.label != _hostLabel(link.href)) return false;
        labels.add(link.label);
      }
      return filled >= 2 && labels.length == 1;
    });
  }

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

  // ---------------------------------------------------------------- styles

  TextStyle _bodyStyle({required bool emphasis}) => TextStyle(
    color: emphasis
        ? widget.textColor
        : widget.textColor.withValues(alpha: 0.82),
    fontSize: widget.fontSize,
    height: 1.25,
    fontFamily: widget.fontFamily,
    fontWeight: emphasis ? FontWeight.w600 : FontWeight.w400,
  );

  /// The header is a label, not a row: smaller, quieter, spaced. It is the one
  /// place a column name is printed, so it never ellipsises into nothing —
  /// [_kMinTextWidth] keeps a few letters of it alive at every width.
  TextStyle get _headerStyle => TextStyle(
    color: widget.textColor.withValues(alpha: 0.55),
    fontSize: (widget.fontSize - 2.5).clamp(11.0, 13.0),
    height: 1.2,
    fontFamily: widget.fontFamily,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.5,
  );

  double _padLeft(int c) => c == 0 ? _kEdgePad : _kGutter;

  double _padRight(int c, int columns) =>
      c == columns - 1 ? _kEdgePad : _kGutter;

  /// What a cell paints, given the collapse decision for its column.
  /// Measured and drawn from the same function, so the plan and the pixels
  /// cannot disagree. A collapsed cell paints no text at all — it is an
  /// arrow, and the arrow is measured separately.
  String _paintedText(List<bool> collapsed, int column, String raw) =>
      collapsed[column] && chukCellLink(raw) != null
      ? ''
      : chukVisibleText(raw);

  // ------------------------------------------------------------------ plan

  /// The plan, in at most two passes.
  ///
  /// The first pass collapses only the columns that are certainly worthless —
  /// every row the same hostname. The second pass collapses a hostname column
  /// that did not get the room to print a hostname: "instagr…" repeated down
  /// a column is worse than the arrow it stands for, and it costs four times
  /// the width. A label the DOCUMENT wrote is never collapsed, at any width;
  /// that is the author talking.
  _Plan _plan(BuildContext context, double maxWidth) {
    // The LayoutBuilder asks again on every relayout at the same width (a
    // bubble above it grew, the thread scrolled a new row in). Same table,
    // same width, same text scale: same plan.
    final Object key = (
      maxWidth,
      MediaQuery.textScalerOf(context),
      Directionality.of(context),
      _bodyStyle(emphasis: true),
      _headerStyle,
    );
    final _Plan? last = _lastPlan;
    if (last != null &&
        identical(_lastPlanTable, widget.table) &&
        _lastPlanKey == key) {
      return last;
    }
    final _Plan plan = _computePlan(context, maxWidth);
    _lastPlan = plan;
    _lastPlanTable = widget.table;
    _lastPlanKey = key;
    return plan;
  }

  _Plan? _lastPlan;
  ParsedTable? _lastPlanTable;
  Object? _lastPlanKey;

  _Plan _computePlan(BuildContext context, double maxWidth) {
    final List<bool> collapsed = List<bool>.of(_collapsedLinkColumns);
    final _Plan plan = _measurePlan(context, maxWidth, collapsed);
    bool changed = false;
    for (int c = 0; c < widget.table.columnCount; c++) {
      if (collapsed[c] || !_hostLinkColumns[c] || c == _subjectColumn) continue;
      // Either the column did not get the room to print a hostname, or the
      // table is about to start panning — and a hostname column is the first
      // thing to trade away for a table that fits.
      if (plan.scrolls || plan.widths[c] < plan.natural[c] - 0.5) {
        collapsed[c] = true;
        changed = true;
      }
    }
    return changed ? _measurePlan(context, maxWidth, collapsed) : plan;
  }

  _Plan _measurePlan(
    BuildContext context,
    double maxWidth,
    List<bool> collapsed,
  ) {
    final ParsedTable t = widget.table;
    final int n = t.columnCount;
    final TextScaler scaler = MediaQuery.textScalerOf(context);
    final double scale = scaler.scale(widget.fontSize) / widget.fontSize;

    final double rowHeight =
        _measuredLine(context, _bodyStyle(emphasis: true)) + _kRowPadY * 2;
    final double headerHeight = _measuredLine(context, _headerStyle) + 13;
    final double headerEm = _headerStyle.fontSize! * 0.62 * scale;

    // An estimate, not a measurement: it decides proportions and the
    // fits/pans boundary, and the ellipsis catches every error either way.
    // Measuring two thousand cells with a TextPainter on every layout pass
    // would cost more than it is worth.
    final double floorText = _kMinTextWidth * scale;
    final List<double> natural = <double>[];
    final List<double> floors = <double>[];
    // The floor a column would have with no favours done for it. When the
    // favours do not fit, they are dropped rather than pushing the whole
    // table into panning sideways.
    final List<double> plainFloors = <double>[];
    for (int c = 0; c < n; c++) {
      final double pad = _padLeft(c) + _padRight(c, n);
      final double headerWidth =
          (c < t.header.length ? chukVisibleLength(t.header[c]) : 0) * headerEm;
      if (collapsed[c]) {
        // An action column is one arrow wide and it does not negotiate: it
        // has no text to cut and nothing to gain from being squeezed. It is
        // still never narrower than its own header — the header is the only
        // thing on screen that says where the arrow goes.
        final double w = headerWidth.clamp(
          _kActionGlyph,
          _kActionHeader * scale,
        );
        natural.add(w + pad);
        floors.add(w + pad);
        plainFloors.add(w + pad);
        continue;
      }
      final double em =
          widget.fontSize * (c == _subjectColumn ? 0.585 : 0.545) * scale;
      double data = 0;
      for (final List<String> row in t.rows.take(_kRowsSampled)) {
        final String raw = c < row.length ? row[c] : '';
        final double w = _paintedText(collapsed, c, raw).length * em;
        if (w > data) data = w;
      }
      // A long column NAME does not buy width away from the values. The
      // header is a label and a label may ellipsise; a value may not, or the
      // table is lying about its own numbers.
      double text = data;
      final double headerShare = headerWidth.clamp(0, floorText * 1.6);
      if (headerShare > text) text = headerShare;
      text = text.clamp(floorText, _kMaxTextWidth * scale);
      natural.add(text + pad);

      // Two kinds of column keep their width outright rather than negotiate,
      // as long as they are short enough to be no trouble:
      //
      //  * a right-aligned column is a number column, and a number that
      //    ellipsises is worse than no number — "129,9…" reads as a price and
      //    is not one;
      //  * a column of links the DOCUMENT labelled. "Suche öffnen" is the one
      //    thing in that cell worth reading, and it is short; cutting it to
      //    "Suche ö…" throws away the reference and saves twenty pixels.
      final bool keepsItsWidth =
          t.alignments[c] == TextAlign.right ||
          (_linkColumns[c] && !_hostLinkColumns[c]);
      // The subject column keeps more of itself than the rest: it is the one
      // a reader scans, and a cut song title is a cut row.
      final double plain =
          text.clamp(0, c == _subjectColumn ? floorText * 1.35 : floorText) +
          pad;
      plainFloors.add(plain);
      floors.add(keepsItsWidth && text <= floorText * 2.8 ? text + pad : plain);
    }

    double sum(List<double> v) =>
        v.fold<double>(0, (double a, double b) => a + b);
    final double naturalTotal = sum(natural);

    if (!maxWidth.isFinite || naturalTotal <= maxWidth) {
      // Room to spare: hand the slack out in proportion, so the table fills
      // its lane instead of hugging the left edge.
      final double slack = !maxWidth.isFinite ? 0 : maxWidth - naturalTotal;
      return _Plan(
        widths: <double>[
          for (final double w in natural)
            w + (naturalTotal == 0 ? 0 : slack * w / naturalTotal),
        ],
        natural: natural,
        collapsed: collapsed,
        scrolls: false,
        rowHeight: rowHeight,
        headerHeight: headerHeight,
      );
    }

    double floorTotal = sum(floors);
    if (floorTotal > maxWidth) {
      // The favours do not fit. Drop them: a cut label is better than a table
      // that has to be panned to be read.
      floors
        ..clear()
        ..addAll(plainFloors);
      floorTotal = sum(floors);
    }
    if (floorTotal <= maxWidth) {
      // It fits once the wide columns give something back. What is left over
      // the floors is handed out in proportion to what each column asked for,
      // and the subject column counts double — the eye spends its time there.
      final List<double> want = <double>[
        for (int c = 0; c < n; c++)
          (natural[c] - floors[c]) * (c == _subjectColumn ? 1.5 : 1.0),
      ];
      final double wantTotal = sum(want);
      final double spare = maxWidth - floorTotal;
      return _Plan(
        widths: <double>[
          for (int c = 0; c < n; c++)
            floors[c] + (wantTotal == 0 ? 0 : spare * want[c] / wantTotal),
        ],
        natural: natural,
        collapsed: collapsed,
        scrolls: false,
        rowHeight: rowHeight,
        headerHeight: headerHeight,
      );
    }

    // Genuinely wider than the lane: pan, with the first column pinned.
    final List<double> widths = List<double>.of(natural);
    final double cap = maxWidth * _kPinnedShare;
    if (widths[0] > cap) widths[0] = cap;
    return _Plan(
      widths: widths,
      natural: natural,
      collapsed: collapsed,
      scrolls: true,
      rowHeight: rowHeight,
      headerHeight: headerHeight,
    );
  }

  /// The painted height of one line in [style], under the reader's text scale.
  /// Line heights already measured, per style, scaler and direction. Every
  /// table in a thread asks for the same two styles, and a thread switch
  /// builds all the visible ones again: one TextPainter layout each time was
  /// the bulk of [_measurePlan].
  static final Map<(TextStyle, TextScaler, TextDirection), double>
  _lineHeights = <(TextStyle, TextScaler, TextDirection), double>{};

  double _measuredLine(BuildContext context, TextStyle style) {
    final TextDirection direction = Directionality.of(context);
    final TextScaler scaler = MediaQuery.textScalerOf(context);
    final (TextStyle, TextScaler, TextDirection) key = (
      style,
      scaler,
      direction,
    );
    final double? known = _lineHeights[key];
    if (known != null) return known;
    final TextPainter painter = TextPainter(
      text: TextSpan(text: 'Hgjy', style: style),
      textDirection: direction,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    final double height = painter.height;
    painter.dispose();
    // A handful of styles in practice; the cap only guards a theme that
    // changes font size continuously.
    if (_lineHeights.length >= 64) _lineHeights.clear();
    _lineHeights[key] = height;
    return height;
  }

  // ---------------------------------------------------------------- render

  @override
  Widget build(BuildContext context) {
    // The spans about to be built own the recognizers; the previous build's
    // are now unreachable.
    _releaseLinkTaps();

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      width: double.infinity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final _Plan plan = _plan(context, constraints.maxWidth);
              return plan.scrolls ? _panning(plan) : _fitting(plan);
            },
          ),
          // The copy control hangs under the table, flush right, clear of the
          // scrollbar a panning table draws.
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

  Color get _rule => widget.textColor.withValues(alpha: 0.09);
  Color get _headerRule => widget.textColor.withValues(alpha: 0.22);

  Widget _fitting(_Plan plan) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: _pane(plan, first: 0, last: plan.widths.length),
  );

  /// Wider than the lane: the first column stands still, the rest pans under
  /// a scrollbar that is always on screen. Both halves are built from the same
  /// plan, and every row is the same height, so the two sides cannot drift out
  /// of line.
  Widget _panning(_Plan plan) {
    final double rest = plan.total - plan.widths[0];
    final Color? surface = widget.surfaceColor;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        DecoratedBox(
          decoration: BoxDecoration(
            border: Border(right: BorderSide(color: _headerRule, width: 1)),
          ),
          child: SizedBox(
            width: plan.widths[0],
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: _pane(plan, first: 0, last: 1),
            ),
          ),
        ),
        Expanded(
          child: ClipRect(
            child: Stack(
              children: <Widget>[
                ScrollConfiguration(
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
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.only(bottom: 10),
                      child: SizedBox(
                        width: rest,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisSize: MainAxisSize.min,
                          children: _pane(
                            plan,
                            first: 1,
                            last: plan.widths.length,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (surface != null)
                  Positioned(
                    top: 0,
                    bottom: 0,
                    right: 0,
                    width: 20,
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                            colors: <Color>[
                              surface.withValues(alpha: 0),
                              surface,
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// The header, its rule, and every row, for the columns `[first, last)`.
  List<Widget> _pane(_Plan plan, {required int first, required int last}) {
    final ParsedTable t = widget.table;
    final List<Widget> out = <Widget>[
      SizedBox(
        height: plan.headerHeight,
        child: Row(
          children: <Widget>[
            for (int c = first; c < last; c++)
              SizedBox(
                width: plan.widths[c],
                child: Padding(
                  padding: EdgeInsets.only(
                    left: _padLeft(c),
                    right: _padRight(c, t.columnCount),
                  ),
                  child: Align(
                    alignment: _boxAlign(_alignOf(plan, c)),
                    child: Text(
                      chukVisibleText(c < t.header.length ? t.header[c] : ''),
                      style: _headerStyle,
                      textAlign: _alignOf(plan, c),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
      Container(height: 1, color: _headerRule),
    ];

    for (int r = 0; r < t.rows.length; r++) {
      if (r > 0) out.add(Container(height: 1, color: _rule));
      final List<String> row = t.rows[r];
      out.add(
        SizedBox(
          height: plan.rowHeight,
          child: Row(
            children: <Widget>[
              for (int c = first; c < last; c++)
                SizedBox(
                  width: plan.widths[c],
                  child: Padding(
                    padding: EdgeInsets.only(
                      left: _padLeft(c),
                      right: _padRight(c, t.columnCount),
                    ),
                    child: Align(
                      alignment: _boxAlign(_alignOf(plan, c)),
                      child: _cell(
                        c < row.length ? row[c] : '',
                        column: c,
                        collapsed: plan.collapsed,
                        align: _alignOf(plan, c),
                        rowHeight: plan.rowHeight,
                        textWidth:
                            plan.widths[c] -
                            _padLeft(c) -
                            _padRight(c, t.columnCount),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    }
    return out;
  }

  /// An action column centres under its header; every other column keeps the
  /// side the delimiter row asked for, so numbers still line up on the right.
  TextAlign _alignOf(_Plan plan, int c) =>
      plan.collapsed[c] ? TextAlign.center : widget.table.alignments[c];

  Alignment _boxAlign(TextAlign align) {
    if (align == TextAlign.center) return Alignment.center;
    if (align == TextAlign.right) return Alignment.centerRight;
    return Alignment.centerLeft;
  }

  /// One drawn cell. One line, always: the row height is fixed, so a cell that
  /// wrapped would paint over its neighbours below.
  Widget _cell(
    String raw, {
    required int column,
    required List<bool> collapsed,
    required TextAlign align,
    required double textWidth,
    required double rowHeight,
  }) {
    final String trimmed = raw.trim();
    if (trimmed.isEmpty) return const SizedBox.shrink();
    final bool emphasis = column == _subjectColumn;

    if (collapsed[column]) {
      final ({String label, String href})? link = chukCellLink(trimmed);
      if (link != null) return _openAction(link.href, height: rowHeight);
    }

    // A fully-bold cell is a highlight: strip the ** and draw an accent chip.
    final bool highlight =
        trimmed.length >= 4 &&
        trimmed.startsWith('**') &&
        trimmed.endsWith('**') &&
        trimmed.substring(2, trimmed.length - 2).trim().isNotEmpty;

    final TextStyle base = _bodyStyle(emphasis: emphasis);

    final Widget text = highlight
        ? Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
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
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          )
        : Text.rich(
            _inlineSpans(trimmed, base),
            textAlign: align,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          );

    // Honest truncation: what was cut is one hover or one long press away,
    // never silently gone. Only the cells that actually run out of room carry
    // the tooltip, so a table of short values holds no extra machinery.
    final String painted = _paintedText(collapsed, column, trimmed);
    final double estimate =
        painted.length * widget.fontSize * (emphasis ? 0.585 : 0.545);
    if (estimate <= textWidth) return text;
    return Tooltip(message: painted, child: text);
  }

  /// A link column where every row said the same thing — three rows of
  /// "open.spotify.com" under a header that already says Spotify.
  ///
  /// The repeated string carried no information, so it is gone and what is
  /// left is the affordance: one arrow, on the same x in every row, with the
  /// whole cell as its target and the URL in its tooltip. The column above it
  /// is what says where the arrow goes.
  Widget _openAction(String href, {required double height}) {
    final ValueChanged<String>? onTap = widget.onTapLink;
    final Color color = onTap == null
        ? widget.textColor.withValues(alpha: 0.45)
        : widget.accentColor;
    final Widget glyph = SizedBox(
      height: height,
      width: _kActionGlyph,
      child: Center(
        child: HugeIcon(HugeIcons.arrowUpRight01, size: 16, color: color),
      ),
    );
    if (onTap == null) return glyph;
    return Semantics(
      link: true,
      label: 'Open link',
      child: Tooltip(
        message: href,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => onTap(href),
          child: glyph,
        ),
      ),
    );
  }

  /// Minimal inline markdown for cells: **bold**, *italic*, `code`, [t](url).
  ///
  /// A link reads as a link — accent colour AND an underline — and opens on a
  /// tap (bead cowork-94s9). With no handler to open it, it is drawn as plain
  /// text instead: a dead underlined link is a promise the table cannot keep.
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
            style: tap == null
                ? base
                : base.copyWith(
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
/// hangs under a table, and 38 still clears the touch minimum). Corners follow
/// [ExpressiveIconButton]'s formula, size × 0.34 at rest morphing to size ×
/// 0.20 while held. The press is the expressive spring; there is no glow and
/// no gradient.
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
