// lib/widgets/message_bubble.dart
import 'package:flutter/material.dart';
import 'package:chuk_chat/services/image_storage_service.dart';
import 'package:chuk_chat/utils/image_clipboard_service.dart';
import 'package:chuk_chat/widgets/markdown_message.dart';
import 'package:chuk_chat/widgets/image_viewer.dart';
import 'package:chuk_chat/widgets/document_viewer.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/utils/color_extensions.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chuk_chat/constants.dart';
import 'package:flutter/foundation.dart';

/// Document attachment data
class DocumentAttachment {
  const DocumentAttachment({
    required this.fileName,
    required this.markdownContent,
  });

  final String fileName;
  final String markdownContent;

  Map<String, String> toJson() {
    return {'fileName': fileName, 'markdownContent': markdownContent};
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
    this.startsNewGroup = true,
    this.endsGroup = true,
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
    this.imageCostEur,
    this.imageGeneratedAt,
  });

  final String message;
  final bool
  isUser; // true for bot, false for user in voice mode (to match image)
  // In regular chat, true for user, false for AI.
  final bool startsNewGroup;
  final bool endsGroup; // Last message before sender changes (shows tail)
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
  final double? imageCostEur;
  final DateTime? imageGeneratedAt;

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble>
    with AutomaticKeepAliveClientMixin {
  bool _isReasoningExpanded = false;
  final Set<String> _expandedCards = {};
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
    final show = widget.showTps ?? kDefaultShowTps;
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
    final Color bgColor = Theme.of(context).scaffoldBackgroundColor;
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: alignRight
          ? MainAxisAlignment.end
          : MainAxisAlignment.start,
      children: [
        Container(
          decoration: BoxDecoration(
            color: bgColor.lighten(0.05),
            borderRadius: BorderRadius.circular(100),
            border: Border.all(
              color: iconFgColor.withValues(alpha: 0.15),
              width: 1,
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 0),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: widget.actions.map((action) {
              return Tooltip(
                message: action.tooltip,
                child: IconButton(
                  icon: Icon(action.icon, color: iconFgColor, size: 15),
                  padding: const EdgeInsets.all(4),
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(
                    minWidth: 24,
                    minHeight: 24,
                  ),
                  onPressed: action.isEnabled ? action.onPressed : null,
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildEditingControls(Color iconFgColor, bool alignRight) {
    final bool canSubmit = widget.onSubmitEdit != null;
    final Color bgColor = Theme.of(context).scaffoldBackgroundColor;
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: alignRight
          ? MainAxisAlignment.end
          : MainAxisAlignment.start,
      children: [
        Container(
          decoration: BoxDecoration(
            color: bgColor.lighten(0.05),
            borderRadius: BorderRadius.circular(100),
            border: Border.all(
              color: iconFgColor.withValues(alpha: 0.15),
              width: 1,
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 0),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Tooltip(
                message: 'Resend edited message',
                child: IconButton(
                  icon: Icon(Icons.send, color: iconFgColor, size: 15),
                  padding: const EdgeInsets.all(4),
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(
                    minWidth: 24,
                    minHeight: 24,
                  ),
                  onPressed: canSubmit
                      ? () => widget.onSubmitEdit?.call(_editController.text)
                      : null,
                ),
              ),
              Tooltip(
                message: 'Cancel edit',
                child: IconButton(
                  icon: Icon(Icons.close, color: iconFgColor, size: 15),
                  padding: const EdgeInsets.all(4),
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(
                    minWidth: 24,
                    minHeight: 24,
                  ),
                  onPressed: widget.onCancelEdit,
                ),
              ),
            ],
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

    // Use provided maxWidth, otherwise default to 80% of screen width.
    final double effectiveMaxWidth =
        widget.maxWidth ?? MediaQuery.of(context).size.width * 0.8;

    final bool hasActions =
        widget.actions.isNotEmpty && !(widget.isEditing && isUserMessage);

    final EdgeInsetsGeometry containerPadding = isUserMessage
        ? const EdgeInsets.symmetric(horizontal: 14, vertical: 10)
        : const EdgeInsets.symmetric(horizontal: 4, vertical: 2);

    final BoxDecoration? decoration = isUserMessage
        ? BoxDecoration(
            color: accentColor.withValues(alpha: .8),
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(16),
              topRight: const Radius.circular(16),
              bottomLeft: const Radius.circular(16),
              bottomRight: Radius.circular(widget.endsGroup ? 5 : 16),
            ),
            border: Border.all(color: iconFgColor.withValues(alpha: .3)),
          )
        : null;

    _maybeRequestEditFocus();

    final Widget bubbleContent = Container(
      margin: EdgeInsets.only(top: widget.startsNewGroup ? 10 : 2, bottom: 2),
      padding: containerPadding,
      decoration: decoration,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: alignRight
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          if (_hasReasoning || _hasModelInfo)
            _buildInfoStatusBar(iconFgColor, accentColor),
          // Display images above the text message
          if (widget.images != null && widget.images!.isNotEmpty) ...[
            _buildImagesGrid(widget.images!),
            if (widget.imageCostEur != null || widget.imageGeneratedAt != null)
              _buildImageMetaMenu(
                iconFgColor,
                alignRight,
                widget.imageCostEur,
                widget.imageGeneratedAt,
              ),
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
              _buildEditingControls(iconFgColor, alignRight),
            if (hasActions) _buildActionButtons(iconFgColor, alignRight),
          ],
        ),
      ),
    );
  }

  /// Unified status bar for reasoning and model info, matching function_calling
  /// client design: expandable cards with accent-tinted backgrounds.
  Widget _buildInfoStatusBar(Color iconFgColor, Color accentColor) {
    final bool isExpanded = _isReasoningExpanded;
    final bool isStreaming = widget.isReasoningStreaming;

    // Determine header label and state
    final String label = isStreaming ? 'Reasoning...' : 'Reasoning';
    final Color barAccent = accentColor;

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: barAccent.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: barAccent.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header bar
          InkWell(
            onTap: () =>
                setState(() => _isReasoningExpanded = !_isReasoningExpanded),
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                children: [
                  if (isStreaming)
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: barAccent,
                      ),
                    )
                  else
                    Icon(Icons.psychology, size: 14, color: barAccent),
                  const SizedBox(width: 8),
                  Text(
                    label,
                    style: TextStyle(
                      color: barAccent,
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Preview text when collapsed
                  if (!isExpanded && _hasReasoning)
                    Expanded(
                      child: Text(
                        _truncatePreview(widget.reasoning!, 60),
                        style: TextStyle(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.5),
                          fontSize: 12,
                        ),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    )
                  else
                    const Spacer(),
                  Icon(
                    isExpanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                ],
              ),
            ),
          ),
          // Expanded content: sub-cards for reasoning and model info
          if (isExpanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
              child: Column(
                children: [
                  if (_hasReasoning)
                    _buildExpandableCard(
                      key: 'reasoning',
                      icon: Icons.psychology,
                      label: 'Reasoning',
                      preview: widget.reasoning!,
                      expandedContent: widget.reasoning!,
                      accentColor: barAccent,
                      isRunning: isStreaming,
                    ),
                  if (_hasModelInfo)
                    _buildExpandableCard(
                      key: 'model_info',
                      icon: Icons.smart_toy_outlined,
                      label: widget.modelLabel!,
                      preview: _buildModelPreview(),
                      expandedContent: _buildModelDetails(),
                      accentColor: Colors.green,
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// Reusable expandable card matching function_calling client design.
  Widget _buildExpandableCard({
    required String key,
    required IconData icon,
    required String label,
    required String preview,
    required String expandedContent,
    required Color accentColor,
    bool isRunning = false,
  }) {
    final bool cardExpanded = _expandedCards.contains(key);

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: accentColor.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: accentColor.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() {
              if (_expandedCards.contains(key)) {
                _expandedCards.remove(key);
              } else {
                _expandedCards.add(key);
              }
            }),
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                children: [
                  if (isRunning)
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: accentColor,
                      ),
                    )
                  else
                    Icon(icon, size: 14, color: accentColor),
                  const SizedBox(width: 8),
                  Text(
                    label,
                    style: TextStyle(
                      color: accentColor,
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      cardExpanded ? '' : _truncatePreview(preview, 60),
                      style: TextStyle(
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.5),
                        fontSize: 12,
                      ),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ),
                  Icon(
                    cardExpanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                ],
              ),
            ),
          ),
          if (cardExpanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: SelectableText(
                expandedContent,
                style: TextStyle(
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.7),
                  fontSize: 12,
                  fontFamily: 'monospace',
                  height: 1.4,
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _buildModelPreview() {
    if (_shouldShowTps) {
      return '${widget.tps!.toStringAsFixed(1)} tok/s';
    }
    return '';
  }

  String _buildModelDetails() {
    final buf = StringBuffer();
    buf.writeln('Model: ${widget.modelLabel}');
    if (_shouldShowTps) {
      buf.writeln('Speed: ${widget.tps!.toStringAsFixed(1)} tok/s');
    }
    return buf.toString().trimRight();
  }

  String _truncatePreview(String text, int maxLength) {
    final clean = text.replaceAll('\n', ' ').trim();
    if (clean.length <= maxLength) return clean;
    return '${clean.substring(0, maxLength)}...';
  }

  Widget _buildImagesGrid(List<String> images) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final double maxWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.of(context).size.width * 0.8;

        if (images.length == 1) {
          final String imageSource = images.first;
          final double imageWidth = maxWidth;
          final double imageHeight = 280;

          return _CachedImageThumbnail(
            imageDataUrl: imageSource,
            width: imageWidth,
            height: imageHeight,
            borderRadius: 12,
            fit: BoxFit.cover,
            onTap: () => _openImagePreview(
              imageSource: imageSource,
              images: images,
              index: 0,
            ),
          );
        }

        final int columns = maxWidth > 520 ? 3 : 2;
        final double tileWidth = ((maxWidth - ((columns - 1) * 8)) / columns)
            .clamp(120.0, 260.0);

        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: images.asMap().entries.map((entry) {
            final int index = entry.key;
            final String imageSource = entry.value;

            return _CachedImageThumbnail(
              imageDataUrl: imageSource,
              width: tileWidth,
              height: tileWidth,
              borderRadius: 10,
              onTap: () => _openImagePreview(
                imageSource: imageSource,
                images: images,
                index: index,
              ),
            );
          }).toList(),
        );
      },
    );
  }

  void _openImagePreview({
    required String imageSource,
    required List<String> images,
    required int index,
  }) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => ImageViewer(
          imageDataUrl: imageSource,
          initialIndex: index,
          allImages: images,
        ),
        fullscreenDialog: true,
      ),
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
                  Icon(Icons.description, size: 18, color: iconColor),
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
      paragraphFontSize: isUserMessage ? 15 : null,
      paragraphHeight: isUserMessage ? 1.38 : null,
    );

    if (isUserMessage) {
      return messageWidget;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: messageWidget,
    );
  }

  Widget _buildImageMetaMenu(
    Color iconFgColor,
    bool alignRight,
    double? imageCostEur,
    DateTime? imageGeneratedAt,
  ) {
    final String generatedLabel = imageGeneratedAt != null
        ? _formatGeneratedAt(imageGeneratedAt)
        : 'Unknown';
    final String? costLabel = imageCostEur != null
        ? 'EUR ${imageCostEur.toStringAsFixed(2)}'
        : null;

    return Padding(
      padding: alignRight
          ? const EdgeInsets.only(top: 1, right: 6)
          : const EdgeInsets.only(top: 1, left: 6),
      child: Row(
        mainAxisAlignment: alignRight
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        children: [
          Tooltip(
            message: 'Copy image',
            child: IconButton(
              icon: Icon(Icons.copy, color: iconFgColor.withValues(alpha: 0.8)),
              iconSize: 15,
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
              onPressed: _copyFirstImageToClipboard,
            ),
          ),
          const SizedBox(width: 1),
          PopupMenuButton<String>(
            tooltip: 'Image details',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
            iconSize: 15,
            icon: Icon(
              Icons.more_vert,
              color: iconFgColor.withValues(alpha: 0.8),
            ),
            itemBuilder: (context) => [
              if (costLabel != null)
                PopupMenuItem<String>(
                  enabled: false,
                  value: 'cost',
                  child: Text('Cost: $costLabel'),
                ),
              PopupMenuItem<String>(
                enabled: false,
                value: 'time',
                child: Text('Generated: $generatedLabel'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _copyFirstImageToClipboard() async {
    final images = widget.images;
    if (images == null || images.isEmpty) {
      return;
    }

    try {
      final bytes = await ImageStorageService.downloadAndDecryptImage(
        images.first,
      );
      final copied = await ImageClipboardService.copyImageBytes(bytes);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(copied ? 'Image copied' : 'Unable to copy image'),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Unable to copy image')));
    }
  }

  String _formatGeneratedAt(DateTime timestamp) {
    final local = timestamp.toLocal();
    final day = local.day.toString().padLeft(2, '0');
    final month = local.month.toString().padLeft(2, '0');
    final year = local.year.toString();
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '$day.$month.$year $hour:$minute';
  }
}

/// Cached image thumbnail that decodes once and caches the bytes
class _CachedImageThumbnail extends StatefulWidget {
  const _CachedImageThumbnail({
    required this.imageDataUrl,
    required this.width,
    required this.height,
    required this.onTap,
    this.borderRadius = 8,
    this.fit = BoxFit.cover,
  });

  /// Can be either:
  /// - A Base64 data URL: "data:image/jpeg;base64,..."
  /// - A storage path: "user-id/uuid.enc"
  final String imageDataUrl;
  final double width;
  final double height;
  final double borderRadius;
  final BoxFit fit;
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
        if (kDebugMode) {
          debugPrint('⏭️ Skipping legacy Base64 image');
        }
      } else {
        // Storage path - download and decrypt
        _cachedBytes = await ImageStorageService.downloadAndDecryptImage(
          widget.imageDataUrl,
        );
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Failed to load image: $e');
      }
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
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          color: Colors.grey.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(widget.borderRadius),
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
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          color: Colors.grey.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(widget.borderRadius),
        ),
        child: const Icon(Icons.broken_image, size: 32),
      );
    }

    return InkWell(
      onTap: widget.onTap,
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(widget.borderRadius),
          child: Image.memory(
            _cachedBytes!,
            width: widget.width,
            height: widget.height,
            fit: widget.fit,
            // Only constrain cacheWidth to preserve aspect ratio during decode.
            // Setting both cacheWidth AND cacheHeight distorts the image before
            // BoxFit.cover can crop it properly.
            cacheWidth: (widget.width * 2).toInt(),
            gaplessPlayback: true,
            errorBuilder: (context, error, stackTrace) {
              return Container(
                width: widget.width,
                height: widget.height,
                decoration: BoxDecoration(
                  color: Colors.grey.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(widget.borderRadius),
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
