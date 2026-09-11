// lib/widgets/sandbox_artifact_block.dart
//
// Renders a [SandboxArtifactPayload] inline inside the AI message bubble.
// The artifact's encrypted bytes live in Supabase Storage (via
// `PdfAttachmentService`). This widget downloads & decrypts on demand, then
// picks a renderer based on the mime type:
//
//  * image/*                 → inline image (tap to open full-screen viewer)
//  * application/pdf         → embedded PDF viewer (pdfrx)
//  * text/*, application/json, application/xml → a compact file card; "Open"
//    renders it in the built-in document viewer (markdown as prose, everything
//    else as text). The content is NOT dumped into the bubble: a document the
//    agent wrote is often longer than the whole conversation around it.
//  * everything else         → file chip with download button

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import 'package:cowork/models/artifact.dart';
import 'package:cowork/models/content_block.dart' show SandboxArtifactPayload;
import 'package:cowork/platform_config.dart' show kFeatureArtifacts;
import 'package:cowork/services/artifact_storage_service.dart';
import 'package:cowork/services/chat_storage_service.dart';
import 'package:cowork/services/file_save_service.dart';
import 'package:cowork/services/pdf_attachment_service.dart';
import 'package:cowork/services/supabase_service.dart';
import 'package:cowork/widgets/image_viewer.dart';
import 'package:cowork/widgets/nice_snackbar.dart';
import 'package:cowork/widgets/chat_document_view.dart';

class SandboxArtifactBlock extends StatefulWidget {
  const SandboxArtifactBlock({super.key, required this.payload});

  final SandboxArtifactPayload payload;

  @override
  State<SandboxArtifactBlock> createState() => _SandboxArtifactBlockState();
}

class _SandboxArtifactBlockState extends State<SandboxArtifactBlock> {
  Uint8List? _bytes;
  bool _loading = true;
  String? _error;

  /// We only auto-decrypt what the bubble itself shows: an image and a PDF are
  /// rendered in place, everything else waits for Open or Download. A text
  /// document is no longer fetched on arrival — it is not shown until asked
  /// for, and fetching it would spend the round-trip and the decrypt for a card
  /// that says three lines.
  bool get _shouldEagerLoad {
    final mime = widget.payload.mime;
    return mime.startsWith('image/') || mime == 'application/pdf';
  }

  bool _isTextLike(String mime) {
    // HTML is never previewed as source — dumping raw markup into the bubble
    // is noise (the user wants the rendered file, not its code). It falls
    // through to a plain file card with Download/Save instead.
    if (mime == 'text/html' || mime == 'application/xhtml+xml') return false;
    return mime.startsWith('text/') ||
        mime == 'application/json' ||
        mime == 'application/xml';
  }

  @override
  void initState() {
    super.initState();
    if (_shouldEagerLoad) {
      _load();
    } else {
      _loading = false;
    }
  }

