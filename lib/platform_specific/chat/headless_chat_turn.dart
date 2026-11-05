// lib/platform_specific/chat/headless_chat_turn.dart
//
// Sends one queued chat message with the FULL tool loop and no chat screen
// (docs/OFFLINE_SEND.md, "The headless send"). It runs the same
// [StreamingMessageHandler] the mobile chat screen runs, so the answer is the
// one a normal send gives: the same history, the same system prompt, the
// same tools, content blocks and tool images.
//
// The handler works on a message list that is a copy of the stored chat up to
// the queued message, with a placeholder after it. The callbacks the screen
// would turn into bubbles fill that placeholder instead. When the turn ends
// the placeholder is written into the stored chat right after its question,
// and the open screen reloads on the outbox success event.
//
// It runs inside [HeadlessTurnScope], so a tool that needs the screen fails
// with a clear tool error, and the chat-scoped tools work on this chat.

import 'package:chuk_chat/services/chat_turn_stats.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'package:chuk_chat/models/chat_model.dart';
import 'package:chuk_chat/models/queued_message.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/platform_config.dart';
import 'package:chuk_chat/platform_specific/chat/chat_ui_helpers.dart';
import 'package:chuk_chat/platform_specific/chat/handlers/streaming_message_handler.dart';
import 'package:chuk_chat/services/app_theme_service.dart';
import 'package:chuk_chat/models/chat_stream_event.dart';
import 'package:chuk_chat/services/chat_compaction.dart';
import 'package:chuk_chat/services/chat_runtime_registry.dart';
import 'package:chuk_chat/services/client_request_ids.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/headless_turn_scope.dart';
import 'package:chuk_chat/services/network_status_service.dart';
import 'package:chuk_chat/services/offline_retry_manager.dart';
import 'package:chuk_chat/services/offline_send_coordinator.dart';
import 'package:chuk_chat/services/offline_send_executor.dart';
import 'package:chuk_chat/services/streaming_manager.dart';
import 'package:chuk_chat/services/workspace_storage_service.dart';

/// The user settings a send reads from the chat screen's widget. The screen
/// gets them from [AppThemeService]; so does the headless turn.
class HeadlessTurnSettings {
  const HeadlessTurnSettings({
    this.includeRecentImagesInHistory = true,
    this.includeAllImagesInHistory = false,
    this.includeReasoningInHistory = false,
    this.includeToolResultsInHistory = true,
    this.toolCallingEnabled = true,
    this.toolDiscoveryMode = true,
  });

  final bool includeRecentImagesInHistory;
  final bool includeAllImagesInHistory;
  final bool includeReasoningInHistory;
  final bool includeToolResultsInHistory;
  final bool toolCallingEnabled;
  final bool toolDiscoveryMode;
}

abstract final class HeadlessChatTurn {
  /// A turn that has not ended after this long is cancelled. The tool loop
  /// has its own pass limit; this only stops a hung socket from holding the
  /// outbox for ever.
  static Duration maxTurn = const Duration(minutes: 30);

  static const Uuid _uuid = Uuid();

  // ── Test seams ──────────────────────────────────────────────────────
  @visibleForTesting
  static StreamingMessageHandler Function() handlerFactory =
      StreamingMessageHandler.new;
  @visibleForTesting
  static HeadlessTurnSettings Function() settings = _defaultSettings;
  @visibleForTesting
  static bool Function(String chatId) serverAccepted = _defaultAccepted;
  @visibleForTesting
  static Future<String?> Function(String chatId) resolveSystemPrompt =
      _defaultResolvePrompt;

  @visibleForTesting
  static void resetSeams() {
    handlerFactory = StreamingMessageHandler.new;
    settings = _defaultSettings;
    serverAccepted = _defaultAccepted;
    resolveSystemPrompt = _defaultResolvePrompt;
    maxTurn = const Duration(minutes: 30);
  }

  static HeadlessTurnSettings _defaultSettings() {
    try {
      final t = AppThemeService.instance;
      return HeadlessTurnSettings(
        includeRecentImagesInHistory: t.includeRecentImagesInHistory,
        includeAllImagesInHistory: t.includeAllImagesInHistory,
        includeReasoningInHistory: t.includeReasoningInHistory,
        includeToolResultsInHistory: t.includeToolResultsInHistory,
        toolCallingEnabled: t.toolCallingEnabled,
        toolDiscoveryMode: t.toolDiscoveryMode,
      );
    } catch (_) {
      return const HeadlessTurnSettings();
    }
  }

  static bool _defaultAccepted(String chatId) {
    try {
      return StreamingManager().serverAccepted(chatId);
    } catch (_) {
      return false;
    }
  }

