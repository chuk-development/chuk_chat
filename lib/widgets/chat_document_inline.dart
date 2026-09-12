// lib/widgets/chat_document_inline.dart
//
// A document the coworker wrote, rendered INSIDE the thread.
//
// A saved document used to arrive as a row: a title, "Version 31 · Saved
// document" and a chevron. The numbers the reader asked for — the election
// result, the price list, the plan — sat behind a tap, so the answer in the
// thread said nothing. A document is content, not a link to content, so the
// thread carries it: a table draws as the app's table, a markdown document
// through the app's markdown renderer, a bar chart as its bars.
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
import 'package:cowork/ui/expressive/huge_icon.dart';
import 'package:cowork/ui/expressive/motion.dart';
import 'package:cowork/utils/theme_extensions.dart';
import 'package:cowork/widgets/agent_markdown.dart';
import 'package:cowork/widgets/chat_document_view.dart';
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
      return documentChartRows(document).isNotEmpty;
    default:
      return '${document['text'] ?? ''}'.trim().isNotEmpty;
  }
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

/// The bars of a chart document: a label, its percentage and a track.
///
/// ONE implementation for the reader and for the thread, so the preview and
/// the full screen show the same chart at two sizes.
class DocumentBarList extends StatelessWidget {
  const DocumentBarList({
    super.key,
    required this.rows,
    this.showScale = true,
    this.barHeight = 28,
  });

  /// Rows that already carry a numeric `value` — see [documentChartRows].
  final List<Map> rows;

  /// The `0 % · 50 % · 100 %` rule under the bars. The thread leaves it out:
  /// six labelled bars say the scale themselves, and the rule is one more line
  /// in a block that has to stay short.
  final bool showScale;

  final double barHeight;

  /// A row's own colour, or the theme's. The value comes from a model, so
  /// "blue", a truncated hex or nothing at all are ordinary inputs — none of
  /// them may reach int.parse, which would throw while the view is building.
  static Color barColor(BuildContext context, Object? raw) {
    if (raw is String) {
      final String hex = raw.trim().replaceFirst('#', '');
      if (RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(hex)) {
        return Color(int.parse('ff$hex', radix: 16));
      }
    }
    return Theme.of(context).colorScheme.primary;
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (final Map row in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 9),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        '${row['label']}',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${(row['value'] as num).toStringAsFixed(1)} %',
                      // titleMedium, not titleLarge: at a 1.3 text scale the
                      // larger size pushed the label down to one ellipsised
                      // word on a phone column.
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        fontFeatures: const <FontFeature>[
                          FontFeature.tabularFigures(),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                // FractionallySizedBox measures the bar against the track
                // itself, so the fill stays right through a resize without a
                // LayoutBuilder rebuilding the whole row.
                Container(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest.withValues(
                      alpha: .5,
                    ),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: (row['value'] as num).clamp(0, 100) / 100,
                      child: Container(
                        height: barHeight,
                        decoration: BoxDecoration(
                          color: barColor(context, row['color']),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: .25,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (showScale)
          Padding(
            padding: const EdgeInsets.only(top: 10, bottom: 20),
            child: DefaultTextStyle.merge(
              style: theme.textTheme.bodySmall!.copyWith(
                color: theme.m3.onSurfaceVariant,
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: <Widget>[Text('0 %'), Text('50 %'), Text('100 %')],
              ),
            ),
          ),
      ],
    );
  }
}

/// A document, drawn in the thread in the coworker's bubble.
class InlineChatDocument extends StatefulWidget {
  const InlineChatDocument({super.key, required this.document, this.onOpen});

  final Map<String, dynamic> document;

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
    } else if (kind == 'bar_chart') {
      final int n = documentChartRows(widget.document).length;
      parts.add(n == 1 ? '1 bar' : '$n bars');
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
        final List<Map> rows = documentChartRows(widget.document);
        final bool cut = rows.length > kInlineDocumentRows;
        body = DocumentBarList(
          rows: cut ? rows.sublist(0, kInlineDocumentRows) : rows,
          showScale: false,
          barHeight: 22,
        );
        more = cut ? 'Open all ${rows.length} bars' : null;
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
        margin: const EdgeInsets.symmetric(vertical: 2),
        decoration: BoxDecoration(
          color: bubble.fill,
          borderRadius: BorderRadius.circular(18),
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
