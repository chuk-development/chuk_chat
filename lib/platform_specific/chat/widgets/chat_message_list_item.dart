import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import 'package:chuk_chat/models/chat_message.dart' show ChatMessageStatus;
import 'package:chuk_chat/platform_specific/chat/chat_ui_helpers.dart';
import 'package:chuk_chat/services/chat_runtime.dart';
import 'package:chuk_chat/services/chat_runtime_registry.dart';
import 'package:chuk_chat/services/offline_retry_manager.dart';
import 'package:chuk_chat/widgets/agents_desktop/message_hover_actions.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';
import 'package:chuk_chat/widgets/message_fly_in.dart';

/// One message row shared by the desktop and mobile chat lists.
///
/// The parent owns parsing and platform actions. This widget owns the common
/// bubble configuration, live-stream updates, grouping, repaint boundary, and
/// one-shot fly-in animation.
class ChatMessageListItem extends StatelessWidget {
  const ChatMessageListItem({
    super.key,
    required this.messages,
    required this.index,
    required this.data,
    required this.uuid,
    required this.maxWidth,
    required this.activeChatId,
    required this.flyInKey,
    required this.showToolCalls,
    required this.showReasoningTokens,
    required this.showModelInfo,
    required this.showTps,
    required this.isEditing,
    required this.actions,
    required this.userMessageActions,
    required this.onSwitchVariant,
    this.onAskUserAnswer,
    this.onConnectMcpServer,
    this.onContinueGeneration,
    this.messengerMode = false,
    this.agentsRuns = false,
    this.reaction,
    this.onReaction,
    this.onReply,
    this.onEditRequested,
    this.hoverActions = false,
  });

  /// The Agents desktop transcript (docs/DESIGN.md §14.4): the message's
  /// actions show in a small toolbar at its top right while the pointer is on
  /// it, instead of as a permanent pill under it. Off everywhere else.
  final bool hoverActions;

  final List<Map<String, String>> messages;
  final int index;
  final MessageRenderData data;
  final Uuid uuid;
  final double maxWidth;
  final String? activeChatId;
  final String? flyInKey;
  final bool showToolCalls;
  final bool showReasoningTokens;
  final bool showModelInfo;
  final bool showTps;
  final bool isEditing;
  final List<MessageBubbleAction> actions;
  final List<MessageBubbleAction> userMessageActions;
  final ValueChanged<int> onSwitchVariant;
  final ValueChanged<String>? onAskUserAnswer;
  final ValueChanged<String>? onConnectMcpServer;
  final VoidCallback? onContinueGeneration;

  /// Agents's messenger presentation. Off everywhere upstream's chat builds
  /// this row, so the fields below stay null there and the bubble is the
  /// same as before.
  final bool messengerMode;

  /// Agents's bubble runs: a day change or a pause longer than
  /// kBubbleGroupPause also starts a new run, not only a change of sender.
  /// Both Agents layouts set it; upstream's chat does not.
  final bool agentsRuns;

  /// The reader's own reaction on this message, if any.
  final String? reaction;

  /// Toggle a reaction. Null hides the reaction picker.
  final ValueChanged<String>? onReaction;

  /// Quote this message in the composer. Null hides "Reply".
  final VoidCallback? onReply;

  /// Edit this (user) message from the messenger menu.
  final VoidCallback? onEditRequested;

