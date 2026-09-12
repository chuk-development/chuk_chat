import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:cowork/ui/expressive/icon_map.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:cowork/constants.dart';
import 'package:cowork/services/file_save_service.dart';
import 'package:cowork/utils/theme_extensions.dart';
import 'package:cowork/widgets/agent_markdown.dart';
import 'package:cowork/widgets/chat_document_inline.dart';
import 'package:cowork/widgets/charts/chuk_chart.dart';
import 'package:cowork/ui/expressive/huge_icon.dart';
import 'package:cowork/ui/expressive/motion.dart';
import 'package:cowork/ui/expressive/top_veil.dart';
import 'package:cowork/widgets/chuk_table.dart';

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
    parts.add(
      sameDay ? clock : '${two(stamp.day)}.${two(stamp.month)}. $clock',
    );
  }
  return parts.isEmpty ? null : parts.join(' · ');
}

/// A file name for a document, from its title.
///
/// The agent titles a document for a reader, not for a filesystem: `Sachsen-
/// Anhalt 2026 · Zweitstimmen` and `reports/q3` are both ordinary titles. A
/// slash in a suggested name asks the save dialog to write into a directory
/// that may not exist, so every separator and reserved character becomes a
/// hyphen and an empty result falls back to `document`.
String documentFileStem(Object? title) {
  final cleaned = '${title ?? ''}'
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '-')
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'^[\s.-]+|[\s.-]+$'), '');
  if (cleaned.isEmpty) return 'document';
  return cleaned.length > 80 ? cleaned.substring(0, 80).trim() : cleaned;
}

class ChatDocumentView extends StatefulWidget {
  const ChatDocumentView({
    super.key,
    required this.document,
    this.showActions = true,
    this.topInset = 0,
  });
  final Map<String, dynamic> document;

  /// Whether the body draws its own Save action. The full-screen presentation
  /// carries Share and Save in its bar instead, and two Saves on one screen is
  /// one too many.
  final bool showActions;

  /// Room kept at the top of the SCROLLING content, not around the widget.
  /// A floating bar needs the document to start below it and then to travel up
  /// behind it; padding the whole view would park the text under the bar for
  /// good and nothing would ever show through the veil.
  final double topInset;

