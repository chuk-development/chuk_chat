// lib/widgets/message_bubble.dart
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:chuk_chat/utils/io_helper.dart';
import 'package:path_provider/path_provider.dart';
import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/services/diagnostics_log_service.dart';
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
import 'package:chuk_chat/widgets/ask_user_card.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
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

class _ToolCallGroupSegment {
  _ToolCallGroupSegment({this.reasoning = ''});

  String reasoning;
  final List<ToolCall> toolCalls = <ToolCall>[];
}

class _ToolTimelineEntry {
  const _ToolTimelineEntry.reasoning(this.reasoning) : toolCall = null;
  const _ToolTimelineEntry.tool(this.toolCall) : reasoning = null;

  final String? reasoning;
  final ToolCall? toolCall;

  bool get isReasoning => reasoning != null;
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
    this.onAskUserAnswer,
    this.onRetry,
    this.userMessageActions = const <MessageBubbleAction>[],
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

  /// Called when the user taps an option button on an ask_user tool call.
  /// When non-null, the bubble renders interactive option buttons extracted
  /// from the most recent ask_user tool call in this message.
  final ValueChanged<String>? onAskUserAnswer;

  /// Called when the user taps the "Retry" button on a finalized AI message
  /// (e.g. after empty response or failed tool calls). Triggers resending
  /// the last user message without re-running the full tool discovery.
  final VoidCallback? onRetry;

  /// Actions shown in a popup menu on long-press for user messages.
  /// These are hidden by default and only appear on long-press, matching
  /// the UX pattern of ChatGPT, Gemini, etc.
  final List<MessageBubbleAction> userMessageActions;

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble>
    with AutomaticKeepAliveClientMixin {
  /// Regex to find `<chart>`, `<map>`, and `<email>` blocks in message content.
  static final RegExp _richBlockRegex = RegExp(
    r'<\s*(chart|map|email)\s*>([\s\S]*?)<\s*/\s*\1\s*>',
    multiLine: true,
    caseSensitive: false,
  );

  static final RegExp _visualBlockStartRegex = RegExp(
    r'<\s*(chart|map|email)\b',
    caseSensitive: false,
  );

  bool _isReasoningExpanded = false;
  final Map<String, bool> _blockExpanded = {};
  final Set<String> _expandedCards = {};
  bool _complexBubbleLogged = false;
  bool _showUserActions = false;

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
  }

  /// Bottom bar for AI messages: action buttons (left) + sources (right).
  /// Both pills share the same height so they look balanced.
  static const double _mobileBottomBarHeight = 36.0;

