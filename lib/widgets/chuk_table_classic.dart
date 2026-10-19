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

/// Width of the fade on an edge that has more columns behind it.
const double _kFadeWidth = 28;

/// Horizontal padding inside a cell.
const double _kCellPadH = 12;

/// Narrowest column, so a short value does not become a sliver.
const double _kMinColumn = 72;

/// Widest column a long text gets before it wraps.
const double _kMaxColumn = 260;

/// Widest column a single long word (a file name, a URL) may claim before it
/// breaks inside the word.
const double _kMaxWord = 360;

/// How the columns of one table are laid out.
class _ColumnPlan {
  const _ColumnPlan(this.widths, {required this.scrolls});
  final Map<int, TableColumnWidth> widths;
  final bool scrolls;
}

class _ChukTableClassicState extends State<ChukTableClassic> {
  bool _copied = false;

  /// Shared by the horizontal Scrollbar and its SingleChildScrollView so the
  /// scrollbar thumb is draggable and the two stay in sync.
  final ScrollController _hCtrl = ScrollController();

  /// The last column plan and its inputs. Planning lays out a TextPainter
  /// per cell and per word, so it runs only when the table, the width, the
  /// text scale or the style changes, not on every layout pass.
  _ColumnPlan? _plan;
  ParsedTable? _planTable;
  double? _planWidth;
  TextScaler? _planScaler;
  TextStyle? _planStyle;

  _ColumnPlan _cachedPlan(
    ParsedTable t,
    double maxW,
    TextScaler scaler,
    TextStyle ambient,
  ) {
    final _ColumnPlan? plan = _plan;
    if (plan != null &&
        identical(t, _planTable) &&
        maxW == _planWidth &&
        scaler == _planScaler &&
        ambient == _planStyle) {
      return plan;
    }
    _planTable = t;
    _planWidth = maxW;
    _planScaler = scaler;
    _planStyle = ambient;
    return _plan = _planColumns(t, maxW, scaler, ambient);
  }

  /// Bumped when the scroll extent changes, so the edge fades follow it.
  final ValueNotifier<int> _metricsTick = ValueNotifier<int>(0);

  @override
  void dispose() {
    _hCtrl.dispose();
    _metricsTick.dispose();
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
          // Fill the message width when the table fits. When it does not,
          // every column gets a width between a floor and a cap and its text
          // wraps; only a table that is still too wide then pans sideways.
          LayoutBuilder(
            builder: (context, constraints) {
              final double maxW = constraints.maxWidth;
              final _ColumnPlan plan = _cachedPlan(
                t,
                maxW,
                MediaQuery.textScalerOf(context),
                DefaultTextStyle.of(context).style,
              );

              final Widget table = Table(
                columnWidths: plan.widths,
                defaultColumnWidth: const IntrinsicColumnWidth(),
                defaultVerticalAlignment: TableCellVerticalAlignment.top,
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

              if (!plan.scrolls) return card;
              return _scroller(context, card);
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

  /// A wide table pans sideways inside its own scroller. The scroller never
  /// draws over the table:
  /// - Touch (Android, iOS): no scrollbar. The edge that has more columns
  ///   behind it fades out, which says "this pans" without covering a cell.
  /// - Mouse (desktop, web): a draggable scrollbar in a lane of its own under
  ///   the card, plus the same fades.
  Widget _scroller(BuildContext context, Widget card) {
    final bool touch = _isTouchPlatform(Theme.of(context).platform);
    final Widget view = SingleChildScrollView(
      controller: _hCtrl,
      scrollDirection: Axis.horizontal,
      child: touch
          ? card
          : Padding(
              // The thumb is painted at the bottom of the viewport; the lane
              // keeps it under the card instead of across the last row.
              padding: const EdgeInsets.only(bottom: _kScrollbarLane),
              child: card,
            ),
    );
    final Widget scrollable = ScrollConfiguration(
      // Mouse drag pans too: on desktop the wheel scrolls the page, so
      // without it a wide table could only be panned through the thumb.
      behavior: ScrollConfiguration.of(context).copyWith(
        dragDevices: <PointerDeviceKind>{
          PointerDeviceKind.touch,
          PointerDeviceKind.mouse,
          PointerDeviceKind.trackpad,
          PointerDeviceKind.stylus,
        },
        scrollbars: false,
      ),
      child: NotificationListener<ScrollMetricsNotification>(
        onNotification: (_) {
          _metricsTick.value++;
          return false;
        },
        child: touch
            ? view
            : Scrollbar(
                controller: _hCtrl,
                thumbVisibility: true,
                interactive: true,
                child: view,
              ),
      ),
    );
    // The first layout sends no scroll notification: read the extent once
    // it exists, so the right-hand fade is there before the first pan.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _metricsTick.value++;
    });
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[_hCtrl, _metricsTick]),
      child: scrollable,
      builder: (context, child) {
        final ScrollPosition? pos = _hCtrl.hasClients ? _hCtrl.position : null;
        final bool known = pos != null && pos.hasContentDimensions;
        final bool moreLeft = known && pos.pixels > 0.5;
        final bool moreRight = !known || pos.pixels < pos.maxScrollExtent - 0.5;
        return ShaderMask(
          key: const ValueKey<String>('chuk-table-fade'),
          blendMode: BlendMode.dstIn,
          shaderCallback: (Rect rect) {
            final double f = rect.width <= 0
                ? 0
                : (_kFadeWidth / rect.width).clamp(0.0, 0.45);
            return LinearGradient(
              colors: <Color>[
                moreLeft ? Colors.transparent : Colors.white,
                Colors.white,
                Colors.white,
                moreRight ? Colors.transparent : Colors.white,
              ],
              stops: <double>[0, f, 1 - f, 1],
            ).createShader(rect);
          },
          child: child,
        );
      },
    );
  }

