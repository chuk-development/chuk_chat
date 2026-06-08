// lib/widgets/sandbox_artifact_block.dart
//
// Renders a [SandboxArtifactPayload] inline inside the AI message bubble.
// The artifact's encrypted bytes live in Supabase Storage (via
// `PdfAttachmentService`). This widget downloads & decrypts on demand, then
// picks a renderer based on the mime type:
//
//  * image/*                 → inline image (tap to open full-screen viewer)
//  * application/pdf         → embedded PDF viewer (pdfrx)
//  * text/*, application/json, application/xml → preview in a code-style card
//    (capped at 16 KB; "Save full file" exposes the rest via FileSaveService)
//  * everything else         → file chip with download button

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import 'package:chuk_chat/models/content_block.dart' show SandboxArtifactPayload;
import 'package:chuk_chat/services/file_save_service.dart';
import 'package:chuk_chat/services/pdf_attachment_service.dart';
import 'package:chuk_chat/widgets/image_viewer.dart';
import 'package:chuk_chat/widgets/nice_snackbar.dart';

/// Maximum number of characters of text content we inline. Anything larger
/// gets a "Save full file" affordance instead.
const int _kInlineTextCharCap = 16 * 1024;

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

  /// We only auto-decrypt previewable mimes (image/pdf/text). For "other"
  /// artifacts we render a file chip without downloading until the user
  /// hits the Download button — saves the round-trip + decrypt cost when
  /// the user never actually wants the file.
  bool get _shouldEagerLoad {
    final mime = widget.payload.mime;
    return mime.startsWith('image/') ||
        mime == 'application/pdf' ||
        _isTextLike(mime);
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
        bytes = await PdfAttachmentService.download(
          widget.payload.storagePath,
        );
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

  @override
  Widget build(BuildContext context) {
    final mime = widget.payload.mime;
    if (mime.startsWith('image/')) {
      return _buildImage(context);
    }
    if (mime == 'application/pdf') {
      return _buildPdf(context);
    }
    if (_isTextLike(mime)) {
      return _buildTextPreview(context);
    }
    return _buildFileChip(context);
  }

  Widget _buildImage(BuildContext context) {
    return _ArtifactCard(
      payload: widget.payload,
      onSave: _save,
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

  Widget _buildTextPreview(BuildContext context) {
    return _ArtifactCard(
      payload: widget.payload,
      onSave: _save,
      child: _content(
        builder: (bytes) {
          String preview;
          var truncated = false;
          try {
            final decoded = utf8.decode(bytes);
            if (decoded.length > _kInlineTextCharCap) {
              preview = decoded.substring(0, _kInlineTextCharCap);
              truncated = true;
            } else {
              preview = decoded;
            }
          } catch (e) {
            return _ArtifactErrorRow(
              message: 'File is not valid UTF-8 text.',
              onSave: _save,
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                constraints: const BoxConstraints(maxHeight: 320),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Scrollbar(
                  child: SingleChildScrollView(
                    child: SelectableText(
                      preview,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12.5,
                        height: 1.4,
                      ),
                    ),
                  ),
                ),
              ),
              if (truncated)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline, size: 14),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Preview truncated. Save the file to view the rest.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildFileChip(BuildContext context) {
    return _ArtifactCard(
      payload: widget.payload,
      onSave: _save,
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
  });

  final SandboxArtifactPayload payload;
  final Future<void> Function() onSave;
  final Widget? child;

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
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
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
                    Text(
                      payload.filename,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$human  •  ${payload.mime}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonalIcon(
                onPressed: onSave,
                icon: const Icon(Icons.download, size: 18),
                label: const Text('Download'),
              ),
            ],
          ),
          if (child != null) ...[
            const SizedBox(height: 10),
            child!,
          ],
        ],
      ),
    );
  }
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
          child: Text(
            message,
            style: Theme.of(context).textTheme.bodySmall,
          ),
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