  Widget _buildBottomBar(Color iconFgColor, bool hasActions) {
    final bool hasSources = widget.toolCalls != null &&
        widget.toolCalls!.isNotEmpty;

    if (!hasSources && !hasActions) return const SizedBox.shrink();

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (hasActions) _buildActionButtons(iconFgColor, false),
        const Spacer(),
        if (hasSources) _buildSourcesBar(widget.toolCalls!),
      ],
    );
  }

  Widget _buildUserActionButtons(Color iconFgColor) {
    final Color bgColor = Theme.of(context).scaffoldBackgroundColor;
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.end,
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
            children: widget.userMessageActions.map((action) {
              return Tooltip(
                message: action.tooltip,
                child: IconButton(
                  icon: Icon(
                    action.icon,
                    color: action.isEnabled
                        ? iconFgColor
                        : iconFgColor.withValues(alpha: 0.38),
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
                  onPressed: action.isEnabled
                      ? () {
                          setState(() => _showUserActions = false);
                          action.onPressed();
                        }
                      : null,
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
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
          height: kPlatformMobile ? _mobileBottomBarHeight : null,
          decoration: BoxDecoration(
            color: bgColor.lighten(0.05),
            borderRadius: BorderRadius.circular(100),
            border: Border.all(
              color: iconFgColor.withValues(alpha: 0.15),
              width: 1,
            ),
          ),
          padding: EdgeInsets.symmetric(
            horizontal: kPlatformMobile ? 4 : 8,
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
                    size: kPlatformMobile ? 18 : 18,
                  ),
                  padding: EdgeInsets.all(kPlatformMobile ? 5 : 8),
                  visualDensity: VisualDensity.compact,
                  constraints: BoxConstraints(
                    minWidth: kPlatformMobile ? 28 : 30,
                    minHeight: kPlatformMobile ? 28 : 30,
                  ),
                  style: kPlatformMobile
                      ? IconButton.styleFrom(
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        )
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

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required for AutomaticKeepAliveClientMixin
    final stopwatch = Stopwatch()..start();

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

    // AI message actions are shown below the bubble (copy, retry).
    // User message actions are hidden and shown via long-press popup.
    final bool hasActions =
        !isUserMessage && widget.actions.isNotEmpty;

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
    // Show the info status bar when:
    // 1. We have reasoning/model info (normal case), OR
    // 2. The message is actively streaming and waiting for first tokens
    //    (shows a "Connecting..." / "Reasoning..." bar instead of plain
    //    "Thinking..." text sitting in the bubble).
    final bool isWaitingForFirstTokens =
        widget.isReasoningStreaming &&
        (widget.message == 'Thinking...' || widget.message.isEmpty);
    final bool hasInfoStatusBar =
        !isUserMessage &&
        !useContentBlocks &&
        (_hasReasoning || _hasModelInfo || isWaitingForFirstTokens) &&
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

    // Wrap user messages in GestureDetector for long-press action bar.
    final bool hasUserActions =
        isUserMessage && widget.userMessageActions.isNotEmpty;
    final Widget userBubble = hasUserActions
        ? GestureDetector(
            onTap: () =>
                setState(() => _showUserActions = !_showUserActions),
            child: bubbleContent,
          )
        : bubbleContent;

    final result = Align(
      alignment: alignRight ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: effectiveMaxWidth),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: alignRight
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            userBubble,
            if (hasUserActions && _showUserActions)
              _buildUserActionButtons(iconFgColor),
            if (!isUserMessage) _buildBottomBar(iconFgColor, hasActions),
          ],
        ),
      ),
    );

    stopwatch.stop();
    final imageCount = widget.images?.length ?? 0;
    final isComplex = imageCount > 0 || widget.message.length > 3000;
    if (isComplex &&
        !_complexBubbleLogged &&
        stopwatch.elapsedMilliseconds >= 8) {
      _complexBubbleLogged = true;
      unawaited(
        DiagnosticsLogService.timing(
          'chat_ui',
          'message_bubble_build',
          stopwatch.elapsedMilliseconds,
          data: {
            'is_user': isUserMessage,
            'message_len': widget.message.length,
            'image_count': imageCount,
            'has_attachments': (widget.attachments?.isNotEmpty ?? false),
            'has_content_blocks': (widget.contentBlocks?.isNotEmpty ?? false),
          },
        ),
      );
    }

    return result;
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
      ..._buildAskUserOptions(),
      // Image actions go below the text, matching the regular action buttons.
      if (widget.images != null && widget.images!.isNotEmpty)
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

    // Images render just above the first text block (after tool calls),
    // so they appear in visual order with the tool that generated them.
    final bool hasImages = widget.images != null && widget.images!.isNotEmpty;

    var insertedImage = false;

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

    final finalizedTextPrefix = blocks
        .where(
          (block) =>
              block.type == ContentBlockType.text &&
              block.text != null &&
              block.text!.trim().isNotEmpty,
        )
        .map((block) => block.text!.trim())
        .join('\n\n')
        .trim();

    // Group contiguous reasoning/tool-call rounds into one parent block.
    // A plain text block ends the current reasoning block and starts a new one
    // below that text.
    final groupedSegments = <_ToolCallGroupSegment>[];

    void flushGroupedReasoningTools() {
      if (groupedSegments.isEmpty) {
        return;
      }

      final mergedToolCalls = <ToolCall>[];
      final timeline = <_ToolTimelineEntry>[];
      final fallbackReasonings = <String>[];

      for (final segment in groupedSegments) {
        final segmentReasoning = segment.reasoning.trim();

        if (!widget.showToolCalls) {
          if (segmentReasoning.isNotEmpty) {
            fallbackReasonings.add(segmentReasoning);
          }
          continue;
        }

        if (segmentReasoning.isNotEmpty) {
          timeline.add(_ToolTimelineEntry.reasoning(segmentReasoning));
        }

        if (segment.toolCalls.isNotEmpty) {
          for (final toolCall in segment.toolCalls) {
            mergedToolCalls.add(toolCall);
            timeline.add(_ToolTimelineEntry.tool(toolCall));
          }
        }
      }

      if (widget.showToolCalls && mergedToolCalls.isNotEmpty) {
        children.add(
          _buildToolCallsBar(
            mergedToolCalls,
            isContentBlock: true,
            contentBlockTimeline: timeline,
          ),
        );
        children.add(const SizedBox(height: 8));
        // Insert images right after the tool calls bar that produced them.
        if (hasImages && !insertedImage) {
          children.add(_buildImagesGrid(widget.images!));
          children.add(const SizedBox(height: 8));
          insertedImage = true;
        }
      } else if (widget.showToolCalls && timeline.isNotEmpty) {
        for (final entry in timeline) {
          if (entry.isReasoning &&
              (entry.reasoning?.trim().isNotEmpty ?? false)) {
            children.add(_buildBlockReasoning(entry.reasoning!, accentColor));
          }
        }
      } else if (!widget.showToolCalls && fallbackReasonings.isNotEmpty) {
        for (final reasoning in fallbackReasonings) {
          children.add(_buildBlockReasoning(reasoning, accentColor));
        }
      }

      groupedSegments.clear();
    }

    // Render grouped reasoning/tool-call blocks. Text blocks break groups.
    for (final block in blocks) {
      switch (block.type) {
        case ContentBlockType.reasoning:
          final reasoningText = block.text?.trim() ?? '';
          if (reasoningText.isNotEmpty) {
            if (groupedSegments.isEmpty ||
                groupedSegments.last.toolCalls.isNotEmpty) {
              groupedSegments.add(
                _ToolCallGroupSegment(reasoning: reasoningText),
              );
            } else {
              final existing = groupedSegments.last.reasoning.trim();
              groupedSegments.last.reasoning = existing.isEmpty
                  ? reasoningText
                  : '$existing\n\n$reasoningText';
            }
          }
        case ContentBlockType.toolCalls:
          if (block.toolCalls != null && block.toolCalls!.isNotEmpty) {
            if (groupedSegments.isEmpty) {
              groupedSegments.add(_ToolCallGroupSegment());
            }
            groupedSegments.last.toolCalls.addAll(
              block.toolCalls!
                  .map((tc) => ToolCall.fromJson(tc.toJson()))
                  .toList(),
            );
          }
        case ContentBlockType.text:
          flushGroupedReasoningTools();
          if (block.text != null && block.text!.trim().isNotEmpty) {
            children.add(_buildBlockText(block.text!, iconFgColor, bgColor));
          }
      }
    }

    // Trailing streaming text from the current pass (only while streaming).
    // When finalized, all text is already in content blocks.
    var trailingText = '';
    if (widget.isStreamingMessage) {
      trailingText = stripToolCallBlocksForDisplay(widget.message).trim();

      // Avoid duplicating finalized text blocks while a newer pass streams.
      if (trailingText.isNotEmpty && finalizedTextPrefix.isNotEmpty) {
        if (trailingText == finalizedTextPrefix) {
          trailingText = '';
        } else if (trailingText.startsWith('$finalizedTextPrefix\n\n')) {
          trailingText = trailingText
              .substring(finalizedTextPrefix.length)
              .trim();
        }
      }

      // Keep one reasoning/tool block open until we actually show text.
      if (trailingText.isNotEmpty) {
        flushGroupedReasoningTools();
      }

      if (trailingText.isNotEmpty) {
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

    // Live tool calls: any tool calls NOT yet in a content block
    // (from the currently-running pass).
    var liveToolCalls = <ToolCall>[];
    if (widget.showToolCalls &&
        widget.toolCalls != null &&
        widget.toolCalls!.isNotEmpty) {
      liveToolCalls = widget.toolCalls!
          .where((tc) => !blockToolCallIds.contains(tc.id))
          .toList();
    }

    if (trailingText.isEmpty && liveToolCalls.isNotEmpty) {
      if (groupedSegments.isEmpty) {
        groupedSegments.add(_ToolCallGroupSegment());
      }
      groupedSegments.last.toolCalls.addAll(
        liveToolCalls.map((tc) => ToolCall.fromJson(tc.toJson())).toList(),
      );
    }

    // Flush any still-open reasoning/tool-call group now.
    flushGroupedReasoningTools();

    // If we already showed trailing text, live tool calls belong to a new block.
    if (trailingText.isNotEmpty && liveToolCalls.isNotEmpty) {
      children.add(_buildToolCallsBar(liveToolCalls));
      children.add(const SizedBox(height: 8));
    }

    if (hasImages && !insertedImage) {
      children.add(_buildImagesGrid(widget.images!));
      children.add(const SizedBox(height: 8));
    }

    // ask_user interactive options.
    children.addAll(_buildAskUserOptions());

    // Image actions at the bottom, matching the regular action buttons.
    if (hasImages) {
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
        } else if (blockType == 'email') {
          final parsed = _tryParseJson(blockJson);
          if (parsed is! Map<String, dynamic>) {
            throw const FormatException('Expected JSON object');
          }
          widgets.add(_buildEmailBlock(parsed));
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

  /// Renders an `<email>` block as a card with subject, recipients, body
  /// preview, and an "Open in Mail App" button that launches a mailto: URI.
  Widget _buildEmailBlock(Map<String, dynamic> data) {
    final to = data['to'] as String? ?? '';
    final subject = data['subject'] as String? ?? '';
    final body = data['body'] as String? ?? '';
    final cc = data['cc'] as String?;
    final bcc = data['bcc'] as String?;

    final colorScheme = Theme.of(context).colorScheme;
    final bgColor = Theme.of(context).scaffoldBackgroundColor;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: bgColor.lighten(0.03),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: colorScheme.primary.withValues(alpha: 0.25),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: colorScheme.primary.withValues(alpha: 0.08),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(11),
                topRight: Radius.circular(11),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.email_outlined,
                  size: 18,
                  color: colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    subject.isNotEmpty ? subject : 'No Subject',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                      color: colorScheme.onSurface,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          // Recipients
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (to.isNotEmpty)
                  _emailField('To', to, colorScheme),
                if (cc != null && cc.isNotEmpty)
                  _emailField('CC', cc, colorScheme),
                if (bcc != null && bcc.isNotEmpty)
                  _emailField('BCC', bcc, colorScheme),
              ],
            ),
          ),
          // Body preview
          if (body.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
              child: Text(
                body.length > 300 ? '${body.substring(0, 300)}...' : body,
                style: TextStyle(
                  fontSize: 13,
                  color: colorScheme.onSurface.withValues(alpha: 0.75),
                  height: 1.4,
                ),
                maxLines: 8,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          // Open button
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => _openMailto(to, subject, body, cc, bcc),
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('Open in Mail App'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  textStyle: const TextStyle(fontSize: 13),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _emailField(String label, String value, ColorScheme colorScheme) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 32,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 13,
                color: colorScheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openMailto(
    String to,
    String subject,
    String body,
    String? cc,
    String? bcc,
  ) async {
    final params = <String, String>{};
    if (subject.isNotEmpty) params['subject'] = subject;
    if (body.isNotEmpty) params['body'] = body;
    if (cc != null && cc.isNotEmpty) params['cc'] = cc;
    if (bcc != null && bcc.isNotEmpty) params['bcc'] = bcc;

    final uri = Uri(
      scheme: 'mailto',
      path: to,
      queryParameters: params.isNotEmpty ? params : null,
    );

    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
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

    // Determine header label and state.
    // When the message is still "Thinking..." (no tokens yet), show
    // "Connecting..." to indicate we're waiting for the server.
    final bool waitingForTokens =
        isStreaming &&
        !_hasReasoning &&
        (widget.message == 'Thinking...' || widget.message.isEmpty);
    final String label = waitingForTokens
        ? 'Connecting...'
        : (isStreaming ? 'Reasoning...' : 'Reasoning');
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
    List<_ToolTimelineEntry>? contentBlockTimeline,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final renderedAssistantText = stripToolCallBlocksForDisplay(widget.message);
    // If the message is finalized (not streaming), tool calls should not
    // remain in running/pending — treat any stale ones as completed for
    // display purposes so the spinner doesn't hang indefinitely.
    final bool isRunning =
        widget.isStreamingMessage &&
        toolCalls.any(
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
        !isContentBlock &&
        widget.isReasoningStreaming &&
        allDone &&
        (renderedAssistantText.trim().isEmpty ||
            renderedAssistantText == 'Thinking...');

    final effectiveTimeline = isContentBlock && contentBlockTimeline != null
        ? contentBlockTimeline
        : const <_ToolTimelineEntry>[];

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
                  // Compact retry button in the header when there are errors
                  if (!showSpinner &&
                      !widget.isStreamingMessage &&
                      widget.onRetry != null &&
                      toolCalls.any(
                        (t) => t.status == ToolCallStatus.error,
                      )) ...[
                    const SizedBox(width: 4),
                    GestureDetector(
                      onTap: widget.onRetry,
                      child: Icon(
                        Icons.replay,
                        size: 14,
                        color: colorScheme.primary,
                      ),
                    ),
                  ],
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
                  if (isContentBlock && effectiveTimeline.isNotEmpty)
                    for (int ti = 0; ti < effectiveTimeline.length; ti++) ...[
                      if (effectiveTimeline[ti].isReasoning)
                        _buildExpandableCard(
                          key: 'timeline_reasoning_${expandKey}_$ti',
                          icon: Icons.psychology,
                          label: 'Reasoning',
                          preview: effectiveTimeline[ti].reasoning!,
                          expandedContent: effectiveTimeline[ti].reasoning!,
                          accentColor: colorScheme.primary,
                        )
                      else
                        _buildExpandableCard(
                          key: 'tool_${effectiveTimeline[ti].toolCall!.id}_$ti',
                          icon: _toolCallIcon(
                            effectiveTimeline[ti].toolCall!.status,
                          ),
                          label: effectiveTimeline[ti].toolCall!.name,
                          preview:
                              _toolCallSubtitle(
                                effectiveTimeline[ti].toolCall!,
                              ) ??
                              (effectiveTimeline[ti].toolCall!.result != null
                                  ? _truncatePreview(
                                      effectiveTimeline[ti].toolCall!.result!,
                                      60,
                                    )
                                  : 'running...'),
                          expandedContent: _formatToolCallDetails(
                            effectiveTimeline[ti].toolCall!,
                          ),
                          accentColor: _toolCallColor(
                            effectiveTimeline[ti].toolCall!.status,
                          ),
                          isRunning:
                              effectiveTimeline[ti].toolCall!.status ==
                              ToolCallStatus.running,
                        ),
                    ]
                  else
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
                        isRunning:
                            toolCalls[i].status == ToolCallStatus.running,
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
                  // Show a retry button when tool calls have errors
                  // and the message is no longer streaming.
                  if (!widget.isStreamingMessage &&
                      widget.onRetry != null &&
                      toolCalls.any((t) => t.status == ToolCallStatus.error))
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          onPressed: widget.onRetry,
                          icon: Icon(
                            Icons.replay,
                            size: 14,
                            color: colorScheme.primary,
                          ),
                          label: Text(
                            'Retry',
                            style: TextStyle(
                              fontSize: 12,
                              color: colorScheme.primary,
                            ),
                          ),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 4,
                            ),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                      ),
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

  // ─── Sources bar (web search / web crawl citations) ──────────────────

  /// Extracts source URLs from web_search and web_crawl tool calls.
  List<Map<String, String>> _extractSources(List<ToolCall> toolCalls) {
    final sources = <Map<String, String>>[];
    final seenUrls = <String>{};

    for (final tool in toolCalls) {
      if (tool.result == null) continue;

      if (tool.name == 'web_search') {
        final urlRegex = RegExp(r'^\s+(https?://\S+)', multiLine: true);
        final titleRegex = RegExp(r'^\d+\.\s+(.+)$', multiLine: true);
        final urls =
            urlRegex.allMatches(tool.result!).map((m) => m.group(1)!).toList();
        final titles = titleRegex
            .allMatches(tool.result!)
            .map((m) => m.group(1)!)
            .toList();
        for (int i = 0; i < urls.length; i++) {
          if (seenUrls.add(urls[i])) {
            sources.add({
              'url': urls[i],
              'title': i < titles.length ? titles[i] : Uri.parse(urls[i]).host,
              'host': Uri.tryParse(urls[i])?.host ?? urls[i],
            });
          }
        }
      } else if (tool.name == 'web_crawl') {
        final url = tool.arguments['url'] as String? ?? '';
        if (url.isNotEmpty && seenUrls.add(url)) {
          final firstLine = tool.result!.split('\n').first;
          sources.add({
            'url': url,
            'title': firstLine.replaceFirst(RegExp(r'^Content from\s+'), ''),
            'host': Uri.tryParse(url)?.host ?? url,
          });
        }
      }
    }
    return sources;
  }

  /// Shows the sources list in a bottom sheet.
  void _showSourcesSheet(
    BuildContext context,
    List<Map<String, String>> sources,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 32,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Icon(
                        Icons.language,
                        size: 18,
                        color: colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${sources.length} source${sources.length == 1 ? '' : 's'}',
                        style: TextStyle(
                          color: colorScheme.onSurface,
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                ...sources.map((source) {
                  return ListTile(
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: Image.network(
                        'https://www.google.com/s2/favicons?domain=${source['host']}&sz=32',
                        width: 20,
                        height: 20,
                        errorBuilder: (_, __, ___) => Icon(
                          Icons.public,
                          size: 20,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    title: Text(
                      source['title']!,
                      style: TextStyle(
                        color: colorScheme.onSurface,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      source['host']!,
                      style: TextStyle(
                        color: colorScheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                    trailing: Icon(
                      Icons.open_in_new,
                      size: 16,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    onTap: () async {
                      final url = Uri.tryParse(source['url']!);
                      if (url != null && await canLaunchUrl(url)) {
                        await launchUrl(
                          url,
                          mode: LaunchMode.externalApplication,
                        );
                      }
                    },
                  );
                }),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Compact sources pill — shows favicon icons + count, opens sheet on tap.
  Widget _buildSourcesBar(List<ToolCall> toolCalls) {
    final sources = _extractSources(toolCalls);
    if (sources.isEmpty) return const SizedBox.shrink();

    final colorScheme = Theme.of(context).colorScheme;
    final Color bgColor = Theme.of(context).scaffoldBackgroundColor;

    return InkWell(
      onTap: () => _showSourcesSheet(context, sources),
      borderRadius: BorderRadius.circular(100),
      child: Container(
        height: kPlatformMobile ? _mobileBottomBarHeight : null,
        decoration: BoxDecoration(
          color: bgColor.lighten(0.05),
          borderRadius: BorderRadius.circular(100),
          border: Border.all(
            color: colorScheme.onSurface.withValues(alpha: 0.15),
            width: 1,
          ),
        ),
        padding: EdgeInsets.symmetric(
          horizontal: kPlatformMobile ? 10 : 10,
          vertical: kPlatformMobile ? 0 : 6,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (int i = 0; i < sources.length && i < 5; i++)
              Padding(
                padding: EdgeInsets.only(right: i < 4 ? 4.0 : 0),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Image.network(
                    'https://www.google.com/s2/favicons?domain=${sources[i]['host']}&sz=32',
                    width: kPlatformMobile ? 21 : 16,
                    height: kPlatformMobile ? 21 : 16,
                    errorBuilder: (_, __, ___) => Icon(
                      Icons.public,
                      size: kPlatformMobile ? 21 : 16,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            const SizedBox(width: 6),
            Text(
              '${sources.length} source${sources.length == 1 ? '' : 's'}',
              style: TextStyle(
                color: colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w500,
                fontSize: kPlatformMobile ? 15 : 12,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── ask_user interactive options ─────────────────────────────────────

  /// Find the last completed ask_user tool call across all tool call sources.
  ToolCall? _findAskUserToolCall() {
    ToolCall? found;

    // Check contentBlocks first (interleaved layout).
    if (widget.contentBlocks != null) {
      for (final block in widget.contentBlocks!) {
        if (block.type == ContentBlockType.toolCalls &&
            block.toolCalls != null) {
          for (final tc in block.toolCalls!) {
            if (tc.name == 'ask_user' &&
                tc.status == ToolCallStatus.completed) {
              found = tc;
            }
          }
        }
      }
    }

    // Check flat toolCalls list (classic layout).
    if (widget.toolCalls != null) {
      for (final tc in widget.toolCalls!) {
        if (tc.name == 'ask_user' && tc.status == ToolCallStatus.completed) {
          found = tc;
        }
      }
    }

    return found;
  }

  /// Build ask_user interactive option buttons if applicable.
  List<Widget> _buildAskUserOptions() {
    if (widget.onAskUserAnswer == null) {
      return const [];
    }

    final askUserCall = _findAskUserToolCall();
    if (askUserCall == null) {
      return const [];
    }

    final rawOptions = askUserCall.arguments['options'];
    List<String> options;
    if (rawOptions is List) {
      options = rawOptions
          .map((o) => o.toString().trim())
          .where((s) => s.isNotEmpty)
          .toList();
    } else if (rawOptions is String) {
      try {
        final decoded = jsonDecode(rawOptions);
        if (decoded is List) {
          options = decoded
              .map((o) => o.toString().trim())
              .where((s) => s.isNotEmpty)
              .toList();
        } else {
          return const [];
        }
      } catch (_) {
        return const [];
      }
    } else {
      return const [];
    }

    if (options.isEmpty) {
      return const [];
    }

    return [AskUserCard(options: options, onSelect: widget.onAskUserAnswer!)];
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
    final displayText = isUserMessage
        ? widget.message
        : stripToolCallBlocksForDisplay(widget.message);

    if (!isUserMessage &&
        (displayText.trim().isEmpty || displayText == 'Thinking...')) {
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

    if (isUserMessage) {
      // Use plain Text so taps pass through to the GestureDetector
      // that toggles the action bar. Copy is available via the action bar.
      return Text(
        displayText,
        style: TextStyle(color: iconFgColor, fontSize: 15, height: 1.38),
      );
    }

    final Widget messageWidget = MarkdownMessage(
      text: displayText,
      textColor: iconFgColor,
      backgroundColor: bgColor,
      wrapWithSelectionArea: false,
    );

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
    // Use the same sizes as _buildActionButtons for consistency.
    const double iconSize = 18;
    final EdgeInsets buttonPadding = EdgeInsets.all(kPlatformMobile ? 5 : 8);
    final double minButtonSize = kPlatformMobile ? 28 : 30;

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
            height: kPlatformMobile ? _mobileBottomBarHeight : null,
            decoration: BoxDecoration(
              color: bgColor.lighten(0.05),
              borderRadius: BorderRadius.circular(100),
              border: Border.all(
                color: iconFgColor.withValues(alpha: 0.15),
                width: 1,
              ),
            ),
            padding: EdgeInsets.symmetric(
              horizontal: kPlatformMobile ? 4 : 8,
              vertical: kPlatformMobile ? 0 : 4,
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
                    style: IconButton.styleFrom(
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: _copyFirstImageToClipboard,
                  ),
                ),
                Tooltip(
                  message: 'Download image',
                  child: IconButton(
                    icon: Icon(
                      Icons.download,
                      color: iconFgColor,
                      size: iconSize,
                    ),
                    padding: buttonPadding,
                    visualDensity: VisualDensity.compact,
                    constraints: BoxConstraints(
                      minWidth: minButtonSize,
                      minHeight: minButtonSize,
                    ),
                    style: IconButton.styleFrom(
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: _downloadFirstImage,
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
                  style: IconButton.styleFrom(
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

  Future<Uint8List?> _loadFirstImageBytes() async {
    final images = widget.images;
    if (images == null || images.isEmpty) return null;
    final source = images.first;
    if (source.startsWith('data:image/')) {
      final commaIndex = source.indexOf(',');
      if (commaIndex < 0) return null;
      return base64Decode(source.substring(commaIndex + 1));
    }
    return ImageStorageService.downloadAndDecryptImage(source);
  }

  Future<void> _copyFirstImageToClipboard() async {
    try {
      final bytes = await _loadFirstImageBytes();
      if (bytes == null) return;
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

  Future<void> _downloadFirstImage() async {
    try {
      final bytes = await _loadFirstImageBytes();
      if (bytes == null) return;
      final dir = await getDownloadsDirectory() ??
          await getApplicationDocumentsDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final file = File('${dir.path}${Platform.pathSeparator}chuk_chat_image_$timestamp.png');
      await file.writeAsBytes(bytes, flush: true);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved to ${file.path}')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Unable to save image')));
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
    final stopwatch = Stopwatch()..start();
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

    stopwatch.stop();
    if (stopwatch.elapsedMilliseconds >= 250) {
      final bool isDataUri = widget.imageDataUrl.startsWith('data:image/');
      unawaited(
        DiagnosticsLogService.timing(
          'chat_ui',
          isDataUri ? 'decode_base64_thumbnail' : 'download_decrypt_thumbnail',
          stopwatch.elapsedMilliseconds,
          data: {
            'source_type': isDataUri ? 'data_uri' : 'storage_path',
            'width': widget.width.round(),
            'height': widget.height.round(),
            'bytes_loaded': _cachedBytes?.length ?? 0,
          },
        ),
      );
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