  static bool _isTouchPlatform(TargetPlatform p) =>
      p == TargetPlatform.android ||
      p == TargetPlatform.iOS ||
      p == TargetPlatform.fuchsia;

  /// Decides the column widths from the measured cell text.
  ///
  /// - Every column at its one-line width fits: flex columns weighted by that
  ///   width, so the table fills the message width.
  /// - Otherwise each column gets `natural` clamped to `[floor, cap]`, and its
  ///   text wraps. The floor is the longest word (so `Sequentiell` never
  ///   breaks in the middle) but at least [_kMinColumn]; the cap is
  ///   [_kMaxColumn] or 60 % of the width, whichever is smaller.
  /// - Those widths fit: flex columns weighted by them (still no panning).
  /// - Still too wide: fixed widths inside a horizontal scroller.
  _ColumnPlan _planColumns(
    ParsedTable t,
    double maxW,
    TextScaler scaler,
    TextStyle ambient,
  ) {
    final int n = t.columnCount;
    if (!maxW.isFinite) {
      return _ColumnPlan(const <int, TableColumnWidth>{}, scrolls: false);
    }
    final List<double> natural = List<double>.filled(n, 0);
    final List<double> word = List<double>.filled(n, 0);
    void measure(int c, String raw, {required bool header}) {
      // The cell's Text inherits the ambient style (letter spacing, ...);
      // measure with it, or a word one column wide still wraps.
      final TextStyle style = ambient.merge(
        _cellStyle(header: header, firstCol: c == 0),
      );
      final String trimmed = raw.trim();
      final TextPainter tp = TextPainter(
        text: _inlineSpans(trimmed, style),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      if (tp.width > natural[c]) natural[c] = tp.width;
      tp.dispose();
      final String visible = trimmed.replaceAll(RegExp(r'[*_`]'), '');
      for (final String w in visible.split(RegExp(r'\s+'))) {
        if (w.isEmpty) continue;
        final TextPainter wp = TextPainter(
          text: TextSpan(
            text: w,
            style: style.copyWith(fontWeight: FontWeight.w700),
          ),
          textDirection: TextDirection.ltr,
          textScaler: scaler,
          maxLines: 1,
        )..layout();
        if (wp.width > word[c]) word[c] = wp.width;
        wp.dispose();
      }
    }

    for (int c = 0; c < n; c++) {
      measure(c, c < t.header.length ? t.header[c] : '', header: true);
      for (final List<String> row in t.rows) {
        if (c < row.length) measure(c, row[c], header: false);
      }
    }

    const double pad = _kCellPadH * 2 + 2;
    final double cap = (maxW * 0.6).clamp(_kMinColumn, _kMaxColumn);
    double sumNatural = 0;
    double sumPlanned = 0;
    final List<double> planned = List<double>.filled(n, 0);
    for (int c = 0; c < n; c++) {
      final double nat = natural[c] + pad;
      final double floor = (word[c] + pad).clamp(_kMinColumn, _kMaxWord);
      final double hi = cap < floor ? floor : cap;
      planned[c] = nat.clamp(floor, hi);
      sumNatural += nat;
      sumPlanned += planned[c];
    }

    if (sumNatural <= maxW) {
      return _ColumnPlan(<int, TableColumnWidth>{
        for (int c = 0; c < n; c++) c: FlexColumnWidth(natural[c] + pad),
      }, scrolls: false);
    }
    if (sumPlanned <= maxW) {
      return _ColumnPlan(<int, TableColumnWidth>{
        for (int c = 0; c < n; c++) c: FlexColumnWidth(planned[c]),
      }, scrolls: false);
    }
    return _ColumnPlan(<int, TableColumnWidth>{
      for (int c = 0; c < n; c++) c: FixedColumnWidth(planned[c]),
    }, scrolls: true);
  }

  TextStyle _cellStyle({required bool header, required bool firstCol}) =>
      TextStyle(
        color: widget.textColor,
        fontSize: widget.fontSize,
        height: 1.35,
        fontFamily: widget.fontFamily,
        fontWeight: header || firstCol ? FontWeight.w600 : FontWeight.w400,
      );

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

    final TextStyle base = _cellStyle(header: header, firstCol: firstCol);

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
      padding: const EdgeInsets.fromLTRB(_kCellPadH, 9, _kCellPadH, 9),
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
        spans.add(
          TextSpan(
            text: link,
            style: base.copyWith(color: widget.accentColor),
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
