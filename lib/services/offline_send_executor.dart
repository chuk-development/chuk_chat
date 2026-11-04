// lib/services/offline_send_executor.dart
//
// Sends one queued chat message without a chat screen (docs/OFFLINE_SEND.md).
// It streams the reply over the normal chat socket and writes the reply into
// the stored chat. The open chat screen reloads on the success event of
// [OfflineRetryManager] and so shows the reply.
//
// What it sends: the queued text (documents are already inlined by the
// composition step), the image storage paths, the system prompt resolved at
// send time (workspace and artifact context included), the model, provider
// and reasoning effort, and a response budget computed from the model's
// limits at flush time.
//
// What it does NOT do: tool calls. The tool loop lives in the chat screen
// (it needs the tool executor, approval cards and MCP sessions of a mounted
// screen). A headless send without tools gives a plain answer; the user can
// regenerate in the chat to get a tool-using one.

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/models/chat_stream_event.dart';
import 'package:chuk_chat/models/queued_message.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/message_composition_service.dart';
import 'package:chuk_chat/services/network_status_service.dart';
import 'package:chuk_chat/services/offline_retry_manager.dart';
import 'package:chuk_chat/services/offline_send_coordinator.dart';
import 'package:chuk_chat/services/streaming_manager.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/services/websocket_chat_service.dart';
import 'package:chuk_chat/widgets/model_selection_dropdown.dart';

/// One headless request, as handed to the stream function.
class OfflineSendRequest {
  const OfflineSendRequest({
    required this.accessToken,
    required this.chatId,
    required this.message,
    required this.modelId,
    required this.providerSlug,
    required this.history,
    required this.maxTokens,
    this.systemPrompt,
    this.images,
    this.reasoningEffort,
  });

  final String accessToken;
  final String chatId;
  final String message;
  final String modelId;
  final String providerSlug;
  final List<Map<String, dynamic>> history;
  final int maxTokens;
  final String? systemPrompt;
  final List<String>? images;
  final String? reasoningEffort;
}

class OfflineSendExecutor {
  OfflineSendExecutor._();

  static bool _registered = false;

  /// Budget when the model's limits are not known yet (the model list has
  /// not loaded) and the payload has none better than the old default.
  static const int fallbackMaxTokens = 4096;

  // ── Test seams ──────────────────────────────────────────────────────
  @visibleForTesting
  static String? Function() accessToken = _defaultAccessToken;
  @visibleForTesting
  static Stream<ChatStreamEvent> Function(OfflineSendRequest req) stream =
      _defaultStream;
  /// A chat whose turn is streaming on screen is left alone: the screen
  /// saves its own list at the end of the turn and would drop a reply
  /// written under it. The row waits for the next flush.
  @visibleForTesting
  static bool Function(String chatId) isChatBusy = _defaultBusy;
  @visibleForTesting
  static Future<StoredChat?> Function(String chatId) loadChat =
      ChatStorageService.loadFullChat;
  @visibleForTesting
  static Future<void> Function(String chatId, List<Map<String, dynamic>> maps)
  saveChat = _defaultSave;

  static String? _defaultAccessToken() {
    try {
      return SupabaseService.auth.currentSession?.accessToken;
    } catch (_) {
      return null;
    }
  }

  static bool _defaultBusy(String chatId) {
    try {
      return StreamingManager().isStreaming(chatId);
    } catch (_) {
      return false;
    }
  }

  static Stream<ChatStreamEvent> _defaultStream(OfflineSendRequest r) =>
      WebSocketChatService.sendStreamingChat(
        accessToken: r.accessToken,
        message: r.message,
        modelId: r.modelId,
        providerSlug: r.providerSlug,
        history: r.history.isEmpty ? null : r.history,
        systemPrompt: r.systemPrompt,
        maxTokens: r.maxTokens,
        images: r.images,
        reasoningEffort: r.reasoningEffort,
        chatId: r.chatId,
      );

  static Future<void> _defaultSave(
    String chatId,
    List<Map<String, dynamic>> maps,
  ) async {
    await ChatStorageService.saveLocal(maps, chatId: chatId);
    // The cloud copy is best effort; the dirty mark retries it.
    unawaited(
      ChatStorageService.syncChat(chatId, maps).then(
        (_) {},
        onError: (Object e) {
          if (kDebugMode) debugPrint('[OfflineSendExecutor] sync later: $e');
        },
      ),
    );
  }

  @visibleForTesting
  static void resetSeams() {
    accessToken = _defaultAccessToken;
    stream = _defaultStream;
    isChatBusy = _defaultBusy;
    loadChat = ChatStorageService.loadFullChat;
    saveChat = _defaultSave;
  }

  /// Idempotently install the executor on [OfflineRetryManager].
  static void register() {
    if (_registered) return;
    _registered = true;
    OfflineRetryManager.instance.registerExecutor(execute);
    OfflineRetryManager.instance.registerAgentsHandoff(
      OfflineSendCoordinator.agentsHandoff,
    );
    if (kDebugMode) {
      debugPrint('[OfflineSendExecutor] registered');
    }
  }

  /// Index of the bubble that belongs to [queued] in [messages], or -1.
  /// By queue id first; then the last user message with the same text that
  /// has no reply after it (the bubble lost its id, e.g. a cloud copy).
  static int findTarget(
    List<ChatMessage> messages,
    QueuedMessage queued,
    String text,
  ) {
    for (var i = 0; i < messages.length; i++) {
      if (messages[i].queueId == queued.id) return i;
    }
    for (var i = messages.length - 1; i >= 0; i--) {
      final m = messages[i];
      if (m.role != 'user') continue;
      final answered = i + 1 < messages.length && messages[i + 1].role != 'user';
      if (!answered && m.text == text) return i;
      break;
    }
    return -1;
  }

