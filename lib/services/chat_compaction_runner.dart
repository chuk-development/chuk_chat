// lib/services/chat_compaction_runner.dart
//
// The app side of chat compaction (lib/services/chat_compaction.dart): reads
// the model's window from the catalogue, picks the summarizing model (the
// previous one when the chat switches to a smaller window) and sends the
// summary request over the chat's own connection with purpose `compact`.
// Called by the send paths after the turn's system prompt is built and
// before the first pass goes out ([beforeSend]), and by the `/compact`
// command ([compactNow]).

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/platform_specific/chat/chat_ui_helpers.dart';
import 'package:chuk_chat/services/chat_compaction.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/chat_turn_stats.dart';
import 'package:chuk_chat/services/provider_resolution_service.dart';
import 'package:chuk_chat/services/storage/chat_origin.dart';
import 'package:chuk_chat/services/websocket_chat_service.dart';
import 'package:chuk_chat/widgets/model_selection_dropdown.dart';

class ChatCompactionRunner {
  const ChatCompactionRunner._();

  /// Tokens `/compact` keeps verbatim when the model's window is unknown.
  static const int manualRetainTokens = 16000;

  /// Replaces the request sender. Tests only.
  @visibleForTesting
  static CompactionSend? debugSend;

  /// Replaces the window lookup (`modelId` -> context length). Tests only.
  @visibleForTesting
  static Future<int?> Function(String modelId, String? providerSlug)?
  debugContextWindow;

  static Future<int?> _window(String modelId, String? providerSlug) async {
    final seam = debugContextWindow;
    if (seam != null) return seam(modelId, providerSlug);
    final int? fromPicker = ModelSelectionDropdown.providerLimitsForModel(
      modelId,
    )?.contextLength;
    if (fromPicker != null && fromPicker > 0) return fromPicker;
    return ChatTurnStats.instance.contextLengthFor(modelId, providerSlug);
  }

  /// New messages a chat must gain after a failed compaction before an
  /// automatic one is tried again. `/compact` ignores it.
  static const int failureBackoffMessages = 4;

  /// Chat id -> the message count (`end`) at its last failed compaction.
  static final Map<String, int> _failedAt = <String, int>{};

  /// Chats with a summary request on its way (a send or `/compact`).
  static final Set<String> _running = <String>{};

  /// Whether a summary request of [chatId] is on its way.
  static bool isRunning(String chatId) => _running.contains(chatId);

  /// The stored rows of [chatId] with [outcome]'s summary written on, for a
  /// chat that is no longer on screen. Null when the chat is not loaded or
  /// no longer holds the summarized row (nothing is written then). The
  /// caller persists the rows under [chatId].
  static List<Map<String, String>>? applyToStored(
    String chatId,
    CompactionOutcome outcome,
  ) {
    final stored = ChatStorageService.getChatById(chatId)?.messagesOrNull;
    if (stored == null || stored.isEmpty) return null;
    final List<Map<String, String>> rows = <Map<String, String>>[
      for (final m in stored) ChatUiHelpers.messageToRawMap(m),
    ];
    return outcome.writeInto(rows) ? rows : null;
  }

  @visibleForTesting
  static void debugReset() {
    _failedAt.clear();
    _running.clear();
  }

