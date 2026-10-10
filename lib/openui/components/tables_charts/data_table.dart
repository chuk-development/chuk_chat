// Table: a column-oriented data table (Col items hold one array each).
//
// The look follows the app's own table (lib/widgets/chuk_table.dart):
// a quiet header printed once above a rule, the first column reads
// strongest, hairlines between rows, horizontal scroll when the
// columns do not fit. Number columns are right-aligned with tabular
// figures. Cells may be text, numbers, links or rendered components
// (for example a Tag from @Each).

// The vendored openui packages mark their whole API experimental.
// ignore_for_file: experimental_member_use

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:openui/openui.dart' show DataNode;

import 'package:chuk_chat/openui/components/tables_charts/chart_common.dart';
import 'package:chuk_chat/openui/openui_actions.dart';
import 'package:chuk_chat/openui/openui_props.dart';
import 'package:chuk_chat/openui/openui_strings.dart';
import 'package:chuk_chat/openui/openui_theme.dart';
import 'package:chuk_chat/ui/expressive/huge_icon.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';

// ------------------------------------------------------------ shared

/// Room a cell keeps on the outer edges of the table.
const double kTableEdgePad = 12;

/// Half the gap between two columns.
const double kTableGutter = 8;

/// Air above and below the text of a row.
const double kTableRowPadY = 9;

/// A text column never gets less room than this for its text.
const double kTableMinText = 44;

/// A text column never claims more room than this for its text.
const double kTableMaxText = 240;

/// How many rows are read to measure the column widths.
const int kTableRowsSampled = 200;

/// The text styles of a table.
@immutable
class OpenUiTableStyles {
  /// Reads the styles for the current theme and chat font.
  factory OpenUiTableStyles.of(BuildContext context) {
    final t = OpenUiTheme.of(context);
    final size = (t.chatFontSize - 1.5).clamp(12.0, 16.0);
    // Full styles (merged over the inherited one), so what is measured
    // is what is painted.
    final base = DefaultTextStyle.of(context).style;
    final body = base.merge(
      TextStyle(
        fontSize: size,
        height: 1.3,
        fontFamily: t.chatFontFamily,
        color: t.textColor.withValues(alpha: 0.86),
      ),
    );
    return OpenUiTableStyles._(
      header: base.merge(
        TextStyle(
          fontSize: (size - 2).clamp(11.0, 13.0),
          height: 1.2,
          fontFamily: t.chatFontFamily,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
          color: t.textColor.withValues(alpha: 0.58),
        ),
      ),
      body: body,
      subject: body.copyWith(color: t.textColor, fontWeight: FontWeight.w600),
      number: body.copyWith(
        fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
      ),
      // The accent as text: readable on the card (docs/DESIGN.md 7).
      link: body.copyWith(
        color: Theme.of(context).accentForegroundOn(t.cardColor),
        fontWeight: FontWeight.w500,
      ),
      muted: body.copyWith(color: t.mutedColor),
    );
  }

  const OpenUiTableStyles._({
    required this.header,
    required this.body,
    required this.subject,
    required this.number,
    required this.link,
    required this.muted,
  });

  /// The header label.
  final TextStyle header;

  /// A body cell.
  final TextStyle body;

  /// A cell of the first column (the subject of the row).
  final TextStyle subject;

  /// A number cell (tabular figures).
  final TextStyle number;

  /// A link cell.
  final TextStyle link;

  /// A quiet cell (an empty mark).
  final TextStyle muted;
}

/// The one-line width of [text] in [style].
double measureTableText(String text, TextStyle style, TextScaler scaler) {
  if (text.isEmpty) return 0;
  // Ceil plus a hair: a column exactly as wide as its text can still
  // wrap the last letter after rounding.
  final tp = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    textScaler: scaler,
    maxLines: 1,
  )..layout();
  final w = tp.width.ceilToDouble() + 2;
  tp.dispose();
  return w;
}

/// The left padding of column [c].
double tableCellPadLeft(int c) => c == 0 ? kTableEdgePad : kTableGutter;

/// The right padding of column [c] of [count].
double tableCellPadRight(int c, int count) =>
    c == count - 1 ? kTableEdgePad : kTableGutter;