  @override
  void didUpdateWidget(SandboxArtifactBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.payload.storagePath != widget.payload.storagePath) {
      _bytes = null;
      _error = null;
      if (_shouldEagerLoad) {
        _load();
      } else {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final bytes = await PdfAttachmentService.download(
        widget.payload.storagePath,
      );
      if (!mounted) return;
      setState(() {
        _bytes = bytes;
        _loading = false;
      });
    } catch (e) {
      if (kDebugMode) {
        debugPrint('SandboxArtifactBlock load failed: $e');
      }
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    var bytes = _bytes;
    if (bytes == null) {
      try {
        bytes = await PdfAttachmentService.download(widget.payload.storagePath);
      } catch (e) {
        if (mounted) {
          NiceSnackBar.showError(context, 'Download failed: $e');
        }
        return;
      }
    }
    final result = await FileSaveService.save(
      bytes: bytes,
      suggestedName: widget.payload.filename,
      dialogTitle: 'Save ${widget.payload.filename}',
    );
    if (!mounted) return;
    switch (result.outcome) {
      case SaveOutcome.savedToFolder:
      case SaveOutcome.savedViaPicker:
      case SaveOutcome.savedViaShare:
        NiceSnackBar.show(context, 'Saved ${widget.payload.filename}');
      case SaveOutcome.cancelled:
        break;
      case SaveOutcome.failed:
        NiceSnackBar.showError(context, 'Could not save file');
    }
  }

  /// Maps a sandbox file's MIME to an artifact type the side panel can render,
  /// or null when the file has no panel renderer (binary, pdf, raster image).
  /// Lets a sent HTML/SVG/markdown/code file open and render exactly like an
  /// artifact instead of sitting as an opaque download.
  static ArtifactType? _panelArtifactType(String mime) {
    final m = mime.toLowerCase().split(';').first.trim();
    if (m == 'text/html' || m == 'application/xhtml+xml') {
      return ArtifactType.html;
    }
    if (m == 'image/svg+xml') return ArtifactType.svg;
    if (m == 'text/markdown' || m == 'text/x-markdown') {
      return ArtifactType.markdown;
    }
    if (m == 'application/json' ||
        m == 'application/xml' ||
        m.startsWith('text/')) {
      return ArtifactType.code;
    }
    return null;
  }

  bool get _canOpenInPanel =>
      kFeatureArtifacts && _panelArtifactType(widget.payload.mime) != null;

  /// What "Open" does for this file, or null when the file cannot be read.
  ///
  /// Text — markdown above all — opens in the app's own document viewer: a
  /// full-size sheet that renders the prose. HTML and SVG want a browser
  /// surface, so they keep the artifact panel. This is the difference between
  /// the button doing something and the button doing nothing on a phone, where
  /// there is no side panel to open into.
  Future<void> Function()? _openAction(BuildContext context) {
    if (_isTextLike(widget.payload.mime)) {
      return () => _openInViewer(context);
    }
    if (_canOpenInPanel) return () => _openInPanel(context);
    return null;
  }

  /// Reads the file and shows it in [ChatDocumentView], the same viewer a
  /// document the agent saved opens in.
  Future<void> _openInViewer(BuildContext context) async {
    var bytes = _bytes;
    if (bytes == null) {
      try {
        bytes = await PdfAttachmentService.download(widget.payload.storagePath);
      } catch (e) {
        if (context.mounted) {
          NiceSnackBar.showError(context, 'Could not open file: $e');
        }
        return;
      }
      if (mounted) setState(() => _bytes = bytes);
    }
    String text;
    try {
      text = utf8.decode(bytes);
    } catch (_) {
      if (context.mounted) {
        NiceSnackBar.showError(context, 'File is not valid UTF-8 text.');
      }
      return;
    }
    if (!context.mounted) return;
    await ChatDocumentView.open(context, <String, dynamic>{
      'title': widget.payload.filename,
      'text': text,
    });
  }

  /// Opens the file in the shared artifact side panel as an ephemeral
  /// (non-persisted) artifact, so it renders identically to artifact_manager
  /// output. Version history simply comes back empty for these.
  Future<void> _openInPanel(BuildContext context) async {
    final type = _panelArtifactType(widget.payload.mime);
    if (type == null) return;

    var bytes = _bytes;
    if (bytes == null) {
      try {
        bytes = await PdfAttachmentService.download(widget.payload.storagePath);
      } catch (e) {
        if (context.mounted) {
          NiceSnackBar.showError(context, 'Could not open file: $e');
        }
        return;
      }
    }

    String content;
    try {
      content = utf8.decode(bytes);
    } catch (_) {
      if (context.mounted) {
        NiceSnackBar.showError(context, 'File is not valid UTF-8 text.');
      }
      return;
    }

    final now = DateTime.now();
    final artifact = ArtifactDocument(
      id: 'sandbox_${widget.payload.storagePath.replaceAll('/', '_')}',
      chatId: ChatStorageService.selectedChatId ?? '',
      userId: SupabaseService.auth.currentUser?.id ?? '',
      title: widget.payload.filename,
      type: type,
      content: content,
      version: 1,
      createdAt: now,
      updatedAt: now,
    );
    ArtifactStorageService.activeArtifactNotifier.value = artifact;
    ArtifactStorageService.requestOpen(artifactId: artifact.id);
  }

  @override
  Widget build(BuildContext context) {
    final document = widget.payload.document;
    if (document != null) {
      return Material(
        color: Colors.transparent,
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 4,
            vertical: 2,
          ),
          leading: Icon(
            document['kind'] == 'table'
                ? Icons.table_chart_outlined
                : Icons.description_outlined,
          ),
          title: Text(
            (document['title'] as String?)?.trim().isNotEmpty == true
                ? document['title'] as String
                : widget.payload.filename,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            document['version'] == null
                ? 'Saved document'
                : 'Version ${document['version']} · Saved document',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          trailing: const Icon(Icons.chevron_right_rounded, size: 22),
          onTap: () => ChatDocumentView.open(context, document),
        ),
      );
    }
    final mime = widget.payload.mime;
    if (mime.startsWith('image/')) {
      return _buildImage(context);
    }
    if (mime == 'application/pdf') {
      return _buildPdf(context);
    }
    return _buildFileChip(context);
  }

