/// Media: everything the agents have handed over, without opening a chat.
///
/// Three kinds, each read its own way:
///
/// - a picture is looked at: a grid of thumbnails, tap for full screen;
/// - a file is opened or saved: one quiet row per file, the row opens it;
/// - a page is a document the agent keeps and rewrites (`chat_document`,
///   docs/PAGES.md): one row per page, whatever the number of versions, and
///   the row opens the newest one.
///
/// Less is more: no button on a row. The row is the target; the viewer it
/// opens carries Share and Save.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import 'package:chuk_chat/services/agents/media_index.dart';
import 'package:chuk_chat/services/file_save_service.dart';
import 'package:chuk_chat/services/pdf_attachment_service.dart';
import 'package:chuk_chat/ui/components/components.dart';
import 'package:chuk_chat/ui/expressive/connected_group.dart';
import 'package:chuk_chat/ui/expressive/huge_icon.dart';
import 'package:chuk_chat/ui/expressive/top_veil.dart';
import 'package:chuk_chat/utils/format_bytes.dart';
import 'package:chuk_chat/widgets/chat_document_view.dart';
import 'package:chuk_chat/widgets/encrypted_image_widget.dart';
import 'package:chuk_chat/widgets/image_viewer.dart';
import 'package:chuk_chat/widgets/nice_snackbar.dart';

/// The three segments, in the order the switch shows them.
const List<String> kMediaSegments = <String>['Pictures', 'Files', 'Pages'];

class MobileMediaPage extends StatefulWidget {
  const MobileMediaPage({
    super.key,
    this.index,
    this.threadKeys = const [],
    this.agentNames = const <String, String>{},
    this.initialSegment = 0,
  });

  final MediaIndex? index;

  /// Every thread this device holds. Read once each, so what arrived before
  /// this tab existed is in the list too.
  final List<String> threadKeys;

  /// The agent name for a thread key, for the line under a row.
  final Map<String, String> agentNames;

  /// The segment shown first (0 pictures, 1 files, 2 pages).
  final int initialSegment;

  @override
  State<MobileMediaPage> createState() => _MobileMediaPageState();
}

class _MobileMediaPageState extends State<MobileMediaPage> {
  late int _filter = widget.initialSegment.clamp(0, 2);

  MediaIndex get _index => widget.index ?? MediaIndex.instance;

  @override
  void initState() {
    super.initState();
    unawaited(_index.ensureFor(widget.threadKeys));
  }

