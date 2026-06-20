// lib/widgets/message_bubble.dart
import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:chuk_chat/models/chat_message.dart' show ChatMessageStatus;
import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/models/artifact.dart';
import 'package:chuk_chat/services/app_theme_service.dart';
import 'package:chuk_chat/utils/chat_font_resolver.dart';
import 'package:chuk_chat/services/artifact_storage_service.dart';
import 'package:chuk_chat/services/diagnostics_log_service.dart';
import 'package:chuk_chat/services/file_save_service.dart';
import 'package:chuk_chat/services/image_storage_service.dart';
import 'package:chuk_chat/widgets/chart_widget.dart';
import 'package:chuk_chat/widgets/diff_widget.dart';
import 'package:chuk_chat/widgets/map_block_renderer.dart';
import 'package:chuk_chat/widgets/weather_widget.dart';
import 'package:chuk_chat/widgets/markdown_message.dart';
import 'package:chuk_chat/widgets/image_viewer.dart';
import 'package:chuk_chat/widgets/document_viewer.dart';
import 'package:chuk_chat/widgets/nice_snackbar.dart';
import 'package:chuk_chat/widgets/sandbox_artifact_block.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/utils/color_extensions.dart';
import 'package:chuk_chat/utils/tool_parser.dart';
import 'package:chuk_chat/widgets/ask_user_card.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/platform_config.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:flutter/foundation.dart';

// ─── Vertical rhythm ─────────────────────────────────────────────────────
// Block widgets (the things the message body stacks vertically — text
// paragraphs, tool-call bars, reasoning cards, artifact cards, sandbox
// artifacts, info status bars, image grids, attachment chips, ask-user
// cards, etc.) MUST render with NO external margin. Callers (the layout
// methods _buildClassicLayout / _buildContentBlocksLayout) own every gap
// between sibling blocks via explicit SizedBox using one of the constants
// below.
//
// This is the single source of truth for vertical spacing. Picking a
// constant by what the gap MEANS, not by pixel value, keeps the layout
// readable and prevents the "hidden margin under one widget that
// silently adds to a caller-side SizedBox" bug class (see
// b8e4414 + ce91f6b).

/// Gap between two sibling "block" rounds inside the same assistant
/// message — e.g. between a text paragraph and the next tool-call bar,
/// or between two consecutive tool-call bars across rounds.
const double _kBlockGap = 8;

/// Gap between a tool-call bar and its attached artifact cards, and
/// between consecutive artifact cards in the same stack. Smaller than
/// _kBlockGap because artifacts visually belong to the bar above them.
const double _kArtifactGap = 6;

/// Gap between sibling expandable cards stacked inside the expanded
/// section of a tool-call bar / info status bar. Same value as the
/// artifact gap by coincidence — they're conceptually different (this
/// is intra-bar list spacing, not block-to-block spacing).
const double _kCardStackGap = 6;

/// Per-image metadata describing how an image arrived in the chat and
/// an optional caption the AI attached to it.
class ImageMeta {
  const ImageMeta({required this.source, this.caption, this.model});

  /// "generated" (AI image tool) or "fetched" (fetch_image from URL).
  final String source;

  /// Optional short subtitle supplied by the AI, shown under the image.
  final String? caption;

  /// Human-readable image-generation model label (e.g. "FLUX 2 Klein 9B").
  /// Only set for generated images. Shown under the caption and as a corner
  /// badge on the image so it is always clear which generator produced it.
  final String? model;

  bool get isGenerated => source == 'generated';

  static List<ImageMeta>? decode(String? json) {
    if (json == null || json.isEmpty) return null;
    try {
      final decoded = jsonDecode(json);
      if (decoded is! List) return null;
      return decoded.whereType<Map>().map((raw) {
        final source = raw['source']?.toString() ?? 'generated';
        final captionRaw = raw['caption']?.toString().trim() ?? '';
        final modelRaw = raw['model']?.toString().trim() ?? '';
        return ImageMeta(
          source: source,
          caption: captionRaw.isEmpty ? null : captionRaw,
          model: modelRaw.isEmpty ? null : modelRaw,
        );
      }).toList();
    } catch (_) {
      return null;
    }
  }
}

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

class _RenderSegment {
  _RenderSegment._({this.text, this.sandboxArtifact})
      : toolCalls = <ToolCall>[],
        timeline = <_ToolTimelineEntry>[];

  _RenderSegment.text(String t) : this._(text: t);
  _RenderSegment.round() : this._();
  _RenderSegment.sandboxArtifact(SandboxArtifactPayload p)
      : this._(sandboxArtifact: p);

  final String? text;

  /// Set for sandbox-artifact segments — the inline downloadable file the
  /// AI handed to the user via send_file_to_user. Rendered as its own
  /// widget (image / pdf / text preview / file chip) between text blocks.
  final SandboxArtifactPayload? sandboxArtifact;

  final List<ToolCall> toolCalls;

  /// Interleaved reasoning/tool entries in true source order — the single
  /// source of truth for a round's contents. A run of
  /// `reasoning → tool → reasoning → tool → reasoning` (multiple streaming
  /// passes with no real text between them, including the final pass's
  /// reasoning *about* the results) accumulates here so the whole round
  /// renders as ONE collapsible bar with cards in the order they happened —
  /// instead of one bar per pass plus a peeled-out trailing reasoning card.
  final List<_ToolTimelineEntry> timeline;

  /// Reasoning strings in source order, derived from [timeline]. Used by the
  /// reasoning-only and `showToolCalls == false` render paths, which collapse
  /// a round's thinking into a single merged reasoning card.
  List<String> get reasoningTexts =>
      timeline.where((e) => e.isReasoning).map((e) => e.reasoning!).toList();

  bool get isText => text != null;
  bool get isSandboxArtifact => sandboxArtifact != null;
  bool get hasContent => timeline.isNotEmpty;
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
    this.imageMetas,
    this.attachments,
    this.imageCostEur,
    this.imageGeneratedAt,
    this.onAskUserAnswer,
    this.userMessageActions = const <MessageBubbleAction>[],
    this.useSharedSelectionArea = false,
    this.status,
    this.lastError,
    this.onRetryPending,
    this.onContinueGeneration,
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

  /// Per-image metadata aligned with [images]. Distinguishes fetched vs
  /// generated and carries the AI-supplied caption rendered under each image.
  final List<ImageMeta>? imageMetas;
  final List<DocumentAttachment>? attachments; // Document attachments
  final double? imageCostEur;
  final DateTime? imageGeneratedAt;

  /// Called when the user taps an option button on an ask_user tool call.
  /// When non-null, the bubble renders interactive option buttons extracted
  /// from the most recent ask_user tool call in this message.
  final ValueChanged<String>? onAskUserAnswer;

  /// Actions shown in a popup menu on long-press for user messages.
  /// These are hidden by default and only appear on long-press, matching
  /// the UX pattern of ChatGPT, Gemini, etc.
  final List<MessageBubbleAction> userMessageActions;
  final bool useSharedSelectionArea;

  /// Local offline-delivery status. Only rendered for user messages. `null`
  /// behaves like [ChatMessageStatus.sent].
  final ChatMessageStatus? status;

  /// Last error text shown in the failed-status tooltip.
  final String? lastError;

  /// Called when the user taps the inline retry button on a failed message.
  final VoidCallback? onRetryPending;

