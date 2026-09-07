import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:cowork/constants.dart';
import 'package:cowork/services/file_save_service.dart';
import 'package:cowork/utils/theme_extensions.dart';
import 'package:cowork/widgets/agent_markdown.dart';

/// The agent stamps `updated_at` in epoch seconds — a float for chat documents,
/// a file mtime for workspace files — so it is neither an ISO string nor
/// milliseconds. Anything else is reported as absent rather than guessed at.
DateTime? documentUpdatedAt(Map<String, dynamic> document) {
  final raw = document['updated_at'];
  if (raw is! num || raw <= 0 || !raw.isFinite) return null;
  return DateTime.fromMillisecondsSinceEpoch((raw * 1000).round()).toLocal();
}

/// How fresh a document is, as one short line: `v17 · 00:06`.
///
/// This answers the only question a reader has about a document the agent keeps
/// rewriting: am I looking at current numbers? Version and wall clock answer it,
/// seconds do not, so seconds are left out. A document last written on an
/// earlier day carries its date too, because a bare `00:06` silently reads as
/// "a moment ago".
///
/// Returns null when the document carries neither a version nor a timestamp: an
/// invented freshness would be worse than none at all.
String? documentFreshness(Map<String, dynamic> document, {DateTime? now}) {
  final parts = <String>[];
  final version = document['version'];
  if (version is num && version > 0) parts.add('v${version.toInt()}');
  final stamp = documentUpdatedAt(document);
  if (stamp != null) {
    final today = (now ?? DateTime.now()).toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    final clock = '${two(stamp.hour)}:${two(stamp.minute)}';
    final sameDay =
        stamp.year == today.year &&
        stamp.month == today.month &&
        stamp.day == today.day;
    parts.add(sameDay ? clock : '${two(stamp.day)}.${two(stamp.month)}. $clock');
  }
  return parts.isEmpty ? null : parts.join(' · ');
}

class ChatDocumentView extends StatefulWidget {
  const ChatDocumentView({super.key, required this.document});
  final Map<String, dynamic> document;

