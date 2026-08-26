// lib/widgets/message_bubble.dart
//
// The chat message bubble. This file is the library root: it owns the imports,
// the shared spacing / regex / preference constants, the [MessageBubble]
// widget, and the core [_MessageBubbleState] (fields + lifecycle + build). The
// heavy rendering is split across `part` files by concern:
//
//   message_bubble/models.dart       — data + render-segment types
//   message_bubble/layout.dart       — user/AI containers + the two layouts
//   message_bubble/chrome.dart       — action bars + pending/failed status
//   message_bubble/rich_blocks.dart  — <chart>/<map>/<email>/<news>/… blocks
//   message_bubble/tools.dart        — tool timeline, detail sheet, artifacts
//   message_bubble/images.dart       — image grids, loaders, attachment chips
//   message_bubble/cards.dart        — thumbnail, artifact card, news card
//
// Every part is `part of` this library, so the split is purely physical: the
// private members below stay reachable from each part with no API change.
import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:chuk_chat/models/chat_message.dart' show ChatMessageStatus;
import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/models/stream_phase.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/widgets/agent_activity/agent_activity_model.dart';
import 'package:chuk_chat/widgets/agent_activity/agent_activity_timeline.dart';
import 'package:chuk_chat/models/artifact.dart';
import 'package:chuk_chat/services/app_theme_service.dart';
import 'package:chuk_chat/utils/chat_font_resolver.dart';
import 'package:chuk_chat/services/streaming_manager.dart';
import 'package:chuk_chat/services/artifact_storage_service.dart';
import 'package:chuk_chat/services/diagnostics_log_service.dart';
import 'package:chuk_chat/services/file_save_service.dart';
import 'package:chuk_chat/services/image_storage_service.dart';
import 'package:chuk_chat/widgets/chart_widget.dart';
import 'package:chuk_chat/widgets/diff_widget.dart';
import 'package:chuk_chat/widgets/map_block_renderer.dart';
import 'package:chuk_chat/widgets/weather_widget.dart';
import 'package:chuk_chat/utils/tool_detail_format.dart';
import 'package:chuk_chat/widgets/markdown_message.dart';
import 'package:chuk_chat/widgets/image_viewer.dart';
import 'package:chuk_chat/widgets/document_viewer.dart';
import 'package:chuk_chat/widgets/nice_snackbar.dart';
import 'package:chuk_chat/widgets/sandbox_artifact_block.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/utils/color_extensions.dart';
import 'package:chuk_chat/utils/tool_parser.dart';
import 'package:chuk_chat/widgets/ask_user_card.dart';
import 'package:chuk_chat/widgets/mcp_connect_card.dart';
import 'package:chuk_chat/services/mcp/mcp_availability.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/platform_config.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:flutter/foundation.dart';

part 'message_bubble/models.dart';
part 'message_bubble/layout.dart';
part 'message_bubble/chrome.dart';
part 'message_bubble/rich_blocks.dart';
part 'message_bubble/tools.dart';
part 'message_bubble/images.dart';
part 'message_bubble/cards.dart';

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

/// AI action / user long-press action bars share this fixed height on mobile
/// so the two button strips look the same size.
const double _kMobileBottomBarHeight = 36.0;

/// Regex to find visual output blocks (`<chart>`, `<map>`, `<email>`,
/// `<weather>`, `<news>`, `<image>`, `<diff>`).
final RegExp _richBlockRegex = RegExp(
  r'<\s*(chart|map|email|weather|news|image|diff)\s*>([\s\S]*?)<\s*/\s*\1\s*>',
  multiLine: true,
  caseSensitive: false,
);

final RegExp _visualBlockStartRegex = RegExp(
  r'<\s*(chart|map|email|weather|news|image|diff)\b',
  caseSensitive: false,
);

/// Matches `<diff>...</diff>` blocks embedded in tool results.
final RegExp _diffBlockRegex = RegExp(
  r'<\s*diff\s*>([\s\S]*?)<\s*/\s*diff\s*>',
  caseSensitive: false,
);

final RegExp _attachmentHeaderRe = RegExp(
  r'^\d+ images? attached(?:, Documents: .+)?$',
);

/// Default chat font family, resolved once. Used when the user has explicitly
/// picked the system font (the historic Arimo default).
final String _kAiResponseFontFamilyDefault =
    GoogleFonts.arimo().fontFamily ?? 'Arimo';

/// Cross-instance cache of the two display preferences, so a freshly built
/// bubble can render with the last known value before its own async load
/// resolves. Written by [_MessageBubbleState._loadPreferences].
bool? _cachedShowReasoningTokens;
bool? _cachedShowModelInfo;

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
    this.turnStartedAt,
    this.workedFor,
    this.images,
    this.imageMetas,
    this.attachments,
    this.imageCostEur,
    this.imageGeneratedAt,
    this.onAskUserAnswer,
    this.onConnectMcpServer,
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

  /// When the request behind this answer went out, so the activity header
  /// can count real seconds from the send rather than from the first tool
  /// call — which on a slow turn starts long after the reader began waiting.
  final DateTime? turnStartedAt;

  /// The finished turn's length as it was written down. Once present the
  /// header shows it unchanged, so reopening a chat cannot produce a
  /// different number than the one the reader watched arrive.
  final Duration? workedFor;

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

  /// Called with the catalogue id when the user taps Connect on an inline
  /// MCP connect card (from a completed `request_mcp_server` tool call).
  /// When non-null, the bubble renders a Connect card for the most recent
  /// such call in this message.
  final ValueChanged<String>? onConnectMcpServer;

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
  bool _complexBubbleLogged = false;
  bool _showUserActions = false;

  // User preferences for display - null until loaded
  bool? _showReasoningTokens;
  bool? _showModelInfo;

  // Memoized display text: stripToolCallBlocksForDisplay(widget.message) runs a
  // chain of regexes over the whole message and was previously called 4× per
  // build (and on every scroll/stream rebuild). Cache the result per distinct
  // message string so a rebuild that doesn't change the text is free.
  String? _strippedMessageCache;
  String? _strippedMessageSource;

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

  @override
  Widget build(BuildContext context) {
    // The timing is reported at most once per bubble, so stop paying for a
    // Stopwatch on every later rebuild.
    final Stopwatch? stopwatch =
        _complexBubbleLogged ? null : (Stopwatch()..start());

    final bool isUserMessage = widget.isUser;
    final Widget result = isUserMessage
        ? _buildUserBubble(context)
        : _buildAiBubble(context);

    stopwatch?.stop();
    final imageCount = widget.images?.length ?? 0;
    final isComplex = imageCount > 0 || widget.message.length > 3000;
    if (stopwatch != null &&
        isComplex &&
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
}
