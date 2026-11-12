import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import 'package:chuk_chat/services/agents/agents_attachment_store.dart';
import 'package:chuk_chat/services/agents/agents_attachments.dart'
    show AgentsAttachmentInfo;
import 'package:chuk_chat/widgets/agents_attachment_chips.dart';
import 'package:chuk_chat/models/chat_message.dart' show ChatMessageStatus;
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/platform_specific/chat/chat_ui_helpers.dart';
import 'package:chuk_chat/services/agents/agents_context_rows.dart';
import 'package:chuk_chat/services/agents/agents_run_cost.dart';
import 'package:chuk_chat/services/chat_compaction.dart';
import 'package:chuk_chat/services/chat_runtime.dart';
import 'package:chuk_chat/services/chat_runtime_registry.dart';
import 'package:chuk_chat/services/dictation_tracker.dart';
import 'package:chuk_chat/services/offline_retry_manager.dart';
import 'package:chuk_chat/services/storage/chat_origin.dart';
import 'package:chuk_chat/widgets/agents_context_chip.dart';
import 'package:chuk_chat/widgets/agents_quiet_run_fold.dart';
import 'package:chuk_chat/widgets/compaction_divider.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';
import 'package:chuk_chat/widgets/message_fly_in.dart';
import 'package:chuk_chat/widgets/message_time_label.dart';

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
    this.onOpenUiMessage,
    this.onContinueGeneration,
    this.messengerMode = false,
    this.reaction,
    this.onReaction,
    this.onReply,
    this.onEditRequested,
  });

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

  /// Sends a message an OpenUI view in this answer composed, as a user
  /// message in the same chat.
  final ValueChanged<String>? onOpenUiMessage;
  final VoidCallback? onContinueGeneration;

  /// Agents's messenger behaviour: reactions, reply and the long-press menu.
  /// Off everywhere upstream's chat builds this row, so the fields below stay
  /// null there. The look is upstream's either way.
  final bool messengerMode;

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
    final bool startsNewGroup = index == 0 || previousIsUser != data.isUser;
    final bool endsGroup =
        index == messages.length - 1 || nextIsUser != data.isUser;
    final String uiKey = ChatUiHelpers.stableUiKey(messages[index], uuid);

    // AGENTS: a prompt nobody typed (a goal round, a schedule, a mail) is a
    // small chip, never a user bubble (docs/WIRE_CONTRACT.md, "Typed source
    // on synthetic rows").
    final String? rowSource = data.isUser
        ? agentsRowSource(messages[index])
        : null;
    if (rowSource != null) {
      return _row(
        AgentsContextChip(
          key: ValueKey<String>(uiKey),
          source: rowSource,
          text: data.displayText,
        ),
      );
    }

    // True from the moment Send is pressed, not only once the server stream
    // is registered. The status header has to be on screen for the whole
    // wait, including the stretch where the request is still going out.
    final ChatRuntime? liveRuntime = activeChatId == null
        ? null
        : ChatRuntimeRegistry.instance.lookup(activeChatId!);
    final bool isLastAiMessage = !data.isUser && index == messages.length - 1;
    final bool forceLive =
        isLastAiMessage && (liveRuntime?.isSending.value ?? false);

    // AGENTS: what an agent's run cost, and its run id, ride on its answer
    // as one synthetic call (docs/WIRE_CONTRACT.md, "Cost per run and weekly
    // budget"). It is lifted off here, so the bubble never draws it as a tool
    // line. The cost is not shown under the answer (the owner does not want
    // cost or token counts in the chat); the run id folds a quiet automation
    // run to one line. Rows without it pass through
    // unchanged (the same lists).
    final costSplit = data.isUser
        ? null
        : splitRunMeta(data.toolCalls, data.contentBlocks);
    final String? runId = costSplit?.runId;
    // AGENTS: context rows the run wrote ride on its answer as synthetic
    // calls; they are lifted off here and drawn as chips above it.
    final contextSplit = data.isUser
        ? null
        : splitAgentsContext(
            costSplit?.toolCalls ?? data.toolCalls ?? const <ToolCall>[],
          );
    final List<ToolCall>? bubbleCalls =
        contextSplit == null || contextSplit.context.isEmpty
        ? (costSplit?.toolCalls ?? data.toolCalls)
        : contextSplit.rest;

    // AGENTS: the files a user sent to a task. The host's replayed list
    // wins; a live send's sealed files ride in `images` as store refs and
    // are drawn as rows, never as broken pictures.
    final List<AgentsAttachmentInfo> agentsFiles = data.isUser
        ? AgentsAttachmentChips.forMessage(
            replayed: messages[index]['agentsAttachments'],
            paths: data.images,
          )
        : const <AgentsAttachmentInfo>[];
    final bool hostListedFiles =
        data.isUser && (messages[index]['agentsAttachments'] ?? '').isNotEmpty;
    final List<String>? bubbleImages = hostListedFiles
        ? null
        : data.images
              ?.where((String p) => !AgentsAttachmentStore.isRef(p))
              .toList();

    MessageBubble buildBubble(String text, String? reasoning) => MessageBubble(
      key: ValueKey<String>(uiKey),
      message: text,
      reasoning: reasoning,
      voicePlayback: messages[index]['voicePlayback'],
      isVoiceInput: data.isUser && isVoiceInput(messages[index]),
      voiceInputDuration: data.isUser
          ? voiceInputDuration(messages[index])
          : null,
      isUser: data.isUser,
      startsNewGroup: startsNewGroup,
      endsGroup: endsGroup,
      maxWidth: data.isUser ? maxWidth * 0.8 : maxWidth,
      isReasoningStreaming: data.isReasoningStreaming || forceLive,
      modelLabel: data.modelLabel,
      modelProvider: data.modelProvider,
      tps: data.tps,
      usage: data.usage,
      toolCalls: bubbleCalls,
      showToolCalls: showToolCalls,
      contentBlocks: costSplit == null
          ? data.contentBlocks
          : costSplit.contentBlocks,
      isStreamingMessage: data.isStreamingMessage || forceLive,
      chatId: activeChatId,
      turnStartedAt: data.turnStartedAt,
      workedFor: data.workedFor,
      images: bubbleImages == null || bubbleImages.isEmpty
          ? null
          : bubbleImages,
      imageMetas: data.imageMetas,
      imageCostEur: data.imageCostEur,
      imageGeneratedAt: data.imageGeneratedAt,
      attachments: data.attachments,
      agentsAttachments: agentsFiles.isEmpty ? null : agentsFiles,
      actions: actions,
      userMessageActions: userMessageActions,
      isEditing: isEditing,
      showReasoningTokens: showReasoningTokens,
      showModelInfo: showModelInfo,
      showTps: showTps,
      onAskUserAnswer: onAskUserAnswer,
      onConnectMcpServer: onConnectMcpServer,
      messageId: uiKey,
      onOpenUiMessage: data.isUser ? null : onOpenUiMessage,
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
      queueId: data.isUser ? data.queueId : null,
      lastError: data.lastError,
      onRetryPending:
          data.isUser &&
              (data.status == ChatMessageStatus.pending ||
                  data.status == ChatMessageStatus.failed)
          // Used only when the message has no outbox row (Agents); a row
          // retries itself through OfflineSendCoordinator.retryRow.
          ? () => OfflineRetryManager.instance.retryNow()
          : null,
      onContinueGeneration: onContinueGeneration,
      messengerMode: messengerMode,
      reaction: reaction,
      onReaction: onReaction,
      onReply: onReply,
      onEditRequested: onEditRequested,
    );

    final ChatRuntime? runtime = liveRuntime;
    final bool wrapForStream =
        runtime != null &&
        isLastAiMessage &&
        (data.isStreamingMessage || runtime.isSending.value);
    if (wrapForStream) {
      return _row(
        ValueListenableBuilder<StreamingLive?>(
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
      );
    }

    final String? reasoning = data.reasoning.trim().isEmpty
        ? null
        : data.reasoning;
    final Widget plainAnswer = buildBubble(data.displayText, reasoning);
    final Widget answer = (contextSplit?.context.isEmpty ?? true)
        ? plainAnswer
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (final c in contextSplit!.context)
                AgentsContextChip(source: c.source, text: c.text),
              plainAnswer,
            ],
          );
    final Widget bubble = runId == null || data.isStreamingMessage
        ? answer
        : AgentsQuietRunFold(runId: runId, child: answer);
    final Widget row = data.isUser && uiKey == flyInKey
        ? MessageFlyIn(key: ValueKey<String>('flyin_$uiKey'), child: bubble)
        : bubble;
    // The first message a compaction kept: the turns above it reach the
    // model as a summary only (lib/services/chat_compaction.dart).
    final bool compactedHere =
        data.isUser &&
        index > 0 &&
        CompactionRecord.decode(messages[index][ChatCompaction.fieldKey]) !=
            null;
    return _row(
      compactedHere
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[const CompactionDivider(), row],
            )
          : row,
    );
  }

  /// The row, with the centred time line above it when an Agents thread
  /// starts a new day or the talk resumes after a pause
  /// ([messageOpensTimeDivider]).
  Widget _row(Widget child) {
    final DateTime? when =
        ChatOrigin.isAgentsThread(activeChatId) || messengerMode
        ? messageRowTime(messages[index])
        : null;
    if (when == null || !messageOpensTimeDivider(messages, index)) {
      return _rowBoundary(child);
    }
    return _rowBoundary(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          MessageTimeDivider(when: when),
          child,
        ],
      ),
    );
  }

  /// One layer and one [TickerMode] per row.
  ///
  /// Every implicit animation listens to the nearest TickerMode's notifier,
  /// and `removeListener` scans that list. With one notifier for the whole
  /// app, tearing down rows was quadratic: over half of the "open long chat"
  /// frame went to `ChangeNotifier.removeListener`. See docs/PERFORMANCE.md.
  static Widget _rowBoundary(Widget child) =>
      RepaintBoundary(child: TickerMode(enabled: true, child: child));
}
