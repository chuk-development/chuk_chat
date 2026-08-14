// lib/widgets/attachment_preview_bar.dart
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:chuk_chat/utils/io_helper.dart';

import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:pdfx/pdfx.dart';

import 'package:chuk_chat/constants/file_constants.dart';
import 'package:chuk_chat/models/chat_model.dart';
import 'package:chuk_chat/widgets/encrypted_image_widget.dart';
import 'package:chuk_chat/widgets/image_viewer.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/constants.dart';

typedef AttachmentRemoveCallback = void Function(String fileId);
typedef AttachmentCopyCallback = Future<void> Function(AttachedFile file);
typedef AttachmentContentChangedCallback =
    void Function(String fileId, String newContent);

const int _kMaxExtensionChars = 3;

// Image card dimensions
const double _kImageCardSize = 72.0;
const double _kImageCardBorderWidth = 2.0;

class AttachmentPreviewBar extends StatefulWidget {
  const AttachmentPreviewBar({
    super.key,
    required this.files,
    required this.onRemove,
    this.onCopy,
    this.onContentChanged,
  });

  final List<AttachedFile> files;
  final AttachmentRemoveCallback onRemove;
  final AttachmentCopyCallback? onCopy;
  final AttachmentContentChangedCallback? onContentChanged;

  @override
  State<AttachmentPreviewBar> createState() => _AttachmentPreviewBarState();
}

