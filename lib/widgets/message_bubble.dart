// lib/widgets/message_bubble.dart
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/services/image_storage_service.dart';
import 'package:chuk_chat/utils/image_clipboard_service.dart';
import 'package:chuk_chat/widgets/chart_widget.dart';
import 'package:chuk_chat/widgets/map_block_renderer.dart';
import 'package:chuk_chat/widgets/markdown_message.dart';
import 'package:chuk_chat/widgets/image_viewer.dart';
import 'package:chuk_chat/widgets/document_viewer.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/utils/color_extensions.dart';
import 'package:chuk_chat/utils/tool_parser.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/platform_config.dart';
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
    this.modelProvider,
    this.tps,
    this.isEditing = false,
    this.initialEditText,
    this.onSubmitEdit,
    this.onCancelEdit,
    this.showReasoningTokens,
    this.showModelInfo,
    this.showTps,
    this.toolCalls,
    this.showToolCalls = true,
    this.contentBlocks,
    this.isStreamingMessage = false,
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
  final String? modelProvider;
  final double? tps; // Tokens per second metric
  final bool isEditing;
  final String? initialEditText;
  final ValueChanged<String>? onSubmitEdit;
  final VoidCallback? onCancelEdit;
  final bool? showReasoningTokens;
  final bool? showModelInfo;
  final bool? showTps;
  final List<ToolCall>? toolCalls;
  final bool showToolCalls;

  /// Ordered content blocks for interleaved AI responses.
  /// When present and non-empty, the bubble renders these in sequence
  /// instead of the flat text + single-tool-calls-bar layout.
  final List<ContentBlock>? contentBlocks;

  /// Whether this message is currently being streamed. Used with
  /// [contentBlocks] to show trailing text from the active streaming pass.
  final bool isStreamingMessage;

  final List<String>? images; // Base64 data URLs of images
  final List<DocumentAttachment>? attachments; // Document attachments
  final double? imageCostEur;
  final DateTime? imageGeneratedAt;

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble>
    with AutomaticKeepAliveClientMixin {
  /// Regex to find `<chart>` and `<map>` blocks in message content.
  static final RegExp _richBlockRegex = RegExp(
    r'<\s*(chart|map)\s*>([\s\S]*?)<\s*/\s*\1\s*>',
    multiLine: true,
    caseSensitive: false,
  );

  static final RegExp _visualBlockStartRegex = RegExp(
    r'<\s*(chart|map)\b',
    caseSensitive: false,
  );

  bool _isReasoningExpanded = false;
  final Map<String, bool> _blockExpanded = {};
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

  bool get _isQrImageMessage {
    bool hasQrTool(Iterable<ToolCall> calls) {
      return calls.any(
        (call) => call.name.trim().toLowerCase() == 'generate_qr',
      );
    }

    final topLevelCalls = widget.toolCalls;
    if (topLevelCalls != null && hasQrTool(topLevelCalls)) {
      return true;
    }

    final blocks = widget.contentBlocks;
    if (blocks != null) {
      for (final block in blocks) {
        final calls = block.toolCalls;
        if (calls != null && hasQrTool(calls)) {
          return true;
        }
      }
    }

    return false;
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
          padding: EdgeInsets.symmetric(
            horizontal: kPlatformMobile ? 2 : 8,
            vertical: kPlatformMobile ? 0 : 4,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: widget.actions.map((action) {
              return Tooltip(
                message: action.tooltip,
                child: IconButton(
                  icon: Icon(
                    action.icon,
                    color: iconFgColor,
                    size: kPlatformMobile ? 15 : 18,
                  ),
                  padding: EdgeInsets.all(kPlatformMobile ? 4 : 8),
                  visualDensity: VisualDensity.compact,
                  constraints: BoxConstraints(
                    minWidth: kPlatformMobile ? 24 : 30,
                    minHeight: kPlatformMobile ? 24 : 30,
                  ),
                  // Desktop has oversized tap targets by default — shrink them.
                  // Mobile was already correct, so leave it untouched.
                  style: kPlatformMobile
                      ? null
                      : IconButton.styleFrom(
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
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
          padding: EdgeInsets.symmetric(
            horizontal: kPlatformMobile ? 2 : 8,
            vertical: kPlatformMobile ? 0 : 4,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Tooltip(
                message: 'Resend edited message',
                child: IconButton(
                  icon: Icon(
                    Icons.send,
                    color: iconFgColor,
                    size: kPlatformMobile ? 15 : 18,
                  ),
                  padding: EdgeInsets.all(kPlatformMobile ? 4 : 8),
                  visualDensity: VisualDensity.compact,
                  constraints: BoxConstraints(
                    minWidth: kPlatformMobile ? 24 : 30,
                    minHeight: kPlatformMobile ? 24 : 30,
                  ),
                  style: kPlatformMobile
                      ? null
                      : IconButton.styleFrom(
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                  onPressed: canSubmit
                      ? () => widget.onSubmitEdit?.call(_editController.text)
                      : null,
                ),
              ),
              Tooltip(
                message: 'Cancel edit',
                child: IconButton(
                  icon: Icon(
                    Icons.close,
                    color: iconFgColor,
                    size: kPlatformMobile ? 15 : 18,
                  ),
                  padding: EdgeInsets.all(kPlatformMobile ? 4 : 8),
                  visualDensity: VisualDensity.compact,
                  constraints: BoxConstraints(
                    minWidth: kPlatformMobile ? 24 : 30,
                    minHeight: kPlatformMobile ? 24 : 30,
                  ),
                  style: kPlatformMobile
                      ? null
                      : IconButton.styleFrom(
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
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

    // Check if we should use the interleaved content blocks layout
    final bool useContentBlocks =
        !isUserMessage &&
        widget.contentBlocks != null &&
        widget.contentBlocks!.isNotEmpty;

    final bool hasVisibleToolCalls =
        !isUserMessage &&
        !useContentBlocks &&
        widget.showToolCalls &&
        widget.toolCalls != null &&
        widget.toolCalls!.isNotEmpty;
    final bool hasInfoStatusBar =
        !isUserMessage &&
        !useContentBlocks &&
        (_hasReasoning || _hasModelInfo) &&
        !hasVisibleToolCalls;

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
        children: useContentBlocks
            ? _buildContentBlocksLayout(
                iconFgColor: iconFgColor,
                accentColor: accentColor,
                bgColor: bgColor,
                alignRight: alignRight,
              )
            : _buildClassicLayout(
                iconFgColor: iconFgColor,
                accentColor: accentColor,
                bgColor: bgColor,
                isUserMessage: isUserMessage,
                alignRight: alignRight,
                hasInfoStatusBar: hasInfoStatusBar,
                hasVisibleToolCalls: hasVisibleToolCalls,
              ),
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

  /// Classic flat layout: single tool calls bar + single text block.
  /// Used when no [ContentBlock]s are present (backward compat).
  List<Widget> _buildClassicLayout({
    required Color iconFgColor,
    required Color accentColor,
    required Color bgColor,
    required bool isUserMessage,
    required bool alignRight,
    required bool hasInfoStatusBar,
    required bool hasVisibleToolCalls,
  }) {
    final bool hasImages = widget.images != null && widget.images!.isNotEmpty;
    final bool placeQrImageAboveResponse = hasImages && _isQrImageMessage;

    return [
      if (hasInfoStatusBar)
        SizedBox(
          width: double.infinity,
          child: _buildInfoStatusBar(iconFgColor, accentColor),
        ),
      if (hasImages && !placeQrImageAboveResponse) ...[
        _buildImagesGrid(widget.images!),
        const SizedBox(height: 8),
      ],
      if (widget.attachments != null && widget.attachments!.isNotEmpty) ...[
        _buildAttachmentsChips(widget.attachments!),
        const SizedBox(height: 8),
      ],
      if (hasVisibleToolCalls) ...[
        _buildToolCallsBar(widget.toolCalls!),
        const SizedBox(height: 8),
      ],
      if (hasImages && placeQrImageAboveResponse) ...[
        _buildImagesGrid(widget.images!),
        const SizedBox(height: 8),
      ],
      _buildMessageBody(
        iconFgColor: iconFgColor,
        accentColor: accentColor,
        bgColor: bgColor,
        isUserMessage: isUserMessage,
      ),
      // Image actions go below the text, matching the regular action buttons.
      if (widget.images != null &&
          widget.images!.isNotEmpty &&
          (widget.imageCostEur != null || widget.imageGeneratedAt != null))
        _buildImageMetaMenu(
          iconFgColor,
          alignRight,
          widget.imageCostEur,
          widget.imageGeneratedAt,
        ),
    ];
  }

  /// Interleaved content blocks layout: renders text, tool calls, and
  /// reasoning blocks in the order they were produced across streaming passes.
  List<Widget> _buildContentBlocksLayout({
    required Color iconFgColor,
    required Color accentColor,
    required Color bgColor,
    required bool alignRight,
  }) {
    final blocks = widget.contentBlocks!;
    final children = <Widget>[];

    // By default, images render at the top.
    // For QR messages, render just above the AI response text.
    final bool hasImages = widget.images != null && widget.images!.isNotEmpty;
    final bool placeQrImageAboveResponse = hasImages && _isQrImageMessage;
    if (hasImages && !placeQrImageAboveResponse) {
      children.add(_buildImagesGrid(widget.images!));
      children.add(const SizedBox(height: 8));
    }

    var insertedQrImage = false;

    // Document attachments
    if (widget.attachments != null && widget.attachments!.isNotEmpty) {
      children.add(_buildAttachmentsChips(widget.attachments!));
      children.add(const SizedBox(height: 8));
    }

    // Collect tool call IDs already inside content blocks so we can detect
    // "live" (not-yet-in-blocks) tool calls for the current streaming pass.
    final blockToolCallIds = <String>{};
    for (final block in blocks) {
      if (block.type == ContentBlockType.toolCalls && block.toolCalls != null) {
        for (final tc in block.toolCalls!) {
          blockToolCallIds.add(tc.id);
        }
      }
    }

    // Render each content block in order
    for (final block in blocks) {
      switch (block.type) {
        case ContentBlockType.text:
          if (block.text != null && block.text!.trim().isNotEmpty) {
            if (placeQrImageAboveResponse && !insertedQrImage) {
              children.add(_buildImagesGrid(widget.images!));
              children.add(const SizedBox(height: 8));
              insertedQrImage = true;
            }
            children.add(_buildBlockText(block.text!, iconFgColor, bgColor));
          }
        case ContentBlockType.toolCalls:
          if (block.toolCalls != null &&
              block.toolCalls!.isNotEmpty &&
              widget.showToolCalls) {
            children.add(
              _buildToolCallsBar(block.toolCalls!, isContentBlock: true),
            );
            children.add(const SizedBox(height: 8));
          }
        case ContentBlockType.reasoning:
          if (block.text != null && block.text!.trim().isNotEmpty) {
            children.add(_buildBlockReasoning(block.text!, accentColor));
          }
      }
    }

    // Live tool calls: any tool calls NOT yet in a content block
    // (from the currently-running pass).
    if (widget.showToolCalls &&
        widget.toolCalls != null &&
        widget.toolCalls!.isNotEmpty) {
      final liveToolCalls = widget.toolCalls!
          .where((tc) => !blockToolCallIds.contains(tc.id))
          .toList();
      if (liveToolCalls.isNotEmpty) {
        children.add(_buildToolCallsBar(liveToolCalls));
        children.add(const SizedBox(height: 8));
      }
    }

    // Trailing streaming text from the current pass (only while streaming).
    // When finalized, all text is already in content blocks.
    if (widget.isStreamingMessage) {
      final trailingText = stripToolCallBlocksForDisplay(widget.message).trim();
      if (trailingText.isNotEmpty) {
        if (placeQrImageAboveResponse && !insertedQrImage) {
          children.add(_buildImagesGrid(widget.images!));
          children.add(const SizedBox(height: 8));
          insertedQrImage = true;
        }
        children.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: MarkdownMessage(
              text: trailingText,
              textColor: iconFgColor,
              backgroundColor: bgColor,
            ),
          ),
        );
      }
    }

    if (placeQrImageAboveResponse && !insertedQrImage) {
      children.add(_buildImagesGrid(widget.images!));
      children.add(const SizedBox(height: 8));
    }

    // Image actions at the bottom, matching the regular action buttons.
    if (hasImages &&
        (widget.imageCostEur != null || widget.imageGeneratedAt != null)) {
      children.add(
        _buildImageMetaMenu(
          iconFgColor,
          alignRight,
          widget.imageCostEur,
          widget.imageGeneratedAt,
        ),
      );
    }

    if (children.isEmpty) {
      children.add(const SizedBox.shrink());
    }

    return children;
  }

  bool _hasVisualBlocks(String content) {
    return _visualBlockStartRegex.hasMatch(content);
  }

  dynamic _tryParseJson(String raw) {
    var s = raw.trim();
    try {
      return jsonDecode(s);
    } catch (_) {}

    if (s.startsWith('{') && s.endsWith(']')) {
      s = s.substring(0, s.length - 1).trim();
      if (s.endsWith('}')) {
        try {
          return jsonDecode(s);
        } catch (_) {}
      }
    }

    s = raw.trim().replaceAll(RegExp(r',\s*([}\]])'), r'$1');
    try {
      return jsonDecode(s);
    } catch (_) {}

    return jsonDecode(raw.trim());
  }

  Widget _buildVisualContent({
    required String content,
    required Color textColor,
    required Color bgColor,
  }) {
    final widgets = <Widget>[];
    var lastEnd = 0;

    for (final match in _richBlockRegex.allMatches(content)) {
      final textBefore = content.substring(lastEnd, match.start).trim();
      if (textBefore.isNotEmpty) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: MarkdownMessage(
              text: textBefore,
              textColor: textColor,
              backgroundColor: bgColor,
            ),
          ),
        );
      }

      final blockType = match.group(1)!.toLowerCase();
      final blockJson = match.group(2)!.trim();

      try {
        if (blockType == 'map') {
          widgets.add(MapBlockWidget(jsonString: blockJson));
        } else {
          final parsed = _tryParseJson(blockJson);
          if (parsed is! Map<String, dynamic>) {
            throw const FormatException('Expected JSON object');
          }
          widgets.add(ChartRenderer(data: parsed));
        }
      } catch (e) {
        widgets.add(
          Container(
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.errorContainer.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '$blockType parse error: $e',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ),
        );
      }

      lastEnd = match.end;
    }

    final textAfter = content.substring(lastEnd).trim();
    if (textAfter.isNotEmpty) {
      widgets.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: MarkdownMessage(
            text: textAfter,
            textColor: textColor,
            backgroundColor: bgColor,
          ),
        ),
      );
    }

    if (widgets.isEmpty) {
      widgets.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: MarkdownMessage(
            text: content,
            textColor: textColor,
            backgroundColor: bgColor,
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: widgets,
    );
  }

  /// Renders a text content block as a MarkdownMessage.
  Widget _buildBlockText(String text, Color textColor, Color bgColor) {
    // Check for embedded <chart> / <map> blocks
    if (_hasVisualBlocks(text)) {
      return _buildVisualContent(
        content: text,
        textColor: textColor,
        bgColor: bgColor,
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: MarkdownMessage(
        text: text,
        textColor: textColor,
        backgroundColor: bgColor,
      ),
    );
  }

  /// Renders a reasoning content block as an expandable card.
  Widget _buildBlockReasoning(String text, Color accentColor) {
    return _buildExpandableCard(
      key: 'block_reasoning_${text.hashCode}',
      icon: Icons.psychology,
      label: 'Reasoning',
      preview: text,
      expandedContent: text,
      accentColor: accentColor,
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
    if (widget.modelProvider != null && widget.modelProvider!.isNotEmpty) {
      buf.writeln('Provider: ${widget.modelProvider}');
    }
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

  Widget _buildToolCallsBar(
    List<ToolCall> toolCalls, {
    bool isContentBlock = false,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final renderedAssistantText = stripToolCallBlocksForDisplay(widget.message);
    final bool isRunning = toolCalls.any(
      (t) =>
          t.status == ToolCallStatus.running ||
          t.status == ToolCallStatus.pending,
    );
    // Use a unique expand key per content block (based on first tool call ID)
    // so multiple tool call bars in the same message have independent state.
    final String expandKey = isContentBlock && toolCalls.isNotEmpty
        ? 'tool_calls_block_${toolCalls.first.id}'
        : 'tool_calls_bar';
    final bool isExpanded = _blockExpanded[expandKey] ?? false;
    final bool allDone =
        toolCalls.isNotEmpty &&
        toolCalls.every(
          (t) =>
              t.status == ToolCallStatus.completed ||
              t.status == ToolCallStatus.error,
        );
    final bool isReasoning =
        widget.isReasoningStreaming &&
        allDone &&
        (renderedAssistantText.trim().isEmpty ||
            renderedAssistantText == 'Thinking...');

    final int completedCount = toolCalls
        .where((t) => t.status == ToolCallStatus.completed)
        .length;
    final String label;
    final IconData icon;
    final bool showSpinner;
    if (isRunning) {
      final runningTool = toolCalls.firstWhere(
        (t) =>
            t.status == ToolCallStatus.running ||
            t.status == ToolCallStatus.pending,
        orElse: () => toolCalls.last,
      );
      label = '${runningTool.name}...';
      icon = Icons.build_circle_outlined;
      showSpinner = true;
    } else if (isReasoning) {
      label = 'Reasoning...';
      icon = Icons.psychology;
      showSpinner = true;
    } else {
      final uniqueNames = toolCalls.map((t) => t.name).toSet();
      if (uniqueNames.length <= 2) {
        label = uniqueNames.join(', ');
      } else {
        label = '${toolCalls.length} tools used';
      }
      icon = Icons.build_circle_outlined;
      showSpinner = false;
    }

    final Color accentColor = isReasoning
        ? colorScheme.primary
        : isRunning
        ? Colors.blue
        : (toolCalls.any((t) => t.status == ToolCallStatus.error)
              ? Colors.orange
              : Colors.green);

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
            onTap: () {
              setState(() {
                _blockExpanded[expandKey] = !isExpanded;
              });
            },
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                children: [
                  if (showSpinner)
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
                  Expanded(
                    child: Text(
                      label,
                      style: TextStyle(
                        color: accentColor,
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (!showSpinner)
                    Text(
                      '$completedCount/${toolCalls.length}',
                      style: TextStyle(
                        color: colorScheme.onSurface.withValues(alpha: 0.6),
                        fontSize: 11,
                      ),
                    ),
                  const SizedBox(width: 4),
                  Icon(
                    isExpanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ],
              ),
            ),
          ),
          if (isExpanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (int i = 0; i < toolCalls.length; i++) ...[
                    if (toolCalls[i].roundThinking != null &&
                        toolCalls[i].roundThinking!.trim().isNotEmpty)
                      _buildExpandableCard(
                        key: 'thinking_round_${toolCalls[i].id}_$i',
                        icon: Icons.psychology,
                        label: 'Reasoning',
                        preview: toolCalls[i].roundThinking!,
                        expandedContent: toolCalls[i].roundThinking!,
                        accentColor: colorScheme.primary,
                      ),
                    _buildExpandableCard(
                      key: 'tool_${toolCalls[i].id}',
                      icon: _toolCallIcon(toolCalls[i].status),
                      label: toolCalls[i].name,
                      preview:
                          _toolCallSubtitle(toolCalls[i]) ??
                          (toolCalls[i].result != null
                              ? _truncatePreview(toolCalls[i].result!, 60)
                              : 'running...'),
                      expandedContent: _formatToolCallDetails(toolCalls[i]),
                      accentColor: _toolCallColor(toolCalls[i].status),
                      isRunning: toolCalls[i].status == ToolCallStatus.running,
                    ),
                  ],
                  // Skip reasoning/model info in content block mode —
                  // those are rendered as separate blocks.
                  if (!isContentBlock && _hasReasoning)
                    _buildExpandableCard(
                      key: 'thinking_final',
                      icon: Icons.psychology,
                      label: 'Reasoning',
                      preview: widget.reasoning!,
                      expandedContent: widget.reasoning!,
                      accentColor: colorScheme.primary,
                    ),
                  if (_hasModelInfo)
                    _buildExpandableCard(
                      key: 'model_info_$expandKey',
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

  IconData _toolCallIcon(ToolCallStatus status) {
    switch (status) {
      case ToolCallStatus.pending:
        return Icons.hourglass_empty;
      case ToolCallStatus.running:
        return Icons.sync;
      case ToolCallStatus.completed:
        return Icons.check_circle;
      case ToolCallStatus.error:
        return Icons.error;
    }
  }

  Color _toolCallColor(ToolCallStatus status) {
    switch (status) {
      case ToolCallStatus.pending:
        return Colors.orange;
      case ToolCallStatus.running:
        return Colors.blue;
      case ToolCallStatus.completed:
        return Colors.green;
      case ToolCallStatus.error:
        return Colors.red;
    }
  }

  String _formatToolCallDetails(ToolCall toolCall) {
    final buffer = StringBuffer();
    if (toolCall.arguments.isNotEmpty) {
      buffer.writeln('Args: ${jsonEncode(toolCall.arguments)}');
    }
    if (toolCall.result != null && toolCall.result!.isNotEmpty) {
      if (buffer.isNotEmpty) {
        buffer.writeln();
      }
      buffer.writeln('Result: ${toolCall.result}');
    }
    if (buffer.isEmpty) {
      return 'No result yet.';
    }
    return buffer.toString().trimRight();
  }

  String? _toolCallSubtitle(ToolCall toolCall) {
    if (toolCall.status == ToolCallStatus.running ||
        toolCall.status == ToolCallStatus.pending) {
      return 'Running';
    }
    if (toolCall.status == ToolCallStatus.error) {
      return toolCall.result == null
          ? 'Failed'
          : _truncatePreview(toolCall.result!, 70);
    }

    final result = toolCall.result;
    if (result == null || result.trim().isEmpty) {
      return null;
    }

    return _truncatePreview(result, 70);
  }

  Widget _buildImagesGrid(List<String> images) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final double maxWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.of(context).size.width * 0.8;
        final bool compactQrLayout = _isQrImageMessage && images.length == 1;

        if (compactQrLayout) {
          final String imageSource = images.first;
          final double squareSize =
              (kPlatformMobile ? maxWidth * 0.55 : maxWidth * 0.4).clamp(
                150.0,
                240.0,
              );

          return Align(
            alignment: Alignment.center,
            child: _CachedImageThumbnail(
              imageDataUrl: imageSource,
              width: squareSize,
              height: squareSize,
              borderRadius: 12,
              fit: BoxFit.contain,
              onTap: () => _openImagePreview(
                imageSource: imageSource,
                images: images,
                index: 0,
              ),
            ),
          );
        }

        if (images.length == 1) {
          final String imageSource = images.first;
          final double imageWidth = maxWidth;
          // Desktop gets a taller preview; mobile stays compact.
          final double imageHeight = kPlatformMobile
              ? 280
              : (maxWidth * 0.65).clamp(280.0, 512.0);

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

    final displayText = isUserMessage
        ? widget.message
        : stripToolCallBlocksForDisplay(widget.message);

    if (!isUserMessage && displayText.trim().isEmpty) {
      return const SizedBox.shrink();
    }

    // For AI messages, check for embedded <chart> / <map> blocks
    if (!isUserMessage && _hasVisualBlocks(displayText)) {
      return _buildVisualContent(
        content: displayText,
        textColor: iconFgColor,
        bgColor: bgColor,
      );
    }

    final Widget messageWidget = MarkdownMessage(
      text: displayText,
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
    final Color bgColor = Theme.of(context).scaffoldBackgroundColor;
    final bool compactQrControls = _isQrImageMessage;
    final double iconSize = kPlatformMobile
        ? (compactQrControls ? 13 : 15)
        : (compactQrControls ? 16 : 18);
    final EdgeInsets buttonPadding = EdgeInsets.all(
      kPlatformMobile
          ? (compactQrControls ? 2 : 4)
          : (compactQrControls ? 5 : 8),
    );
    final double minButtonSize = kPlatformMobile
        ? (compactQrControls ? 20 : 24)
        : (compactQrControls ? 26 : 30);

    // Match the pill-shaped container style used by _buildActionButtons.
    return Padding(
      padding: alignRight
          ? const EdgeInsets.only(top: 4, right: 6)
          : const EdgeInsets.only(top: 4, left: 6),
      child: Row(
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
            padding: EdgeInsets.symmetric(
              horizontal: kPlatformMobile
                  ? (compactQrControls ? 1 : 2)
                  : (compactQrControls ? 5 : 8),
              vertical: kPlatformMobile ? 0 : (compactQrControls ? 2 : 4),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Tooltip(
                  message: 'Copy image',
                  child: IconButton(
                    icon: Icon(Icons.copy, color: iconFgColor, size: iconSize),
                    padding: buttonPadding,
                    visualDensity: VisualDensity.compact,
                    constraints: BoxConstraints(
                      minWidth: minButtonSize,
                      minHeight: minButtonSize,
                    ),
                    style: kPlatformMobile
                        ? null
                        : IconButton.styleFrom(
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                    onPressed: _copyFirstImageToClipboard,
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Image details',
                  padding: buttonPadding,
                  constraints: BoxConstraints(
                    minWidth: minButtonSize,
                    minHeight: minButtonSize,
                  ),
                  menuPadding: EdgeInsets.zero,
                  iconSize: iconSize,
                  icon: Icon(Icons.more_vert, color: iconFgColor),
                  style: kPlatformMobile
                      ? null
                      : IconButton.styleFrom(
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
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
        // Base64 data URI — decode inline (used by tool-generated images
        // like QR codes, or as fallback when Supabase upload fails).
        final commaIndex = widget.imageDataUrl.indexOf(',');
        if (commaIndex >= 0) {
          try {
            _cachedBytes = base64Decode(
              widget.imageDataUrl.substring(commaIndex + 1),
            );
          } catch (e) {
            if (kDebugMode) {
              debugPrint('Failed to decode Base64 image: $e');
            }
          }
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
