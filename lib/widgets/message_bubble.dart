// lib/widgets/message_bubble.dart
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:chuk_chat/services/image_storage_service.dart';
import 'package:chuk_chat/widgets/markdown_message.dart';
import 'package:chuk_chat/widgets/image_viewer.dart';
import 'package:chuk_chat/widgets/document_viewer.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chuk_chat/constants.dart';

/// Document attachment data
class DocumentAttachment {
  const DocumentAttachment({
    required this.fileName,
    required this.markdownContent,
  });

  final String fileName;
  final String markdownContent;

  Map<String, String> toJson() {
    return {
      'fileName': fileName,
      'markdownContent': markdownContent,
    };
  }

  factory DocumentAttachment.fromJson(Map<String, dynamic> json) {
    return DocumentAttachment(
      fileName: json['fileName'] as String? ?? 'document',
      markdownContent: json['markdownContent'] as String? ?? '',
    );
  }
}

class MessageBubbleAction {
  const MessageBubbleAction({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.isEnabled = true,
    this.label,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final bool isEnabled;
  final String? label;
}

class MessageBubble extends StatefulWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.isUser,
    this.maxWidth,
    this.actions = const <MessageBubbleAction>[],
    this.reasoning,
    this.isReasoningStreaming = false,
    this.modelLabel,
    this.tps,
    this.isEditing = false,
    this.initialEditText,
    this.onSubmitEdit,
    this.onCancelEdit,
    this.showReasoningTokens,
    this.showModelInfo,
    this.showTps,
    this.images,
    this.attachments,
  });

  final String message;
  final bool
  isUser; // true for bot, false for user in voice mode (to match image)
  // In regular chat, true for user, false for AI.
  final double? maxWidth; // Neue optionale Eigenschaft für responsive Breite
  final List<MessageBubbleAction> actions;
  final String? reasoning;
  final bool isReasoningStreaming;
  final String? modelLabel;
  final double? tps; // Tokens per second metric
  final bool isEditing;
  final String? initialEditText;
  final ValueChanged<String>? onSubmitEdit;
  final VoidCallback? onCancelEdit;
  final bool? showReasoningTokens;
  final bool? showModelInfo;
  final bool? showTps;
  final List<String>? images; // Base64 data URLs of images
  final List<DocumentAttachment>? attachments; // Document attachments

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble>
    with AutomaticKeepAliveClientMixin {
  bool _isReasoningExpanded = false;
  bool _isModelInfoExpanded = false;
  final TextEditingController _editController = TextEditingController();
  final FocusNode _editFocusNode = FocusNode();
  bool _shouldFocusEditField = false;

  @override
  bool get wantKeepAlive => true; // Keep this widget alive to prevent rebuilds

  // User preferences for display - null until loaded
  bool? _showReasoningTokens;
  bool? _showModelInfo;
  static bool? _cachedShowReasoningTokens;
  static bool? _cachedShowModelInfo;

  bool get _hasReasoning {
    // Prioritize widget prop, then loaded preference, then cached, then default
    final show =
        widget.showReasoningTokens ??
        _showReasoningTokens ??
        _cachedShowReasoningTokens ??
        kDefaultShowReasoningTokens;
    return show &&
        widget.reasoning != null &&
        widget.reasoning!.trim().isNotEmpty;
  }

  bool get _hasModelInfo {
    // Prioritize widget prop, then loaded preference, then cached, then default
    final show =
        widget.showModelInfo ??
        _showModelInfo ??
        _cachedShowModelInfo ??
        kDefaultShowModelInfo;
    return show && widget.modelLabel != null && widget.modelLabel!.isNotEmpty;
  }

  bool get _shouldShowTps {
    final show =
        widget.showTps ?? kDefaultShowTps;
    return show && widget.tps != null && widget.tps! > 0;
  }

  @override
  void initState() {
    super.initState();
    _loadPreferences();
    if (widget.isEditing) {
      _configureEditController();
    }
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      final showReasoning =
          prefs.getBool('showReasoningTokens') ?? kDefaultShowReasoningTokens;
      final showModel = prefs.getBool('showModelInfo') ?? kDefaultShowModelInfo;

      setState(() {
        _showReasoningTokens = showReasoning;
        _showModelInfo = showModel;
      });

      // Cache for future instances
      _cachedShowReasoningTokens = showReasoning;
      _cachedShowModelInfo = showModel;
    }
  }

  @override
  void didUpdateWidget(covariant MessageBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isEditing && !oldWidget.isEditing) {
      _configureEditController();
    } else if (!widget.isEditing && oldWidget.isEditing) {
      _editController.clear();
      _shouldFocusEditField = false;
    } else if (widget.isEditing &&
        oldWidget.isEditing &&
        widget.initialEditText != oldWidget.initialEditText) {
      _configureEditController();
    }
  }

  @override
  void dispose() {
    _editController.dispose();
    _editFocusNode.dispose();
    super.dispose();
  }

  void _configureEditController() {
    final String sourceText = widget.initialEditText ?? widget.message;
    _editController
      ..text = sourceText
      ..selection = TextSelection.fromPosition(
        TextPosition(offset: sourceText.length),
      );
    _shouldFocusEditField = true;
  }

  void _maybeRequestEditFocus() {
    if (!_shouldFocusEditField) return;
    _shouldFocusEditField = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_editFocusNode.canRequestFocus) {
        _editFocusNode.requestFocus();
      }
    });
  }

  Widget _buildActionButtons(Color iconFgColor, bool alignRight) {
    return Wrap(
      alignment: alignRight ? WrapAlignment.end : WrapAlignment.start,
      spacing: 4,
      runSpacing: 4,
      children: widget.actions.map((action) {
        return Tooltip(
          message: action.tooltip,
          child: IconButton(
            icon: Icon(action.icon, color: iconFgColor),
            padding: const EdgeInsets.all(8),
            constraints: const BoxConstraints(minWidth: 38, minHeight: 38),
            onPressed: action.isEnabled ? action.onPressed : null,
          ),
        );
      }).toList(),
    );
  }

  Widget _buildEditingControls(Color iconFgColor, bool alignRight) {
    final bool canSubmit = widget.onSubmitEdit != null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: alignRight
          ? MainAxisAlignment.end
          : MainAxisAlignment.start,
      children: [
        Tooltip(
          message: 'Resend edited message',
          child: IconButton(
            icon: Icon(Icons.send, color: iconFgColor),
            padding: const EdgeInsets.all(8),
            constraints: const BoxConstraints(minWidth: 38, minHeight: 38),
            onPressed: canSubmit
                ? () => widget.onSubmitEdit?.call(_editController.text)
                : null,
          ),
        ),
        const SizedBox(width: 4),
        Tooltip(
          message: 'Cancel edit',
          child: IconButton(
            icon: Icon(Icons.close, color: iconFgColor),
            padding: const EdgeInsets.all(8),
            constraints: const BoxConstraints(minWidth: 38, minHeight: 38),
            onPressed: widget.onCancelEdit,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required for AutomaticKeepAliveClientMixin

    // Determine alignment based on whether it's a user message or not.
    // Historically voice mode inverted this flag, so we keep compatibility.
    final bool isUserMessage =
        widget.isUser; // In regular chat, true for user, false for AI.
    final bool alignRight =
        isUserMessage; // User messages go right, assistant responses go left.

    // Get colors from theme
    final Color accentColor = Theme.of(context).colorScheme.primary;
    final Color bgColor = Theme.of(context).scaffoldBackgroundColor;
    final Color iconFgColor = Theme.of(context).resolvedIconColor;

    // Nutze die übergebene maxWidth, falls vorhanden, ansonsten den Standardwert von 70% der Bildschirmbreite
    final double effectiveMaxWidth =
        widget.maxWidth ?? MediaQuery.of(context).size.width * 0.7;

    final bool hasActions =
        widget.actions.isNotEmpty && !(widget.isEditing && isUserMessage);

    final EdgeInsetsGeometry containerPadding = isUserMessage
        ? const EdgeInsets.all(12)
        : const EdgeInsets.symmetric(horizontal: 4, vertical: 2);

    final BoxDecoration? decoration = isUserMessage
        ? BoxDecoration(
            color: accentColor.withValues(alpha: .8),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: iconFgColor.withValues(alpha: .3)),
          )
        : null;

    _maybeRequestEditFocus();

    final Widget bubbleContent = Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: containerPadding,
      decoration: decoration,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: alignRight
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          if (_hasReasoning) ...[
            _buildReasoningToggle(iconFgColor, alignRight),
            const SizedBox(height: 4),
            if (_isReasoningExpanded)
              _buildReasoningBox(iconFgColor, alignRight),
          ],
          if (_hasModelInfo) ...[
            _buildModelInfoToggle(iconFgColor, alignRight),
            const SizedBox(height: 4),
            if (_isModelInfoExpanded)
              _buildModelInfoBox(iconFgColor, alignRight),
          ],
          // Display images above the text message
          if (widget.images != null && widget.images!.isNotEmpty) ...[
            _buildImagesGrid(widget.images!),
            const SizedBox(height: 8),
          ],
          // Display document attachments
          if (widget.attachments != null && widget.attachments!.isNotEmpty) ...[
            _buildAttachmentsChips(widget.attachments!),
            const SizedBox(height: 8),
          ],
          _buildMessageBody(
            iconFgColor: iconFgColor,
            accentColor: accentColor,
            bgColor: bgColor,
            isUserMessage: isUserMessage,
          ),
        ],
      ),
    );

    return Align(
      alignment: alignRight ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: effectiveMaxWidth),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: alignRight
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            bubbleContent,
            if (widget.isEditing && isUserMessage)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: _buildEditingControls(iconFgColor, alignRight),
              ),
            if (hasActions)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: _buildActionButtons(iconFgColor, alignRight),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildReasoningToggle(Color iconFgColor, bool alignRight) {
    final bool expanded = _isReasoningExpanded;
    final IconData icon = expanded ? Icons.expand_less : Icons.expand_more;
    final String label = expanded ? 'Hide reasoning' : 'Show reasoning';

    return InkWell(
      onTap: () {
        setState(() => _isReasoningExpanded = !expanded);
      },
      child: Row(
        mainAxisAlignment: alignRight
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: iconFgColor.withValues(alpha: 0.6)),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: iconFgColor.withValues(alpha: 0.7),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (widget.isReasoningStreaming) ...[
            const SizedBox(width: 6),
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(
                  iconFgColor.withValues(alpha: 0.6),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildReasoningBox(Color iconFgColor, bool alignRight) {
    final Color containerColor = iconFgColor.withValues(alpha: 0.08);
    return Container(
      key: const ValueKey('reasoning-expanded'),
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: containerColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: iconFgColor.withValues(alpha: 0.18)),
      ),
      child: Text(
        widget.reasoning!,
        style: TextStyle(
          color: iconFgColor.withValues(alpha: 0.85),
          height: 1.35,
        ),
        textAlign: alignRight ? TextAlign.right : TextAlign.left,
      ),
    );
  }

  Widget _buildModelInfoToggle(Color iconFgColor, bool alignRight) {
    final bool expanded = _isModelInfoExpanded;
    final IconData icon = expanded ? Icons.expand_less : Icons.expand_more;
    final String label = expanded ? 'Hide model' : 'Show model';

    return InkWell(
      onTap: () {
        setState(() => _isModelInfoExpanded = !expanded);
      },
      child: Row(
        mainAxisAlignment: alignRight
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: iconFgColor.withValues(alpha: 0.6)),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: iconFgColor.withValues(alpha: 0.7),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModelInfoBox(Color iconFgColor, bool alignRight) {
    final Color containerColor = iconFgColor.withValues(alpha: 0.08);
    return Container(
      key: const ValueKey('model-info-expanded'),
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: containerColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: iconFgColor.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: alignRight
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: alignRight
                ? MainAxisAlignment.end
                : MainAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.smart_toy_outlined,
                size: 16,
                color: iconFgColor.withValues(alpha: 0.7),
              ),
              const SizedBox(width: 6),
              Text(
                'Model',
                style: TextStyle(
                  color: iconFgColor.withValues(alpha: 0.9),
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.modelLabel!,
                style: TextStyle(
                  color: iconFgColor.withValues(alpha: 0.85),
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: alignRight ? TextAlign.right : TextAlign.left,
              ),
              if (_shouldShowTps) ...[
                const SizedBox(width: 8),
                Builder(
                  builder: (context) {
                    final accent = Theme.of(context).colorScheme.primary;
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '${widget.tps!.toStringAsFixed(1)} tok/s',
                        style: TextStyle(
                          color: accent,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    );
                  },
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildImagesGrid(List<String> images) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: images.asMap().entries.map((entry) {
        final int index = entry.key;
        final String imageDataUrl = entry.value;

        return _CachedImageThumbnail(
          imageDataUrl: imageDataUrl,
          onTap: () {
            // Open image viewer with all images
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (context) => ImageViewer(
                  imageDataUrl: imageDataUrl,
                  initialIndex: index,
                  allImages: images,
                ),
                fullscreenDialog: true,
              ),
            );
          },
        );
      }).toList(),
    );
  }

  Widget _buildAttachmentsChips(List<DocumentAttachment> attachments) {
    final iconColor = Theme.of(context).colorScheme.onSurface;
    final accentColor = Theme.of(context).colorScheme.primary;

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: attachments.map((attachment) {
        return InkWell(
          onTap: () {
            // Open document viewer
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (context) => DocumentViewer(
                  fileName: attachment.fileName,
                  markdownContent: attachment.markdownContent,
                ),
                fullscreenDialog: true,
              ),
            );
          },
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: accentColor.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: accentColor.withValues(alpha: 0.5),
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.description,
                    size: 18,
                    color: iconColor,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      attachment.fileName,
                      style: TextStyle(
                        color: iconColor,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    Icons.open_in_new,
                    size: 14,
                    color: iconColor.withValues(alpha: 0.7),
                  ),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildMessageBody({
    required Color iconFgColor,
    required Color accentColor,
    required Color bgColor,
    required bool isUserMessage,
  }) {
    if (widget.isEditing && isUserMessage) {
      return Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: accentColor.withValues(
            alpha: 0.9,
          ), // Full accent color background
          borderRadius: BorderRadius.circular(8),
        ),
        child: TextField(
          controller: _editController,
          focusNode: _editFocusNode,
          minLines: 1,
          maxLines: null,
          keyboardType: TextInputType.multiline,
          style: TextStyle(color: iconFgColor, fontSize: 14, height: 1.35),
          cursorColor: iconFgColor,
          decoration: InputDecoration(
            isDense: true,
            isCollapsed: true,
            filled: true,
            fillColor: accentColor.withValues(alpha: 0.9), // Accent color fill
            border: InputBorder.none,
            focusedBorder: InputBorder.none,
            enabledBorder: InputBorder.none,
            hintText: 'Edit your message',
            hintStyle: TextStyle(color: iconFgColor.withValues(alpha: 0.6)),
          ),
        ),
      );
    }

    final Widget messageWidget = MarkdownMessage(
      text: widget.message,
      textColor: iconFgColor,
      backgroundColor: isUserMessage
          ? accentColor.withValues(alpha: .8)
          : bgColor,
    );

    if (isUserMessage) {
      return messageWidget;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: messageWidget,
    );
  }
}

/// Cached image thumbnail that decodes once and caches the bytes
class _CachedImageThumbnail extends StatefulWidget {
  const _CachedImageThumbnail({
    required this.imageDataUrl,
    required this.onTap,
  });

  /// Can be either:
  /// - A Base64 data URL: "data:image/jpeg;base64,..."
  /// - A storage path: "user-id/uuid.enc"
  final String imageDataUrl;
  final VoidCallback onTap;

  @override
  State<_CachedImageThumbnail> createState() => _CachedImageThumbnailState();
}

class _CachedImageThumbnailState extends State<_CachedImageThumbnail>
    with AutomaticKeepAliveClientMixin {
  Uint8List? _cachedBytes;
  bool _isLoading = true;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  Future<void> _loadImage() async {
    try {
      if (widget.imageDataUrl.startsWith('data:image/')) {
        // Legacy Base64 format - no longer supported, skip loading
        debugPrint('⏭️ Skipping legacy Base64 image');
      } else {
        // Storage path - download and decrypt
        _cachedBytes = await ImageStorageService.downloadAndDecryptImage(
          widget.imageDataUrl,
        );
      }
    } catch (e) {
      debugPrint('Failed to load image: $e');
    }
    if (mounted) {
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required for AutomaticKeepAliveClientMixin

    if (_isLoading) {
      return Container(
        width: 100,
        height: 100,
        decoration: BoxDecoration(
          color: Colors.grey.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    if (_cachedBytes == null) {
      return Container(
        width: 100,
        height: 100,
        decoration: BoxDecoration(
          color: Colors.grey.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Icon(Icons.broken_image, size: 32),
      );
    }

    return GestureDetector(
      onTap: widget.onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.memory(
            _cachedBytes!,
            width: 100,
            height: 100,
            fit: BoxFit.cover,
            cacheWidth: 200,
            cacheHeight: 200,
            gaplessPlayback: true,
            errorBuilder: (context, error, stackTrace) {
              return Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                  color: Colors.grey.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.broken_image, size: 32),
              );
            },
          ),
        ),
      ),
    );
  }
}