class _AttachmentPreviewBarState extends State<AttachmentPreviewBar> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// Convert vertical mouse-wheel events into horizontal scrolling.
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      final double delta = event.scrollDelta.dy;
      final double target = (_scrollController.offset + delta).clamp(
        0.0,
        _scrollController.position.maxScrollExtent,
      );
      _scrollController.jumpTo(target);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.files.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final Color baseTextColor =
        theme.iconTheme.color ?? theme.colorScheme.onSurface;

    return Align(
      alignment: Alignment.centerLeft,
      child: Listener(
        onPointerSignal: _onPointerSignal,
        child: SingleChildScrollView(
          controller: _scrollController,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: widget.files.map((file) {
              final bool isImage = _isImageFile(file.fileName);
              if (isImage) {
                return _ImageAttachmentCard(
                  file: file,
                  onRemove: widget.onRemove,
                );
              }
              return _DocumentAttachmentTile(
                file: file,
                onRemove: widget.onRemove,
                onCopy: widget.onCopy,
                onContentChanged: widget.onContentChanged,
                textColor: baseTextColor,
                accentColor: theme.colorScheme.primary,
                cardColor: theme.colorScheme.surface.withValues(alpha: 0.9),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Image attachment card — large thumbnail with overlay controls
// ---------------------------------------------------------------------------

class _ImageAttachmentCard extends StatelessWidget {
  const _ImageAttachmentCard({required this.file, required this.onRemove});

  final AttachedFile file;
  final AttachmentRemoveCallback onRemove;
  static final Map<String, Uint8List> _localThumbnailCache =
      <String, Uint8List>{};
  static const int _kLocalThumbnailCacheLimit = 24;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bool isUploading = file.isUploading;
    final accent = theme.colorScheme.primary;
    const double innerSize = _kImageCardSize - _kImageCardBorderWidth * 2;
    final BorderRadius outerRadius = BorderRadius.circular(16);
    final BorderRadius innerRadius = BorderRadius.circular(14);

    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: isUploading ? null : () => _openImageViewer(context),
        child: Container(
          width: _kImageCardSize,
          height: _kImageCardSize,
          padding: const EdgeInsets.all(_kImageCardBorderWidth),
          decoration: BoxDecoration(
            borderRadius: outerRadius,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                accent.withValues(alpha: 0.6),
                accent.withValues(alpha: 0.1),
              ],
            ),
          ),
          child: ClipRRect(
            borderRadius: innerRadius,
            child: SizedBox(
              width: innerSize,
              height: innerSize,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Thumbnail image
                  _buildThumbnail(theme),

                  // Upload progress overlay
                  if (isUploading)
                    Container(
                      color: Colors.black.withValues(alpha: 0.5),
                      child: Center(
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            valueColor: AlwaysStoppedAnimation(accent),
                          ),
                        ),
                      ),
                    ),

                  // Size badge (bottom-left)
                  if (!isUploading && file.fileSizeBytes != null)
                    Positioned(
                      left: 4,
                      bottom: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          _formatBytes(file.fileSizeBytes!),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 8,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),

                  // Remove button (top-right)
                  Positioned(
                    top: 3,
                    right: 3,
                    child: _RemoveButton(
                      onTap: isUploading ? null : () => onRemove(file.id),
                      tooltip: AppLocalizations.of(context)!.removeFile(file.fileName),
                      size: 18,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildThumbnail(ThemeData theme) {
    // Encrypted image (after upload)
    if (file.encryptedImagePath != null) {
      return EncryptedImageWidget(
        storagePath: file.encryptedImagePath!,
        fit: BoxFit.cover,
      );
    }

    // Local file image (during/before upload)
    if (!kIsWeb && file.localPath != null) {
      final localPath = file.localPath!;
      final cachedBytes = _localThumbnailCache[localPath];
      if (cachedBytes != null) {
        return Image.memory(
          cachedBytes,
          fit: BoxFit.cover,
          cacheWidth: (_kImageCardSize * 2).toInt(),
          cacheHeight: (_kImageCardSize * 2).toInt(),
        );
      }

      final localFile = File(localPath);
      if (localFile.existsSync()) {
        final bytes = localFile.readAsBytesSync();
        if (_localThumbnailCache.length >= _kLocalThumbnailCacheLimit) {
          _localThumbnailCache.remove(_localThumbnailCache.keys.first);
        }
        _localThumbnailCache[localPath] = bytes;
        return Image.memory(
          bytes,
          fit: BoxFit.cover,
          cacheWidth: (_kImageCardSize * 2).toInt(),
          cacheHeight: (_kImageCardSize * 2).toInt(),
        );
      }
    }

    // Fallback placeholder
    return Container(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
      child: Icon(
        Icons.image_outlined,
        color: theme.colorScheme.primary.withValues(alpha: 0.5),
        size: 32,
      ),
    );
  }

  void _openImageViewer(BuildContext context) {
    final String? encryptedPath = file.encryptedImagePath;
    String? imageSource;

    if (encryptedPath != null) {
      // Use encrypted storage path — ImageViewer handles download + decrypt
      imageSource = encryptedPath;
    } else if (!kIsWeb && file.localPath != null) {
      // Convert local file bytes to a data URL for ImageViewer
      final localFile = File(file.localPath!);
      if (localFile.existsSync()) {
        final bytes = localFile.readAsBytesSync();
        imageSource = 'data:image/png;base64,${base64Encode(bytes)}';
      }
    }

    if (imageSource == null) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => ImageViewer(imageDataUrl: imageSource!),
        fullscreenDialog: true,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Small circular remove button overlay
// ---------------------------------------------------------------------------

class _RemoveButton extends StatelessWidget {
  const _RemoveButton({required this.onTap, this.tooltip, this.size = 22});

  final VoidCallback? onTap;
  final String? tooltip;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.55),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: kBorderRadiusRow,
        onTap: onTap,
        child: Tooltip(
          message: tooltip ?? 'Remove',
          child: Padding(
            padding: EdgeInsets.all(size * 0.18),
            child: Icon(Icons.close, size: size * 0.6, color: Colors.white),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Document / non-image attachment card — matches image card style (72px square)
// ---------------------------------------------------------------------------

class _DocumentAttachmentTile extends StatelessWidget {
  const _DocumentAttachmentTile({
    required this.file,
    required this.onRemove,
    required this.onCopy,
    this.onContentChanged,
    required this.textColor,
    required this.accentColor,
    required this.cardColor,
  });

  final AttachedFile file;
  final AttachmentRemoveCallback onRemove;
  final AttachmentCopyCallback? onCopy;
  final AttachmentContentChangedCallback? onContentChanged;
  final Color textColor;
  final Color accentColor;
  final Color cardColor;

  @override
  Widget build(BuildContext context) {
    final bool isUploading = file.isUploading;
    const double innerSize = _kImageCardSize - _kImageCardBorderWidth * 2;
    final BorderRadius outerRadius = BorderRadius.circular(16);
    final BorderRadius innerRadius = BorderRadius.circular(14);
    final String extLabel = _extensionLabel(file.fileName);

    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: isUploading
            ? null
            : () => _showDocumentPreview(
                context,
                file,
                textColor,
                onContentChanged: onContentChanged,
              ),
        child: Tooltip(
          message: file.fileName,
          child: Container(
            width: _kImageCardSize,
            height: _kImageCardSize,
            padding: const EdgeInsets.all(_kImageCardBorderWidth),
            decoration: BoxDecoration(
              borderRadius: outerRadius,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  accentColor.withValues(alpha: 0.6),
                  accentColor.withValues(alpha: 0.1),
                ],
              ),
            ),
            child: ClipRRect(
              borderRadius: innerRadius,
              child: SizedBox(
                width: innerSize,
                height: innerSize,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // Background with extension label
                    Container(
                      color: cardColor,
                      child: Center(
                        child: Text(
                          extLabel.isNotEmpty ? extLabel : '?',
                          style: TextStyle(
                            color: accentColor,
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                          ),
                        ),
                      ),
                    ),

                    // Upload progress overlay
                    if (isUploading)
                      Container(
                        color: Colors.black.withValues(alpha: 0.5),
                        child: Center(
                          child: SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              valueColor: AlwaysStoppedAnimation(accentColor),
                            ),
                          ),
                        ),
                      ),

                    // Size badge (bottom-left)
                    if (!isUploading && file.fileSizeBytes != null)
                      Positioned(
                        left: 4,
                        bottom: 4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.6),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            _formatBytes(file.fileSizeBytes!),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 8,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),

                    // Remove button (top-right)
                    Positioned(
                      top: 3,
                      right: 3,
                      child: _RemoveButton(
                        onTap: isUploading ? null : () => onRemove(file.id),
                        tooltip: AppLocalizations.of(context)!.removeFile(file.fileName),
                        size: 18,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Document preview dialog — themed, editable for plain text files
// ---------------------------------------------------------------------------

void _showDocumentPreview(
  BuildContext context,
  AttachedFile file,
  Color textColor, {
  AttachmentContentChangedCallback? onContentChanged,
}) {
  showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.7),
    builder: (context) =>
        _DocumentPreviewDialog(file: file, onContentChanged: onContentChanged),
  );
}

class _DocumentPreviewDialog extends StatefulWidget {
  const _DocumentPreviewDialog({required this.file, this.onContentChanged});

  final AttachedFile file;
  final AttachmentContentChangedCallback? onContentChanged;

  @override
  State<_DocumentPreviewDialog> createState() => _DocumentPreviewDialogState();
}

class _DocumentPreviewDialogState extends State<_DocumentPreviewDialog> {
  // File type flags
  late final bool _isPlainText;
  late final bool _isPdf;

  // Plain-text state
  bool _isEditing = false;
  bool _isLoading = true;
  String? _content;
  late TextEditingController _editController;
  final ScrollController _scrollController = ScrollController();

  // PDF state
  PdfController? _pdfController;
  bool _pdfError = false;

  @override
  void initState() {
    super.initState();
    _isPlainText = _isPlainTextFile(widget.file.fileName);
    _isPdf = _isPdfFile(widget.file.fileName);
    _editController = TextEditingController();

    if (_isPlainText) {
      _loadTextContent();
    } else if (_isPdf) {
      _loadPdfContent();
    } else {
      // No preview available — stop loading immediately
      _isLoading = false;
    }
  }

  @override
  void dispose() {
    _editController.dispose();
    _scrollController.dispose();
    _pdfController?.dispose();
    super.dispose();
  }

  // -- Plain text loading ------------------------------------------------

  Future<void> _loadTextContent() async {
    final text = await _loadPlainTextContent(widget.file);
    if (!mounted) return;
    setState(() {
      _content = text ?? widget.file.markdownContent;
      _isLoading = false;
    });
  }

  // -- PDF loading -------------------------------------------------------

  Future<void> _loadPdfContent() async {
    final String? localPath = widget.file.localPath;
    if (localPath == null) {
      if (mounted) {
        setState(() {
          _pdfError = true;
          _isLoading = false;
        });
      }
      return;
    }
    try {
      final localFile = File(localPath);
      if (!await localFile.exists()) {
        if (mounted) {
          setState(() {
            _pdfError = true;
            _isLoading = false;
          });
        }
        return;
      }
      final bytes = await localFile.readAsBytes();
      final doc = await PdfDocument.openData(bytes);
      if (!mounted) return;
      setState(() {
        _pdfController = PdfController(document: Future.value(doc));
        _isLoading = false;
      });
    } catch (e) {
      if (kDebugMode) {
        debugPrint('PDF load error: $e');
      }
      if (mounted) {
        setState(() {
          _pdfError = true;
          _isLoading = false;
        });
      }
    }
  }

  // -- Editing helpers ---------------------------------------------------

  void _startEditing() {
    setState(() {
      _editController.text = _content ?? '';
      _isEditing = true;
    });
  }

  Future<void> _saveEdits() async {
    final newContent = _editController.text;

    // Write to local file if available
    final localPath = widget.file.localPath;
    if (localPath != null) {
      try {
        await File(localPath).writeAsString(newContent);
      } catch (_) {
        // Ignore write errors
      }
    }

    // Notify parent to update the AttachedFile
    widget.onContentChanged?.call(widget.file.id, newContent);

    if (!mounted) return;
    setState(() {
      _content = newContent;
      _isEditing = false;
    });
  }

  void _cancelEditing() {
    setState(() => _isEditing = false);
  }

  // -- Build -------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Color bg = theme.scaffoldBackgroundColor;
    final Color accent = theme.colorScheme.primary;
    final Color textColor =
        theme.iconTheme.color ?? theme.colorScheme.onSurface;
    final String extLabel = _extensionLabel(widget.file.fileName);

    return Dialog(
      backgroundColor: bg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: textColor.withValues(alpha: 0.3), width: 2),
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620, maxHeight: 680),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
              child: Row(
                children: [
                  // Extension badge
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: accent.withValues(alpha: 0.3)),
                    ),
                    child: Text(
                      extLabel.isNotEmpty ? extLabel : 'FILE',
                      style: TextStyle(
                        color: accent,
                        fontWeight: FontWeight.w800,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // Filename + size
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          widget.file.fileName,
                          style: TextStyle(
                            color: textColor,
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (widget.file.fileSizeBytes != null)
                          Text(
                            _formatBytes(widget.file.fileSizeBytes!),
                            style: TextStyle(
                              color: textColor.withValues(alpha: 0.5),
                              fontSize: 11,
                            ),
                          ),
                      ],
                    ),
                  ),
                  // Edit / Save / Cancel buttons (plain text only)
                  if (_isPlainText && !_isLoading) ...[
                    if (_isEditing) ...[
                      IconButton(
                        icon: Icon(Icons.check_rounded, color: accent),
                        tooltip: AppLocalizations.of(context)!.save,
                        onPressed: _saveEdits,
                      ),
                      IconButton(
                        icon: Icon(
                          Icons.close_rounded,
                          color: textColor.withValues(alpha: 0.5),
                        ),
                        tooltip: AppLocalizations.of(context)!.cancel,
                        onPressed: _cancelEditing,
                      ),
                    ] else
                      IconButton(
                        icon: Icon(
                          Icons.edit_rounded,
                          color: textColor.withValues(alpha: 0.7),
                        ),
                        tooltip: AppLocalizations.of(context)!.edit,
                        onPressed: _startEditing,
                      ),
                  ],
                  // Close button
                  IconButton(
                    icon: Icon(
                      Icons.close,
                      color: textColor.withValues(alpha: 0.7),
                    ),
                    tooltip: AppLocalizations.of(context)!.close,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: textColor.withValues(alpha: 0.15)),
            // Content area
            Expanded(child: _buildContent(textColor, accent)),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(Color textColor, Color accent) {
    if (_isLoading) {
      return Center(
        child: CircularProgressIndicator(
          valueColor: AlwaysStoppedAnimation(accent),
        ),
      );
    }

    // PDF viewer
    if (_isPdf) {
      return _buildPdfViewer(textColor, accent);
    }

    // Plain text viewer / editor
    if (_isPlainText) {
      if (_content == null || _content!.isEmpty) {
        return _buildEmptyState(textColor, accent, 'File is empty.');
      }
      return _isEditing
          ? _buildEditor(textColor, accent)
          : _buildTextViewer(textColor);
    }

    // Everything else — no preview
    return _buildEmptyState(
      textColor,
      accent,
      'Preview not available for this file type.',
    );
  }

  // -- PDF viewer --------------------------------------------------------

  Widget _buildPdfViewer(Color textColor, Color accent) {
    if (_pdfError || _pdfController == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.picture_as_pdf,
              size: 48,
              color: accent.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 12),
            Text(
              'PDF preview not available on this platform.',
              style: TextStyle(
                color: textColor.withValues(alpha: 0.5),
                fontSize: 13,
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        // Page indicator
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 4),
          child: PdfPageNumber(
            controller: _pdfController!,
            builder: (_, loadingState, page, pagesCount) => Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(
                color: textColor.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                loadingState == PdfLoadingState.loading
                    ? 'Loading...'
                    : 'Page $page of $pagesCount',
                style: TextStyle(
                  color: textColor.withValues(alpha: 0.7),
                  fontSize: 12,
                ),
              ),
            ),
          ),
        ),
        // PDF pages
        Expanded(
          child: Container(
            margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            decoration: BoxDecoration(
              color: textColor.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: textColor.withValues(alpha: 0.12)),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: PdfView(
                controller: _pdfController!,
                builders: PdfViewBuilders<DefaultBuilderOptions>(
                  options: const DefaultBuilderOptions(),
                  documentLoaderBuilder: (_) => Center(
                    child: CircularProgressIndicator(
                      valueColor: AlwaysStoppedAnimation(accent),
                    ),
                  ),
                  pageLoaderBuilder: (_) => Center(
                    child: CircularProgressIndicator(
                      valueColor: AlwaysStoppedAnimation(accent),
                    ),
                  ),
                  errorBuilder: (_, error) => Center(
                    child: Text(
                      'Error: $error',
                      style: const TextStyle(color: Colors.red),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // -- Text viewer / editor ----------------------------------------------

  Widget _buildTextViewer(Color textColor) {
    return Scrollbar(
      controller: _scrollController,
      thumbVisibility: true,
      child: SingleChildScrollView(
        controller: _scrollController,
        padding: const EdgeInsets.all(20),
        child: SelectableText(
          _content!,
          style: TextStyle(
            color: textColor.withValues(alpha: 0.9),
            fontFamily: 'monospace',
            fontSize: 13,
            height: 1.5,
          ),
        ),
      ),
    );
  }

  Widget _buildEditor(Color textColor, Color accent) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: TextField(
        controller: _editController,
        maxLines: null,
        expands: true,
        textAlignVertical: TextAlignVertical.top,
        style: TextStyle(
          color: textColor.withValues(alpha: 0.9),
          fontFamily: 'monospace',
          fontSize: 13,
          height: 1.5,
        ),
        decoration: InputDecoration(
          filled: true,
          fillColor: textColor.withValues(alpha: 0.04),
          contentPadding: const EdgeInsets.all(16),
        ),
        cursorColor: accent,
      ),
    );
  }

  // -- Empty / no-preview state ------------------------------------------

  Widget _buildEmptyState(Color textColor, Color accent, String message) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.insert_drive_file_outlined,
            size: 48,
            color: accent.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 12),
          Text(
            message,
            style: TextStyle(
              color: textColor.withValues(alpha: 0.5),
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

Future<String?> _loadPlainTextContent(AttachedFile file) async {
  final String? localPath = file.localPath;
  if (localPath != null) {
    final File localFile = File(localPath);
    if (await localFile.exists()) {
      try {
        return await localFile.readAsString();
      } catch (_) {
        try {
          final bytes = await localFile.readAsBytes();
          return utf8.decode(bytes, allowMalformed: true);
        } catch (_) {
          // Fall through to other strategies.
        }
      }
    }
  }
  final String? markdown = file.markdownContent;
  if (markdown != null && markdown.isNotEmpty) {
    return markdown;
  }
  return null;
}

// Use FileConstants for consistent file type detection across the app
bool _isImageFile(String fileName) {
  final String ext = _extractExtension(fileName);
  return FileConstants.isImage(ext);
}

bool _isPdfFile(String fileName) {
  return _extractExtension(fileName) == 'pdf';
}

bool _isPlainTextFile(String fileName) {
  final String ext = _extractExtension(fileName);
  return FileConstants.isPlainText(ext);
}

String _extensionLabel(String fileName) {
  final String ext = _extractExtension(fileName);
  if (ext.isEmpty) return '';
  return ext.length <= _kMaxExtensionChars
      ? ext.toUpperCase()
      : ext.substring(0, _kMaxExtensionChars).toUpperCase();
}

String _extractExtension(String fileName) {
  final int dotIndex = fileName.lastIndexOf('.');
  if (dotIndex == -1 || dotIndex == fileName.length - 1) return '';
  return fileName.substring(dotIndex + 1).toLowerCase();
}

String _formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
  double size = bytes.toDouble();
  int suffixIndex = 0;
  while (size >= 1024 && suffixIndex < suffixes.length - 1) {
    size /= 1024;
    suffixIndex++;
  }
  final bool displayDecimal = size < 10 && suffixIndex > 0;
  final String formatted = displayDecimal
      ? size.toStringAsFixed(1)
      : size.toStringAsFixed(0);
  return '$formatted ${suffixes[suffixIndex]}';
}
