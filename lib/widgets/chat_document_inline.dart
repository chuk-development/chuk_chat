// lib/widgets/chat_document_inline.dart
//
// A document the coworker wrote, rendered INSIDE the thread.
//
// A saved document used to arrive as a row: a title, "Version 31 · Saved
// document" and a chevron. The numbers the reader asked for — the election
// result, the price list, the plan — sat behind a tap, so the answer in the
// thread said nothing. A document is content, not a link to content, so the
// thread carries it: a table draws as the app's table, a markdown document
// through the app's markdown renderer, a chart as the app's chart.
//
// A real file stays a file: `sandbox_artifact_block.dart` keeps the full-width
// attachment row for anything the coworker sent as bytes. Only the documents
// the `chat_document` tool writes render here.
//
// Long documents do not flood the thread. A table shows its first rows, a
// chart its first bars, and prose stops at a fixed height with a fade into the
// bubble. Each cut ends in the same quiet action, and the whole block opens the
// full-screen reader on a tap.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:cowork/ui/expressive/bubble_kind.dart';
import 'package:cowork/ui/expressive/bubble_shape.dart' show kBubbleRadiusBig;
import 'package:cowork/ui/expressive/huge_icon.dart';
import 'package:cowork/ui/expressive/motion.dart';
import 'package:cowork/utils/theme_extensions.dart';
import 'package:cowork/widgets/agent_markdown.dart';
import 'package:cowork/widgets/chat_document_view.dart';
import 'package:cowork/widgets/charts/chuk_chart.dart';
import 'package:cowork/widgets/chuk_table.dart';

/// How much of a document the thread shows before it defers to the reader.
///
/// Rows, not pixels, for a table and a chart: below 560 pixels [ChukTable]
/// stacks a row into a card, so a pixel cut would slice a card in half. Pixels
/// for prose, because a paragraph has no rows to count.
const int kInlineDocumentRows = 6;

/// The same cut for a table that had to stack into one card per row: a card
/// carries every field of the row, so three of them say as much as six grid
/// rows do and take a third of the thread.
const int kInlineDocumentStackedRows = 3;
const double kInlineDocumentProseHeight = 260;

/// Whether [document] carries content the thread can draw.
///
/// The chat payload holds the whole document (see the roundtrip test in
/// `chat_document_view_test.dart`), so this is normally true. A payload that
/// carries only a reference — an older row, a truncated snapshot — answers
/// false, and the caller keeps the compact row instead of drawing an empty
/// block.
bool inlineDocumentHasContent(Map<String, dynamic> document) {
  switch ('${document['kind'] ?? ''}') {
    case 'file':
      return false;
    case 'table':
      final List<String> columns = documentColumns(document);
      return columns.isNotEmpty && documentRows(document).isNotEmpty;
    case 'bar_chart':
    case 'chart':
      return !documentChart(document).spec.unusable;
    default:
      return '${document['text'] ?? ''}'.trim().isNotEmpty;
  }
}

/// Whether [document] draws as a chart.
///
/// `bar_chart` is the kind the `chat_document` tool writes and the kind every
/// document already in a store carries. `chart` is accepted as well, so a
/// document from another producer draws instead of falling back to prose.
bool documentIsChart(Map<String, dynamic> document) {
  final String kind = '${document['kind'] ?? ''}';
  return kind == 'bar_chart' || kind == 'chart';
}

/// The column names of a table document.
List<String> documentColumns(Map<String, dynamic> document) => <String>[
  for (final Object? v in document['columns'] as List? ?? const []) '$v',
];

/// The rows of a table document.
List<Map> documentRows(Map<String, dynamic> document) =>
    (document['rows'] as List? ?? const []).whereType<Map>().toList();

/// The rows of a chart document that have a bar to draw.
///
/// A row without a numeric value has no bar; casting it would take the whole
/// view down over one row.
List<Map> documentChartRows(Map<String, dynamic> document) =>
    documentRows(document).where((Map row) => row['value'] is num).toList();

