// lib/widgets/attachment_preview_bar.dart
import 'dart:async';
import 'dart:convert';
import 'package:chuk_chat/utils/io_helper.dart';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'package:chuk_chat/constants/file_constants.dart';
import 'package:chuk_chat/models/chat_model.dart';
import 'package:chuk_chat/widgets/encrypted_image_widget.dart';
import 'package:chuk_chat/widgets/image_viewer.dart';

typedef AttachmentRemoveCallback = void Function(String fileId);
typedef AttachmentCopyCallback = Future<void> Function(AttachedFile file);

const int _kMaxPlainTextCharacters = 20000;
const int _kMaxExtensionChars = 3;

// Image card dimensions
const double _kImageCardSize = 72.0;
const double _kImageCardBorderWidth = 2.0;

// Document chip thumbnail
const double _kDocThumbnailSize = 30.0;

class AttachmentPreviewBar extends StatelessWidget {
  const AttachmentPreviewBar({
    super.key,
    required this.files,
    required this.onRemove,
    this.onCopy,
  });

  final List<AttachedFile> files;
  final AttachmentRemoveCallback onRemove;
  final AttachmentCopyCallback? onCopy;

  @override
  Widget build(BuildContext context) {
    if (files.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final Color baseTextColor =
        theme.iconTheme.color ?? theme.colorScheme.onSurface;

    return Align(
      alignment: Alignment.centerLeft,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: files.map((file) {
            final bool isImage = _isImageFile(file.fileName);
            if (isImage) {
              return _ImageAttachmentCard(file: file, onRemove: onRemove);
            }
            return _DocumentAttachmentTile(
              file: file,
              onRemove: onRemove,
              onCopy: onCopy,
              textColor: baseTextColor,
              accentColor: theme.colorScheme.primary,
              cardColor: theme.colorScheme.surface.withValues(alpha: 0.9),
            );
          }).toList(),
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
                      tooltip: 'Remove ${file.fileName}',
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
      final localFile = File(file.localPath!);
      if (localFile.existsSync()) {
        return Image.memory(
          localFile.readAsBytesSync(),
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
// Document / non-image attachment tile — clean chip style
// ---------------------------------------------------------------------------

class _DocumentAttachmentTile extends StatelessWidget {
  const _DocumentAttachmentTile({
    required this.file,
    required this.onRemove,
    required this.onCopy,
    required this.textColor,
    required this.accentColor,
    required this.cardColor,
  });

  final AttachedFile file;
  final AttachmentRemoveCallback onRemove;
  final AttachmentCopyCallback? onCopy;
  final Color textColor;
  final Color accentColor;
  final Color cardColor;

  @override
  Widget build(BuildContext context) {
    final BorderRadius cardRadius = BorderRadius.circular(12);
    final bool isUploading = file.isUploading;
    final Color metaTextColor = textColor.withValues(
      alpha: isUploading ? 0.5 : 0.65,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: cardRadius,
          onTap: isUploading
              ? null
              : () => _showDocumentPreview(context, file, textColor),
          child: Container(
            constraints: const BoxConstraints(minHeight: 32, maxWidth: 200),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: cardColor,
              borderRadius: cardRadius,
              border: Border.all(color: textColor.withValues(alpha: 0.1)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _DocumentThumbnail(file: file, accentColor: accentColor),
                const SizedBox(width: 8),
                Flexible(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Tooltip(
                        message: file.fileName,
                        child: Text(
                          file.fileName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: textColor,
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      if (isUploading || file.fileSizeBytes != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (isUploading)
                                SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    valueColor: AlwaysStoppedAnimation(
                                      accentColor,
                                    ),
                                  ),
                                ),
                              if (isUploading && file.fileSizeBytes != null)
                                const SizedBox(width: 6),
                              if (file.fileSizeBytes != null)
                                Text(
                                  _formatBytes(file.fileSizeBytes!),
                                  style: TextStyle(
                                    color: metaTextColor,
                                    fontSize: 10,
                                  ),
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                if (onCopy != null) ...[
                  IconButton(
                    iconSize: 16,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 28,
                      height: 28,
                    ),
                    splashRadius: 18,
                    icon: Icon(
                      Icons.copy,
                      color: textColor.withValues(
                        alpha: isUploading ? 0.25 : 0.7,
                      ),
                    ),
                    tooltip: 'Copy ${file.fileName}',
                    onPressed: isUploading ? null : () => onCopy?.call(file),
                  ),
                  const SizedBox(width: 4),
                ],
                IconButton(
                  iconSize: 16,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 28,
                    height: 28,
                  ),
                  splashRadius: 18,
                  icon: Icon(
                    Icons.close,
                    color: textColor.withValues(
                      alpha: isUploading ? 0.25 : 0.7,
                    ),
                  ),
                  tooltip: 'Remove ${file.fileName}',
                  onPressed: isUploading ? null : () => onRemove(file.id),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Document thumbnail (extension badge)
// ---------------------------------------------------------------------------

class _DocumentThumbnail extends StatelessWidget {
  const _DocumentThumbnail({required this.file, required this.accentColor});

  final AttachedFile file;
  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    final String label = _extensionLabel(file.fileName);
    return Container(
      width: _kDocThumbnailSize,
      height: _kDocThumbnailSize,
      decoration: BoxDecoration(
        color: accentColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      alignment: Alignment.center,
      child: label.isNotEmpty
          ? Text(
              label,
              style: TextStyle(
                color: accentColor,
                fontWeight: FontWeight.w700,
                fontSize: 10,
              ),
            )
          : Icon(Icons.insert_drive_file, color: accentColor, size: 18),
    );
  }
}

// ---------------------------------------------------------------------------
// Document preview dialog (plain text / markdown / unsupported)
// ---------------------------------------------------------------------------

void _showDocumentPreview(
  BuildContext context,
  AttachedFile file,
  Color textColor,
) {
  final bool isPlainText = _isPlainTextFile(file.fileName);
  final bool hasMarkdown =
      file.markdownContent != null && file.markdownContent!.isNotEmpty;

  showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.6),
    builder: (context) {
      final theme = Theme.of(context);

      return Dialog(
        backgroundColor: theme.colorScheme.surface,
        insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 620),
          child: Column(
            mainAxisSize: MainAxisSize.max,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 20,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            file.fileName,
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: textColor,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (file.fileSizeBytes != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                _formatBytes(file.fileSizeBytes!),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: textColor.withValues(alpha: 0.7),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: 'Close preview',
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: isPlainText
                      ? _PlainTextPreview(file: file)
                      : hasMarkdown
                      ? _MarkdownPreview(file: file)
                      : _buildNoPreviewMessage(context),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

// ---------------------------------------------------------------------------
// Text / Markdown preview widgets
// ---------------------------------------------------------------------------

class _PlainTextPreview extends StatelessWidget {
  const _PlainTextPreview({required this.file});

  final AttachedFile file;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<String?>(
      future: _loadPlainTextContent(file),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final String? rawText = snapshot.data;
        if (rawText == null || rawText.isEmpty) {
          return _buildNoPreviewMessage(
            context,
            message: 'Preview not available for this file.',
          );
        }
        final String text = _truncateForPreview(rawText);
        return Scrollbar(
          thumbVisibility: true,
          child: SingleChildScrollView(
            child: SelectableText(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFamily: 'monospace',
                height: 1.4,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _MarkdownPreview extends StatelessWidget {
  const _MarkdownPreview({required this.file});

  final AttachedFile file;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final String? content = file.markdownContent;
    if (content == null || content.trim().isEmpty) {
      return _buildNoPreviewMessage(context);
    }
    final String display = _truncateForPreview(content);
    return Scrollbar(
      thumbVisibility: true,
      child: SingleChildScrollView(
        child: SelectableText(
          display,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontFamily: 'monospace',
            height: 1.4,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

Widget _buildNoPreviewMessage(BuildContext context, {String? message}) {
  final theme = Theme.of(context);
  return Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
    decoration: BoxDecoration(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.insert_drive_file,
          size: 56,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(height: 12),
        Text(
          message ?? 'Preview not available for this file type.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium,
        ),
      ],
    ),
  );
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

String _truncateForPreview(String text) {
  if (text.length <= _kMaxPlainTextCharacters) return text;
  final truncated = text.substring(0, _kMaxPlainTextCharacters);
  return '$truncated\n… preview truncated to $_kMaxPlainTextCharacters characters.';
}

// Use FileConstants for consistent file type detection across the app
bool _isImageFile(String fileName) {
  final String ext = _extractExtension(fileName);
  return FileConstants.isImage(ext);
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