  /// Called when the user taps the inline "Continue generation" button on
  /// an assistant message that was cut off mid-stream (status =
  /// [ChatMessageStatus.interrupted]). When null no button is rendered.
  final VoidCallback? onContinueGeneration;

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble> {
  /// Regex to find visual output blocks (`<chart>`, `<map>`, `<email>`,
  /// `<weather>`, `<news>`, `<image>`).
  static final RegExp _richBlockRegex = RegExp(
    r'<\s*(chart|map|email|weather|news|image|diff)\s*>([\s\S]*?)<\s*/\s*\1\s*>',
    multiLine: true,
    caseSensitive: false,
  );

  static final RegExp _visualBlockStartRegex = RegExp(
    r'<\s*(chart|map|email|weather|news|image|diff)\b',
    caseSensitive: false,
  );

  /// Matches `<diff>...</diff>` blocks embedded in tool results.
  static final RegExp _diffBlockRegex = RegExp(
    r'<\s*diff\s*>([\s\S]*?)<\s*/\s*diff\s*>',
    caseSensitive: false,
  );

  bool _isReasoningExpanded = false;
  final Map<String, bool> _blockExpanded = {};
  final Set<String> _expandedCards = {};
  bool _complexBubbleLogged = false;
  bool _showUserActions = false;
  static final String _kAiResponseFontFamilyDefault =
      GoogleFonts.arimo().fontFamily ?? 'Arimo';

  /// Returns the user-selected chat font family, falling back to the historic
  /// Arimo default when the user has explicitly picked the system font.
  String get _chatFontFamily {
    final resolved = resolveChatFontFamily(
      AppThemeService.instance.chatFontFamily,
    );
    return resolved ?? _kAiResponseFontFamilyDefault;
  }

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
    final allToolCalls = _collectAllToolCalls();
    final bool hasSources = allToolCalls.isNotEmpty;

    if (!hasSources && !hasActions) return const SizedBox.shrink();

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (hasActions) _buildActionButtons(iconFgColor, false),
        const Spacer(),
        if (hasSources) _buildSourcesBar(allToolCalls),
      ],
    );
  }

  /// Combine top-level tool calls with those nested in content blocks so the
  /// sources bar still surfaces citations after a multi-round response is
  /// finalized into blocks.
  List<ToolCall> _collectAllToolCalls() {
    final result = <ToolCall>[];
    final seenIds = <String>{};
    void add(ToolCall tc) {
      if (seenIds.add(tc.id)) result.add(tc);
    }

    final top = widget.toolCalls;
    if (top != null) {
      for (final tc in top) {
        add(tc);
      }
    }
    final blocks = widget.contentBlocks;
    if (blocks != null) {
      for (final block in blocks) {
        if (block.type == ContentBlockType.toolCalls &&
            block.toolCalls != null) {
          for (final tc in block.toolCalls!) {
            add(tc);
          }
        }
      }
    }
    return result;
  }

  Widget _buildUserActionButtons(Color iconFgColor) {
    final Color bgColor = Theme.of(context).scaffoldBackgroundColor;
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Container(
          // Match the AI action bar's fixed height on mobile so the two button
          // strips are visually the same size (AI row uses this constant too).
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
            children: widget.userMessageActions.map((action) {
              return Tooltip(
                message: action.tooltip,
                child: IconButton(
                  icon: Icon(
                    action.icon,
                    color: action.isEnabled
                        ? iconFgColor
                        : iconFgColor.withValues(alpha: 0.38),
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
                  onPressed: action.isEnabled
                      ? () {
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
    final stopwatch = Stopwatch()..start();

    final bool isUserMessage = widget.isUser;
    final Widget result = isUserMessage
        ? _buildUserBubble(context)
        : _buildAiBubble(context);

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

  Widget _buildUserBubble(BuildContext context) {
    const bool isUserMessage = true;
    const bool alignRight = true;

    final Color accentColor = Theme.of(context).colorScheme.primary;
    final Color bgColor = Theme.of(context).scaffoldBackgroundColor;
    final Color iconFgColor = Theme.of(context).resolvedIconColor;

    final double effectiveMaxWidth =
        widget.maxWidth ?? MediaQuery.of(context).size.width * 0.8;

    final EdgeInsetsGeometry containerPadding = const EdgeInsets.symmetric(
      horizontal: 14,
      vertical: 10,
    );

    final BoxDecoration decoration = BoxDecoration(
      color: accentColor.withValues(alpha: .8),
      borderRadius: BorderRadius.only(
        topLeft: const Radius.circular(16),
        topRight: const Radius.circular(16),
        bottomLeft: const Radius.circular(16),
        bottomRight: Radius.circular(widget.endsGroup ? 5 : 16),
      ),
      border: Border.all(color: iconFgColor.withValues(alpha: .3)),
    );

    final Widget bubbleContent = Container(
      margin: EdgeInsets.only(top: widget.startsNewGroup ? 10 : 2, bottom: 2),
      padding: containerPadding,
      decoration: decoration,
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: _buildClassicLayout(
          iconFgColor: iconFgColor,
          accentColor: accentColor,
          bgColor: bgColor,
          isUserMessage: isUserMessage,
          alignRight: alignRight,
          hasInfoStatusBar: false,
          hasVisibleToolCalls: false,
        ),
      ),
    );

    final bool hasUserActions = widget.userMessageActions.isNotEmpty;
    final Widget userBubble = hasUserActions
        ? GestureDetector(
            onTap: () => setState(() => _showUserActions = !_showUserActions),
            child: bubbleContent,
          )
        : bubbleContent;

    final bool hasUserImages =
        widget.images != null && widget.images!.isNotEmpty;
    final bool hideEmptyUserBubble =
        hasUserImages &&
        _stripAttachmentHeaderForUser(widget.message).trim().isEmpty;

    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: effectiveMaxWidth),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (hasUserImages) ...[
              _buildFramedUserImageGrid(_buildImagesGrid(widget.images!)),
              const SizedBox(height: 2),
            ],
            if (!hideEmptyUserBubble) userBubble,
            if (hasUserActions && _showUserActions)
              _buildUserActionButtons(iconFgColor),
            if (widget.status == ChatMessageStatus.pending ||
                widget.status == ChatMessageStatus.failed)
              _buildStatusIndicator(context),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusIndicator(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final t = Theme.of(context);
    final isFailed = widget.status == ChatMessageStatus.failed;
    final color = isFailed
        ? t.colorScheme.error
        : t.colorScheme.onSurface.withValues(alpha: .6);
    final icon = isFailed ? Icons.error_outline : Icons.schedule;
    final label = isFailed
        ? (loc?.messageFailed ?? 'Failed to send')
        : (loc?.messagePending ?? 'Will send when online');
    final tooltip = isFailed && widget.lastError != null
        ? '$label: ${widget.lastError}'
        : label;

    return Padding(
      padding: const EdgeInsets.only(top: 4, right: 2),
      child: Tooltip(
        message: tooltip,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: color),
              ),
            ),
            if (isFailed && widget.onRetryPending != null) ...[
              const SizedBox(width: 8),
              InkWell(
                onTap: widget.onRetryPending,
                borderRadius: BorderRadius.circular(4),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  child: Text(
                    loc?.messageRetry ?? 'Retry',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: t.colorScheme.primary,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildAiBubble(BuildContext context) {
    const bool isUserMessage = false;
    const bool alignRight = false;

    final Color accentColor = Theme.of(context).colorScheme.primary;
    final Color bgColor = Theme.of(context).scaffoldBackgroundColor;
    final Color iconFgColor = Theme.of(context).resolvedIconColor;

    final double effectiveMaxWidth =
        widget.maxWidth ?? MediaQuery.of(context).size.width * 0.8;

    final bool hasActions = widget.actions.isNotEmpty;

    final bool useContentBlocks =
        widget.contentBlocks != null && widget.contentBlocks!.isNotEmpty;

    final bool hasVisibleToolCalls =
        !useContentBlocks &&
        widget.showToolCalls &&
        widget.toolCalls != null &&
        widget.toolCalls!.isNotEmpty;

    final bool isWaitingForFirstTokens =
        widget.isReasoningStreaming &&
        (widget.message == 'Thinking...' || widget.message.isEmpty);
    final bool hasInfoStatusBar =
        !useContentBlocks &&
        (_hasReasoning || _hasModelInfo || isWaitingForFirstTokens) &&
        !hasVisibleToolCalls;

    final EdgeInsetsGeometry containerPadding = const EdgeInsets.symmetric(
      horizontal: 0,
      vertical: 2,
    );

    final Widget bubbleContent = Container(
      margin: EdgeInsets.only(top: widget.startsNewGroup ? 10 : 2, bottom: 2),
      padding: containerPadding,
      decoration: null,
      clipBehavior: Clip.none,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
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

    final bool showContinueButton = !widget.isUser &&
        !widget.isStreamingMessage &&
        widget.status == ChatMessageStatus.interrupted &&
        widget.onContinueGeneration != null;

    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: effectiveMaxWidth),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            bubbleContent,
            if (showContinueButton) _buildContinueButton(context, accentColor),
            _buildBottomBar(iconFgColor, hasActions),
          ],
        ),
      ),
    );
  }

  Widget _buildContinueButton(BuildContext context, Color accentColor) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 2),
      child: Tooltip(
        message:
            'This response was cut off. Tap to ask the model to keep going.',
        child: Material(
          color: accentColor.withValues(alpha: .10),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: accentColor.withValues(alpha: .35)),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: widget.onContinueGeneration,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 6,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.play_arrow_outlined,
                    size: 16,
                    color: accentColor,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'Continue generation',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: t.colorScheme.onSurface,
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
    // User messages render images above the bubble (see build()).
    final bool renderImagesInBubble = hasImages && !isUserMessage;

    // When streaming AND the model emitted text before any tool call started
    // (text is visible while tools are still pending/running), render the
    // text body above the tool-calls bar so chronological order is preserved.
    final bool streamingTextBeforeTools =
        hasVisibleToolCalls &&
        widget.isStreamingMessage &&
        stripToolCallBlocksForDisplay(widget.message).trim().isNotEmpty &&
        widget.toolCalls!.any(
          (t) =>
              t.status == ToolCallStatus.pending ||
              t.status == ToolCallStatus.running,
        );

    final Widget toolBarSection = !hasVisibleToolCalls
        ? const SizedBox.shrink()
        : Builder(
            builder: (_) {
              final cards = _buildArtifactCards(widget.toolCalls!);
              // Classic layout renders arrived images separately above, so the
              // loader grid here shows loaders only (includeArrived: false).
              final generatingGrid = _buildGeneratingImagesGrid(
                widget.toolCalls!,
                includeArrived: false,
              );
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildToolCallsBar(widget.toolCalls!),
                  if (cards.isNotEmpty) ...[
                    const SizedBox(height: _kArtifactGap),
                    ..._stackArtifactCards(cards),
                  ],
                  if (generatingGrid != null) ...[
                    const SizedBox(height: _kArtifactGap),
                    generatingGrid,
                  ],
                  const SizedBox(height: _kBlockGap),
                ],
              );
            },
          );

    final Widget messageBody = _buildMessageBody(
      iconFgColor: iconFgColor,
      bgColor: bgColor,
      isUserMessage: isUserMessage,
    );

    return [
      if (hasInfoStatusBar) ...[
        SizedBox(
          width: double.infinity,
          child: _buildInfoStatusBar(iconFgColor, accentColor),
        ),
        // Match the legacy 6-px gap that used to live inside the
        // info status bar's bottom margin. Caller owns the gap now.
        const SizedBox(height: _kCardStackGap),
      ],
      if (renderImagesInBubble && !placeQrImageAboveResponse) ...[
        _buildFramedUserImageGrid(_buildImagesGrid(widget.images!)),
        const SizedBox(height: _kBlockGap),
      ],
      if (widget.attachments != null && widget.attachments!.isNotEmpty) ...[
        _buildAttachmentsChips(widget.attachments!),
        const SizedBox(height: _kBlockGap),
      ],
      if (streamingTextBeforeTools) messageBody,
      if (hasVisibleToolCalls) toolBarSection,
      if (renderImagesInBubble && placeQrImageAboveResponse) ...[
        _buildFramedUserImageGrid(_buildImagesGrid(widget.images!)),
        const SizedBox(height: _kBlockGap),
      ],
      if (!streamingTextBeforeTools) messageBody,
      ..._buildAskUserOptions(),
    ];
  }

  Widget _buildFramedUserImageGrid(Widget child) {
    // No frame on user-uploaded images: the thumbnail already has its own
    // rounded border and an outer frame made the bubble look cluttered.
    return child;
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
      children.add(const SizedBox(height: _kBlockGap));
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

    // Live tool calls from the current streaming pass that aren't in blocks.
    final liveToolCalls = widget.showToolCalls &&
            widget.toolCalls != null &&
            widget.toolCalls!.isNotEmpty
        ? widget.toolCalls!
              .where((tc) => !blockToolCallIds.contains(tc.id))
              .map((tc) => ToolCall.fromJson(tc.toJson()))
              .toList()
        : <ToolCall>[];

    // Pre-process blocks into render segments. Text blocks act as separators.
    // Between any two text blocks, ALL reasoning blocks merge into one string
    // and ALL tool-calls collect into one list — so a run of reasoning+tool
    // emissions with no text between them renders as ONE collapsible bar.
    final segments = <_RenderSegment>[];
    _RenderSegment current = _RenderSegment.round();

    // A round holds everything between two real text blocks — all reasoning
    // and all tool calls, in source order. Reasoning is NEVER a separator
    // (only real, non-empty text is), so the final pass's reasoning *about*
    // the tool results stays in the round and renders as the last card inside
    // the one bar — not a peeled-out standalone card between the bar and the
    // answer. Empty rounds add nothing.
    void closeCurrentRound() {
      if (current.hasContent) segments.add(current);
      current = _RenderSegment.round();
    }

    // Trailing widget.message (streaming or finalized tail like an error)
    // computed up front so we know whether trailing text "ends" the last
    // round before live tools or appears after.
    var trailingText = stripToolCallBlocksForDisplay(widget.message).trim();
    if (trailingText.isNotEmpty && finalizedTextPrefix.isNotEmpty) {
      if (trailingText == finalizedTextPrefix) {
        trailingText = '';
      } else if (trailingText.startsWith('$finalizedTextPrefix\n\n')) {
        trailingText = trailingText
            .substring(finalizedTextPrefix.length)
            .trim();
      }
    }

    for (final block in blocks) {
      switch (block.type) {
        case ContentBlockType.reasoning:
          final r = block.text?.trim() ?? '';
          if (r.isNotEmpty) {
            // Reasoning that arrives AFTER tool calls in the same open round is
            // a later streaming pass thinking *about the tool results*
            // (buildRoundBlocks always emits a pass's reasoning BEFORE its
            // tools, so reasoning-after-tools can only come from a subsequent
            // pass / the appended final-pass reasoning). We keep it in the SAME
            // round — appended to the ordered timeline — so a run of
            // reasoning+tool emissions renders as ONE bar with cards in true
            // order, instead of one bar per pass. The trailing final-pass
            // reasoning stays here too, so it renders as the last card inside
            // the bar rather than as a separate card after it.
            current.timeline.add(_ToolTimelineEntry.reasoning(r));
          }
        case ContentBlockType.toolCalls:
          if (block.toolCalls != null && block.toolCalls!.isNotEmpty) {
            for (final raw in block.toolCalls!) {
              final tc = ToolCall.fromJson(raw.toJson());
              current.toolCalls.add(tc);
              current.timeline.add(_ToolTimelineEntry.tool(tc));
            }
          }
        case ContentBlockType.text:
          // Strip Kimi tool-call special tokens / dangling `<` at RENDER time,
          // exactly like the trailing-text path above. The desktop send path
          // strips before committing the block, but mobile (and any block
          // already persisted raw in the cache) can still carry a lone `<`
          // text block — this guarantees it never renders as a stray `<`
          // line above a tool-call bar, on every platform.
          final t = stripToolCallBlocksForDisplay(block.text ?? '').trim();
          // A text block that strips to nothing (e.g. a lone `<` junk block a
          // Kimi multiplex leaks between two tool-call sections) is NOT a real
          // separator. Closing the round on it would split one logical tool
          // round into several bars — round 1 of `web_search ×4 → text → …`
          // rendering as four bars instead of one `web_search (4×)`. Skip it
          // (mirroring the trailing-text `isNotEmpty` guard) so adjacent
          // tool-call blocks still merge into a single bar.
          if (t.isEmpty) break;
          closeCurrentRound();
          segments.add(_RenderSegment.text(t));
        case ContentBlockType.sandboxArtifact:
          // Sandbox artifacts are first-class inline blocks. Close the
          // current reasoning/tool round so the artifact appears between
          // the round above it and any subsequent text, in source order.
          closeCurrentRound();
          final p = block.sandboxArtifact;
          if (p != null) segments.add(_RenderSegment.sandboxArtifact(p));
      }
    }

    // Trailing text acts as a separator before any live tool calls, just
    // like a text content block would.
    if (trailingText.isNotEmpty) {
      closeCurrentRound();
      segments.add(_RenderSegment.text(trailingText));
    }

    if (liveToolCalls.isNotEmpty) {
      current.toolCalls.addAll(liveToolCalls);
      for (final tc in liveToolCalls) {
        current.timeline.add(_ToolTimelineEntry.tool(tc));
      }
    }
    closeCurrentRound();

    // Render segments.
    var hasRenderedMainContent = false;

    void renderRound(_RenderSegment seg) {
      if (!seg.hasContent) return;
      // Reasoning-only round: standalone collapsible reasoning card.
      // _buildBlockReasoning has no margin, so the trailing gap below
      // the card lives here. `_kCardStackGap` matches the legacy baked-
      // in 6 px tail.
      if (seg.toolCalls.isEmpty) {
        final reasoning = seg.reasoningTexts.join('\n\n');
        if (reasoning.isEmpty) return;
        children.add(_buildBlockReasoning(reasoning, accentColor));
        children.add(const SizedBox(height: _kCardStackGap));
        hasRenderedMainContent = true;
        return;
      }
      // Tool-calls round: one bar with merged reasoning + all tools.
      if (!widget.showToolCalls) {
        final reasoning = seg.reasoningTexts.join('\n\n');
        if (reasoning.isNotEmpty) {
          children.add(_buildBlockReasoning(reasoning, accentColor));
          children.add(const SizedBox(height: _kCardStackGap));
          hasRenderedMainContent = true;
        }
        return;
      }
      // The ordered timeline (reasoning/tool interleaved in source order) drives
      // the bar's cards, so they render in the order they happened — including
      // the trailing final-pass reasoning as the last card.
      final timeline = seg.timeline;
      if (hasRenderedMainContent) {
        children.add(const SizedBox(height: _kBlockGap));
      }
      children.add(
        _buildToolCallsBar(
          seg.toolCalls,
          isContentBlock: true,
          contentBlockTimeline: timeline,
        ),
      );
      // Match the gap above the bar (`_kBlockGap`) — only insert the
      // `_kArtifactGap` bar→artifacts spacer when there ARE artifacts,
      // so the gap below the bar stays symmetric with the gap above
      // when no artifacts are attached. (Previously a 6-px spacer always
      // sat between the bar and the artifact slot AND an 8-px spacer
      // sat after, stacking to 14 px below while the gap above stayed
      // at 8 — see commits ce91f6b + b8e4414.)
      final artifactCards = _buildArtifactCards(seg.toolCalls);
      if (artifactCards.isNotEmpty) {
        children.add(const SizedBox(height: _kArtifactGap));
        children.addAll(_stackArtifactCards(artifactCards));
      }
      // While any generate_image call in this round is still running, render a
      // single unified grid (arrived images + loader tiles) in place of the
      // normal image grid, so the images don't reflow as loaders are replaced.
      final generatingGrid = _buildGeneratingImagesGrid(
        seg.toolCalls,
        includeArrived: true,
      );
      if (generatingGrid != null) {
        children.add(const SizedBox(height: _kArtifactGap));
        children.add(generatingGrid);
        children.add(const SizedBox(height: _kBlockGap));
        hasRenderedMainContent = true;
        insertedImage = true;
        return;
      }
      children.add(const SizedBox(height: _kBlockGap));
      hasRenderedMainContent = true;
      // Image insertion right after the round that produced it.
      if (hasImages && !insertedImage) {
        final hasImageResult = seg.toolCalls.any((tc) {
          final r = tc.result;
          return r != null &&
              (r.startsWith('IMAGE:') || r.startsWith('IMAGE_DATA:'));
        });
        if (hasImageResult) {
          children.add(_buildImagesGrid(widget.images!));
          children.add(const SizedBox(height: _kBlockGap));
          insertedImage = true;
        }
      }
    }

    for (final seg in segments) {
      if (seg.isText) {
        children.addAll(
          _buildTextParagraphs(
            text: seg.text!,
            textColor: iconFgColor,
            bgColor: bgColor,
          ),
        );
        hasRenderedMainContent = true;
      } else if (seg.isSandboxArtifact) {
        if (hasRenderedMainContent) {
          children.add(const SizedBox(height: _kArtifactGap));
        }
        children.add(SandboxArtifactBlock(payload: seg.sandboxArtifact!));
        children.add(const SizedBox(height: _kArtifactGap));
        hasRenderedMainContent = true;
      } else {
        renderRound(seg);
      }
    }

    if (hasImages && !insertedImage) {
      children.add(_buildImagesGrid(widget.images!));
      children.add(const SizedBox(height: _kBlockGap));
    }

    // ask_user interactive options.
    children.addAll(_buildAskUserOptions());

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

  /// Renders interleaved markdown + rich `<chart>` / `<map>` / `<email>`
  /// / `<weather>` / `<news>` / `<image>` blocks. Returns ONE Column —
  /// no external margin. The `Padding(symmetric(vertical: 4))` on each
  /// inner MarkdownMessage is internal breathing room, not a layout
  /// gap (see `_buildBlockText`). Callers control gaps to neighbouring
  /// blocks via `_kBlockGap`.
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
              wrapWithSelectionArea: !widget.useSharedSelectionArea,
              fontFamily: _chatFontFamily,
              paragraphFontSize: AppThemeService.instance.chatFontSize,
            ),
          ),
        );
      }

      final blockType = match.group(1)!.toLowerCase();
      final blockJson = match.group(2)!.trim();

      try {
        if (blockType == 'diff') {
          final parsed = _tryParseJson(blockJson);
          if (parsed is! Map<String, dynamic>) {
            throw const FormatException('Expected JSON object');
          }
          widgets.add(_buildDiffBlock(parsed));
        } else if (blockType == 'map') {
          widgets.add(MapBlockWidget(jsonString: blockJson));
        } else if (blockType == 'email') {
          final parsed = _tryParseJson(blockJson);
          if (parsed is! Map<String, dynamic>) {
            throw const FormatException('Expected JSON object');
          }
          widgets.add(_buildEmailBlock(parsed));
        } else if (blockType == 'weather') {
          final parsed = _tryParseJson(blockJson);
          if (parsed is! Map<String, dynamic>) {
            throw const FormatException('Expected JSON object');
          }
          widgets.add(WeatherBlockWidget(data: parsed));
        } else if (blockType == 'news') {
          final parsed = _tryParseJson(blockJson);
          if (parsed is! Map<String, dynamic>) {
            throw const FormatException('Expected JSON object');
          }
          widgets.add(_buildNewsBlock(parsed));
        } else if (blockType == 'image') {
          final parsed = _tryParseJson(blockJson);
          if (parsed is! Map<String, dynamic>) {
            throw const FormatException('Expected JSON object');
          }
          widgets.add(_buildImageBlock(parsed));
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
            wrapWithSelectionArea: !widget.useSharedSelectionArea,
            fontFamily: _chatFontFamily,
            paragraphFontSize: AppThemeService.instance.chatFontSize,
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
            wrapWithSelectionArea: !widget.useSharedSelectionArea,
            fontFamily: _chatFontFamily,
            paragraphFontSize: AppThemeService.instance.chatFontSize,
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: widgets,
    );
  }

  Widget _buildDiffBlock(Map<String, dynamic> data) {
    return DiffWidget(
      before: data['before'] as String? ?? '',
      after: data['after'] as String? ?? '',
      title: data['title'] as String?,
      type: data['type'] as String?,
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
                if (to.isNotEmpty) _emailField('To', to, colorScheme),
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
                label: Text(AppLocalizations.of(context)!.openInMailApp),
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
              style: TextStyle(fontSize: 13, color: colorScheme.onSurface),
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

  /// Renders a `<news>` block as a list of news cards (thumbnail, title,
  /// publisher · age, description, tap-to-open).
  Widget _buildNewsBlock(Map<String, dynamic> data) {
    final rawItems = data['items'];
    final items = <Map<String, dynamic>>[];
    if (rawItems is List) {
      for (final entry in rawItems) {
        if (entry is Map) {
          items.add(Map<String, dynamic>.from(entry));
        }
      }
    }
    if (items.isEmpty) {
      return const SizedBox.shrink();
    }

    final colorScheme = Theme.of(context).colorScheme;
    final cards = <Widget>[];
    for (int i = 0; i < items.length; i++) {
      cards.add(_NewsCard(item: items[i], colorScheme: colorScheme));
      if (i < items.length - 1) {
        cards.add(const SizedBox(height: 10));
      }
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: cards,
      ),
    );
  }

  /// Renders an `<image>` block as a display-only image card.
  ///
  /// This is intentionally separate from the `fetch_image` tool path:
  /// - `<image>` = render-only output tag (no fetch/persist side effects)
  /// - `fetch_image` = tool pipeline for fetch/store/vision workflows
  Widget _buildImageBlock(Map<String, dynamic> data) {
    final rawUrl = (data['url'] ?? data['image_url'] ?? data['src'] ?? '')
        .toString()
        .trim();
    final caption = (data['caption'] ?? '').toString().trim();
    final source = (data['source'] ?? data['credit'] ?? '').toString().trim();

    final uri = Uri.tryParse(rawUrl);
    final validHttp =
        uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
    if (!validHttp) {
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Theme.of(
            context,
          ).colorScheme.errorContainer.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          'image parse error: invalid or missing http(s) url',
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.error,
          ),
        ),
      );
    }

    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.6),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(11)),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => _openImagePreview(
                  imageSource: rawUrl,
                  images: [rawUrl],
                  index: 0,
                ),
                child: Image.network(
                  rawUrl,
                  width: double.infinity,
                  fit: BoxFit.fitWidth,
                  frameBuilder: (context, child, frame, wasSync) {
                    if (frame == null) {
                      return Container(
                        height: 180,
                        color: colorScheme.surfaceContainerHighest,
                        alignment: Alignment.center,
                        child: const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      );
                    }
                    return child;
                  },
                  errorBuilder: (context, error, stackTrace) => Container(
                    height: 120,
                    color: colorScheme.surfaceContainerHighest,
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.broken_image_outlined,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (caption.isNotEmpty || source.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (caption.isNotEmpty)
                    Text(
                      caption,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: colorScheme.onSurface,
                      ),
                    ),
                  if (source.isNotEmpty) ...[
                    if (caption.isNotEmpty) const SizedBox(height: 2),
                    Text(
                      source,
                      style: TextStyle(
                        fontSize: 12,
                        color: colorScheme.onSurface.withValues(alpha: 0.65),
                      ),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// Renders a text content block as a MarkdownMessage.
  ///
  /// The `Padding(symmetric(vertical: 4))` is intentional internal
  /// padding around the markdown — it gives text blocks breathing room
  /// against the bubble background and acts as part of the block's own
  /// presentation, NOT as a between-blocks layout gap. Callers still
  /// add `_kBlockGap` between text and other blocks.
  Widget _buildBlockText(String text, Color textColor, Color bgColor) {
    // Check for embedded visual blocks (<chart>/<map>/<email>/<weather>/<news>/<image>)
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
        wrapWithSelectionArea: !widget.useSharedSelectionArea,
        fontFamily: _chatFontFamily,
        paragraphFontSize: AppThemeService.instance.chatFontSize,
      ),
    );
  }

  List<Widget> _buildTextParagraphs({
    required String text,
    required Color textColor,
    required Color bgColor,
  }) {
    final String trimmed = text.trim();
    if (trimmed.isEmpty) {
      return const <Widget>[];
    }

    if (_hasVisualBlocks(trimmed)) {
      return <Widget>[
        _buildVisualContent(
          content: trimmed,
          textColor: textColor,
          bgColor: bgColor,
        ),
      ];
    }

    return <Widget>[_buildBlockText(trimmed, textColor, bgColor)];
  }

  /// Renders a reasoning content block as an expandable card. Renders
  /// NO external margin — callers control the gap below the card via
  /// SizedBox (typically `_kCardStackGap` or `_kBlockGap`).
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
  ///
  /// Renders NO external margin — callers control the gap below the bar
  /// via SizedBox using the `_kBlockGap` constant.
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
        : _hasReasoning
        ? (isStreaming ? 'Reasoning...' : 'Reasoning')
        : 'Model Info';
    final Color barAccent = accentColor;

    return SelectionContainer.disabled(
      child: Container(
        width: double.infinity,
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
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
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
                      Icon(
                        _hasReasoning
                            ? Icons.psychology
                            : Icons.smart_toy_outlined,
                        size: 14,
                        color: barAccent,
                      ),
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
                    if (_hasReasoning && _hasModelInfo)
                      const SizedBox(height: _kCardStackGap),
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
      ),
    );
  }

  /// Stack expandable cards inside an expanded section, inserting
  /// `_kCardStackGap` after every card. Used to be implicit via a baked
  /// `margin: only(bottom: 6)` on each card; the explicit helper makes
  /// the spacing live at the layout layer where it belongs and matches
  /// the visual behavior of master HEAD (every card has a 6 px tail).
  List<Widget> _stackCards(List<Widget> cards) {
    if (cards.isEmpty) return cards;
    final out = <Widget>[];
    for (final card in cards) {
      out.add(card);
      out.add(const SizedBox(height: _kCardStackGap));
    }
    return out;
  }

  /// Reusable expandable card matching function_calling client design.
  ///
  /// Renders NO external margin. When stacking multiple cards in a
  /// column the caller must insert `SizedBox(height: _kCardStackGap)`
  /// between siblings (or pass them through `_stackCards`); when using
  /// a card as a standalone message-body block the caller must provide
  /// a `_kBlockGap` spacer relative to neighbouring blocks. Previously
  /// this widget baked a `margin: only(bottom: 6)` which silently
  /// stacked with any caller-side spacer, producing asymmetric gaps
  /// that were very hard to trace (see commit b8e4414).
  Widget _buildExpandableCard({
    required String key,
    required IconData icon,
    required String label,
    required String preview,
    required String expandedContent,
    required Color accentColor,
    bool isRunning = false,
    Widget? expandedWidget,
  }) {
    final bool cardExpanded = _expandedCards.contains(key);

    return SelectionContainer.disabled(
      child: Container(
        width: double.infinity,
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
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
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
                child:
                    expandedWidget ??
                    SelectableText(
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

  /// Renders inline artifact cards for artifact_manager tool calls, so users
  /// can re-open the artifact panel after closing it (Claude.ai style).
  ///
  /// Cards render NO external padding — callers must stack them through
  /// `_stackArtifactCards` (or insert `_kArtifactGap` spacers manually)
  /// so the artifact-to-artifact spacing lives in the layout, not in
  /// this builder. Previously every card was wrapped in
  /// `Padding(bottom: 6)`, which silently added a 6 px tail after the
  /// last card on top of whatever spacer the caller appended.
  List<Widget> _buildArtifactCards(List<ToolCall> toolCalls) {
    if (!kFeatureArtifacts) return const [];
    final cards = <Widget>[];
    for (final tc in toolCalls) {
      // Render error ToolCalls as a visible error chip so silent failures
      // (malformed tag, RLS denial, network error) surface to the user
      // instead of producing a mysteriously empty chat bubble.
      if (tc.status == ToolCallStatus.error &&
          (tc.name == 'artifact_manager' || tc.name == 'typst_compile')) {
        final result = tc.result ?? 'Unknown error';
        cards.add(_ArtifactErrorCard(toolName: tc.name, message: result));
        continue;
      }
      if (tc.status != ToolCallStatus.completed) continue;

      String artifactId = '';
      String title = '';
      String type = '';

      if (tc.name == 'artifact_manager') {
        final args = tc.arguments;
        final action = args['action'] as String? ?? '';
        if (action != 'create' && action != 'rewrite') continue;
        artifactId = args['artifact_id'] as String? ?? '';
        if (artifactId.isEmpty) continue;
        title = args['title'] as String? ?? artifactId;
        type = args['type'] as String? ?? '';
      } else if (tc.name == 'typst_compile') {
        final args = tc.arguments;
        artifactId = args['artifact_id'] as String? ?? '';
        if (artifactId.isEmpty) continue;
        final rawTitle = args['title'];
        title = (rawTitle is String && rawTitle.trim().isNotEmpty)
            ? rawTitle.trim()
            : artifactId;
        type = 'typst';
      } else {
        continue;
      }

      // Parse "version: N" from the tool result so each chip can open the
      // exact snapshot that was produced at this point in the chat.
      int? version;
      final result = tc.result;
      if (result != null) {
        final match = RegExp(r'version:\s*(\d+)').firstMatch(result);
        if (match != null) {
          version = int.tryParse(match.group(1) ?? '');
        }
      }

      cards.add(
        _ArtifactInlineCard(
          artifactId: artifactId,
          title: title,
          type: type,
          authoredVersion: version,
        ),
      );
    }
    return cards;
  }

  /// Wrap a list of artifact cards into one cohesive "artifact stack":
  /// a `_kArtifactGap` after every card, including the last one, so the
  /// stack reads as a single visual unit attached to the tool-call bar
  /// above it. Callers add a separate `_kBlockGap` AFTER the stack to
  /// separate it from the next block in the message body. Matches the
  /// legacy baked-in `Padding(bottom: 6)` per-card behaviour for visual
  /// parity with master HEAD.
  List<Widget> _stackArtifactCards(List<Widget> cards) {
    if (cards.isEmpty) return cards;
    final out = <Widget>[];
    for (final card in cards) {
      out.add(card);
      out.add(const SizedBox(height: _kArtifactGap));
    }
    return out;
  }

  /// Returns a self-contained tool-calls bar (the pill with the
  /// "Tools…" header + the expandable list of call cards). Renders NO
  /// external margin — callers must wrap with `SizedBox(height:
  /// _kBlockGap)` (and `_kArtifactGap` for any attached artifact stack)
  /// for spacing relative to sibling blocks. Re-adding a hidden margin
  /// here was the bug fixed in commit b8e4414.
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
      final uniqueNames = toolCalls.map((t) => t.name).toList();
      final distinct = uniqueNames.toSet();
      if (toolCalls.length == 1) {
        label = uniqueNames.first;
      } else if (distinct.length == 1) {
        label = '${uniqueNames.first} (${toolCalls.length}×)';
      } else if (distinct.length <= 3) {
        final counts = <String, int>{};
        for (final n in uniqueNames) {
          counts[n] = (counts[n] ?? 0) + 1;
        }
        label = counts.entries
            .map((e) => e.value > 1 ? '${e.key} (${e.value}×)' : e.key)
            .join(', ');
      } else {
        label = '${toolCalls.length} tool calls';
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

    final bar = SelectionContainer.disabled(
      child: Container(
        width: double.infinity,
        // No baked-in margin — see the doc comment on
        // `_buildToolCallsBar`. Callers own the gap below the bar.
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
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
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
                  ],
                ),
              ),
            ),
            if (isExpanded)
              Padding(
                padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  // Each card carries no margin (see _buildExpandableCard);
                  // _stackCards inserts a `_kCardStackGap` spacer after every
                  // card, preserving the trailing 6 px below the last card
                  // that the old per-card margin used to add (kept for
                  // visual parity with master HEAD).
                  children: _stackCards([
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
                            key:
                                'tool_${effectiveTimeline[ti].toolCall!.id}_$ti',
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
                            expandedWidget: _buildToolCallExpandedWidget(
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
                          expandedWidget: _buildToolCallExpandedWidget(
                            toolCalls[i],
                          ),
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
                  ]),
                ),
              ),
          ],
        ),
      ),
    );

    final diffWidgets = _extractNoteDiffWidgets(toolCalls);
    if (diffWidgets.isEmpty) return bar;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [bar, const SizedBox(height: 4), ...diffWidgets],
    );
  }

  List<Widget> _extractNoteDiffWidgets(List<ToolCall> toolCalls) {
    final result = <Widget>[];
    for (final tc in toolCalls) {
      if (tc.name != 'notes' || tc.result == null) continue;
      for (final match in _diffBlockRegex.allMatches(tc.result!)) {
        try {
          final data = jsonDecode(match.group(1)!) as Map<String, dynamic>;
          result.add(
            DiffWidget(
              before: data['before'] as String? ?? '',
              after: data['after'] as String? ?? '',
              title: data['title'] as String?,
              type: data['type'] as String?,
            ),
          );
        } catch (_) {}
      }
    }
    return result;
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

  /// Builds a plain-formatted expanded view for a tool call. No syntax
  /// highlighting — just labelled sections with monospace containers so
  /// the raw `code` / stdout / stderr stay readable instead of showing
  /// as a single escape-ridden line.
  Widget _buildToolCallExpandedWidget(ToolCall toolCall) {
    final sections = <Widget>[];

    final args = Map<String, dynamic>.from(toolCall.arguments);
    final rawCode = args.remove('code');
    final String? codeArg = rawCode is String && rawCode.isNotEmpty
        ? rawCode
        : null;

    if (codeArg != null) {
      sections.add(_buildToolSection(label: 'code', body: codeArg, mono: true));
    }

    args.forEach((k, v) {
      if (v == null) return;
      if (v is String) {
        final mono = v.contains('\n') || v.length > 80;
        sections.add(_buildToolSection(label: k, body: v, mono: mono));
      } else if (v is num || v is bool) {
        sections.add(_buildToolSection(label: k, body: v.toString()));
      } else {
        String pretty;
        try {
          pretty = const JsonEncoder.withIndent('  ').convert(v);
        } catch (_) {
          pretty = v.toString();
        }
        sections.add(_buildToolSection(label: k, body: pretty, mono: true));
      }
    });

    final result = toolCall.result;
    if (result != null && result.isNotEmpty) {
      sections.addAll(_buildToolResultSections(toolCall, result));
    } else if (toolCall.status == ToolCallStatus.running ||
        toolCall.status == ToolCallStatus.pending) {
      sections.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Text(
            'Running…',
            style: TextStyle(
              fontSize: 12,
              fontStyle: FontStyle.italic,
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ),
      );
    }

    if (sections.isEmpty) {
      return Text(
        'No details.',
        style: TextStyle(
          fontSize: 12,
          fontStyle: FontStyle.italic,
          color: Theme.of(
            context,
          ).colorScheme.onSurface.withValues(alpha: 0.6),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: sections,
    );
  }

  Widget _buildToolSection({
    required String label,
    required String body,
    bool mono = false,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final labelColor = colorScheme.onSurface.withValues(alpha: 0.7);
    final bodyColor = colorScheme.onSurface.withValues(alpha: 0.85);

    final Widget bodyWidget = mono
        ? Container(
            width: double.infinity,
            margin: const EdgeInsets.only(top: 4),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: colorScheme.onSurface.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: colorScheme.onSurface.withValues(alpha: 0.08),
              ),
            ),
            child: SelectableText(
              body,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                height: 1.4,
                color: bodyColor,
              ),
            ),
          )
        : Padding(
            padding: const EdgeInsets.only(top: 2),
            child: SelectableText(
              body,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: bodyColor,
              ),
            ),
          );

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: labelColor,
              letterSpacing: 0.3,
            ),
          ),
          bodyWidget,
        ],
      ),
    );
  }

  List<Widget> _buildToolResultSections(ToolCall toolCall, String result) {
    // Strip <diff> blocks — rendered separately as DiffWidget cards.
    final displayResult = result.replaceAll(_diffBlockRegex, '').trim();
    if (displayResult.isEmpty) return const [];

    final stdoutMarker = RegExp(r'^--- stdout ---\s*$', multiLine: true);
    final stderrMarker = RegExp(r'^--- stderr ---\s*$', multiLine: true);
    final stdoutMatch = stdoutMarker.firstMatch(displayResult);
    final stderrMatch = stderrMarker.firstMatch(displayResult);

    if (stdoutMatch != null) {
      final header = displayResult.substring(0, stdoutMatch.start).trim();
      final stdoutStart = stdoutMatch.end;
      final stdoutEnd = stderrMatch?.start ?? displayResult.length;
      final stdout = displayResult.substring(stdoutStart, stdoutEnd).trim();
      final stderr = stderrMatch != null
          ? displayResult.substring(stderrMatch.end).trim()
          : '';

      final out = <Widget>[];
      if (header.isNotEmpty) {
        out.add(_buildToolSection(label: 'result', body: header));
      }
      out.add(
        _buildToolSection(
          label: 'stdout',
          body: stdout.isEmpty ? '(empty)' : stdout,
          mono: true,
        ),
      );
      if (stderr.isNotEmpty) {
        out.add(_buildToolSection(label: 'stderr', body: stderr, mono: true));
      }
      return out;
    }

    final isError =
        toolCall.status == ToolCallStatus.error ||
        displayResult.startsWith('Error:');
    return [
      _buildToolSection(
        label: isError ? 'error' : 'result',
        body: displayResult,
        mono: true,
      ),
    ];
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

    // Strip <diff> blocks so raw JSON doesn't appear in the collapsed preview.
    final preview = result.replaceAll(_diffBlockRegex, '').trim();
    if (preview.isEmpty) return null;
    return _truncatePreview(preview, 70);
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
        final urls = urlRegex
            .allMatches(tool.result!)
            .map((m) => m.group(1)!)
            .toList();
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
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.7,
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
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: sources.length,
                    itemBuilder: (ctx, index) {
                      final source = sources[index];
                      return ListTile(
                        leading: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: Image.network(
                            'https://www.google.com/s2/favicons?domain=${source['host']}&sz=32',
                            width: 20,
                            height: 20,
                            errorBuilder: (context, error, stackTrace) => Icon(
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
                          size: 22,
                          color: colorScheme.onSurfaceVariant,
                        ),
                        onTap: () async {
                          final url = Uri.tryParse(source['url']!);
                          if (url == null) return;
                          try {
                            final launched = await launchUrl(
                              url,
                              mode: LaunchMode.externalApplication,
                            );
                            if (!launched) {
                              await launchUrl(
                                url,
                                mode: LaunchMode.platformDefault,
                              );
                            }
                          } catch (_) {
                            // swallow: nothing to do if no handler available
                          }
                        },
                      );
                    },
                  ),
                ),
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
                    errorBuilder: (context, error, stackTrace) => Icon(
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

  /// Build ask_user interactive option buttons if applicable. Returns
  /// a list of widgets with NO external margin between them or after
  /// them — callers control the gap to neighbouring blocks (typically
  /// the ask_user card is the last block in the bubble).
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

  /// Human-readable generator model for the image at [index], or null when
  /// unknown (legacy images, user uploads, web-fetched images).
  String? _modelFor(int index) {
    final metas = widget.imageMetas;
    if (metas == null || index < 0 || index >= metas.length) return null;
    final model = metas[index].model?.trim();
    if (model == null || model.isEmpty) return null;
    return model;
  }

  /// A round can fan out N `generate_image` tool calls that produce N images.
  /// While ANY of them is still running we render a single unified grid —
  /// already-arrived images in their real tiles, still-running ones as loader
  /// tiles — laid out exactly like the final [_buildImagesGrid] so nothing
  /// reflows when a loader is swapped for the finished image.
  ///
  /// We deliberately do NOT gate on [MessageBubble.isStreamingMessage]: a
  /// `generate_image` call with status running/pending and no IMAGE result is
  /// in flight by definition, and the desktop streaming flag flips false during
  /// the tool-execution phase (so gating on it hid the loaders entirely). A
  /// finalized message has its stale tool calls flipped to error by
  /// [finalizeStaleToolCalls], so they won't match here.
  ///
  /// [includeArrived] folds already-finished images into this grid (content-
  /// blocks layout, where it replaces the normal grid). The classic layout
  /// renders arrived images separately, so it passes false (loaders only).
  ///
  /// Returns null when no image generation is in flight for [roundToolCalls].
  Widget? _buildGeneratingImagesGrid(
    List<ToolCall> roundToolCalls, {
    required bool includeArrived,
  }) {
    int runningCount = 0;
    int completedWithImage = 0;
    ToolCall? firstPending;
    for (final tc in roundToolCalls) {
      if (tc.name != 'generate_image') continue;
      final String? r = tc.result;
      final bool hasImage =
          r != null && (r.startsWith('IMAGE:') || r.startsWith('IMAGE_DATA:'));
      if (hasImage) {
        completedWithImage++;
        continue;
      }
      final bool running =
          tc.status == ToolCallStatus.running ||
          tc.status == ToolCallStatus.pending;
      if (running) {
        runningCount++;
        firstPending ??= tc;
      }
    }

    final List<String> arrived = includeArrived
        ? (widget.images ?? const <String>[])
        : const <String>[];
    final int arrivedCount = arrived.length;

    // Keep a loader for every generate_image that is still running AND for
    // every completed-with-result image whose bytes haven't been folded into
    // [widget.images] yet — the fetch/encrypt/upload step after the tool
    // result lands. This keeps the tile count stable (no reflow) and stops a
    // finished-but-not-yet-displayed image from briefly vanishing.
    final int unfetched = includeArrived
        ? (completedWithImage - arrivedCount).clamp(0, completedWithImage)
        : 0;
    final int loaderCount = runningCount + unfetched;
    if (loaderCount == 0) return null;
    final int total = arrivedCount + loaderCount;

    return LayoutBuilder(
      builder: (context, constraints) {
        final double maxWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.of(context).size.width * 0.8;

        // Single loader: follow the requested aspect ratio, like a lone AI
        // image renders at its natural ratio.
        if (total == 1) {
          final size = firstPending != null
              ? _pendingImageSize(firstPending.arguments)
              : MapEntry<double, String>(1024 / 768, '');
          final double height = (maxWidth / size.key).clamp(
            80.0,
            maxWidth * 1.9,
          );
          return _loaderTile(
            width: maxWidth,
            height: height,
            borderRadius: 12,
            label: size.value,
          );
        }

        // Multi: mirror _buildImagesGrid's Wrap layout exactly so arrived
        // images and loaders share one consistent grid.
        final int columns = total == 3 ? 3 : (maxWidth > 520 ? 3 : 2);
        final double tileWidth = ((maxWidth - ((columns - 1) * 8)) / columns)
            .clamp(90.0, 260.0);

        final List<Widget> cells = <Widget>[];
        for (int i = 0; i < arrived.length; i++) {
          final String src = arrived[i];
          cells.add(
            _captionedTile(
              imageSource: src,
              width: tileWidth,
              height: tileWidth,
              borderRadius: 10,
              model: _modelFor(i),
              onTap: () => _openImagePreview(
                imageSource: src,
                images: arrived,
                index: i,
              ),
            ),
          );
        }
        for (int i = 0; i < loaderCount; i++) {
          cells.add(
            _loaderTile(
              width: tileWidth,
              height: tileWidth,
              borderRadius: 10,
            ),
          );
        }

        return Wrap(spacing: 8, runSpacing: 8, children: cells);
      },
    );
  }

  /// A grey rounded loader tile for an image that is being *generated*. The
  /// sparkle icon + "Generating…" caption deliberately distinguish it from the
  /// plain spinner [_CachedImageThumbnail] shows while merely *fetching* an
  /// already-generated image from storage — so it's clear the AI is still
  /// creating the picture, not just downloading it.
  ///
  /// The caption text is shown only on tiles wide enough to fit it; [label]
  /// (a resolution / aspect hint) is appended on larger single tiles.
  Widget _loaderTile({
    required double width,
    required double height,
    required double borderRadius,
    String? label,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final Color fg = colorScheme.onSurface.withValues(alpha: 0.6);
    final bool roomForText = width >= 150 && height >= 110;
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Colors.grey.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_awesome, size: 18, color: fg),
            const SizedBox(height: 8),
            const SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            if (roomForText) ...[
              const SizedBox(height: 10),
              Text(
                AppLocalizations.of(context)?.generatingImage ?? 'Generating…',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: fg,
                ),
              ),
              if (label != null && label.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w400,
                    color: colorScheme.onSurface.withValues(alpha: 0.45),
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  /// Best-effort target size for a pending `generate_image` call: returns
  /// (aspectRatio = width / height, human label). Models express size via
  /// `resolution` ("1024x768"), `aspect_ratio` ("16:9"), or an `image_size`
  /// preset; the server falls back to landscape_4_3 when none is given.
  MapEntry<double, String> _pendingImageSize(Map<String, dynamic> args) {
    final resolution = args['resolution'];
    if (resolution is String) {
      final m = RegExp(r'(\d+)\s*[x×]\s*(\d+)').firstMatch(resolution);
      if (m != null) {
        final w = int.parse(m.group(1)!);
        final h = int.parse(m.group(2)!);
        if (w > 0 && h > 0) return MapEntry(w / h, '$w × $h');
      }
    }
    final aspectRatio = args['aspect_ratio'];
    if (aspectRatio is String) {
      final m = RegExp(r'(\d+)\s*[:x×]\s*(\d+)').firstMatch(aspectRatio);
      if (m != null) {
        final w = int.parse(m.group(1)!);
        final h = int.parse(m.group(2)!);
        if (w > 0 && h > 0) return MapEntry(w / h, aspectRatio);
      }
    }
    const presets = <String, List<int>>{
      'square_hd': [1024, 1024],
      'square': [512, 512],
      'portrait_4_3': [768, 1024],
      'portrait_16_9': [576, 1024],
      'landscape_4_3': [1024, 768],
      'landscape_16_9': [1024, 576],
    };
    final imageSize = args['image_size'];
    if (imageSize is String && presets.containsKey(imageSize)) {
      final dims = presets[imageSize]!;
      return MapEntry(dims[0] / dims[1], '${dims[0]} × ${dims[1]}');
    }
    return MapEntry(1024 / 768, '');
  }

  /// Renders the image grid (1, 2+1, or N-col Wrap) for the message.
  /// Renders NO external margin — callers add `_kBlockGap` after the
  /// grid to separate it from the next block.
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
            child: _captionedTile(
              imageSource: imageSource,
              width: squareSize,
              height: squareSize,
              borderRadius: 12,
              fit: BoxFit.contain,
              model: _modelFor(0),
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
          // User uploads render as a square preview (width == height) so the
          // aspect ratio stays predictable on both mobile and desktop.
          // Mobile stays compact (~140 px side); desktop gets a larger square
          // sized to ~45 % of the bubble's max width, clamped.
          if (widget.isUser) {
            final double userSquare = kPlatformMobile
                ? 140.0
                : (maxWidth * 0.45).clamp(200.0, 320.0);
            // Outer Column already right-aligns user messages via
            // CrossAxisAlignment.end — do NOT wrap in Align here, or the frame
            // stretches to full width and shows an asymmetric gap on the left.
            return _captionedTile(
              imageSource: imageSource,
              width: userSquare,
              height: userSquare,
              borderRadius: 12,
              fit: BoxFit.cover,
              model: _modelFor(0),
              onTap: () => _openImagePreview(
                imageSource: imageSource,
                images: images,
                index: 0,
              ),
            );
          }

          // AI-generated images render full bubble width and follow the
          // image's *real* aspect ratio (same as web-fetched <image> blocks),
          // instead of being cropped into a fixed-height box. A tall portrait
          // (e.g. 9:16 phone wallpaper) keeps its height; height is capped so a
          // freak panorama can't dominate the chat. Until the bytes decode, a
          // placeholder of the same width reserves space and shows a spinner,
          // then the tile resizes to the true ratio.
          return _captionedTile(
            imageSource: imageSource,
            width: maxWidth,
            height: maxWidth, // placeholder height before decode (square)
            borderRadius: 12,
            naturalAspect: true,
            maxNaturalHeight: maxWidth * 1.9,
            model: _modelFor(0),
            onTap: () => _openImagePreview(
              imageSource: imageSource,
              images: images,
              index: 0,
            ),
          );
        }

        // 3 images always render as a single 3-wide row — the 2+1 layout
        // from the generic mobile 2-column grid looks unbalanced.
        final int columns = images.length == 3 ? 3 : (maxWidth > 520 ? 3 : 2);
        final double tileWidth = ((maxWidth - ((columns - 1) * 8)) / columns)
            .clamp(90.0, 260.0);

        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: images.asMap().entries.map((entry) {
            final int index = entry.key;
            final String imageSource = entry.value;

            return _captionedTile(
              imageSource: imageSource,
              width: tileWidth,
              height: tileWidth,
              borderRadius: 10,
              model: _modelFor(index),
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

  Widget _captionedTile({
    required String imageSource,
    required double width,
    required double height,
    required double borderRadius,
    required VoidCallback onTap,
    String? model,
    BoxFit fit = BoxFit.cover,
    bool naturalAspect = false,
    double? maxNaturalHeight,
  }) {
    Widget thumbnail = _CachedImageThumbnail(
      imageDataUrl: imageSource,
      width: width,
      height: height,
      borderRadius: borderRadius,
      fit: fit,
      naturalAspect: naturalAspect,
      maxNaturalHeight: maxNaturalHeight,
      onTap: onTap,
    );

    // Right-click (desktop) / long-press (mobile) on a stored image opens a
    // context menu to delete it from storage. Skip data: URIs (QR codes,
    // base64 fallbacks) — there is no storage object to remove.
    if (!imageSource.startsWith('data:image/')) {
      thumbnail = GestureDetector(
        behavior: HitTestBehavior.translucent,
        onSecondaryTapDown: (d) =>
            _showImageContextMenu(d.globalPosition, imageSource),
        onLongPressStart: (d) =>
            _showImageContextMenu(d.globalPosition, imageSource),
        child: thumbnail,
      );
    }

    final hasModel = model != null && model.trim().isNotEmpty;
    if (!hasModel) return thumbnail;

    // The generator model is overlaid as a small pill in the bottom-right
    // corner of the image itself — the only place it is shown (no duplicate
    // caption row below the image). Works for single and multi-image grids.
    return Stack(
      children: [
        thumbnail,
        Positioned(
          right: 6,
          bottom: 6,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: width - 12),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.auto_awesome,
                    size: 10,
                    color: Colors.white.withValues(alpha: 0.9),
                  ),
                  const SizedBox(width: 3),
                  Flexible(
                    child: Text(
                      model,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 9,
                        fontWeight: FontWeight.w600,
                        height: 1.0,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
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
          models: [for (int i = 0; i < images.length; i++) _modelFor(i)],
        ),
        fullscreenDialog: true,
      ),
    );
  }

  /// Context menu shown on right-click / long-press of a stored chat image.
  /// Currently a single Delete action; deletion removes the encrypted object
  /// from storage (like the Media Manager) and the tile live-updates to
  /// "Image deleted" via [ImageStorageService.onImageDeleted].
  Future<void> _showImageContextMenu(Offset globalPosition, String path) async {
    final l = AppLocalizations.of(context)!;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;

    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        globalPosition & const Size(40, 40),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem<String>(
          value: 'delete',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.delete_outline, size: 18, color: Colors.red),
              const SizedBox(width: 8),
              Text(l.delete, style: const TextStyle(color: Colors.red)),
            ],
          ),
        ),
      ],
    );

    if (selected == 'delete' && mounted) {
      await _confirmDeleteImage(path);
    }
  }

  /// Confirms and deletes a stored image's encrypted object. Mirrors the Media
  /// Manager flow: warn (but still allow) when the image is referenced by
  /// chats, then delete. The tile repaints to "Image deleted" via the deletion
  /// broadcast, so no message mutation is needed here.
  Future<void> _confirmDeleteImage(String path) async {
    final l = AppLocalizations.of(context)!;

    List<ChatUsingImage> usedIn = const [];
    try {
      usedIn = await ImageStorageService.findChatsUsingImage(path);
    } catch (_) {
      // Best-effort: if the usage lookup fails, fall back to a plain confirm.
    }
    if (!mounted) return;

    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(l.deleteImageTitle),
            content: Text(
              usedIn.isNotEmpty
                  ? '${l.deleteImageShowDeleted}\n\n${l.deleteImageConfirm}'
                  : l.deleteImageBody,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(l.cancel),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                style: TextButton.styleFrom(foregroundColor: Colors.red),
                child: Text(usedIn.isNotEmpty ? l.deleteAnyway : l.delete),
              ),
            ],
          ),
        ) ??
        false;

    if (!confirmed || !mounted) return;

    try {
      await ImageStorageService.deleteEncryptedImage(path);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l.imageDeleted)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l.deleteFailed(e.toString()))));
      }
    }
  }

  /// Renders document attachment chips as a Wrap. Renders NO external
  /// margin — callers add `_kBlockGap` between the chip row and the
  /// next block.
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

  static final RegExp _attachmentHeaderRe = RegExp(
    r'^\d+ images? attached(?:, Documents: .+)?$',
  );

  String _stripAttachmentHeaderForUser(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return trimmed;
    final separatorIndex = trimmed.indexOf('\n\n');
    if (separatorIndex < 0) {
      if (_attachmentHeaderRe.hasMatch(trimmed) ||
          trimmed.startsWith('Documents: ')) {
        return '';
      }
      return text;
    }
    final header = trimmed.substring(0, separatorIndex).trim();
    if (_attachmentHeaderRe.hasMatch(header) ||
        header.startsWith('Documents: ')) {
      return trimmed.substring(separatorIndex + 2).trim();
    }
    return text;
  }

  Widget _buildMessageBody({
    required Color iconFgColor,
    required Color bgColor,
    required bool isUserMessage,
  }) {
    final displayText = isUserMessage
        ? _stripAttachmentHeaderForUser(widget.message)
        : stripToolCallBlocksForDisplay(widget.message);

    if (!isUserMessage &&
        (displayText.trim().isEmpty || displayText == 'Thinking...')) {
      return const SizedBox.shrink();
    }
    if (isUserMessage && displayText.trim().isEmpty) {
      return const SizedBox.shrink();
    }

    if (isUserMessage) {
      final List<Widget> children = <Widget>[];

      // Use plain Text so taps pass through to the GestureDetector
      // that toggles the action bar. Copy is available via the action bar.
      children.add(
        Text(
          displayText,
          style: TextStyle(
            color: iconFgColor,
            fontSize: AppThemeService.instance.chatFontSize,
            fontFamily: resolveChatFontFamily(
              AppThemeService.instance.chatFontFamily,
            ),
            height: 1.38,
          ),
        ),
      );

      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      );
    }

    final List<Widget> aiParagraphs = _buildTextParagraphs(
      text: displayText,
      textColor: iconFgColor,
      bgColor: bgColor,
    );
    if (aiParagraphs.isEmpty) {
      return const SizedBox.shrink();
    }
    if (aiParagraphs.length == 1) {
      return aiParagraphs.first;
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: aiParagraphs,
    );
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
    this.naturalAspect = false,
    this.maxNaturalHeight,
  });

  /// Can be either:
  /// - A Base64 data URL: "data:image/jpeg;base64,..."
  /// - A storage path: "user-id/uuid.enc"
  final String imageDataUrl;
  final double width;

  /// Used as a fixed tile height in the default (cropped) mode, and as the
  /// placeholder height while bytes are still loading in [naturalAspect] mode.
  final double height;
  final double borderRadius;
  final BoxFit fit;

  /// When true the tile renders at [width] and follows the decoded image's own
  /// aspect ratio (no cropping), capped at [maxNaturalHeight]. The decode-time
  /// [height] is only the placeholder size shown before the ratio is known.
  final bool naturalAspect;

  /// Upper bound on height in [naturalAspect] mode so an extreme portrait /
  /// panorama can't take over the chat. Ignored when [naturalAspect] is false.
  final double? maxNaturalHeight;

  final VoidCallback onTap;

  @override
  State<_CachedImageThumbnail> createState() => _CachedImageThumbnailState();
}