/// The chart JSON of [document], in the contract `chart_spec.dart` documents.
///
/// Two shapes arrive here and exactly one leaves.
///
/// A document written since the renderer landed carries the spec itself under
/// `chart` — kind, unit, axis, reference_line, points or series.
///
/// Every document written before it carries `rows` of {label, value, color}
/// where the value is a percentage, plus `caption`, `source_url` and
/// `retrieved_at`. Those are mapped onto the same contract rather than drawn
/// by a second widget: what is already in a store keeps working, and there is
/// one renderer to keep right.
Map<String, Object?> documentChartJson(Map<String, dynamic> document) {
  final Object? raw = document['chart'];
  final Map<String, Object?> json = <String, Object?>{
    if (raw is Map)
      for (final MapEntry<Object?, Object?> e in raw.entries) '${e.key}': e.value,
  };
  if (json['points'] == null && json['series'] == null) {
    json['points'] = documentChartRows(document);
    // The tool validates a legacy row as a percentage, so the axis is one.
    json['unit'] ??= '%';
    json['kind'] ??= 'bar';
  }
  json['title'] ??= document['title'];
  json['subtitle'] ??= document['caption'];
  json['source'] ??= documentSourceName(document['source_url']);
  json['retrieved_at'] ??= document['retrieved_at'];
  return json;
}

/// A source URL as a chart footer says it: the host, not the whole path.
///
/// `source_url` is a link, and the card's footer is painted text nobody can
/// tap. A 78-character URL under a chart is noise; the host is the fact the
/// footer is for. The reader keeps the full URL in a block that opens it.
String documentSourceName(Object? raw) {
  final String value = '${raw ?? ''}'.trim();
  final Uri? uri = Uri.tryParse(value);
  if (uri == null ||
      (uri.scheme != 'https' && uri.scheme != 'http') ||
      uri.host.isEmpty) {
    return value;
  }
  return uri.host.replaceFirst('www.', '');
}

/// A document's chart, ready to draw, with what had to be left out of it.
@immutable
class DocumentChart {
  const DocumentChart({
    required this.spec,
    required this.total,
    required this.shown,
  });

  /// The spec as drawn — already sorted, already cut to [shown] categories.
  final ChartSpec spec;

  /// How many categories the document holds.
  final int total;

  /// How many of them this spec draws.
  final int shown;

  /// True when the reader has to open the document to see the rest.
  bool get isCut => shown < total;

  /// "6 bars", "30 points" — what the block says it is holding.
  String get countLabel {
    final String noun = spec.kind == ChartKind.line ? 'point' : 'bar';
    return '$total ${total == 1 ? noun : '${noun}s'}';
  }
}

/// Reads the chart out of [document].
///
/// ONE parse for the thread and for the reader, so the preview and the full
/// screen cannot drift into two different charts.
///
/// [maxPoints] caps how many categories are drawn — the thread's six-bar rule.
/// A line is one stroke rather than a stack of rows, so it is never cut: a
/// week of prices says nothing when six days of it are missing.
///
/// [withSource] false leaves the source line out of the card, for a caller
/// that prints the source itself with a link the reader can open.
DocumentChart documentChart(
  Map<String, dynamic> document, {
  int? maxPoints,
  bool withSource = true,
}) {
  final Map<String, Object?> json = documentChartJson(document);
  if (!withSource) {
    json.remove('source');
    json.remove('retrieved_at');
  }
  // The card sits under the block's own title; printing it twice is the block
  // saying the same thing to itself. A chart that carries a DIFFERENT title
  // keeps it — that one is information.
  final String title = '${json['title'] ?? ''}'.trim();
  if (title.toLowerCase() == '${document['title'] ?? ''}'.trim().toLowerCase()) {
    json.remove('title');
  }

  final ChartSpec spec = ChartSpec.parse(json);
  final int total = spec.categories.length;
  if (maxPoints == null ||
      total <= maxPoints ||
      spec.kind == ChartKind.line ||
      spec.unusable) {
    return DocumentChart(spec: spec, total: total, shown: total);
  }
  // Cut AFTER the parse, because the parse is what applies `sort`: cutting the
  // JSON would keep the first six written, not the six biggest.
  return DocumentChart(
    spec: spec.copyWith(
      series: <ChartSeries>[
        for (final ChartSeries s in spec.series)
          ChartSeries(
            points: s.points.length > maxPoints
                ? s.points.sublist(0, maxPoints)
                : s.points,
            name: s.name,
            color: s.color,
            direction: s.direction,
          ),
      ],
    ),
    total: total,
    shown: maxPoints,
  );
}