/// Fits the natural column widths [natural] (padding included) into
/// [available]. Returns the widths and whether the table must scroll.
/// Extra room goes to the columns in proportion to their width.
({List<double> widths, bool scrolls}) planTableColumns(
  List<double> natural,
  double available,
) {
  final total = natural.fold<double>(0, (a, w) => a + w);
  if (!available.isFinite || total >= available || total <= 0) {
    return (widths: natural, scrolls: available.isFinite && total > available);
  }
  final extra = available - total;
  return (
    widths: [for (final w in natural) w + extra * w / total],
    scrolls: false,
  );
}

/// The card around a table, with the horizontal scroll and its bar.
class OpenUiTableShell extends StatefulWidget {
  /// Creates the shell. [builder] gets the available width and builds
  /// the table and whether it scrolls.
  const OpenUiTableShell({required this.builder, this.footer, super.key});

  /// Builds the table for the available width.
  final ({Widget table, double width, bool scrolls}) Function(
    BuildContext context,
    double available,
  )
  builder;

  /// A row under the table (pager, save bar), or `null`.
  final Widget? footer;

  @override
  State<OpenUiTableShell> createState() => _OpenUiTableShellState();
}

class _OpenUiTableShellState extends State<OpenUiTableShell> {
  final ScrollController _h = ScrollController();

  @override
  void dispose() {
    _h.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = OpenUiTheme.of(context);
    return Container(
      decoration: t.cardDecoration(),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          LayoutBuilder(
            builder: (context, c) {
              final available = c.maxWidth.isFinite ? c.maxWidth : 360.0;
              final built = widget.builder(context, available);
              if (!built.scrolls) return built.table;
              return Scrollbar(
                controller: _h,
                thumbVisibility: true,
                child: SingleChildScrollView(
                  controller: _h,
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.only(bottom: 8),
                  child: SizedBox(width: built.width, child: built.table),
                ),
              );
            },
          ),
          ?widget.footer,
        ],
      ),
    );
  }
}

/// A web link in a cell, or `null`.
Uri? tableCellUrl(Object? v) {
  if (v is! String) return null;
  final s = v.trim();
  if (!(s.startsWith('http://') || s.startsWith('https://'))) return null;
  if (s.contains(' ')) return null;
  final uri = Uri.tryParse(s);
  return uri != null && uri.host.isNotEmpty ? uri : null;
}

/// Opens [url] through the host of the view.
void openTableUrl(BuildContext context, String url) =>
    OpenUiScope.maybeOf(context)?.handler?.openUrl(url);

/// A link cell: the host (or the given text) in the accent, and an
/// arrow icon. A tap opens the URL through the host.
class TableLinkCell extends StatelessWidget {
  /// Creates a link cell for [url].
  const TableLinkCell({
    required this.url,
    required this.style,
    this.text,
    super.key,
  });

  /// The link target.
  final Uri url;

  /// The text style.
  final TextStyle style;

  /// The visible text; the host when `null`.
  final String? text;

  @override
  Widget build(BuildContext context) {
    final label = text ?? url.host.replaceFirst('www.', '');
    return Semantics(
      link: true,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => openTableUrl(context, url.toString()),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Flexible(
              child: Text(
                label,
                style: style,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 3),
            HugeIcon(HugeIcons.arrowUpRight01, size: 14, color: style.color),
          ],
        ),
      ),
    );
  }
}

// -------------------------------------------------------------- Table

/// What a Table column shows.
enum _ColKind { text, number, widget }

class _ColSpec {
  _ColSpec(this.label, this.cells, this.type);

  final String label;
  final List<Object?> cells;
  final String type;

  late final _ColKind kind = _kindOf();

  _ColKind _kindOf() {
    var numbers = 0;
    var other = 0;
    for (final c in cells.take(kTableRowsSampled)) {
      if (_isWidget(c)) return _ColKind.widget;
      if (c == null || (c is String && c.trim().isEmpty)) continue;
      if (c is num) {
        numbers++;
      } else {
        other++;
      }
    }
    if (type == 'number') return _ColKind.number;
    if (type.isEmpty && numbers > 0 && other == 0) return _ColKind.number;
    return _ColKind.text;
  }