class _CachedImageThumbnailState extends State<_CachedImageThumbnail>
    with AutomaticKeepAliveClientMixin {
  Uint8List? _cachedBytes;
  bool _isLoading = true;

  /// True when the storage object 404'd — i.e. the image was deleted from the
  /// backend (a manual Media-Manager delete, or a purged bucket). Distinguished
  /// from a generic load failure so the tile can say "deleted" instead of a
  /// bare broken-image icon.
  bool _notFound = false;

  /// Intrinsic width/height of the decoded image. Only resolved (and only
  /// used) in [_CachedImageThumbnail.naturalAspect] mode.
  double? _aspectRatio;

  StreamSubscription<String>? _deletionSub;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadImage();
    // Live-swap to the "Image deleted" state the moment this exact storage
    // object is removed anywhere (chat right-click, Media Manager) — no reload
    // needed. Data: URIs have no storage object, so skip the subscription.
    if (!widget.imageDataUrl.startsWith('data:image/')) {
      _deletionSub = ImageStorageService.onImageDeleted.listen((deletedPath) {
        if (deletedPath == widget.imageDataUrl && mounted) {
          setState(() {
            _cachedBytes = null;
            _notFound = true;
            _isLoading = false;
          });
        }
      });
    }
  }

  @override
  void dispose() {
    _deletionSub?.cancel();
    super.dispose();
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
      // Detect a deleted/missing storage object (404) so the tile can show a
      // clear "Image deleted" state rather than a generic broken-image icon.
      // Mirrors the heuristic in EncryptedImageWidget.
      final errorStr = e.toString().toLowerCase();
      _notFound =
          errorStr.contains('not found') ||
          errorStr.contains('404') ||
          errorStr.contains('does not exist') ||
          errorStr.contains('object not found');
      if (kDebugMode) {
        debugPrint('Failed to load image: $e');
      }
    }

    // In natural-aspect mode, decode the intrinsic dimensions so the tile can
    // size itself to the real ratio instead of a placeholder square.
    if (widget.naturalAspect && _cachedBytes != null) {
      try {
        final codec = await ui.instantiateImageCodec(_cachedBytes!);
        final frame = await codec.getNextFrame();
        final img = frame.image;
        if (img.height > 0) {
          _aspectRatio = img.width / img.height;
        }
        img.dispose();
        codec.dispose();
      } catch (e) {
        if (kDebugMode) {
          debugPrint('Failed to decode image dimensions: $e');
        }
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

    // Resolve the height this tile should occupy. In natural-aspect mode we
    // follow the decoded ratio once it is known (capped), otherwise we fall
    // back to the placeholder square; in default mode it is always the fixed
    // tile height.
    final double renderHeight;
    if (widget.naturalAspect && _aspectRatio != null && _aspectRatio! > 0) {
      final double natural = widget.width / _aspectRatio!;
      final double cap = widget.maxNaturalHeight ?? double.infinity;
      renderHeight = natural > cap ? cap : natural;
    } else {
      renderHeight = widget.height;
    }

    // In natural-aspect mode the placeholder → real-image height change is
    // animated so the bubble grows/shrinks smoothly instead of snapping.
    Widget wrap(Widget child) {
      if (!widget.naturalAspect) return child;
      return AnimatedSize(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        alignment: Alignment.topCenter,
        child: child,
      );
    }

    if (_isLoading) {
      return wrap(
        Container(
          width: widget.width,
          height: renderHeight,
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
        ),
      );
    }

    if (_cachedBytes == null) {
      // Only show the text label when the tile is tall enough for icon + gap +
      // caption, so a small grid thumbnail can't overflow vertically.
      final bool showLabel = renderHeight >= 64;
      final Color fg = Theme.of(context).colorScheme.onSurfaceVariant;
      return wrap(
        Container(
          width: widget.width,
          height: renderHeight,
          decoration: BoxDecoration(
            color: Colors.grey.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(widget.borderRadius),
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _notFound ? Icons.image_not_supported_outlined : Icons.broken_image,
                  size: 32,
                  color: fg,
                ),
                if (showLabel) ...[
                  const SizedBox(height: 8),
                  Text(
                    _notFound ? 'Image deleted' : 'Failed to load',
                    style: TextStyle(
                      color: fg,
                      fontSize: 12,
                      fontStyle: _notFound
                          ? FontStyle.italic
                          : FontStyle.normal,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    return wrap(
      InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(widget.borderRadius),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(widget.borderRadius),
            child: Image.memory(
              _cachedBytes!,
              width: widget.width,
              height: renderHeight,
              fit: widget.fit,
              // Only constrain cacheWidth to preserve aspect ratio during
              // decode. Setting both cacheWidth AND cacheHeight distorts the
              // image before BoxFit.cover can crop it properly.
              cacheWidth: (widget.width * 2).toInt(),
              gaplessPlayback: true,
              errorBuilder: (context, error, stackTrace) {
                return Container(
                  width: widget.width,
                  height: renderHeight,
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
      ),
    );
  }
}

/// Compact artifact card shown inline in chat after artifact_manager calls.
/// Clicking it opens the artifact panel (Claude.ai-style UX).
///
/// The card is *reactive*: it always shows the latest current version of the
/// referenced artifact, looked up live from [ArtifactStorageService]. The
/// version originally captured when the assistant message was authored
/// ([authoredVersion]) is used only to show a subtle "(was vN)" hint when the
/// artifact has moved on, never as the primary label. This keeps old chat
/// bubbles in sync with the artifact's current state instead of advertising
/// stale snapshot numbers.
///
/// If the artifact has been deleted (e.g. by a regenerate rollback that
/// removed the version that created it), the card degrades to a disabled
/// "Artifact removed" state instead of dangling open a 404. While the
/// artifact has not yet been resolved (chat still loading, network in
/// flight) the card falls back to the authored title/version to avoid a
/// flash of "Removed".
class _ArtifactInlineCard extends StatefulWidget {
  const _ArtifactInlineCard({
    required this.artifactId,
    required this.title,
    required this.type,
    this.authoredVersion,
  });

  final String artifactId;

  /// Title captured at message-author time. Used as a fallback before the
  /// live artifact has been resolved, and as the title when the artifact
  /// has been deleted.
  final String title;

  /// Type captured at message-author time (e.g. `excalidraw`, `markdown`).
  /// Drives the icon and type label. Type can't change for an artifact id,
  /// so we don't need a live lookup for this.
  final String type;

  /// The artifact's version at the time the assistant message was authored.
  /// Used to render the "(was vN)" hint when the artifact has been rewritten
  /// since, and as the fallback label while the live lookup is in flight.
  final int? authoredVersion;

  @override
  State<_ArtifactInlineCard> createState() => _ArtifactInlineCardState();
}

class _ArtifactInlineCardState extends State<_ArtifactInlineCard> {
  /// Latest live snapshot of the artifact, or `null` until the first load
  /// resolves. Distinct from [_resolved] so we can tell "not loaded yet"
  /// (show authored fallback) from "loaded and confirmed missing" (show
  /// removed state).
  ArtifactDocument? _live;

  /// `true` once we've completed at least one resolution attempt — even if
  /// it returned `null`. Used to differentiate the initial loading state
  /// from a confirmed-deleted state.
  bool _resolved = false;

  StreamSubscription<void>? _changesSub;

  @override
  void initState() {
    super.initState();
    _refresh();
    _changesSub = ArtifactStorageService.changes.listen((_) => _refresh());
  }

  @override
  void dispose() {
    _changesSub?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final doc = await ArtifactStorageService.loadArtifactById(
        widget.artifactId,
      );
      if (!mounted) return;
      setState(() {
        _live = doc;
        _resolved = true;
      });
    } catch (_) {
      // Resolution failure is non-fatal — keep showing the authored fallback.
      if (!mounted) return;
      // Do NOT flip _resolved here. A transient network error must not
      // collapse the card into the "Removed" state. The next changes-stream
      // event (or a retry) can still upgrade us to a live snapshot.
    }
  }

  IconData get _icon {
    switch (widget.type) {
      case 'code':
        return Icons.code;
      case 'markdown':
        return Icons.article_outlined;
      case 'html':
        return Icons.html;
      case 'mermaid':
        return Icons.account_tree_outlined;
      case 'svg':
        return Icons.image_outlined;
      case 'technical_drawing':
        return Icons.architecture;
      case 'typst':
        return Icons.picture_as_pdf;
      case 'excalidraw':
        return Icons.brush_outlined;
      default:
        return Icons.description_outlined;
    }
  }

  String get _typeLabel {
    switch (widget.type) {
      case 'code':
        return 'Code';
      case 'markdown':
        return 'Document · MD';
      case 'html':
        return 'HTML';
      case 'mermaid':
        return 'Diagram · Mermaid';
      case 'svg':
        return 'Image · SVG';
      case 'technical_drawing':
        return 'Technical drawing';
      case 'typst':
        return 'Typst · PDF';
      case 'excalidraw':
        return 'Excalidraw sketch';
      default:
        return 'Artifact';
    }
  }

  Future<void> _open(BuildContext context) async {
    // Always try to resolve and activate the clicked artifact — even when the
    // panel is already showing something with a matching id. Users may have
    // multiple cards for the same artifact (e.g. create + rewrite) and expect
    // each click to refocus that artifact at the live version.
    //
    // loadArtifactById hits Supabase directly and does not depend on
    // ArtifactStorageService.activeChatId. The deferred setActiveChat() call
    // in RootWrapperDesktop runs ~2s after launch, so guarding on activeChatId
    // here would silently no-op for any tap that lands during that window —
    // exactly the "first start, artifact card does nothing" symptom.
    try {
      ArtifactDocument? match = await ArtifactStorageService.loadArtifactById(
        widget.artifactId,
      );
      final chatId = ArtifactStorageService.activeChatId;
      if (match == null && chatId != null && chatId.isNotEmpty) {
        match = (await ArtifactStorageService.loadArtifactsForChat(
          chatId,
        )).where((a) => a.id == widget.artifactId).firstOrNull;
      }

      if (match != null) {
        final current = ArtifactStorageService.activeArtifactNotifier.value;
        if (!identical(current, match)) {
          ArtifactStorageService.activeArtifactNotifier.value = match;
        }
      }
    } catch (_) {
      // Request open anyway below; resolution failures are non-fatal.
    }
    // Fire the open-request event last so the listener reads a fresh
    // active artifact. Using requestOpen() ensures repeated taps reopen the
    // sheet even when panelOpenNotifier is already true.
    //
    // Pass `version: null` so the panel opens at the LATEST version, not
    // the snapshot captured at message-author time. The card's whole point
    // is to point at the live artifact; pinning to an old version on click
    // would be inconsistent with the label we just rendered.
    ArtifactStorageService.requestOpen(
      artifactId: widget.artifactId,
      version: null,
    );
  }

  /// Saves the artifact's source to a file. Mirrors the file card's Download so
  /// artifacts and sent files expose the same Open + Download actions. The
  /// panel header still offers richer rendered exports (PDF/DOCX/PNG); this is
  /// the always-available source download.
  Future<void> _download(BuildContext context) async {
    try {
      final art =
          _live ??
          await ArtifactStorageService.loadArtifactById(widget.artifactId);
      if (art == null) {
        if (context.mounted) {
          NiceSnackBar.showError(context, 'Artifact is no longer available.');
        }
        return;
      }
      final rawTitle = art.title.trim();
      final safeTitle = rawTitle.isEmpty ? 'artifact' : rawTitle;
      final ext = art.type.defaultExtension;
      final name = safeTitle.toLowerCase().endsWith('.$ext')
          ? safeTitle
          : '$safeTitle.$ext';
      final result = await FileSaveService.save(
        bytes: Uint8List.fromList(utf8.encode(art.content)),
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
          NiceSnackBar.showError(context, 'Could not save file');
      }
    } catch (e) {
      if (context.mounted) {
        NiceSnackBar.showError(context, 'Download failed: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final borderColor = theme.colorScheme.outline.withValues(alpha: 0.3);

    // Artifact is confirmed-deleted: render a disabled "removed" state.
    // We keep the authored title so the user knows WHICH artifact is gone.
    final bool removed = _resolved && _live == null;

    // Build the secondary label.
    //   - Removed:                  "Artifact removed"
    //   - Live + version moved:     "Excalidraw sketch · v3 (was v1)"
    //   - Live + same version:      "Excalidraw sketch · v3"
    //   - Not yet resolved:         "Excalidraw sketch · v1" (authored)
    //   - No version info anywhere: "Excalidraw sketch"
    final String secondaryLabel;
    if (removed) {
      secondaryLabel = 'Artifact removed';
    } else {
      final liveVersion = _live?.version;
      final authoredVersion = widget.authoredVersion;
      final shownVersion = liveVersion ?? authoredVersion;
      if (shownVersion == null) {
        secondaryLabel = _typeLabel;
      } else if (liveVersion != null &&
          authoredVersion != null &&
          liveVersion != authoredVersion) {
        secondaryLabel = '$_typeLabel · v$liveVersion (was v$authoredVersion)';
      } else {
        secondaryLabel = '$_typeLabel · v$shownVersion';
      }
    }

    // Prefer the live title once resolved (artifact may have been renamed
    // via rewrite). Fall back to the authored title for the loading
    // window and for the removed state.
    final String shownTitle = _live?.title ?? widget.title;

    final bool enabled = !removed;
    final secondaryColor = removed
        ? theme.colorScheme.error
        : theme.colorScheme.onSurfaceVariant;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: enabled ? () => _open(context) : null,
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: borderColor),
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 44,
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(6),
                ),
                alignment: Alignment.center,
                child: Icon(
                  removed ? Icons.delete_outline : _icon,
                  size: 20,
                  color: removed ? theme.colorScheme.error : null,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      shownTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      secondaryLabel,
                      style: TextStyle(fontSize: 12, color: secondaryColor),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (enabled)
                TextButton(
                  onPressed: () => _download(context),
                  child: const Text('Download'),
                ),
              TextButton(
                onPressed: enabled ? () => _open(context) : null,
                child: const Text('Open'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Visible error chip when an inline artifact tag (or artifact_manager tool
/// call) fails. Without this the failure is invisible — the protocol tag is
/// stripped from display but no chip replaces it, leaving the bubble empty.
class _ArtifactErrorCard extends StatelessWidget {
  const _ArtifactErrorCard({required this.toolName, required this.message});

  final String toolName;
  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = message.replaceFirst(RegExp(r'^Error:\s*'), '');
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.error.withValues(alpha: 0.4)),
        color: scheme.errorContainer.withValues(alpha: 0.25),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 18, color: scheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Artifact could not be created',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: scheme.error,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  text,
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onErrorContainer,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// News article card: thumbnail (left, 96x96), title, publisher · age, summary,
/// tap anywhere → opens the article URL. Stretches to full bubble width.
class _NewsCard extends StatelessWidget {
  const _NewsCard({required this.item, required this.colorScheme});

  final Map<String, dynamic> item;
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    final title = (item['title'] as String? ?? '').trim();
    final publisher = (item['publisher'] as String? ?? '').trim();
    final age = (item['age'] as String? ?? '').trim();
    final summary =
        (item['summary'] as String? ?? item['description'] as String? ?? '')
            .trim();
    final url = (item['url'] as String? ?? '').trim();
    final thumbnail =
        (item['thumbnail'] as String? ?? item['thumbnail_url'] as String? ?? '')
            .trim();
    final breaking = item['breaking'] == true;

    final metaParts = <String>[
      if (publisher.isNotEmpty) publisher,
      if (age.isNotEmpty) age,
    ];

    final cardBg = Theme.of(context).brightness == Brightness.dark
        ? colorScheme.surface.withValues(alpha: 0.6)
        : colorScheme.surface;

    return Material(
      color: cardBg,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: url.isEmpty ? null : () => _openUrl(context, url),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: colorScheme.outlineVariant.withValues(alpha: 0.5),
              width: 1,
            ),
          ),
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (thumbnail.isNotEmpty) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.network(
                    thumbnail,
                    width: 96,
                    height: 96,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Container(
                      width: 96,
                      height: 96,
                      color: colorScheme.surfaceContainerHighest,
                      child: Icon(
                        Icons.broken_image_outlined,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    loadingBuilder: (ctx, child, progress) {
                      if (progress == null) return child;
                      return Container(
                        width: 96,
                        height: 96,
                        color: colorScheme.surfaceContainerHighest,
                        alignment: Alignment.center,
                        child: const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (breaking)
                      Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: colorScheme.error,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          'BREAKING',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.5,
                            color: colorScheme.onError,
                          ),
                        ),
                      ),
                    Text(
                      title.isEmpty ? '(untitled)' : title,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        height: 1.3,
                        color: colorScheme.onSurface,
                      ),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (metaParts.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        metaParts.join(' · '),
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: colorScheme.primary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    if (summary.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        summary,
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.35,
                          color: colorScheme.onSurfaceVariant,
                        ),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    if (url.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Icon(
                            Icons.open_in_new,
                            size: 12,
                            color: colorScheme.onSurfaceVariant.withValues(
                              alpha: 0.7,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              Uri.tryParse(url)?.host ?? url,
                              style: TextStyle(
                                fontSize: 11,
                                color: colorScheme.onSurfaceVariant.withValues(
                                  alpha: 0.7,
                                ),
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openUrl(BuildContext context, String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    if (!const {'http', 'https'}.contains(uri.scheme.toLowerCase())) return;
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}