  /// Response budget: the model's limits when known, else the queued value
  /// when it is better than the old 512 default, else [fallbackMaxTokens].
  static int budgetFor({
    required String modelId,
    required List<Map<String, dynamic>> history,
    required String message,
    String? systemPrompt,
    int? queued,
  }) {
    if (ModelSelectionDropdown.providerLimitsForModel(modelId) != null) {
      final b = MessageCompositionService.resolveResponseTokenBudget(
        selectedModelId: modelId,
        apiHistory: history,
        aiPromptContent: message,
        systemPrompt: systemPrompt,
      );
      if (b.maxResponseTokens != null) return b.maxResponseTokens!;
    }
    if (queued != null && queued > 512) return queued;
    return fallbackMaxTokens;
  }

  static Future<SendExecutorResult> execute(QueuedMessage queued) async {
    try {
      final token = accessToken();
      if (token == null || token.isEmpty) {
        return const SendExecutorResult.deferred('not signed in');
      }

      final payload = OfflineSendCoordinator.payloadFrom(queued);
      if (payload.chatId.isEmpty || payload.messageText.trim().isEmpty) {
        return const SendExecutorResult.failure('invalid payload');
      }
      if (isChatBusy(payload.chatId)) {
        return const SendExecutorResult.deferred('chat busy');
      }

      final chat = await loadChat(payload.chatId);
      if (chat == null || !chat.isFullyLoaded) {
        return const SendExecutorResult.failure('chat not found');
      }
      final before = chat.messages.toList();
      final target = findTarget(before, queued, payload.messageText);
      final historySource = target >= 0 ? before.sublist(0, target) : before;

      // History: everything before the queued message that was delivered.
      final history = <Map<String, dynamic>>[];
      for (final m in historySource) {
        if (m.text.trim().isEmpty || m.text == 'Thinking...') continue;
        if (m.role == 'user' && m.effectiveStatus != ChatMessageStatus.sent) {
          continue;
        }
        history.add({
          'role': m.role == 'user' ? 'user' : 'assistant',
          'content': m.text,
        });
      }

      final maxTokens = budgetFor(
        modelId: payload.modelId,
        history: history,
        message: payload.messageText,
        systemPrompt: payload.systemPrompt,
        queued: payload.maxTokens,
      );

      final reasoning = StringBuffer();
      final content = StringBuffer();
      var accepted = false;
      String? errorMessage;
      try {
        await for (final ChatStreamEvent event in stream(
          OfflineSendRequest(
            accessToken: token,
            chatId: payload.chatId,
            message: payload.messageText,
            modelId: payload.modelId,
            providerSlug: payload.providerSlug,
            history: history,
            maxTokens: maxTokens,
            systemPrompt: payload.systemPrompt,
            images: payload.images,
            reasoningEffort: payload.reasoningEffort,
          ),
        )) {
          if (event is! ErrorEvent) accepted = true;
          switch (event) {
            case ContentEvent(:final text):
              content.write(text);
            case FinalContentEvent(:final text):
              content
                ..clear()
                ..write(text);
            case ReasoningEvent(:final text):
              reasoning.write(text);
            case ErrorEvent(:final message):
              errorMessage = message;
            case DoneEvent():
            case UsageEvent():
            case MetaEvent():
            case TpsEvent():
            case ToolCallsEvent():
            case HeartbeatEvent():
              break;
          }
          if (errorMessage != null) break;
        }
      } catch (e) {
        errorMessage = e.toString();
      }

      if (errorMessage != null) {
        // Once the server answered anything, a second send could bill the
        // turn twice: the row fails and waits for the user's Retry.
        return accepted
            ? SendExecutorResult.accepted(errorMessage)
            : SendExecutorResult.failure(_classify(errorMessage));
      }
      if (content.isEmpty) {
        return const SendExecutorResult.accepted('empty reply');
      }

      // Re-read: the chat may have changed while the reply streamed.
      final fresh = await loadChat(payload.chatId) ?? chat;
      final messages = fresh.messages.toList();
      var idx = findTarget(messages, queued, payload.messageText);
      final maps = messages.map((m) => m.toJson()).toList();
      if (idx < 0) {
        // The bubble is gone (another device's copy replaced the chat):
        // put the message back so the reply has its question.
        maps.add({'role': 'user', 'text': payload.messageText});
        idx = maps.length - 1;
      } else {
        maps[idx] = Map<String, dynamic>.of(maps[idx])
          ..remove('status')
          ..remove('queueId')
          ..remove('lastError')
          ..['text'] = (maps[idx]['text'] as String?)?.isNotEmpty == true
              ? maps[idx]['text']
              : payload.messageText;
      }
      final reply = ChatMessage(
        role: 'assistant',
        text: content.toString(),
        reasoning: reasoning.isEmpty ? null : reasoning.toString(),
        modelId: payload.modelId,
        provider: payload.providerSlug,
      ).toJson();
      // Right after its question; later queued messages stay after it.
      maps.insert(idx + 1, reply);
      await saveChat(payload.chatId, maps);
      return const SendExecutorResult.success();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[OfflineSendExecutor] failed: ${e.runtimeType}');
      }
      return SendExecutorResult.failure(_classify(e.toString()));
    }
  }

  /// Network errors keep the word "network" so the manager retries them.
  static String _classify(String msg) =>
      NetworkStatusService.isNetworkError(msg) ? 'network: $msg' : msg;
}