  static bool _isWidget(Object? c) =>
      _isDrawn(c) || (c is List && c.any(_isDrawn));
}

/// Whether [v] is a rendered component (a data node draws nothing).
bool _isDrawn(Object? v) => v is Widget && v is! DataNode;

/// The plain text of a cell value (numbers lose a `.0`).
String tableCellText(Object? v) {
  if (v == null || v is DataNode || v is Widget) return '';
  if (v is String) return v;
  if (v is num) {
    // As written by the model (upstream prints String(cell)): no
    // grouping, so a year stays 1991. Only a trailing ".0" goes.
    if (!v.isFinite) return '';
    if (v is double && v == v.roundToDouble() && v.abs() < 1e15) {
      return v.toInt().toString();
    }
    return v.toString();
  }
  if (v is bool) return v ? 'Yes' : 'No';
  if (v is List) {
    return v.map(tableCellText).where((s) => s.isNotEmpty).join(', ');
  }
  if (v is Map) {
    return v.entries
        .map((e) => '${e.key}: ${tableCellText(e.value)}')
        .join(', ');
  }
  return '';
}

List<_ColSpec> _readColumns(OpenUiProps p) {
  final out = <_ColSpec>[];
  for (final c in p.data('columns', type: 'Col')) {
    out.add(
      _ColSpec(
        c.string('label'),
        c.list('data'),
        c.choice('type', fallback: ''),
      ),
    );
  }
  // Object-literal columns: {label, data, type?}.
  for (final m in p.mapList('columns')) {
    final data = m['data'];
    final type = m['type'];
    out.add(
      _ColSpec(
        tableCellText(m['label']),
        data is List ? data : (data == null ? const <Object?>[] : [data]),
        type is String && const ['string', 'number', 'action'].contains(type)
            ? type
            : '',
      ),
    );
  }
  return out;
}

/// Builds `Table(columns)`.
Widget buildTable(BuildContext context, OpenUiProps p) {
  final columns = _readColumns(p);
  if (columns.isEmpty) return chartPlaceholder(context, p, 80);
  return _OpenUiDataTable(columns: columns);
}

/// The rows shown on one page.
const int kTablePageSize = 10;

/// The Table widget. Pages of [kTablePageSize] rows.
class _OpenUiDataTable extends StatefulWidget {
  const _OpenUiDataTable({required this.columns});

  final List<_ColSpec> columns;

  @override
  State<_OpenUiDataTable> createState() => _OpenUiDataTableState();
}

class _OpenUiDataTableState extends State<_OpenUiDataTable> {
  int _page = 0;

  int get _rowCount =>
      widget.columns.fold<int>(0, (a, c) => math.max(a, c.cells.length));

  @override
  Widget build(BuildContext context) {
    final styles = OpenUiTableStyles.of(context);
    final rows = _rowCount;
    final pages = math.max(1, (rows / kTablePageSize).ceil());
    final page = _page.clamp(0, pages - 1);
    final first = page * kTablePageSize;
    final last = math.min(rows, first + kTablePageSize);
    return OpenUiTableShell(
      builder: (context, available) {
        final natural = _naturalWidths(context, styles);
        final plan = planTableColumns(natural, available);
        final width = plan.widths.fold<double>(0, (a, w) => a + w);
        return (
          table: _table(context, styles, plan.widths, first, last),
          width: width,
          scrolls: plan.scrolls,
        );
      },
      footer: pages > 1
          ? _Pager(
              first: first,
              last: last,
              total: rows,
              onPrev: page > 0 ? () => setState(() => _page = page - 1) : null,
              onNext: page < pages - 1
                  ? () => setState(() => _page = page + 1)
                  : null,
            )
          : null,
    );
  }