  /// The system prompt of a row that was queued without one (a follow-up the
  /// app parked): resolved now, the way the screen resolves it at send time.
  static Future<String?> _defaultResolvePrompt(String chatId) =>
      ChatUiHelpers.resolveSystemPromptForSend(
        cachedSystemPrompt: null,
        selectedWorkspaceId: kFeatureWorkspaces
            ? WorkspaceStorageService.selectedWorkspaceId
            : null,
        activeChatId: chatId,
      );

  /// Installs the turn as the executor's tool path.
  static void install() {
    OfflineSendExecutor.toolTurn = run;
  }

  /// Sends [queued] with the full tool loop. See the file comment.
  static Future<SendExecutorResult> run(
    QueuedMessage queued,
    OfflineSendPayload payload,
  ) => HeadlessTurnScope.run(payload.chatId, () => _run(queued, payload));

  static Future<SendExecutorResult> _run(
    QueuedMessage queued,
    OfflineSendPayload payload,
  ) async {
    final String chatId = payload.chatId;
    if (!NetworkStatusService.isOnline) {
      return const SendExecutorResult.failure('network: offline');
    }
    final chat = await OfflineSendExecutor.readChat(chatId);
    if (chat == null || !chat.isFullyLoaded) {
      return const SendExecutorResult.failure('chat not found');
    }
    final List<ChatMessage> stored = chat.messages.toList();
    final int target = OfflineSendExecutor.findTarget(
      stored,
      queued,
      payload.messageText,
    );

    // Everything before the queued message that was delivered. A user
    // message that still waits (or failed) has no answer and is no history.
    final List<Map<String, String>> working = <Map<String, String>>[
      for (final m in (target >= 0 ? stored.sublist(0, target) : stored))
        if (!(m.role == 'user' &&
            (m.effectiveStatus == ChatMessageStatus.pending ||
                m.effectiveStatus == ChatMessageStatus.failed)))
          ChatUiHelpers.messageToRawMap(m),
    ];
    // Then the queued message itself, as delivered, the way a screen send
    // has it: the handler reads its `sentAt` (the turn's `[Sent: …]` line,
    // its prompt context) and compacts the chat before it (bead
    // chuk_chat-3b2q). The history builder drops it again: it is the turn
    // being sent.
    final Map<String, String> question = queuedRow(
      target >= 0 ? stored[target] : null,
      payload.messageText,
    );
    working.add(question);
    final String messageId = _uuid.v4();
    working.add(<String, String>{
      'sender': 'ai',
      'text': 'Thinking...',
      'reasoning': '',
      'modelId': payload.modelId,
      'provider': payload.providerSlug,
      'messageId': messageId,
      'startedAt': DateTime.now().toIso8601String(),
    });
    final int placeholderIndex = working.length - 1;
    final Map<String, String> reply = working[placeholderIndex];

    final HeadlessTurnSettings s = settings();
    final String? systemPrompt =
        payload.systemPrompt ??
        (payload.resolvePromptAtSend
            ? await resolveSystemPrompt(chatId)
            : null);

    // Summaries the rows carry now; a compaction in the turn adds one.
    final List<String?> summariesBefore = <String?>[
      for (final row in working) row[ChatCompaction.fieldKey],
    ];

    final StreamingMessageHandler handler = handlerFactory();
    final Completer<void> done = Completer<void>();
    var accepted = false;
    var notAccepted = false;
    var paymentRequired = false;
    var finalized = false;
    String? lastNotice;
    String? turnErrorCode;

    void noteAccepted() {
      if (serverAccepted(chatId)) accepted = true;
    }

    void checkDone() {
      if (!handler.isSending && !handler.isStreaming && !done.isCompleted) {
        done.complete();
      }
    }

    handler
      ..onShowSnackBar = (String text) {
        lastNotice = text;
      }
      ..onUpdateUI = () {
        noteAccepted();
        checkDone();
      }
      ..onMessageUpdate = (int i, String content, String reasoning, String c) {
        // Text streamed back: the server took the request.
        accepted = true;
        if (i == placeholderIndex) {
          reply['text'] = content;
          reply['reasoning'] = reasoning;
        }
      }
      ..onMessageFinalize =
          (int i, String content, String reasoning, String c, double? tps) {
            noteAccepted();
            finalized = true;
            if (i != placeholderIndex) return;
            reply['text'] = content;
            reply['reasoning'] = reasoning;
            if (tps != null) reply['tps'] = tps.toString();
            final String? usage = ChatTurnStats.instance
                .usageOf(c)
                ?.encode();
            if (usage != null) reply['usage'] = usage;
          }
      ..onToolCallsUpdate = (int i, List<ToolCall> calls, String c) {
        noteAccepted();
        if (calls.isNotEmpty) accepted = true;
        if (i == placeholderIndex) {
          reply['toolCalls'] = ChatUiHelpers.encodeToolCalls(calls);
        }
      }
      ..onContentBlocksUpdate = (int i, String json, String c) {
        noteAccepted();
        if (i == placeholderIndex) reply['contentBlocks'] = json;
      }
      ..onToolImagesProcessed =
          (
            int i,
            List<String> paths,
            String metas,
            String? cost,
            String? at,
            String toolCallsJson,
            String c,
          ) {
            if (i != placeholderIndex || paths.isEmpty) return;
            reply
              ..['images'] = jsonEncode(paths)
              ..['imageMetas'] = metas
              ..['toolCalls'] = toolCallsJson;
            if (cost != null) reply['imageCostEur'] = cost;
            if (at != null) reply['imageGeneratedAt'] = at;
          }
      ..onStreamInterrupted = (String c, int i) {
        if (i == placeholderIndex) reply['status'] = 'interrupted';
      }
      ..onPaymentRequired = () {
        paymentRequired = true;
      }
      ..onCompactionStored = (String c, int i, Map<String, String> row) {
        // The handler compacted a copy of the rows: put the summary on the
        // working row it was made for.
        final String? record = row[ChatCompaction.fieldKey];
        if (record == null || i < 0 || i >= working.length) return;
        if (!ChatCompaction.sameMessage(working[i], row)) return;
        working[i] = Map<String, String>.from(working[i])
          ..[ChatCompaction.fieldKey] = record;
      }
      ..onTurnError = (String c, int i, String error, String? code) {
        turnErrorCode = code;
      }
      ..onSendNotAccepted = (String c, int i) async {
        // Never reached the server: the row goes back to the outbox.
        notAccepted = true;
        return true;
      };

    final runtime = ChatRuntimeRegistry.instance.get(chatId);
    runtime.isSending.value = true;
    // The row's own `client_request_id`s: the same on every send of it, so
    // a re-send after a kill or a dropped socket is billed once.
    ClientRequestIds.arm(
      chatId,
      OfflineSendCoordinator.requestBaseFor(queued, payload),
    );
    try {
      await handler.sendMessage(
        userInput: payload.messageText,
        attachedFiles: <AttachedFile>[
          for (final (int i, String path) in (payload.images ?? const <String>[])
              .indexed)
            AttachedFile(
              id: 'queued-$i',
              fileName: 'image-$i',
              encryptedImagePath: path,
              isImage: true,
            ),
        ],
        selectedModelId: payload.modelId,
        selectedProviderSlug: payload.providerSlug,
        messages: working,
        systemPrompt: systemPrompt,
        activeChatId: chatId,
        placeholderIndex: placeholderIndex,
        getProviderSlug: () async => payload.providerSlug,
        isOffline: !NetworkStatusService.isOnline,
        includeRecentImagesInHistory: s.includeRecentImagesInHistory,
        includeAllImagesInHistory: s.includeAllImagesInHistory,
        includeReasoningInHistory: s.includeReasoningInHistory,
        includeToolResultsInHistory: s.includeToolResultsInHistory,
        toolCallingEnabled: s.toolCallingEnabled,
        toolDiscoveryMode: s.toolDiscoveryMode,
        reasoningEffort: payload.reasoningEffort,
      );
      checkDone();
      await done.future.timeout(
        maxTurn,
        onTimeout: () async {
          await handler.cancelStream(chatId);
        },
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[HeadlessChatTurn] turn failed: ${e.runtimeType}');
      }
      if (!accepted) {
        return SendExecutorResult.failure(_classify(e.toString()));
      }
    } finally {
      ClientRequestIds.disarm(chatId);
      handler.dispose();
      runtime.isSending.value = false;
    }

    if (notAccepted) {
      return const SendExecutorResult.failure('network: not accepted');
    }
    if (!accepted) {
      if (paymentRequired) {
        return const SendExecutorResult.failure('payment required');
      }
      final String error = lastNotice ??
          (finalized ? reply['text'] ?? 'not sent' : 'not sent');
      return SendExecutorResult.failure(_classify(error));
    }

    // The socket died (or the answer was still being written) and no tool
    // ran: the server holds this request under the row's ids, so the next
    // flush re-sends the same ids and gets the answer from the server's
    // record, billed once. Nothing is stored now; the bubble keeps
    // waiting. A turn that ran tools keeps its error instead: a re-send
    // would run the tools again.
    if (resendable(turnErrorCode, reply)) {
      return SendExecutorResult.failure('network: resend ($turnErrorCode)');
    }

    // The server took the turn: what it produced is the answer, like a send
    // on screen (an error after acceptance stays as the turn's text).
    final String text = reply['text'] ?? '';
    if (text == 'Thinking...') reply['text'] = '';
    // A compaction before the first pass marked one working row (the
    // first kept user message) with its summary; store it on that row.
    Map<String, String>? summaryRow;
    for (var i = 0; i < placeholderIndex; i++) {
      final String? now = working[i][ChatCompaction.fieldKey];
      if (now != null && now.isNotEmpty && now != summariesBefore[i]) {
        summaryRow = working[i];
      }
    }
    await _writeReply(
      queued,
      payload,
      reply,
      question: question,
      summaryRow: summaryRow,
    );
    return const SendExecutorResult.success();
  }

