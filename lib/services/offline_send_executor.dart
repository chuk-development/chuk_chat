// lib/services/offline_send_executor.dart
//
// Standalone executor registered with [OfflineRetryManager] that knows how to
// replay a queued chat send.  Runs without an active chat widget — it goes
// straight to the WebSocket and persists the result via
// [ChatStorageService.updateChat].

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/models/chat_stream_event.dart';
import 'package:chuk_chat/models/queued_message.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/network_status_service.dart';
import 'package:chuk_chat/services/offline_retry_manager.dart';
import 'package:chuk_chat/services/offline_send_coordinator.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/services/websocket_chat_service.dart';

class OfflineSendExecutor {
  OfflineSendExecutor._();

  static bool _registered = false;

  /// Idempotently install the executor on [OfflineRetryManager].
  static void register() {
    if (_registered) return;
    _registered = true;
    OfflineRetryManager.instance.registerExecutor(_execute);
    if (kDebugMode) {
      debugPrint('[OfflineSendExecutor] registered');
    }
  }

  static Future<SendExecutorResult> _execute(QueuedMessage queued) async {
    try {
      // Require a Supabase session — without it, sending will 401.
      final session = SupabaseService.auth.currentSession;
      if (session == null) {
        return const SendExecutorResult.failure('not signed in');
      }
      final token = session.accessToken;

      final payload = OfflineSendCoordinator.payloadFrom(queued);
      if (payload.chatId.isEmpty || payload.messageText.isEmpty) {
        return const SendExecutorResult.failure('invalid payload');
      }

      // Load existing chat so we can append the AI response on success.
      final chat = await ChatStorageService.loadFullChat(payload.chatId);
      if (chat == null || !chat.isFullyLoaded) {
        return const SendExecutorResult.failure('chat not loaded');
      }

      final messages = chat.messages.toList();

      // Build conversational history from prior messages (exclude any
      // pending/failed entries that haven't been delivered yet).
      final history = <Map<String, dynamic>>[];
      for (final m in messages) {
        if (m.text.trim().isEmpty || m.text == 'Thinking...') continue;
        if (m.role == 'user' &&
            m.effectiveStatus != ChatMessageStatus.sent) {
          continue;
        }
        history.add({
          'role': m.role == 'user' ? 'user' : 'assistant',
          'content': m.text,
        });
      }

      // Stream the response.
      final reasoning = StringBuffer();
      final content = StringBuffer();
      bool sawError = false;
      String? errorMessage;
      try {
        await for (final ChatStreamEvent event
            in WebSocketChatService.sendStreamingChat(
              accessToken: token,
              message: payload.messageText,
              modelId: payload.modelId,
              providerSlug: payload.providerSlug,
              history: history.isEmpty ? null : history,
              systemPrompt: payload.systemPrompt,
              maxTokens: payload.maxTokens ?? 512,
              images: payload.images,
              reasoningEffort: payload.reasoningEffort,
            )) {
          switch (event) {
            case ContentEvent(:final text):
              content.write(text);
              break;
            case ReasoningEvent(:final text):
              reasoning.write(text);
              break;
            case ErrorEvent(:final message):
              sawError = true;
              errorMessage = message;
              break;
            case DoneEvent():
              break;
            case UsageEvent():
            case MetaEvent():
            case TpsEvent():
              break;
          }
          if (sawError) break;
        }
      } catch (e) {
        return SendExecutorResult.failure(e.toString());
      }

      if (sawError) {
        return SendExecutorResult.failure(errorMessage ?? 'stream error');
      }

      // Find the user message attached to this queue entry and mark it sent.
      final updated = <ChatMessage>[];
      var flippedUser = false;
      for (final m in messages) {
        if (!flippedUser &&
            m.role == 'user' &&
            (m.queueId == queued.id ||
                (m.text == payload.messageText &&
                    m.effectiveStatus != ChatMessageStatus.sent))) {
          updated.add(
            m.copyWith(status: ChatMessageStatus.sent, queueId: ''),
          );
          flippedUser = true;
        } else {
          updated.add(m);
        }
      }
      // Append the AI response.
      updated.add(
        ChatMessage(
          role: 'assistant',
          text: content.toString(),
          reasoning: reasoning.isEmpty ? null : reasoning.toString(),
          modelId: payload.modelId,
          provider: payload.providerSlug,
        ),
      );

      await ChatStorageService.updateChat(
        payload.chatId,
        updated.map((m) => m.toJson()).toList(),
      );
      return const SendExecutorResult.success();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[OfflineSendExecutor] failed: $e');
      }
      // Classify network errors so they stay retryable.
      final msg = e.toString();
      if (NetworkStatusService.isNetworkError(msg)) {
        return SendExecutorResult.failure('network: $msg');
      }
      return SendExecutorResult.failure(msg);
    }
  }
}