  /// Show [document].
  ///
  /// On a phone this is a screen of its own, not a dialog: a document is read,
  /// and reading it through a window with a margin on every side wastes the
  /// width a table needs. A wide window keeps the dialog, where a full-screen
  /// takeover would be the wrong weight.
  static Future<void> open(
    BuildContext context,
    Map<String, dynamic> document,
  ) {
    final Size media = MediaQuery.sizeOf(context);
    if (media.width < 700) {
      return Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (BuildContext context) =>
              _DocumentScreen(document: document),
        ),
      );
    }
    return showDialog<void>(
      context: context,
      builder: (context) {
        final theme = Theme.of(context);
        return Dialog(
          clipBehavior: Clip.antiAlias,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 24,
          ),
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
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Text(
                            '${document['title']}',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                              height: 1.25,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Close',
                        onPressed: () => Navigator.pop(context),
                        icon: const AppIcon(Icons.close),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: theme.m3.outlineVariant),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: ChatDocumentView(document: document),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// The document as the bytes a file would hold: JSON for a table, the
  /// markdown source for prose.
  static (Uint8List, String) _fileOf(Map<String, dynamic> document) {
    final bool isTable =
        document['kind'] == 'table' || documentIsChart(document);
    final String text = isTable
        ? const JsonEncoder.withIndent('  ').convert(document)
        : '${document['text'] ?? ''}';
    final String name =
        '${documentFileStem(document['title'])}.${isTable ? 'json' : 'md'}';
    return (Uint8List.fromList(utf8.encode(text)), name);
  }

  /// Write the document to wherever the user keeps their downloads.
  static Future<void> save(Map<String, dynamic> document) async {
    final (Uint8List bytes, String name) = _fileOf(document);
    await FileSaveService.save(
      bytes: bytes,
      suggestedName: name,
      allowedExtensions: [name.split('.').last],
    );
  }

  /// Hand the document to whatever the platform offers to share with.
  static Future<void> share(Map<String, dynamic> document) async {
    final (Uint8List bytes, String name) = _fileOf(document);
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile.fromData(bytes, name: name, mimeType: 'text/markdown')],
      ),
    );
  }

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
    final isChart = documentIsChart(document);
    final isTable = document['kind'] == 'table' || isChart;
    final columns = (document['columns'] as List? ?? [])
        .map((v) => '$v')
        .toList();
    final rows = (document['rows'] as List? ?? []).whereType<Map>().toList();
    final shape = isChart
        ? documentChart(document).countLabel
        : isTable
        ? '${rows.length} rows'
        : 'Markdown document';
    final freshness = documentFreshness(document);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Under a floating bar the meta line would sit in the one place the
        // document travels through, and the two would overlap. The bar already
        // names the file, so the line is dropped there and the scroller keeps
        // the room instead.
        if (widget.topInset == 0)
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
              if (widget.showActions)
                TextButton.icon(
                  style: TextButton.styleFrom(
                    shape: const StadiumBorder(),
                    // The icon is a drawing now, not a glyph with its own side
                    // bearings, so the default padding pushed it past the
                    // reading column at phone width.
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    visualDensity: VisualDensity.compact,
                  ),
                  icon: const AppIcon(Icons.download, size: 18),
                  label: const Text('Save'),
                  onPressed: () => ChatDocumentView.save(document),
                ),
            ],
          ),
        if (widget.topInset == 0) const SizedBox(height: 12),
        Expanded(
          child: SingleChildScrollView(
            // The last line of a document needs room under it; without this
            // the closing paragraph sat flush against the dialog edge.
            padding: EdgeInsets.only(bottom: 24, top: widget.topInset),
            child: isChart
                ? _chart(context)
                : isTable && columns.isNotEmpty
                ? _table(context)
                : _prose(context, '${document['text'] ?? ''}'),
          ),
        ),
      ],
    );
  }

  /// The longest line a reader should have to track back from. Past roughly
  /// this width the eye loses the start of the next line, so on a wide dialog
  /// the prose keeps a column instead of running the full 968 pixels.
  static const double _readingMeasure = 720;

  /// A markdown document, at document size rather than chat size: a larger
  /// body and a looser line height than a chat bubble, inside a reading
  /// measure. The renderer is the app's own — see [AgentMarkdown].
  Widget _prose(BuildContext context, String text) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: _readingMeasure),
      child: AgentMarkdown(text, fontSize: 15.5, height: 1.7),
    ),
  );

  /// A table document, drawn by the same widget the chat uses.
  ///
  /// The old [DataTable] was 875 pixels wide inside a 348-pixel phone column
  /// (963 at a 1.3 text scale): four of five columns sat off the right edge,
  /// pannable but with nothing to say they were there. [ChukTable] stacks a
  /// table that cannot fit below 560 pixels into one card per row, every field
  /// labelled, which is the answer the chat already shipped for this.
  Widget _table(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: ChukTable(
          // The same shape the thread draws inline — one table, two sizes.
          table: documentParsedTable(widget.document),
          textColor: theme.colorScheme.onSurface,
          accentColor: theme.colorScheme.primary,
          fontSize: 14,
          onTapLink: (href) => openDocumentLink(context, href),
        ),
      ),
    );
  }

  /// The chart, whole.
  ///
  /// The same [ChukChart] the thread draws, from the same [documentChart]
  /// mapping — the reader is the thread's chart without the six-bar cap, not a
  /// second drawing of the same numbers. The caption travels into the chart as
  /// its subtitle, so it is not printed twice.
  ///
  /// The source keeps its own block below the card: a painted footer cannot be
  /// tapped, and a source URL exists to be opened.
  Widget _chart(BuildContext context) {
    final document = widget.document;
    final theme = Theme.of(context);
    final source = '${document['source_url'] ?? ''}';
    final retrieved = '${document['retrieved_at'] ?? ''}';
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _readingMeasure),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ChukChart(
              spec: documentChart(document, withSource: false).spec,
              accentColor: theme.colorScheme.primary,
            ),
            const SizedBox(height: 12),
            // A rule under nothing is furniture: the footer only appears when
            // the document carries a source or a retrieval time.
            if (source.isNotEmpty || retrieved.isNotEmpty) ...[
              Divider(height: 1, color: theme.m3.outlineVariant),
              if (source.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Source', style: theme.textTheme.labelMedium),
                      const SizedBox(height: 4),
                      _DocumentCell(source, expanded: true),
                    ],
                  ),
                ),
              if (retrieved.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Retrieved: $retrieved',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.m3.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
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
          AppIcon(
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
          icon: const AppIcon(Icons.copy, size: 18),
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
          icon: const AppIcon(Icons.open_in_new, size: 18),
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

/// The phone presentation of a document: its own screen, a bar that floats on
/// the shared veil, and the document reading through underneath it.
class _DocumentScreen extends StatelessWidget {
  const _DocumentScreen({required this.document});

  final Map<String, dynamic> document;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    // The bar is as tall as its buttons plus the padding around them; the
    // document starts under it and scrolls through the veil.
    const double barHeight = 48 + 12;
    return Scaffold(
      body: Stack(
        children: <Widget>[
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: ChatDocumentView(
                document: document,
                showActions: false,
                // The document starts below the bar and then travels up behind
                // it, which is the only way the veil has anything to veil.
                topInset: MediaQuery.paddingOf(context).top + barHeight,
              ),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: TopVeil(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
                child: Row(
                  children: <Widget>[
                    ExpressiveIconButton(
                      hugeIcon: HugeIcons.cancel01,
                      tooltip: 'Close',
                      color: scheme.surfaceContainerHighest,
                      onTap: () => Navigator.pop(context),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _MiddleEllipsis(
                        text: '${document['title']}',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    ExpressiveIconButton(
                      hugeIcon: HugeIcons.share01,
                      tooltip: 'Share',
                      color: scheme.surfaceContainerHighest,
                      onTap: () => ChatDocumentView.share(document),
                    ),
                    const SizedBox(width: 8),
                    ExpressiveIconButton(
                      hugeIcon: HugeIcons.download01,
                      tooltip: 'Save',
                      color: scheme.surfaceContainerHighest,
                      onTap: () => ChatDocumentView.save(document),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One line that loses its middle, not its end.
///
/// A file name ends with the part that says what it is — `.md`, `.xlsx` — and
/// ellipsising from the right throws exactly that away:
/// `geschichte_der_dampfmasc…`. Cut from the middle and both ends survive:
/// `geschichte_der…maschine.md`.
class _MiddleEllipsis extends StatelessWidget {
  const _MiddleEllipsis({required this.text, this.style});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final TextStyle? resolved = style;
        final double scale = MediaQuery.textScalerOf(context).scale(1);
        double width(String candidate) {
          final TextPainter painter = TextPainter(
            text: TextSpan(text: candidate, style: resolved),
            maxLines: 1,
            textDirection: Directionality.of(context),
            textScaler: TextScaler.linear(scale),
          )..layout();
          return painter.width;
        }

        String shown = text;
        if (width(shown) > constraints.maxWidth) {
          // Take one character from each side in turn until it fits, so the
          // remaining halves stay about even.
          int head = text.length ~/ 2;
          int tail = text.length - head;
          while (head + tail > 4) {
            if (head > tail) {
              head--;
            } else {
              tail--;
            }
            shown =
                '${text.substring(0, head)}…${text.substring(text.length - tail)}';
            if (width(shown) <= constraints.maxWidth) break;
          }
        }
        return Text(shown, style: resolved, maxLines: 1, softWrap: false);
      },
    );
  }
}