  @override
  Widget build(BuildContext context) {
    final bool previousIsUser = index == 0
        ? data.isUser
        : (messages[index - 1]['sender'] ?? 'ai') == 'user';
    final bool nextIsUser = index == messages.length - 1
        ? data.isUser
        : (messages[index + 1]['sender'] ?? 'ai') == 'user';
    // The Agents thread breaks a bubble run on a day change and on a long
    // pause too, as the original app did (chat_ui_helpers).
    final bool startsNewGroup = agentsRuns
        ? messageStartsRun(messages, index)
        : index == 0 || previousIsUser != data.isUser;
    final bool endsGroup = agentsRuns
        ? messageEndsRun(messages, index)
        : index == messages.length - 1 || nextIsUser != data.isUser;
    final String uiKey = ChatUiHelpers.stableUiKey(messages[index], uuid);

    // True from the moment Send is pressed, not only once the server stream
    // is registered. The status header has to be on screen for the whole
    // wait, including the stretch where the request is still going out.
    final ChatRuntime? liveRuntime = activeChatId == null
        ? null
        : ChatRuntimeRegistry.instance.lookup(activeChatId!);
    final bool isLastAiMessage = !data.isUser && index == messages.length - 1;
    final bool forceLive =
        isLastAiMessage && (liveRuntime?.isSending.value ?? false);

    MessageBubble buildBubble(String text, String? reasoning) => MessageBubble(
      key: ValueKey<String>(uiKey),
      message: text,
      reasoning: reasoning,
      isUser: data.isUser,
      startsNewGroup: startsNewGroup,
      endsGroup: endsGroup,
      // Agents's user bubble is narrower (0.72, the original app's
      // messenger width); upstream keeps 0.8.
      maxWidth: data.isUser
          ? maxWidth * (messengerMode ? 0.72 : 0.8)
          : maxWidth,
      isReasoningStreaming: data.isReasoningStreaming || forceLive,
      modelLabel: data.modelLabel,
      modelProvider: data.modelProvider,
      tps: data.tps,
      toolCalls: data.toolCalls,
      showToolCalls: showToolCalls,
      contentBlocks: data.contentBlocks,
      isStreamingMessage: data.isStreamingMessage || forceLive,
      chatId: activeChatId,
      turnStartedAt: data.turnStartedAt,
      workedFor: data.workedFor,
      images: data.images,
      imageMetas: data.imageMetas,
      imageCostEur: data.imageCostEur,
      imageGeneratedAt: data.imageGeneratedAt,
      attachments: data.attachments,
      actions: hoverActions ? const <MessageBubbleAction>[] : actions,
      userMessageActions: hoverActions
          ? const <MessageBubbleAction>[]
          : userMessageActions,
      isEditing: isEditing,
      showReasoningTokens: showReasoningTokens,
      showModelInfo: showModelInfo,
      showTps: showTps,
      onAskUserAnswer: onAskUserAnswer,
      onConnectMcpServer: onConnectMcpServer,
      useSharedSelectionArea: true,
      variantIndex: data.variantIndex,
      variantCount: data.variantCount,
      onPrevVariant: data.variantCount > 1
          ? () => onSwitchVariant(data.variantIndex - 1)
          : null,
      onNextVariant: data.variantCount > 1
          ? () => onSwitchVariant(data.variantIndex + 1)
          : null,
      status: data.status,
      lastError: data.lastError,
      onRetryPending:
          data.isUser &&
              (data.status == ChatMessageStatus.pending ||
                  data.status == ChatMessageStatus.failed)
          ? () => OfflineRetryManager.instance.retryNow()
          : null,
      onContinueGeneration: onContinueGeneration,
      messengerMode: messengerMode,
      reaction: reaction,
      onReaction: onReaction,
      onReply: onReply,
      onEditRequested: onEditRequested,
      sentAt: messengerMode
          ? DateTime.tryParse(messages[index]['sentAt'] ?? '')
          : null,
    );

    final ChatRuntime? runtime = liveRuntime;
    final bool wrapForStream =
        runtime != null &&
        isLastAiMessage &&
        (data.isStreamingMessage || runtime.isSending.value);
    if (wrapForStream) {
      return _withHoverActions(
        RepaintBoundary(
          child: ValueListenableBuilder<StreamingLive?>(
            valueListenable: runtime.streamingLive,
            builder: (context, live, _) {
              final bool matches = live != null && live.index == index;
              final String text = matches
                  ? live.text.trimRight()
                  : data.displayText;
              final String rawReasoning = matches
                  ? live.reasoning
                  : data.reasoning;
              final String? reasoning = rawReasoning.trim().isEmpty
                  ? null
                  : rawReasoning;
              return buildBubble(text, reasoning);
            },
          ),
        ),
      );
    }

    final String? reasoning = data.reasoning.trim().isEmpty
        ? null
        : data.reasoning;
    final Widget bubble = buildBubble(data.displayText, reasoning);
    return _withHoverActions(
      RepaintBoundary(
        child: data.isUser && uiKey == flyInKey
            ? MessageFlyIn(key: ValueKey<String>('flyin_$uiKey'), child: bubble)
            : bubble,
      ),
    );
  }

  Widget _withHoverActions(Widget row) {
    if (!hoverActions) return row;
    return MessageHoverActions(
      actions: data.isUser ? userMessageActions : actions,
      child: row,
    );
  }
}