  /// The queued message [m] as the handler gets it: delivered (no waiting
  /// marks), with a send time when it has none. Its text is the queued
  /// text (what goes to the model, documents inlined; a voice bubble's
  /// transcript), the same string the handler gets as `userInput`, so the
  /// history builder knows it as the turn being sent and leaves it out of
  /// `history`. The stored bubble keeps its own display text. Null [m]
  /// (the bubble is gone): a new row.
  @visibleForTesting
  static Map<String, String> queuedRow(ChatMessage? m, String messageText) {
    final Map<String, String> row = m == null
        ? <String, String>{'sender': 'user', 'text': messageText}
        : ChatUiHelpers.messageToRawMap(m);
    row
      ..remove('status')
      ..remove('queueId')
      ..remove('lastError');
    if (messageText.trim().isNotEmpty) row['text'] = messageText;
    if ((row['sentAt'] ?? '').isEmpty) {
      row['sentAt'] = DateTime.now().toIso8601String();
    }
    return row;
  }

  /// Whether a turn that ended on [code] goes back to the outbox: the
  /// server can de-duplicate a re-send ([StreamErrorCodes.resendSameId])
  /// and no tool ran, so a re-send repeats nothing.
  @visibleForTesting
  static bool resendable(String? code, Map<String, String> reply) {
    if (code == null || !StreamErrorCodes.resendSameId.contains(code)) {
      return false;
    }
    final String calls = reply['toolCalls'] ?? '';
    return calls.isEmpty || calls == '[]';
  }