  static Future<void> open(
    BuildContext context,
    Map<String, dynamic> document,
  ) => showDialog<void>(
    context: context,
    builder: (context) {
      final theme = Theme.of(context);
      final media = MediaQuery.sizeOf(context);
      return Dialog(
        clipBehavior: Clip.antiAlias,
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kRadiusDialog),
          side: BorderSide(color: theme.m3.outlineVariant),
        ),
        child: SizedBox(
          width: math.min(1000, math.max(280, media.width - 32)),
          height: math.min(720, math.max(320, media.height - 48)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${document['title']}',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: theme.m3.outlineVariant),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                  child: ChatDocumentView(document: document),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );

  @override
  State<ChatDocumentView> createState() => _ChatDocumentViewState();
}

class _ChatDocumentViewState extends State<ChatDocumentView> {
  /// How long the "Updated" mark stays up after the agent rewrote the document
  /// the reader is looking at. Long enough to be noticed on a glance back at
  /// the screen, short enough not to become furniture.
  static const Duration _flashDuration = Duration(seconds: 6);

  Timer? _flashTimer;
  bool _flashing = false;

  @override
  void didUpdateWidget(ChatDocumentView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Only a rewrite of *this* document is an update. Switching to another
    // document also changes the version number, and marking that "updated"
    // would train the reader to ignore the mark.
    final same = oldWidget.document['id'] == widget.document['id'];
    final before = oldWidget.document['version'];
    final after = widget.document['version'];
    if (same && before is num && after is num && after > before) {
      _flashTimer?.cancel();
      _flashTimer = Timer(_flashDuration, () {
        if (mounted) setState(() => _flashing = false);
      });
      _flashing = true;
    }
  }

  @override
  void dispose() {
    _flashTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final document = widget.document;
    final theme = Theme.of(context);
    final isChart = document['kind'] == 'bar_chart';
    final isTable = document['kind'] == 'table' || isChart;
    final columns = (document['columns'] as List? ?? [])
        .map((v) => '$v')
        .toList();
    final rows = (document['rows'] as List? ?? []).whereType<Map>().toList();
    final shape = isChart
        ? '${rows.length} parties · Percent'
        : isTable
        ? '${rows.length} rows'
        : 'Markdown document';
    final freshness = documentFreshness(document);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // A Wrap, not a Row: at a large text scale the Save button moves to its
        // own line instead of pushing the meta line off the edge.
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 4,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    freshness == null ? shape : '$shape · $freshness',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.m3.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                // The mark holds its slot whether or not it is lit, so a
                // rewrite arriving while the reader is mid-page changes a
                // colour and nothing else.
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: AnimatedOpacity(
                    opacity: _flashing ? 1 : 0,
                    duration: const Duration(milliseconds: 250),
                    child: const _UpdatedMark(),
                  ),
                ),
              ],
            ),
            TextButton.icon(
              style: TextButton.styleFrom(shape: const StadiumBorder()),
              icon: const Icon(Icons.download, size: 18),
              label: const Text('Save'),
              onPressed: () async {
                final text = isTable
                    ? const JsonEncoder.withIndent('  ').convert(document)
                    : '${document['text'] ?? ''}';
                await FileSaveService.save(
                  bytes: Uint8List.fromList(utf8.encode(text)),
                  suggestedName:
                      '${document['title'] ?? 'document'}.${isTable ? 'json' : 'md'}',
                  allowedExtensions: [isTable ? 'json' : 'md'],
                );
              },
            ),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: SingleChildScrollView(
            child: isChart
                // A chart row without a numeric value has no bar to draw;
                // casting it would take the whole view down over one row.
                // Table rows carry no value at all, so this filter belongs
                // here and not on the shared list.
                ? _chart(
                    context,
                    rows.where((row) => row['value'] is num).toList(),
                  )
                : isTable && columns.isNotEmpty
                ? SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: DataTable(
                      columnSpacing: 16,
                      horizontalMargin: 8,
                      dataRowMinHeight: 64,
                      dataRowMaxHeight: 88,
                      headingRowColor: WidgetStatePropertyAll(
                        theme.colorScheme.surfaceContainerLow,
                      ),
                      headingTextStyle: theme.textTheme.labelLarge,
                      dividerThickness: 0.5,
                      columns: columns
                          .map((c) => DataColumn(label: Text(c)))
                          .toList(),
                      rows: rows
                          .map(
                            (row) => DataRow(
                              cells: columns
                                  .map(
                                    (column) => DataCell(
                                      _DocumentCell('${row[column] ?? ''}'),
                                    ),
                                  )
                                  .toList(),
                            ),
                          )
                          .toList(),
                    ),
                  )
                : AgentMarkdown('${document['text'] ?? ''}'),
          ),
        ),
      ],
    );
  }

  /// A row's own colour, or the theme's. The value comes from a model, so
  /// "blue", a truncated hex or nothing at all are ordinary inputs — none of
  /// them may reach int.parse, which would throw while the panel is building.
  Color _barColor(BuildContext context, Object? raw) {
    if (raw is String) {
      final hex = raw.trim().replaceFirst('#', '');
      if (RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(hex)) {
        return Color(int.parse('ff$hex', radix: 16));
      }
    }
    return Theme.of(context).colorScheme.primary;
  }

  Widget _chart(BuildContext context, List<Map> rows) {
    final document = widget.document;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if ('${document['caption'] ?? ''}'.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text('${document['caption']}'),
          ),
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${row['label']}',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    Text(
                      '${(row['value'] as num).toStringAsFixed(1)} %',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                LayoutBuilder(
                  builder: (context, constraints) => Container(
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest
                          .withValues(alpha: .5),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    width: constraints.maxWidth,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        height: 30,
                        width:
                            constraints.maxWidth *
                            (row['value'] as num).clamp(0, 100) /
                            100,
                        decoration: BoxDecoration(
                          color: _barColor(context, row['color']),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurface.withValues(alpha: .25),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 24),
          child: DefaultTextStyle.merge(
            style: Theme.of(context).textTheme.bodySmall!.copyWith(
              color: Theme.of(context).m3.onSurfaceVariant,
            ),
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [Text('0 %'), Text('50 %'), Text('100 %')],
            ),
          ),
        ),
        const Divider(),
        if ('${document['source_url'] ?? ''}'.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Source', style: Theme.of(context).textTheme.labelMedium),
                const SizedBox(height: 4),
                _DocumentCell('${document['source_url']}', expanded: true),
              ],
            ),
          ),
        if ('${document['retrieved_at'] ?? ''}'.isNotEmpty)
          Text('Retrieved: ${document['retrieved_at']}'),
      ],
    );
  }
}

/// The quiet end of "make an update legible": a mark, not a message. It never
/// steals focus and it never queues, so a burst of agent writes cannot turn
/// into a stack of notifications.
class _UpdatedMark extends StatelessWidget {
  const _UpdatedMark();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.auto_awesome,
            size: 12,
            color: scheme.onSecondaryContainer,
          ),
          const SizedBox(width: 4),
          Text(
            'Updated',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: scheme.onSecondaryContainer,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _DocumentCell extends StatelessWidget {
  const _DocumentCell(this.value, {this.expanded = false});
  final String value;
  final bool expanded;
  @override
  Widget build(BuildContext context) {
    final uri = Uri.tryParse(value);
    final link =
        uri != null &&
        (uri.scheme == 'https' || uri.scheme == 'http') &&
        uri.host.isNotEmpty;
    if (!link) {
      return SizedBox(width: 145, child: SelectableText(value, maxLines: 3));
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (expanded)
          Expanded(
            child: SelectableText(
              value,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          )
        else
          Tooltip(
            message: value,
            child: SizedBox(
              width: 95,
              child: Text(
                uri.host.replaceFirst('www.', ''),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        IconButton(
          tooltip: 'Copy link',
          constraints: const BoxConstraints.tightFor(width: 32, height: 40),
          padding: EdgeInsets.zero,
          icon: const Icon(Icons.copy, size: 18),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: value));
            if (context.mounted) {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('Link copied')));
            }
          },
        ),
        IconButton(
          tooltip: 'Open in browser',
          constraints: const BoxConstraints.tightFor(width: 32, height: 40),
          padding: EdgeInsets.zero,
          icon: const Icon(Icons.open_in_new, size: 18),
          onPressed: () async {
            final opened = await launchUrl(
              uri,
              mode: LaunchMode.externalApplication,
            );
            if (!opened && context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Could not open link')),
              );
            }
          },
        ),
      ],
    );
  }
}