  List<double> _naturalWidths(BuildContext context, OpenUiTableStyles s) {
    final scaler = MediaQuery.textScalerOf(context);
    final cols = widget.columns;
    return <double>[
      for (var c = 0; c < cols.length; c++)
        () {
          final col = cols[c];
          var w = measureTableText(col.label, s.header, scaler);
          if (col.kind == _ColKind.widget) {
            w = math.max(w, 120);
          } else {
            final style = col.kind == _ColKind.number
                ? s.number
                : (c == 0 ? s.subject : s.body);
            for (final v in col.cells.take(kTableRowsSampled)) {
              final url = tableCellUrl(v);
              final text = url != null
                  ? url.host.replaceFirst('www.', '')
                  : tableCellText(v);
              w = math.max(
                w,
                measureTableText(text, url != null ? s.link : style, scaler) +
                    (url != null ? 18 : 0),
              );
            }
          }
          return w.clamp(kTableMinText, kTableMaxText) +
              tableCellPadLeft(c) +
              tableCellPadRight(c, cols.length) +
              1;
        }(),
    ];
  }

  Widget _table(
    BuildContext context,
    OpenUiTableStyles s,
    List<double> widths,
    int first,
    int last,
  ) {
    final t = OpenUiTheme.of(context);
    final cols = widget.columns;
    final n = cols.length;
    EdgeInsets pad(int c) => EdgeInsets.fromLTRB(
      tableCellPadLeft(c),
      kTableRowPadY,
      tableCellPadRight(c, n),
      kTableRowPadY,
    );
    return Table(
      columnWidths: <int, TableColumnWidth>{
        for (var c = 0; c < n; c++) c: FixedColumnWidth(widths[c]),
      },
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      children: <TableRow>[
        TableRow(
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: t.headerRule,
              ),
            ),
          ),
          children: <Widget>[
            for (var c = 0; c < n; c++)
              Padding(
                padding: pad(c),
                child: Text(
                  cols[c].label,
                  style: s.header,
                  textAlign: cols[c].kind == _ColKind.number
                      ? TextAlign.right
                      : TextAlign.left,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
        for (var r = first; r < last; r++)
          TableRow(
            decoration: r < last - 1
                ? BoxDecoration(
                    border: Border(bottom: BorderSide(color: t.hairline)),
                  )
                : null,
            children: <Widget>[
              for (var c = 0; c < n; c++)
                Padding(
                  padding: pad(c),
                  child: _cell(
                    context,
                    s,
                    cols[c],
                    r < cols[c].cells.length ? cols[c].cells[r] : null,
                    subject: c == 0,
                  ),
                ),
            ],
          ),
      ],
    );
  }

  Widget _cell(
    BuildContext context,
    OpenUiTableStyles s,
    _ColSpec col,
    Object? v, {
    required bool subject,
  }) {
    if (v is DataNode) return const SizedBox.shrink();
    if (v is Widget) {
      return Align(alignment: Alignment.centerLeft, child: v);
    }
    if (v is List && v.any(_isDrawn)) {
      return Wrap(
        spacing: 6,
        runSpacing: 4,
        children: <Widget>[
          for (final e in v)
            if (_isDrawn(e)) e as Widget,
        ],
      );
    }
    final url = tableCellUrl(v);
    if (url != null) return TableLinkCell(url: url, style: s.link);
    final text = tableCellText(v);
    if (col.kind == _ColKind.number) {
      return Text(
        text,
        style: subject ? s.subject.merge(s.number) : s.number,
        textAlign: TextAlign.right,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }
    final cell = Text(
      text,
      style: subject ? s.subject : s.body,
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
    );
    if (text.length > 60) return Tooltip(message: text, child: cell);
    return cell;
  }
}

/// The page control under a long table.
class _Pager extends StatelessWidget {
  const _Pager({
    required this.first,
    required this.last,
    required this.total,
    required this.onPrev,
    required this.onNext,
  });

  final int first;
  final int last;
  final int total;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    final t = OpenUiTheme.of(context);
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: t.hairline)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              openUiStrings(
                context,
              ).openUiPageRange('${first + 1}', '$last', '$total'),
              style: t.captionStyle.copyWith(
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ),
          ExpressiveIconButton(
            hugeIcon: HugeIcons.arrowLeft01,
            size: 34,
            tooltip: openUiStrings(context).openUiPreviousPage,
            onTap: onPrev,
          ),
          const SizedBox(width: 6),
          ExpressiveIconButton(
            hugeIcon: HugeIcons.arrowRight01,
            size: 34,
            tooltip: openUiStrings(context).openUiNextPage,
            onTap: onNext,
          ),
        ],
      ),
    );
  }
}
