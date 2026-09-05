// lib/models/chat_message.dart

/// Delivery status of a chat message in the local queue/UI.
///
/// - [sent]: server acknowledged or stored — default for historical messages
///   and the only state visible until offline support landed.
/// - [pending]: in the persistent offline queue, awaiting connectivity.
/// - [failed]: retried and gave up (non-retryable error or max attempts).
/// - [interrupted]: assistant stream was disposed/cancelled before its final
///   `done` event fired — the persisted body is partial and the UI offers a
///   "Continue generation" affordance.
enum ChatMessageStatus { sent, pending, failed, interrupted }

ChatMessageStatus? _statusFromString(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  switch (raw) {
    case 'pending':
      return ChatMessageStatus.pending;
    case 'failed':
      return ChatMessageStatus.failed;
    case 'sent':
      return ChatMessageStatus.sent;
    case 'interrupted':
      return ChatMessageStatus.interrupted;
  }
  return null;
}

/// Parse an int that may arrive as an int, a num, or a String — the UI map
/// stores `activeVariant` as a stringified int, while a decoded JSON payload
/// carries it as a number.
int? parseFlexibleInt(dynamic value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value.toString());
}

String? _statusToString(ChatMessageStatus? status) {
  if (status == null) return null;
  switch (status) {
    case ChatMessageStatus.sent:
      return 'sent';
    case ChatMessageStatus.pending:
      return 'pending';
    case ChatMessageStatus.failed:
      return 'failed';
    case ChatMessageStatus.interrupted:
      return 'interrupted';
  }
}

/// Represents a single message in a chat.
class ChatMessage {
  ChatMessage({
    required this.role,
    required this.text,
    this.reasoning,
    this.replyContext,
    this.images,
    this.imageMetas,
    this.imageCostEur,
    this.imageGeneratedAt,
    this.attachments,
    this.attachedFilesJson,
    this.toolCalls,
    this.contentBlocks,
    this.modelId,
    this.provider,
    this.status,
    this.queueId,
    this.messageId,
    this.startedAt,
    this.generationMs,
    this.variants,
    this.activeVariant,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      role: json['role'] as String? ?? json['sender'] as String? ?? 'user',
      text: json['text'] as String? ?? '',
      reasoning: json['reasoning'] as String?,
      replyContext: json['replyContext'] as String?,
      images: json['images'] as String?,
      imageMetas: json['imageMetas'] as String?,
      imageCostEur: json['imageCostEur'] as String?,
      imageGeneratedAt: json['imageGeneratedAt'] as String?,
      attachments: json['attachments'] as String?,
      attachedFilesJson: json['attachedFilesJson'] as String?,
      toolCalls: json['toolCalls'] as String?,
      contentBlocks: json['contentBlocks'] as String?,
      modelId: json['modelId'] as String?,
      provider: json['provider'] as String?,
      status: _statusFromString(json['status'] as String?),
      queueId: json['queueId'] as String?,
      messageId: json['messageId'] as String?,
      startedAt: json['startedAt']?.toString(),
      generationMs: json['generationMs']?.toString(),
      variants: json['variants'] as String?,
      activeVariant: parseFlexibleInt(json['activeVariant']),
    );
  }

  final String role;
  final String text;
  final String? reasoning;
  final String? replyContext;
  final String? images;

  /// JSON-encoded list of per-image metadata objects aligned with [images].
  /// Each entry: `{"source": "generated"|"fetched", "caption": "..."}`.
  /// Absent for legacy messages — fall back to message-level metadata.
  final String? imageMetas;
  final String? imageCostEur;
  final String? imageGeneratedAt;
  final String? attachments;
  final String? attachedFilesJson;
  final String? toolCalls;

  /// JSON-encoded list of [ContentBlock] objects representing the ordered
  /// content of an AI response.  When present, the UI renders these blocks
  /// in sequence instead of the flat text + tool-calls layout.
  final String? contentBlocks;

  final String? modelId;
  final String? provider;

  /// Local-only delivery status. `null` is treated as [ChatMessageStatus.sent]
  /// so existing chats stay unchanged.
  final ChatMessageStatus? status;

  /// Optional offline-queue id linking this user message to its pending entry
  /// in [OfflineQueueService]. Local-only.
  final String? queueId;

  /// Stable id assigned to an assistant message at placeholder creation time.
  /// Persisted so the artifact rollback path (regenerate / resend) can match
  /// `artifact_versions.message_id` rows across reloads. `null` for legacy
  /// messages that pre-date the field; the rollback then falls back to
  /// hard-deleting any artifacts created by the discarded message via the
  /// `artifacts.message_id` link (which has been populated since artifact
  /// creation was introduced).
  final String? messageId;

  /// When the request for this answer went out, ISO-8601. Stamped on the
  /// placeholder, so the header can count from the send rather than from
  /// the first tool call.
  final String? startedAt;

  /// How long the turn took, in whole milliseconds, written down when the
  /// answer was saved. Absent on messages from before it was recorded —
  /// the header then falls back to the tool-call stamps.
  final String? generationMs;