  /// Compacts the chat before a send when its next request reaches the
  /// trigger of [modelId] (or when the chat switches from a model with a
  /// larger window: the old model summarizes, its cache is warm).
  ///
  /// [messages] holds the chat; `0..end-1` is what comes before the message
  /// being sent. It is only read: the summary goes onto a copy of those
  /// rows ([CompactionOutcome.messages]), because the summary request
  /// takes seconds and a screen's live list may hold another chat when it
  /// returns. The caller writes the record back with
  /// [CompactionOutcome.writeInto] after checking the chat. [history] is
  /// the request history built for this send, [systemPrompt] the turn's
  /// frozen system prompt and [tools] its `tools[]`: the summary request
  /// repeats them byte for byte. [buildHistory] builds the same history
  /// from the rows it gets and fills the message start offsets. [madeAt]
  /// defaults to [end] (a continue passes `end - 1`: the answer it
  /// continues is measured after the summary). On
  /// [CompactionStatus.compacted] the caller rebuilds the history from
  /// [CompactionOutcome.messages] and persists the chat.
  static Future<CompactionOutcome> beforeSend({
    required List<Map<String, String>> messages,
    required int end,
    required String chatId,
    required String modelId,
    required String providerSlug,
    required String accessToken,
    required String systemPrompt,
    required List<Map<String, dynamic>> tools,
    required List<Map<String, dynamic>> history,
    required String pendingMessage,
    required Future<List<Map<String, dynamic>>> Function(
      List<Map<String, String>> rows,
      List<int> starts,
    )
    buildHistory,
    int? madeAt,
    bool force = false,
  }) async {
    if (ChatOrigin.isAgentsThread(chatId) || end <= 1) {
      return const CompactionOutcome(CompactionStatus.notNeeded);
    }
    if (!_running.add(chatId)) {
      return const CompactionOutcome(
        CompactionStatus.notNeeded,
        reason: 'busy',
      );
    }
    final int cut = end > messages.length ? messages.length : end;
    final List<Map<String, String>> rows = <Map<String, String>>[
      for (final m in messages.take(cut)) Map<String, String>.from(m),
    ];
    int? window;
    var estimate = 0;
    try {
      window = await _window(modelId, providerSlug);
      final CompactionBudget? budget = window == null
          ? null
          : ChatCompaction.budgetFor(
              contextWindow: window,
              maxOutput: ChatCompaction.maxOutputFor(
                window,
                ModelSelectionDropdown.providerLimitsForModel(modelId)
                    ?.maxCompletionTokens,
              ),
            );
      final CompactionBudget effective;
      if (budget != null) {
        effective = budget;
      } else if (force) {
        // `/compact` on a model whose window is unknown: keep a fixed tail.
        effective = const CompactionBudget(
          threshold: 0,
          retain: manualRetainTokens,
        );
      } else {
        return const CompactionOutcome(CompactionStatus.notNeeded);
      }
      estimate = ChatCompaction.estimatePrompt(
        messages: rows,
        history: history,
        pendingMessage: pendingMessage,
        systemPrompt: systemPrompt,
        modelId: modelId,
      );
      final bool overflow = window != null && estimate >= window;
      if (!force && estimate < effective.threshold) {
        return const CompactionOutcome(CompactionStatus.notNeeded);
      }
      // A failed compaction is not retried on every send: wait for a few
      // new messages first (each try is a paid request).
      final int? failedAt = _failedAt[chatId];
      if (!force &&
          failedAt != null &&
          cut >= failedAt &&
          cut - failedAt < failureBackoffMessages) {
        return CompactionOutcome(
          CompactionStatus.failed,
          reason: 'backoff',
          overflow: overflow,
          estimate: estimate,
          window: window,
        );
      }

      // A switch to a smaller window: the previous model writes the
      // summary (its prefix is cached, and the history fits it).
      var summaryModel = modelId;
      var summaryProvider = providerSlug;
      int? summaryWindow = window;
      final previous = ChatCompaction.lastAnswerModel(rows, cut);
      if (window != null && previous != null && previous.$1 != modelId) {
        final int? previousWindow = await _window(previous.$1, previous.$2);
        if (ChatCompaction.summarizeWithPrevious(
          currentModelId: modelId,
          previousModelId: previous.$1,
          currentWindow: window,
          previousWindow: previousWindow,
        )) {
          final String? slug = debugSend != null
              ? previous.$2
              : await ProviderResolutionService.resolveForSend(
                  previous.$1,
                  previous.$2,
                );
          if (slug != null && slug.isNotEmpty) {
            summaryModel = previous.$1;
            summaryProvider = slug;
            summaryWindow = previousWindow;
          }
        }
      }

      final CompactionOutcome outcome = await ChatCompaction.maybeCompact(
        messages: rows,
        end: cut,
        estimatedPromptTokens: estimate,
        budget: effective,
        force: force,
        madeAt: madeAt ?? cut,
        summaryModelId: summaryModel,
        summaryProviderSlug: summaryProvider,
        summaryWindow: summaryWindow,
        systemPrompt: systemPrompt,
        buildHistory: (starts) => buildHistory(rows, starts),
        send:
            debugSend ??
            ({
              required String instruction,
              required List<Map<String, dynamic>> history,
              required String modelId,
              required String providerSlug,
            }) => WebSocketChatService.sendStreamingChat(
              accessToken: accessToken,
              message: instruction,
              modelId: modelId,
              providerSlug: providerSlug,
              history: history,
              systemPrompt: systemPrompt,
              maxTokens: ChatCompaction.summaryMaxTokens,
              // The same tools[] as the chat (prefix cache); the summary
              // request may not call them.
              tools: tools.isEmpty ? null : tools,
              toolChoice: tools.isEmpty ? null : 'none',
              chatId: chatId,
              requestPurpose: 'compact',
            ),
      );
      if (outcome.compacted) {
        _failedAt.remove(chatId);
        return outcome;
      }
      if (outcome.status == CompactionStatus.failed) _failedAt[chatId] = cut;
      return overflow
          ? CompactionOutcome(
              outcome.status,
              reason: outcome.reason,
              overflow: true,
              estimate: estimate,
              window: window,
            )
          : outcome;
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[Compaction] failed: ${error.runtimeType}');
      }
      _failedAt[chatId] = cut;
      return CompactionOutcome(
        CompactionStatus.failed,
        reason: '$error',
        overflow: window != null && estimate >= window,
        estimate: estimate,
        window: window,
      );
    } finally {
      _running.remove(chatId);
    }
  }

  /// The `/compact` command: summarizes everything before the chat's last
  /// user turn now, whatever the size. Same request as [beforeSend] (the
  /// chat's system prompt, `tools[]` and history byte for byte), with no
  /// message being sent: [messages] is the whole chat (only read). On
  /// [CompactionStatus.compacted] the caller writes the record back
  /// ([CompactionOutcome.writeInto]) and persists the chat.
  static Future<CompactionOutcome> compactNow({
    required List<Map<String, String>> messages,
    required String chatId,
    required String modelId,
    required String providerSlug,
    required String accessToken,
    required String systemPrompt,
    required List<Map<String, dynamic>> tools,
    required Future<List<Map<String, dynamic>>> Function(
      List<Map<String, String>> rows,
      List<int> starts,
    )
    buildHistory,
  }) async {
    final List<Map<String, dynamic>> history;
    try {
      history = await buildHistory(messages, <int>[]);
    } catch (error) {
      return CompactionOutcome(CompactionStatus.failed, reason: '$error');
    }
    return beforeSend(
      messages: messages,
      end: messages.length,
      chatId: chatId,
      modelId: modelId,
      providerSlug: providerSlug,
      accessToken: accessToken,
      systemPrompt: systemPrompt,
      tools: tools,
      history: history,
      pendingMessage: '',
      buildHistory: buildHistory,
      force: true,
    );
  }
}
