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
// Tools: the executor itself sends a plain request. The real send is one of
// two paths that run the full tool loop, the same as a send on screen:
//  * the chat is open on a screen ([OutboxScreen]): the screen sends the row
//    through its own send path, so the user sees it stream;
//  * otherwise [toolTurn] (`HeadlessChatTurn`) runs the screen's streaming
//    handler with no screen.
// The plain path below is only the fallback when no tool path is installed
// (unit tests of the executor itself).

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/models/chat_stream_event.dart';
import 'package:chuk_chat/models/queued_message.dart';
import 'package:chuk_chat/services/chat_runtime_registry.dart';
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

/// A chat screen that can send an outbox row through its own send path, so
/// a queued message of the chat in view goes out with the full tool loop
/// and streams on screen (docs/OFFLINE_SEND.md).
abstract interface class OutboxScreen {
  /// The chat the screen shows now, or null.
  String? get outboxChatId;

  /// Sends [queued] on screen and reports how it ended. Null when the screen
  /// cannot take it now (the row is not the last message of the chat, or a
  /// turn runs): the headless path sends it instead.
  Future<SendExecutorResult?> sendOutboxRow(
    QueuedMessage queued,
    OfflineSendPayload payload,
  );
}

class OfflineSendExecutor {
  OfflineSendExecutor._();

  static final Set<OutboxScreen> _screens = <OutboxScreen>{};

  /// A chat screen comes up. It answers [OutboxScreen.outboxChatId] live.
  static void registerScreen(OutboxScreen screen) => _screens.add(screen);

  /// A chat screen goes away.
  static void unregisterScreen(OutboxScreen screen) => _screens.remove(screen);

  /// The mounted screen that shows [chatId], or null.
  static OutboxScreen? screenFor(String chatId) {
    for (final OutboxScreen s in _screens) {
      if (s.outboxChatId == chatId) return s;
    }
    return null;
  }

  /// The full tool-loop send with no screen (`HeadlessChatTurn.run`).
  /// Installed at app start; null in unit tests of the plain path.
  static Future<SendExecutorResult> Function(
    QueuedMessage queued,
    OfflineSendPayload payload,
  )?
  toolTurn;

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

  static bool _defaultBusy(String chatId) => isTurnRunning(chatId);

  /// Whether a turn of [chatId] runs now: a stream is open, or a send is in
  /// flight (also between two tool passes, when no stream is open).
  static bool isTurnRunning(String chatId) {
    try {
      if (StreamingManager().isStreaming(chatId)) return true;
    } catch (_) {}
    return ChatRuntimeRegistry.instance.lookup(chatId)?.isSending.value ??
        false;
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

  /// The stored chat, through the [loadChat] seam.
  static Future<StoredChat?> readChat(String chatId) => loadChat(chatId);

  /// Saves the chat on the device and syncs it, through the [saveChat] seam.
  static Future<void> writeChat(
    String chatId,
    List<Map<String, dynamic>> maps,
  ) => saveChat(chatId, maps);

  @visibleForTesting
  static void resetSeams() {
    _screens.clear();
    toolTurn = null;
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

  /// [map] (a stored user message) as delivered: the waiting marks go, and
  /// an empty text (a voice bubble) takes [text].
  static Map<String, dynamic> delivered(
    Map<String, dynamic> map,
    String text,
  ) {
    final out = Map<String, dynamic>.of(map)
      ..remove('status')
      ..remove('queueId')
      ..remove('lastError');
    if ((out['text'] as String?)?.isNotEmpty != true) out['text'] = text;
    return out;
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

      // The chat is on screen: its own send path, with tools, streaming.
      final OutboxScreen? screen = screenFor(payload.chatId);
      if (screen != null) {
        final SendExecutorResult? onScreen = await screen.sendOutboxRow(
          queued,
          payload,
        );
        if (onScreen != null) return onScreen;
      }
      // No screen: the same tool loop, headless.
      final turn = toolTurn;
      if (turn != null) return await turn(queued, payload);

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
        maps[idx] = delivered(maps[idx], payload.messageText);
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
