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

import 'package:chuk_chat/services/chat_compaction.dart';
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

  /// Compacts the chat before a send when its next request reaches the
  /// trigger of [modelId] (or when the chat switches from a model with a
  /// larger window: the old model summarizes, its cache is warm).
  ///
  /// [messages] holds the chat; `0..end-1` is what comes before the message
  /// being sent. [history] is the request history built for this send,
  /// [systemPrompt] the turn's frozen system prompt and [tools] its
  /// `tools[]`: the summary request repeats them byte for byte.
  /// [buildHistory] builds the same history again and fills the message
  /// start offsets. On [CompactionStatus.compacted] the caller persists the
  /// chat and rebuilds the history and the tool session.
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
    required Future<List<Map<String, dynamic>>> Function(List<int> starts)
    buildHistory,
    bool force = false,
  }) async {
    if (ChatOrigin.isAgentsThread(chatId) || end <= 1) {
      return const CompactionOutcome(CompactionStatus.notNeeded);
    }
    try {
      final int? window = await _window(modelId, providerSlug);
      final CompactionBudget? budget = window == null
          ? null
          : ChatCompaction.budgetFor(
              contextWindow: window,
              maxOutput: ChatCompaction.maxOutputFor(
                window,
                ModelSelectionDropdown.providerLimitsForModel(
                  modelId,
                )?.maxCompletionTokens,
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
      final before = messages.sublist(0, end);
      final int estimate = ChatCompaction.estimatePrompt(
        messages: before,
        history: history,
        pendingMessage: pendingMessage,
        systemPrompt: systemPrompt,
        modelId: modelId,
      );
      if (!force && estimate < effective.threshold) {
        return const CompactionOutcome(CompactionStatus.notNeeded);
      }

      // A switch to a smaller window: the previous model writes the
      // summary (its prefix is cached, and the history fits it).
      var summaryModel = modelId;
      var summaryProvider = providerSlug;
      final previous = ChatCompaction.lastAnswerModel(messages, end);
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
          }
        }
      }

      return await ChatCompaction.maybeCompact(
        messages: messages,
        end: end,
        estimatedPromptTokens: estimate,
        budget: effective,
        force: force,
        madeAt: end,
        summaryModelId: summaryModel,
        summaryProviderSlug: summaryProvider,
        buildHistory: buildHistory,
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
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[Compaction] failed: ${error.runtimeType}');
      }
      return CompactionOutcome(CompactionStatus.failed, reason: '$error');
    }
  }

  /// The `/compact` command: summarizes everything before the chat's last
  /// user turn now, whatever the size. Same request as [beforeSend] (the
  /// chat's system prompt, `tools[]` and history byte for byte), with no
  /// message being sent: [messages] is the whole chat. On
  /// [CompactionStatus.compacted] the caller persists the chat.
  static Future<CompactionOutcome> compactNow({
    required List<Map<String, String>> messages,
    required String chatId,
    required String modelId,
    required String providerSlug,
    required String accessToken,
    required String systemPrompt,
    required List<Map<String, dynamic>> tools,
    required Future<List<Map<String, dynamic>>> Function(List<int> starts)
    buildHistory,
  }) async {
    final List<Map<String, dynamic>> history;
    try {
      history = await buildHistory(<int>[]);
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