  @override
  void didUpdateWidget(MobileMediaPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    unawaited(_index.ensureFor(widget.threadKeys));
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return AnimatedBuilder(
      animation: _index,
      builder: (BuildContext context, Widget? _) {
        final MediaKind kind = MediaKind.values[_filter];
        final List<MediaEntry> shown = _index.entries(kind: kind);
        final EdgeInsets inset = MediaQuery.paddingOf(context);
        final double topSpace = inset.top + 58 + 4 + 72;
        final EdgeInsets listPadding = EdgeInsets.fromLTRB(
          12,
          topSpace,
          12,
          inset.bottom + 24,
        );
        return Stack(
          children: <Widget>[
            Positioned.fill(
              child: shown.isEmpty
                  ? _Empty(topSpace: topSpace, kind: kind)
                  : kind == MediaKind.image
                  ? GridView.builder(
                      padding: listPadding,
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 160,
                            crossAxisSpacing: 8,
                            mainAxisSpacing: 8,
                          ),
                      itemCount: shown.length,
                      itemBuilder: (BuildContext context, int i) =>
                          _Thumbnail(entry: shown[i]),
                    )
                  : ListView.builder(
                      key: PageStorageKey<String>('media-${kind.name}'),
                      padding: listPadding,
                      itemCount: shown.length,
                      itemBuilder: (BuildContext context, int i) => MediaRow(
                        entry: shown[i],
                        agentName: widget.agentNames[shown[i].threadKey],
                      ),
                    ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: TopVeil(
                fadeBelow: 14,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 12, 0),
                      child: SizedBox(
                        height: 58,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'Media',
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.5,
                            ),
                          ),
                        ),
                      ),
                    ),
                    // The one switch component the app has, the same one the
                    // roster uses above its list. No counts: the list says it.
                    Padding(
                      padding: const EdgeInsets.only(top: 6, bottom: 10),
                      child: ConnectedGroup(
                        labels: kMediaSegments,
                        selected: _filter,
                        onSelected: (int i) => setState(() => _filter = i),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// One file or one page: a glyph tile, the name, one quiet line. The whole
/// row opens it.
class MediaRow extends StatefulWidget {
  const MediaRow({super.key, required this.entry, this.agentName});

  final MediaEntry entry;
  final String? agentName;

  @override
  State<MediaRow> createState() => _MediaRowState();
}

class _MediaRowState extends State<MediaRow> {
  bool _busy = false;

  Future<void> _open() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (widget.entry.kind == MediaKind.page) {
        await _openPage(context, widget.entry);
      } else {
        await _openFile(context, widget.entry);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final MediaEntry entry = widget.entry;
    final String meta = mediaRowMeta(entry, agentName: widget.agentName);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: _open,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              children: <Widget>[
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  alignment: Alignment.center,
                  child: _busy
                      ? SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: scheme.onSurfaceVariant,
                          ),
                        )
                      : HugeIcon(
                          mediaRowGlyph(entry),
                          size: 22,
                          color: scheme.onSurfaceVariant,
                        ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      _RowName(
                        name: entry.name,
                        // A file name ends with what it is; a page title does
                        // not, so only a file gets the quiet extension.
                        splitExtension: entry.kind == MediaKind.file,
                      ),
                      if (meta.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 2),
                        Text(
                          meta,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RowName extends StatelessWidget {
  const _RowName({required this.name, required this.splitExtension});

  final String name;
  final bool splitExtension;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextStyle? style = theme.textTheme.bodyLarge?.copyWith(
      fontWeight: FontWeight.w600,
      height: 1.25,
    );
    final int dot = name.lastIndexOf('.');
    if (!splitExtension || dot <= 0 || dot >= name.length - 1) {
      return Text(
        name,
        style: style,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }
    // The stem may lose its end; the extension never does.
    return Row(
      children: <Widget>[
        Flexible(
          child: Text(
            name.substring(0, dot),
            style: style,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Text(
          name.substring(dot),
          style: style?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          maxLines: 1,
        ),
      ],
    );
  }
}

/// The extension of [name] in lower case, or '' when it has none.
String _extensionOf(String name) {
  final int dot = name.lastIndexOf('.');
  if (dot <= 0 || dot >= name.length - 1) return '';
  return name.substring(dot + 1).toLowerCase();
}

/// The glyph for a row: the page kind, or the file kind from the extension
/// first and the mime type second (docs/DESIGN.md §5).
@visibleForTesting
HugeIconData mediaRowGlyph(MediaEntry entry) {
  if (entry.kind == MediaKind.page) {
    return switch (entry.pageKind) {
      'html' => HugeIcons.globe02,
      'table' => HugeIcons.sheet,
      'bar_chart' || 'chart' => HugeIcons.sorting01,
      _ => HugeIcons.fileText,
    };
  }
  final String mime = entry.mime.toLowerCase();
  return switch (_extensionOf(entry.name)) {
    'pdf' => HugeIcons.pdf01,
    'csv' || 'tsv' || 'xlsx' || 'xls' || 'ods' => HugeIcons.sheet,
    'pptx' || 'ppt' || 'key' => HugeIcons.presentation01,
    'md' ||
    'markdown' ||
    'txt' ||
    'rst' ||
    'docx' ||
    'doc' => HugeIcons.fileText,
    'json' || 'yaml' || 'yml' || 'toml' => HugeIcons.braces,
    'html' || 'htm' => HugeIcons.globe02,
    'xml' ||
    'css' ||
    'js' ||
    'ts' ||
    'dart' ||
    'py' ||
    'c' ||
    'cpp' ||
    'rs' ||
    'go' ||
    'java' ||
    'kt' ||
    'swift' => HugeIcons.sourceCode,
    'sh' || 'bash' || 'zsh' => HugeIcons.terminal,
    'zip' || 'gz' || 'tar' || 'tgz' || '7z' || 'rar' => HugeIcons.zip01,
    'db' || 'sqlite' || 'sql' => HugeIcons.database01,
    'mp4' || 'mov' || 'webm' || 'mkv' => HugeIcons.video01,
    'epub' => HugeIcons.bookOpen01,
    _ =>
      mime == 'application/pdf'
          ? HugeIcons.pdf01
          : mime.startsWith('video/')
          ? HugeIcons.video01
          : mime.startsWith('image/')
          ? HugeIcons.image01
          : mime.startsWith('text/')
          ? HugeIcons.fileText
          : HugeIcons.file01,
  };
}

/// The line under a row's name: what it is, how big, which agent, when.
@visibleForTesting
String mediaRowMeta(MediaEntry entry, {String? agentName, DateTime? now}) {
  final List<String> parts = <String>[];
  if (entry.kind == MediaKind.page) {
    parts.add(switch (entry.pageKind) {
      'html' => 'HTML page',
      'table' => 'Table',
      'bar_chart' || 'chart' => 'Chart',
      _ => 'Page',
    });
    final int? version = entry.version;
    if (version != null && version > 1) parts.add('v$version');
  } else {
    final String ext = _extensionOf(entry.name);
    if (ext.isNotEmpty) parts.add(ext.toUpperCase());
    final int? size = entry.sizeBytes;
    if (size != null && size > 0) parts.add(formatBytes(size));
  }
  final String agent = (agentName ?? '').trim();
  if (agent.isNotEmpty) parts.add(agent);
  final DateTime? at = entry.at?.toLocal();
  if (at != null) {
    final DateTime today = (now ?? DateTime.now()).toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    final bool sameDay =
        at.year == today.year && at.month == today.month && at.day == today.day;
    parts.add(
      sameDay
          ? '${two(at.hour)}:${two(at.minute)}'
          : at.year == today.year
          ? '${at.day}.${at.month}.'
          : '${at.day}.${at.month}.${at.year}',
    );
  }
  return parts.join(' · ');
}

Future<void> _openPage(BuildContext context, MediaEntry entry) async {
  Map<String, dynamic>? page;
  try {
    page = await MediaIndex.loadPage(entry);
  } catch (error) {
    if (kDebugMode) debugPrint('Media: page load failed: $error');
  }
  if (!context.mounted) return;
  if (page == null) {
    NiceSnackBar.showError(context, 'This page is not on this device yet.');
    return;
  }
  await ChatDocumentView.open(context, page);
}

/// What opening a file does: read it in the app when the app can show it,
/// otherwise hand it to the save flow.
Future<void> _openFile(BuildContext context, MediaEntry entry) async {
  final Uint8List bytes;
  try {
    bytes = await PdfAttachmentService.download(entry.reference);
  } catch (error) {
    if (context.mounted) {
      NiceSnackBar.showError(context, 'Could not open ${entry.name}.');
    }
    return;
  }
  if (!context.mounted) return;
  final String ext = _extensionOf(entry.name);
  final String mime = entry.mime.toLowerCase().split(';').first.trim();
  if (ext == 'pdf' || mime == 'application/pdf') {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => _PdfScreen(name: entry.name, bytes: bytes),
      ),
    );
    return;
  }
  final _Readable? readable = _readableOf(ext, mime);
  if (readable != null) {
    final String? text = _utf8OrNull(bytes);
    if (text != null) {
      await ChatDocumentView.open(context, <String, dynamic>{
        'title': entry.name,
        if (readable == _Readable.html) 'kind': 'html',
        'text': readable == _Readable.code ? '```$ext\n$text\n```' : text,
      });
      return;
    }
  }
  await _save(context, entry.name, bytes);
}

enum _Readable { prose, code, html }

_Readable? _readableOf(String ext, String mime) {
  if (ext == 'html' ||
      ext == 'htm' ||
      mime == 'text/html' ||
      mime == 'application/xhtml+xml') {
    return _Readable.html;
  }
  if (ext == 'md' ||
      ext == 'markdown' ||
      ext == 'txt' ||
      mime == 'text/markdown' ||
      mime == 'text/plain') {
    return _Readable.prose;
  }
  if (const <String>{
        'json',
        'yaml',
        'yml',
        'toml',
        'csv',
        'xml',
        'css',
        'js',
        'ts',
        'dart',
        'py',
        'sh',
      }.contains(ext) ||
      mime == 'application/json' ||
      mime.startsWith('text/')) {
    return _Readable.code;
  }
  return null;
}

String? _utf8OrNull(Uint8List bytes) {
  try {
    return utf8.decode(bytes);
  } catch (_) {
    return null;
  }
}

Future<void> _save(BuildContext context, String name, Uint8List bytes) async {
  final SaveResult result = await FileSaveService.save(
    bytes: bytes,
    suggestedName: name,
    dialogTitle: 'Save $name',
  );
  if (!context.mounted) return;
  switch (result.outcome) {
    case SaveOutcome.savedToFolder:
    case SaveOutcome.savedViaPicker:
    case SaveOutcome.savedViaShare:
      NiceSnackBar.show(context, 'Saved $name');
    case SaveOutcome.cancelled:
      break;
    case SaveOutcome.failed:
      NiceSnackBar.showError(context, 'Could not save $name');
  }
}

/// A PDF, full screen, in the frame every viewer uses.
class _PdfScreen extends StatelessWidget {
  const _PdfScreen({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    return ExpressiveScreen(
      title: name,
      actions: <Widget>[
        FloatingHeaderButton(
          hugeIcon: HugeIcons.download01,
          tooltip: 'Save',
          onPressed: () => _save(context, name, bytes),
        ),
      ],
      builder: (BuildContext context) => Padding(
        padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
        child: PdfViewer.data(
          bytes,
          sourceName: name,
          params: const PdfViewerParams(margin: 8),
        ),
      ),
    );
  }
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.entry});

  final MediaEntry entry;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ImageViewer(imageDataUrl: entry.reference),
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: EncryptedImageWidget(
          storagePath: entry.reference,
          fit: BoxFit.cover,
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.topSpace, required this.kind});

  final double topSpace;
  final MediaKind kind;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final (HugeIconData glyph, String title, String hint) = switch (kind) {
      MediaKind.image => (
        HugeIcons.image01,
        'No pictures yet',
        'Pictures an agent sends you show up here.',
      ),
      MediaKind.file => (
        HugeIcons.folder01,
        'No files yet',
        'Files an agent sends you show up here.',
      ),
      MediaKind.page => (
        HugeIcons.fileText,
        'No pages yet',
        'Ask an agent to make a page. It keeps the page up to date here.',
      ),
    };
    return Padding(
      padding: EdgeInsets.only(top: topSpace + 48, left: 32, right: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(22),
            ),
            alignment: Alignment.center,
            child: HugeIcon(glyph, size: 28, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          Text(title, style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            hint,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
