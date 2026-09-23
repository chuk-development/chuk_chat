// lib/services/offline_send_coordinator.dart
//
// Bridges the chat send flow to the offline queue + retry manager.  Keeps the
// payload schema (`buildPayload` / `payloadFrom`) in one place so the executor
// registered with [OfflineRetryManager] reads the same shape that callers
// produce when enqueueing.
//
// AGENTS ADAPTATION. With FEATURE_AGENTS off this is upstream's file in
// behaviour: every payload goes into [OfflineQueueService], which
// [OfflineRetryManager] drains through [OfflineSendExecutor].
//
// With it on, the chat kind picks the queue ([ChatOrigin]):
//
// * a chuk_chat chat keeps upstream's path, so a message typed offline is
//   sent by the executor once the network is back;
// * an Agents thread queues only the PROMPT in [AgentsTaskOutbox]. The run
//   belongs to the host and keeps going with no client attached, so the
//   answer must never be replayed here. The thread view flushes that outbox
//   when the host is paired.
//
// [OfflineSendPayload] stays verbatim: several imported files build it.
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/models/queued_message.dart';
import 'package:chuk_chat/services/agents/agents_task_outbox.dart';
import 'package:chuk_chat/services/offline_queue_service.dart';
import 'package:chuk_chat/services/offline_retry_manager.dart';
import 'package:chuk_chat/services/storage/chat_origin.dart';

class OfflineSendPayload {
  const OfflineSendPayload({
    required this.chatId,
    required this.messageText,
    required this.modelId,
    required this.providerSlug,
    this.systemPrompt,
    this.imagesJson,
    this.attachmentsJson,
    this.attachedFilesJson,
    this.maxTokens,
    this.reasoningEffort,
  });

  factory OfflineSendPayload.fromJson(Map<String, dynamic> json) {
    return OfflineSendPayload(
      chatId: json['chatId'] as String? ?? '',
      messageText: json['messageText'] as String? ?? '',
      modelId: json['modelId'] as String? ?? '',
      providerSlug: json['providerSlug'] as String? ?? '',
      systemPrompt: json['systemPrompt'] as String?,
      imagesJson: json['imagesJson'] as String?,
      attachmentsJson: json['attachmentsJson'] as String?,
      attachedFilesJson: json['attachedFilesJson'] as String?,
      maxTokens: json['maxTokens'] is int ? json['maxTokens'] as int : null,
      reasoningEffort: json['reasoningEffort'] as String?,
    );
  }

  final String chatId;
  final String messageText;
  final String modelId;
  final String providerSlug;
  final String? systemPrompt;

  /// JSON-encoded list of image data URLs (already prepared in send flow).
  final String? imagesJson;

  /// JSON-encoded document attachments.
  final String? attachmentsJson;

  /// JSON-encoded original AttachedFile list (for resend reconstruction).
  final String? attachedFilesJson;

  final int? maxTokens;
  final String? reasoningEffort;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'chatId': chatId,
    'messageText': messageText,
    'modelId': modelId,
    'providerSlug': providerSlug,
    if (systemPrompt != null && systemPrompt!.isNotEmpty)
      'systemPrompt': systemPrompt,
    if (imagesJson != null && imagesJson!.isNotEmpty) 'imagesJson': imagesJson,
    if (attachmentsJson != null && attachmentsJson!.isNotEmpty)
      'attachmentsJson': attachmentsJson,
    if (attachedFilesJson != null && attachedFilesJson!.isNotEmpty)
      'attachedFilesJson': attachedFilesJson,
    if (maxTokens != null) 'maxTokens': maxTokens,
    if (reasoningEffort != null) 'reasoningEffort': reasoningEffort,
  };

  List<String>? get images {
    final json = imagesJson;
    if (json == null || json.isEmpty) return null;
    try {
      final decoded = jsonDecode(json);
      if (decoded is List) return decoded.whereType<String>().toList();
    } catch (_) {}
    return null;
  }
}

/// Convenience wrapper around [OfflineQueueService] + [OfflineRetryManager].
/// AGENTS: an Agents thread's prompt goes into [AgentsTaskOutbox] instead.
class OfflineSendCoordinator {
  OfflineSendCoordinator._();

  /// Enqueue a payload for later send. Returns the queue id assigned to it.
  ///
  /// The id is what the caller writes into the bubble's `queueId`; the drain
  /// of the same queue finds the row again by it.
  static Future<String> enqueue(OfflineSendPayload payload) {
    if (ChatOrigin.isAgentsThread(payload.chatId)) {
      return _enqueueAgentsPrompt(payload);
    }
    if (kDebugMode) {
      debugPrint(
        '[OfflineSend] enqueue chat=${payload.chatId} '
        'text_len=${payload.messageText.length}',
      );
    }
    return OfflineQueueService.instance.enqueue(
      chatId: payload.chatId,
      sendPayload: payload.toJson(),
    );
  }

  /// AGENTS: the payload's [OfflineSendPayload.chatId] IS the executor's
  /// `session_key`, so the prompt queues under the key the flush sends it on.
  /// Everything upstream needs to reproduce the answer (system prompt,
  /// history, `maxTokens`) is dropped: the host composes the run.
  static Future<String> _enqueueAgentsPrompt(OfflineSendPayload payload) async {
    final OutboxTask task = await AgentsTaskOutbox.enqueue(
      sessionKey: payload.chatId,
      prompt: payload.messageText,
      modelId: payload.modelId.isEmpty ? null : payload.modelId,
      providerSlug: payload.providerSlug.isEmpty ? null : payload.providerSlug,
      reasoningEffort: payload.reasoningEffort,
    );
    return task.localId;
  }

  /// Triggers an immediate drain of the queue.
  static Future<void> retryNow() => OfflineRetryManager.instance.retryNow();

  /// Helper to decode a [QueuedMessage]'s payload back into a typed value.
  static OfflineSendPayload payloadFrom(QueuedMessage msg) =>
      OfflineSendPayload.fromJson(msg.sendPayload);
}