  /// JSON-encoded `List` of answer-variant snapshots for a regenerated
  /// assistant message. Each entry captures the swappable content of one
  /// answer (`text`, `reasoning`, `contentBlocks`, `toolCalls`, `modelId`,
  /// `provider`, `generationMs`, `startedAt`, `messageId`, `images`,
  /// `imageMetas`, `imageCostEur`, `imageGeneratedAt`). The currently shown
  /// answer lives in the message's own top-level fields; this list is the
  /// archive the OpenAI-style pager switches between. `null`/absent for
  /// messages that were never regenerated (legacy + first answers).
  final String? variants;

  /// Index into [variants] of the answer currently shown at top level.
  /// `null` when there are no variants.
  final int? activeVariant;

  /// [generationMs] as a duration, or null when it was never recorded or
  /// cannot be read.
  Duration? get workedFor {
    final ms = int.tryParse(generationMs ?? '');
    if (ms == null || ms < 0) return null;
    return Duration(milliseconds: ms);
  }

  // Alias for backwards compatibility
  String get sender => role == 'assistant' ? 'ai' : role;

  /// Effective status — defaults to [ChatMessageStatus.sent] for legacy rows.
  ChatMessageStatus get effectiveStatus =>
      status ?? ChatMessageStatus.sent;

  /// Wire string for [status] (`null` when unset), matching the persisted
  /// `status` field so raw-map bridges can round-trip it without duplicating
  /// the enum switch.
  String? get statusString => _statusToString(status);

  ChatMessage copyWith({
    String? role,
    String? text,
    String? reasoning,
    String? replyContext,
    String? images,
    String? imageMetas,
    String? imageCostEur,
    String? imageGeneratedAt,
    String? attachments,
    String? attachedFilesJson,
    String? toolCalls,
    String? contentBlocks,
    String? modelId,
    String? provider,
    ChatMessageStatus? status,
    String? queueId,
    String? messageId,
    String? startedAt,
    String? generationMs,
    String? variants,
    int? activeVariant,
  }) {
    return ChatMessage(
      role: role ?? this.role,
      text: text ?? this.text,
      reasoning: reasoning ?? this.reasoning,
      replyContext: replyContext ?? this.replyContext,
      images: images ?? this.images,
      imageMetas: imageMetas ?? this.imageMetas,
      imageCostEur: imageCostEur ?? this.imageCostEur,
      imageGeneratedAt: imageGeneratedAt ?? this.imageGeneratedAt,
      attachments: attachments ?? this.attachments,
      attachedFilesJson: attachedFilesJson ?? this.attachedFilesJson,
      toolCalls: toolCalls ?? this.toolCalls,
      contentBlocks: contentBlocks ?? this.contentBlocks,
      modelId: modelId ?? this.modelId,
      provider: provider ?? this.provider,
      status: status ?? this.status,
      queueId: queueId ?? this.queueId,
      messageId: messageId ?? this.messageId,
      startedAt: startedAt ?? this.startedAt,
      generationMs: generationMs ?? this.generationMs,
      variants: variants ?? this.variants,
      activeVariant: activeVariant ?? this.activeVariant,
    );
  }

  Map<String, dynamic> toJson() => {
    'role': role,
    'text': text,
    if (reasoning != null && reasoning!.isNotEmpty) 'reasoning': reasoning,
    if (replyContext != null && replyContext!.isNotEmpty)
      'replyContext': replyContext,
    if (images != null && images!.isNotEmpty) 'images': images,
    if (imageMetas != null && imageMetas!.isNotEmpty) 'imageMetas': imageMetas,
    if (imageCostEur != null && imageCostEur!.isNotEmpty)
      'imageCostEur': imageCostEur,
    if (imageGeneratedAt != null && imageGeneratedAt!.isNotEmpty)
      'imageGeneratedAt': imageGeneratedAt,
    if (attachments != null && attachments!.isNotEmpty)
      'attachments': attachments,
    if (attachedFilesJson != null && attachedFilesJson!.isNotEmpty)
      'attachedFilesJson': attachedFilesJson,
    if (toolCalls != null && toolCalls!.isNotEmpty) 'toolCalls': toolCalls,
    if (contentBlocks != null && contentBlocks!.isNotEmpty)
      'contentBlocks': contentBlocks,
    if (modelId != null && modelId!.isNotEmpty) 'modelId': modelId,
    if (provider != null && provider!.isNotEmpty) 'provider': provider,
    if (_statusToString(status) != null) 'status': _statusToString(status),
    if (queueId != null && queueId!.isNotEmpty) 'queueId': queueId,
    if (messageId != null && messageId!.isNotEmpty) 'messageId': messageId,
    if (startedAt != null && startedAt!.isNotEmpty) 'startedAt': startedAt,
    if (generationMs != null && generationMs!.isNotEmpty)
      'generationMs': generationMs,
    if (variants != null && variants!.isNotEmpty) 'variants': variants,
    if (activeVariant != null) 'activeVariant': activeVariant,
  };
}