/// One cell as [ChukTable] reads it. A bare URL becomes a markdown link
/// labelled with its host, so the cell says "wahlergebnisse.sachsen-anhalt.de"
/// and opens the page on a tap, instead of pushing a 78-character URL through
/// the column and taking every other column off screen with it.
String documentCellText(Object? raw) {
  final String value = '${raw ?? ''}'.trim();
  if (value.isEmpty) return '';
  final Uri? uri = Uri.tryParse(value);
  if (uri != null &&
      (uri.scheme == 'https' || uri.scheme == 'http') &&
      uri.host.isNotEmpty &&
      !value.contains(RegExp(r'[\s\]()]'))) {
    return '[${uri.host.replaceFirst('www.', '')}]($value)';
  }
  return value;
}

/// A table document in the shape [ChukTable] draws.
///
/// [maxRows] cuts the body for the inline preview. The alignments are read
/// from EVERY row, not only the shown ones, so a column does not change side
/// between the thread and the reader.
ParsedTable documentParsedTable(Map<String, dynamic> document, {int? maxRows}) {
  final List<String> columns = documentColumns(document);
  final List<Map> all = documentRows(document);
  final List<Map> shown = maxRows != null && all.length > maxRows
      ? all.sublist(0, maxRows)
      : all;

  // A column whose every filled cell is a number is read as a number column,
  // and numbers line up on the right so their digits compare.
  bool numeric(String column) {
    bool seen = false;
    for (final Map row in all) {
      final Object? value = row[column];
      if (value == null || '$value'.trim().isEmpty) continue;
      if (value is! num && num.tryParse('$value'.trim()) == null) return false;
      seen = true;
    }
    return seen;
  }

  return ParsedTable(
    header: columns,
    rows: <List<String>>[
      for (final Map row in shown)
        <String>[for (final String c in columns) documentCellText(row[c])],
    ],
    alignments: <TextAlign>[
      for (final String c in columns)
        numeric(c) ? TextAlign.right : TextAlign.left,
    ],
  );
}

/// Open a link out of a document cell, in the platform browser.
Future<void> openDocumentLink(BuildContext context, String href) async {
  final Uri? uri = Uri.tryParse(href);
  if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) return;
  final bool opened = await launchUrl(
    uri,
    mode: LaunchMode.externalApplication,
  );
  if (!opened && context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Could not open link')));
  }
}

/// A document, drawn in the thread in the coworker's bubble.
class InlineChatDocument extends StatefulWidget {
  const InlineChatDocument({
    super.key,
    required this.document,
    this.onOpen,
    this.borderRadius,
  });

  final Map<String, dynamic> document;

  /// The corners this block draws. A document that follows an answer from the
  /// same coworker is one more block of that run, so the run hands it its
  /// geometry — small radii where it touches the answer above it. Null keeps
  /// the standalone shape.
  final BorderRadius? borderRadius;

  /// What a tap does. Defaults to the full-screen reader the row opened
  /// before — the inline render is the content, the tap is for reading it big,
  /// saving it or sharing it.
  final VoidCallback? onOpen;

  @override
  State<InlineChatDocument> createState() => _InlineChatDocumentState();
}

class _InlineChatDocumentState extends State<InlineChatDocument> {
  /// Whether the prose ran past [kInlineDocumentProseHeight]. Measured, not
  /// guessed: a 400-character document with three headings is taller than a
  /// 900-character paragraph.
  bool _proseCut = false;

