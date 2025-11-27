// lib/widgets/attachment_preview_bar.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'package:chuk_chat/models/chat_model.dart';
import 'package:chuk_chat/widgets/encrypted_image_widget.dart';

typedef AttachmentRemoveCallback = void Function(String fileId);
typedef AttachmentCopyCallback = Future<void> Function(AttachedFile file);

const int _kMaxPlainTextCharacters = 20000;
const double _kChipThumbnailSize = 30.0;
const int _kMaxExtensionChars = 3;

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
    final Color containerColor = theme.colorScheme.surfaceContainerHighest
        .withValues(alpha: 0.25);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: containerColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.35)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: files
              .map(
                (file) => _AttachmentTile(
                  file: file,
                  onRemove: onRemove,
                  onCopy: onCopy,
                  textColor: baseTextColor,
                  accentColor: theme.colorScheme.primary,
                  cardColor: theme.colorScheme.surface.withValues(alpha: 0.9),
                ),
              )
              .toList(),
        ),
      ),
    );
  }
}

class _AttachmentTile extends StatelessWidget {
  const _AttachmentTile({
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
              : () => _showAttachmentPreview(context, file, textColor),
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
                _AttachmentThumbnail(file: file, accentColor: accentColor),
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

class _AttachmentThumbnail extends StatelessWidget {
  const _AttachmentThumbnail({required this.file, required this.accentColor});

  final AttachedFile file;
  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    final BorderRadius radius = BorderRadius.circular(8);
    final bool isImage = _isImageFile(file.fileName);

    // Show encrypted image if available
    if (isImage && file.encryptedImagePath != null) {
      return ClipRRect(
        borderRadius: radius,
        child: EncryptedImageWidget(
          storagePath: file.encryptedImagePath!,
          width: _kChipThumbnailSize,
          height: _kChipThumbnailSize,
          fit: BoxFit.cover,
        ),
      );
    }

    // Show local file thumbnail if available
    final File? localFile = file.localPath != null
        ? File(file.localPath!)
        : null;

    if (isImage && localFile != null && localFile.existsSync()) {
      return ClipRRect(
        borderRadius: radius,
        child: Image.file(
          localFile,
          width: _kChipThumbnailSize,
          height: _kChipThumbnailSize,
          fit: BoxFit.cover,
        ),
      );
    }

    final String label = _extensionLabel(file.fileName);
    return Container(
      width: _kChipThumbnailSize,
      height: _kChipThumbnailSize,
      decoration: BoxDecoration(
        color: accentColor.withValues(alpha: 0.12),
        borderRadius: radius,
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

void _showAttachmentPreview(
  BuildContext context,
  AttachedFile file,
  Color textColor,
) {
  showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.6),
    builder: (context) {
      final theme = Theme.of(context);
      final bool isImage = _isImageFile(file.fileName);
      final bool isPlainText = _isPlainTextFile(file.fileName);
      final File? candidateFile = file.localPath != null
          ? File(file.localPath!)
          : null;
      final File? imageFile =
          isImage && candidateFile != null && candidateFile.existsSync()
          ? candidateFile
          : null;
      final bool hasEncryptedImage = file.encryptedImagePath != null;
      final bool hasMarkdown =
          file.markdownContent != null && file.markdownContent!.isNotEmpty;

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
                  child: hasEncryptedImage
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: InteractiveViewer(
                            minScale: 0.5,
                            maxScale: 4.0,
                            child: EncryptedImageWidget(
                              storagePath: file.encryptedImagePath!,
                              fit: BoxFit.contain,
                            ),
                          ),
                        )
                      : imageFile != null
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: InteractiveViewer(
                            minScale: 0.5,
                            maxScale: 4.0,
                            child: Image.file(imageFile, fit: BoxFit.contain),
                          ),
                        )
                      : isPlainText
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

const Set<String> _imageExtensions = {
  'png',
  'jpg',
  'jpeg',
  'gif',
  'bmp',
  'webp',
  'heic',
  'heif',
};

const Set<String> _plainTextExtensions = {
  'txt',
  'md',
  'markdown',
  'json',
  'jsonl',
  'yaml',
  'yml',
  'csv',
  'tsv',
  'xml',
  'html',
  'htm',
  'css',
  'scss',
  'less',
  'js',
  'mjs',
  'cjs',
  'ts',
  'tsx',
  'jsx',
  'dart',
  'java',
  'kt',
  'kts',
  'swift',
  'c',
  'h',
  'hpp',
  'cc',
  'cpp',
  'cs',
  'rs',
  'go',
  'py',
  'rb',
  'php',
  'sql',
  'sh',
  'zsh',
  'bash',
  'ps1',
  'ini',
  'cfg',
  'conf',
  'env',
  'log',
  'lock',
  'toml',
  'gradle',
  'groovy',
  'pl',
  'lua',
  'scala',
  'r',
  'm',
  'tex',
  'srt',
  'vtt',
};

bool _isImageFile(String fileName) {
  final String ext = _extractExtension(fileName);
  return _imageExtensions.contains(ext);
}

bool _isPlainTextFile(String fileName) {
  final String ext = _extractExtension(fileName);
  return _plainTextExtensions.contains(ext);
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
