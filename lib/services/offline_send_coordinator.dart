// AGENTS ADAPTER. Upstream: chuk_chat/lib/services/offline_send_coordinator.dart @ d31526a229fdde27c82adf3661d5d3a149db8340.
// Reason: replaced by relay. Upstream queues a send while the phone is offline
// and later replays it against the hosted API, ANSWER AND ALL. Agents must not
// do that: the run belongs to the host and keeps going with no client
// attached, so only the PROMPT is queued here — never the reply.
// [OfflineSendPayload] is kept verbatim (it is a plain value object several
// imported files build).
//
// It used to be inert, and that lost data. The imported send paths
// (`chat_ui_mobile.dart`, `desktop_send_logic.dart`) short-circuit on
// `NetworkStatusService.isOnline == false` BEFORE the relay is ever asked, and
// they call this. With `enqueue` returning `''` the row was written with
// `status: pending, queueId: ''` and nothing behind it: a prompt typed in
// airplane mode was silently gone. It now goes into [AgentsTaskOutbox], the
// same queue the host-unreachable path uses.
// Keep the public API signature-compatible with upstream so the imported chat UI compiles unchanged. Do not "improve" this file.

import 'dart:convert';

import 'package:chuk_chat/models/queued_message.dart';
import 'package:chuk_chat/services/agents/agents_task_outbox.dart';
import 'package:chuk_chat/services/offline_retry_manager.dart';

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

/// The imported send paths' door into [AgentsTaskOutbox].
///
/// One id names the same thing everywhere: the payload's [OfflineSendPayload.chatId]
/// IS the executor's `session_key` AND the imported screen's `selectedChatId`
/// (see `AgentsThreadView.threadKey`), so the prompt queues under the very key
/// the flush later sends it on.
class OfflineSendCoordinator {
  OfflineSendCoordinator._();

  /// Queues the prompt and returns the outbox entry's id.
  ///
  /// The returned id is what the caller writes into the bubble's `queueId`, so
  /// it must be REAL: it is how the flush later finds the row again and takes
  /// the queue mark off it.
  ///
  /// Everything upstream would need to reproduce the answer — the system
  /// prompt, the history, `maxTokens` — is deliberately dropped. The host
  /// composes the run; this side only has to deliver the question.
  static Future<String> enqueue(OfflineSendPayload payload) async {
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
  ///
  /// RESTORED from upstream (chuk_chat). Dropped by the Agents adapter because
  /// nothing in the imported closure called it; the merged tree brings
  /// upstream's offline retry path back with it.
  static Future<void> retryNow() => OfflineRetryManager.instance.retryNow();

  /// Helper to decode a [QueuedMessage]'s payload back into a typed value.
  ///
  /// RESTORED from upstream: `services/offline_send_executor.dart` calls it.
  static OfflineSendPayload payloadFrom(QueuedMessage msg) =>
      OfflineSendPayload.fromJson(msg.sendPayload);
}