  void _open() {
    final VoidCallback? onOpen = widget.onOpen;
    if (onOpen != null) {
      onOpen();
      return;
    }
    ChatDocumentView.open(context, widget.document);
  }

  /// The line under the title: what the document is, how big it is, which
  /// version. It keeps every fact the old row carried and none of its weight —
  /// the numbers above it are the message now.
  String _meta() {
    final String kind = '${widget.document['kind'] ?? ''}';
    final List<String> parts = <String>[];
    if (kind == 'table') {
      final int n = documentRows(widget.document).length;
      parts.add(n == 1 ? '1 row' : '$n rows');
    } else if (documentIsChart(widget.document)) {
      parts.add(documentChart(widget.document).countLabel);
    } else {
      parts.add('Markdown document');
    }
    final String? fresh = documentFreshness(widget.document);
    if (fresh != null) parts.add(fresh);
    return parts.join(' · ');
  }

  HugeIconData get _glyph {
    switch ('${widget.document['kind'] ?? ''}') {
      case 'table':
        return HugeIcons.sheet;
      case 'bar_chart':
      case 'chart':
        return HugeIcons.sorting01;
      default:
        return HugeIcons.fileText;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final AgentBubbleColors bubble = agentBubbleColors(
      scheme,
      AgentBubbleKind.answer,
    );
    final String kind = '${widget.document['kind'] ?? ''}';
    final String title = '${widget.document['title'] ?? ''}'.trim();

    final Widget body;
    final String? more;
    switch (kind) {
      case 'table':
        final int total = documentRows(widget.document).length;
        // How many rows fit depends on how the table is drawn. In a phone
        // column [ChukTable] stacks each row into a labelled card — a card is
        // a paragraph, so three of them are already a screenful, where three
        // grid rows would be three lines.
        body = LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final ParsedTable wide = documentParsedTable(
              widget.document,
              maxRows: kInlineDocumentRows,
            );
            final bool stacks = chukTableStacks(
              wide,
              maxWidth: constraints.maxWidth,
              fontSize: 13.5,
            );
            final int limit = stacks
                ? kInlineDocumentStackedRows
                : kInlineDocumentRows;
            final bool cut = total > limit;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                ChukTable(
                  table: cut
                      ? documentParsedTable(widget.document, maxRows: limit)
                      : wide,
                  textColor: scheme.onSurface,
                  accentColor: scheme.primary,
                  fontSize: 13.5,
                  onTapLink: (String href) => openDocumentLink(context, href),
                ),
                if (cut) ...<Widget>[
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: _OpenAction(
                      label: 'Open all $total rows',
                      onTap: _open,
                    ),
                  ),
                ],
              ],
            );
          },
        );
        more = null;
      case 'bar_chart':
      case 'chart':
        final DocumentChart chart = documentChart(
          widget.document,
          maxPoints: kInlineDocumentRows,
        );
        body = ChukChart(spec: chart.spec, accentColor: scheme.primary);
        more = chart.isCut ? 'Open all ${chart.countLabel}' : null;
      default:
        body = _CutAtHeight(
          maxHeight: kInlineDocumentProseHeight,
          fade: bubble.fill,
          cut: _proseCut,
          onCut: (bool value) {
            if (mounted && value != _proseCut) {
              setState(() => _proseCut = value);
            }
          },
          // Not selectable: selection belongs in the reader, and a nested
          // SelectionArea swallows the tap that opens it.
          child: AgentMarkdown(
            '${widget.document['text'] ?? ''}',
            fontSize: 15,
            height: 1.55,
            selectable: false,
          ),
        );
        more = _proseCut ? 'Open document' : null;
    }

    return SizedBox(
      width: double.infinity,
      child: Container(
        decoration: BoxDecoration(
          color: bubble.fill,
          borderRadius:
              widget.borderRadius ?? BorderRadius.circular(kBubbleRadiusBig),
        ),
        clipBehavior: Clip.antiAlias,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: _open,
            child: Padding(
              padding: EdgeInsets.fromLTRB(14, 12, 14, more == null ? 14 : 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Padding(
                        padding: const EdgeInsets.only(top: 2, right: 8),
                        child: HugeIcon(
                          _glyph,
                          size: 18,
                          color: scheme.primary,
                        ),
                      ),
                      Expanded(
                        child: Text(
                          title.isEmpty ? 'Document' : title,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            height: 1.25,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _meta(),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.m3.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 10),
                  body,
                  if (more != null) ...<Widget>[
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: _OpenAction(label: more, onTap: _open),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The one action a cut document offers, in the app's button family: a tonal
/// pill that springs on a press, the same shape the documents panel uses.
class _OpenAction extends StatelessWidget {
  const _OpenAction({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return MorphTap(
      onTap: onTap,
      color: scheme.secondaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: scheme.onSecondaryContainer,
                fontWeight: FontWeight.w700,
                fontSize: 14,
              ),
            ),
          ),
          const SizedBox(width: 8),
          HugeIcon(
            HugeIcons.arrowRight01,
            size: 16,
            color: scheme.onSecondaryContainer,
          ),
        ],
      ),
    );
  }
}

/// Shows the top [maxHeight] of its child and fades the cut into the bubble.
///
/// The fade is the veil idea from the design rulebook: never a band with an
/// edge, because the edge draws a line across the text. [onCut] reports
/// whether the child was actually taller, so a short document draws no fade
/// and offers no action.
class _CutAtHeight extends StatelessWidget {
  const _CutAtHeight({
    required this.maxHeight,
    required this.fade,
    required this.cut,
    required this.onCut,
    required this.child,
  });

  final double maxHeight;
  final Color fade;
  final bool cut;
  final ValueChanged<bool> onCut;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        _HeightCap(maxHeight: maxHeight, onOverflow: onCut, child: child),
        if (cut)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 56,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: <Color>[fade.withValues(alpha: 0), fade],
                    stops: const <double>[0, 0.92],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _HeightCap extends SingleChildRenderObjectWidget {
  const _HeightCap({
    required this.maxHeight,
    required this.onOverflow,
    required Widget super.child,
  });

  final double maxHeight;
  final ValueChanged<bool> onOverflow;

  @override
  _RenderHeightCap createRenderObject(BuildContext context) =>
      _RenderHeightCap(maxHeight: maxHeight, onOverflow: onOverflow);

  @override
  void updateRenderObject(BuildContext context, _RenderHeightCap render) {
    render
      ..maxHeight = maxHeight
      ..onOverflow = onOverflow;
  }
}

class _RenderHeightCap extends RenderProxyBox {
  _RenderHeightCap({required double maxHeight, required this.onOverflow})
    : _maxHeight = maxHeight;

  double _maxHeight;
  ValueChanged<bool> onOverflow;
  bool? _reported;

  set maxHeight(double value) {
    if (value == _maxHeight) return;
    _maxHeight = value;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    final RenderBox? child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(
      BoxConstraints(
        minWidth: constraints.minWidth,
        maxWidth: constraints.maxWidth,
      ),
      parentUsesSize: true,
    );
    final bool over = child.size.height > _maxHeight + 0.5;
    size = constraints.constrain(
      Size(child.size.width, math.min(child.size.height, _maxHeight)),
    );
    if (over != _reported) {
      _reported = over;
      // Reporting during layout would rebuild inside a layout pass. The frame
      // after this one carries the fade and the action; nothing moves, because
      // the height is already the capped one.
      SchedulerBinding.instance.addPostFrameCallback((_) => onOverflow(over));
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final RenderBox? child = this.child;
    if (child == null) return;
    context.pushClipRect(
      needsCompositing,
      offset,
      Offset.zero & size,
      (PaintingContext inner, Offset innerOffset) =>
          inner.paintChild(child, innerOffset),
    );
  }
}