  Widget _buildImage(BuildContext context) {
    return _ArtifactCard(
      payload: widget.payload,
      onSave: _save,
      onOpen: _openAction(context),
      child: _content(
        builder: (bytes) {
          return GestureDetector(
            onTap: () {
              final dataUrl =
                  'data:${widget.payload.mime};base64,${base64Encode(bytes)}';
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ImageViewer(imageDataUrl: dataUrl),
                ),
              );
            },
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.memory(bytes, fit: BoxFit.contain),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildPdf(BuildContext context) {
    return _ArtifactCard(
      payload: widget.payload,
      onSave: _save,
      onOpen: _openAction(context),
      child: _content(
        builder: (bytes) => SizedBox(
          height: 480,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: PdfViewer.data(
              bytes,
              sourceName: widget.payload.filename,
              params: const PdfViewerParams(
                margin: 8,
                backgroundColor: Color(0xFF202020),
                enableKeyboardNavigation: true,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFileChip(BuildContext context) {
    return _ArtifactCard(
      payload: widget.payload,
      onSave: _save,
      onOpen: _openAction(context),
      child: null,
    );
  }

  /// Common loading/error shell around the typed-content builder.
  Widget _content({required Widget Function(Uint8List bytes) builder}) {
    if (_loading) {
      return const SizedBox(
        height: 120,
        child: Center(
          child: SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2.4),
          ),
        ),
      );
    }
    if (_error != null) {
      return _ArtifactErrorRow(
        message: 'Could not load file: $_error',
        onSave: _save,
      );
    }
    final bytes = _bytes;
    if (bytes == null) return const SizedBox.shrink();
    return builder(bytes);
  }
}

class _ArtifactCard extends StatelessWidget {
  const _ArtifactCard({
    required this.payload,
    required this.onSave,
    required this.child,
    this.onOpen,
  });

  final SandboxArtifactPayload payload;
  final Future<void> Function() onSave;
  final Widget? child;

  /// When non-null, the card shows an "Open" action that renders the file in
  /// the artifact side panel (in addition to Download).
  final Future<void> Function()? onOpen;

  IconData get _icon {
    final mime = payload.mime;
    if (mime.startsWith('image/')) return Icons.image_outlined;
    if (mime == 'application/pdf') return Icons.picture_as_pdf_outlined;
    if (mime.startsWith('video/')) return Icons.movie_outlined;
    if (mime.startsWith('audio/')) return Icons.audiotrack_outlined;
    if (mime.startsWith('text/') ||
        mime == 'application/json' ||
        mime == 'application/xml') {
      return Icons.description_outlined;
    }
    if (mime.contains('zip') ||
        mime.contains('tar') ||
        mime.contains('compressed')) {
      return Icons.folder_zip_outlined;
    }
    return Icons.insert_drive_file_outlined;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final human = _humanReadableBytes(payload.sizeBytes);
    // A file with nothing to preview is one line: a typed badge, the name with
    // its extension, the size. The row itself opens it. Two big buttons in a
    // chat bubble are louder than the message they belong to, and they squeezed
    // the one thing that identifies the file — its name — down to "gesch…".
    if (child == null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 2),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(14),
          ),
          clipBehavior: Clip.antiAlias,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onOpen,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(11),
                      ),
                      child: Icon(_icon, size: 21, color: scheme.primary),
                    ),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _FileName(filename: payload.filename, scheme: scheme),
                          const SizedBox(height: 2),
                          Text(
                            human,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    IconButton(
                      onPressed: onSave,
                      icon: const Icon(Icons.download, size: 20),
                      tooltip: 'Download',
                      visualDensity: VisualDensity.compact,
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(_icon, size: 22, color: scheme.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _FileName(filename: payload.filename, scheme: scheme),
                          const SizedBox(height: 2),
                          Text(
                            '$human  ·  ${_kindLabel(payload.mime)}',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: scheme.onSurfaceVariant),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: onSave,
                      icon: const Icon(Icons.download, size: 20),
                      tooltip: 'Download',
                      visualDensity: VisualDensity.compact,
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                child!,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The file name, with the extension in the quieter colour.
///
/// `Marktdaten_TEST_2026-09-11.md` is read as a name and a kind, and the kind
/// is the part a reader does not need in full strength. Nothing is hidden: the
/// whole name is there, it simply stops shouting the last four characters.
class _FileName extends StatelessWidget {
  const _FileName({required this.filename, required this.scheme});

  final String filename;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final int dot = filename.lastIndexOf('.');
    final bool hasExtension = dot > 0 && dot < filename.length - 1;
    final String stem = hasExtension ? filename.substring(0, dot) : filename;
    final String extension = hasExtension ? filename.substring(dot) : '';
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: stem),
          if (extension.isNotEmpty)
            TextSpan(
              text: extension,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
        ],
      ),
      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// A short, readable name for a mime type. `text/markdown` says nothing to a
/// reader that "Markdown" does not say better, and the raw type was long
/// enough to push the size off the line.
String _kindLabel(String mime) {
  final String m = mime.toLowerCase().split(';').first.trim();
  return switch (m) {
    'text/markdown' || 'text/x-markdown' => 'Markdown',
    'text/plain' => 'Text',
    'text/html' || 'application/xhtml+xml' => 'HTML',
    'text/csv' => 'CSV',
    'application/json' => 'JSON',
    'application/xml' || 'text/xml' => 'XML',
    'application/pdf' => 'PDF',
    'image/svg+xml' => 'SVG',
    _ =>
      m.startsWith('image/')
          ? 'Image'
          : m.startsWith('video/')
          ? 'Video'
          : m.startsWith('audio/')
          ? 'Audio'
          : m.startsWith('text/')
          ? 'Text'
          : m,
  };
}

class _ArtifactErrorRow extends StatelessWidget {
  const _ArtifactErrorRow({required this.message, required this.onSave});

  final String message;
  final Future<void> Function() onSave;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.error_outline, size: 18, color: Colors.redAccent),
        const SizedBox(width: 8),
        Expanded(
          child: Text(message, style: Theme.of(context).textTheme.bodySmall),
        ),
        TextButton(onPressed: onSave, child: const Text('Retry / Save')),
      ],
    );
  }
}

String _humanReadableBytes(int n) {
  if (n < 1024) return '$n B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = n / 1024.0;
  var unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex++;
  }
  final formatted = value < 10
      ? value.toStringAsFixed(1)
      : value.round().toString();
  return '$formatted ${units[unitIndex]}';
}
