// lib/services/offline_send_coordinator.dart
//
// Bridges the chat send flow to the offline queue + retry manager.  Keeps the
// payload schema (`buildPayload` / `payloadFrom`) in one place so the executor
// registered with [OfflineRetryManager] reads the same shape that callers
// produce when enqueueing.
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/models/queued_message.dart';
import 'package:chuk_chat/services/offline_queue_service.dart';
import 'package:chuk_chat/services/offline_retry_manager.dart';

class OfflineSendPayload {
  const OfflineSendPayload({
    required this.chatId,
    required this.messageText,
    required this.modelId,
    required this.providerSlug,
    this.systemPrompt,
    this.replyContext,
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
      replyContext: json['replyContext'] as String?,
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
  final String? replyContext;

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
    if (replyContext != null && replyContext!.isNotEmpty)
      'replyContext': replyContext,
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
class OfflineSendCoordinator {
  OfflineSendCoordinator._();

  /// Enqueue a payload for later send. Returns the queue id assigned to it.
  static Future<String> enqueue(OfflineSendPayload payload) {
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

  /// Triggers an immediate drain of the queue.
  static Future<void> retryNow() => OfflineRetryManager.instance.retryNow();

  /// Helper to decode a [QueuedMessage]'s payload back into a typed value.
  static OfflineSendPayload payloadFrom(QueuedMessage msg) =>
      OfflineSendPayload.fromJson(msg.sendPayload);
}
