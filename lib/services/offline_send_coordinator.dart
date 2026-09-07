// COWORK STUB. Upstream: chuk_chat/lib/services/offline_send_coordinator.dart @ d31526a229fdde27c82adf3661d5d3a149db8340.
// Reason: replaced by relay — upstream queues a send while the phone is offline
// and replays it against the hosted API. In CoWork the run belongs to the host,
// which keeps working with no client attached, so there is nothing to queue.
// [OfflineSendPayload] is kept verbatim (it is a plain value object several
// imported files build); the coordinator itself is inert.
// Keep the public API signature-compatible with upstream so the imported chat UI compiles unchanged. Do not "improve" this file.

import 'dart:convert';

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

/// Inert in CoWork: nothing is queued, so [enqueue] returns an id nobody reads.
class OfflineSendCoordinator {
  OfflineSendCoordinator._();

  static Future<String> enqueue(OfflineSendPayload payload) async => '';
}