  /// Writes [reply] into the stored chat right after its question, and what
  /// the turn wrote onto the question ([question]: its send time, and a
  /// compaction summary) or onto an earlier row (a summary).
  static Future<void> _writeReply(
    QueuedMessage queued,
    OfflineSendPayload payload,
    Map<String, String> reply, {
    Map<String, String>? question,
    Map<String, String>? summaryRow,
  }) async {
    final String chatId = payload.chatId;
    final fresh = await OfflineSendExecutor.readChat(chatId);
    final List<ChatMessage> messages = fresh?.messages.toList() ?? [];
    var idx = OfflineSendExecutor.findTarget(
      messages,
      queued,
      payload.messageText,
    );
    final List<Map<String, dynamic>> maps = messages
        .map((m) => m.toJson())
        .toList();
    if (idx < 0) {
      maps.add(<String, dynamic>{
        'role': 'user',
        'text': payload.messageText,
        'sentAt': ?question?['sentAt'],
      });
      idx = maps.length - 1;
    } else {
      maps[idx] = OfflineSendExecutor.delivered(maps[idx], payload.messageText);
      final String? sentAt = question?['sentAt'];
      if ((maps[idx]['sentAt'] as String? ?? '').isEmpty && sentAt != null) {
        maps[idx]['sentAt'] = sentAt;
      }
    }
    if (summaryRow != null) {
      _storeSummary(
        maps,
        idx,
        summaryRow,
        isQuestion: identical(summaryRow, question),
      );
    }
    maps.insert(idx + 1, Map<String, dynamic>.of(reply));
    await OfflineSendExecutor.writeChat(chatId, maps);
  }

  /// Puts the summary of [row] (the working row the compaction marked) on
  /// the stored row it came from: the question at [questionIdx] when
  /// [isQuestion], else the user row before it with the same send time and
  /// text (the working list is the stored chat minus waiting rows).
  static void _storeSummary(
    List<Map<String, dynamic>> maps,
    int questionIdx,
    Map<String, String> row, {
    required bool isQuestion,
  }) {
    final String? summary = row[ChatCompaction.fieldKey];
    if (summary == null || summary.isEmpty) return;
    if (isQuestion) {
      maps[questionIdx][ChatCompaction.fieldKey] = summary;
      return;
    }
    for (var i = questionIdx - 1; i >= 0; i--) {
      final m = maps[i];
      final String role = m['role']?.toString() ?? m['sender']?.toString() ?? '';
      if (role != 'user') continue;
      if ((m['sentAt'] ?? '') == (row['sentAt'] ?? '') &&
          (m['text'] ?? '') == (row['text'] ?? '')) {
        m[ChatCompaction.fieldKey] = summary;
        return;
      }
    }
  }

  static String _classify(String msg) =>
      NetworkStatusService.isNetworkError(msg) ? 'network: $msg' : msg;
}
