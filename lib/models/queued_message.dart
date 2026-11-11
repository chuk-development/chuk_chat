// lib/models/queued_message.dart
import 'dart:convert';

/// Where one outbox row is in its life. See docs/OFFLINE_SEND.md.
///
/// * [queued]: waits for the next flush (network, backoff time).
/// * [preparing]: a preparer runs (voice transcription, image upload).
/// * [sending]: the request is on its way to the server.
/// * [failed]: the row gave up (backoff exhausted, a hard error, or the
///   server had already accepted the request). Only a manual Retry moves it
///   back to [queued]. It is never retried by itself.
/// * [held]: a voice row whose transcript is ready but auto-send is off.
///   The user sends it (Retry = "Send") or deletes it.
enum OutboxState { queued, preparing, sending, failed, held }

OutboxState outboxStateFromString(String? raw) {
  switch (raw) {
    case 'preparing':
      return OutboxState.preparing;
    case 'sending':
      return OutboxState.sending;
    case 'failed':
      return OutboxState.failed;
    case 'held':
      return OutboxState.held;
    default:
      return OutboxState.queued;
  }
}

/// Kinds of outbox rows. A row of kind [voice] carries a recording that
/// must be transcribed before it can be sent.
abstract final class OutboxKind {
  static const String text = 'text';
  static const String voice = 'voice';
}

/// A message persisted in the offline outbox, waiting to be sent.
/// Local-only, never synced. The payload is stored encrypted at rest; this
/// object always holds the decrypted payload.
class QueuedMessage {
  QueuedMessage({
    required this.id,
    required this.chatId,
    required this.sendPayload,
    required this.attemptCount,
    required this.createdAt,
    required this.updatedAt,
    this.lastError,
    this.userId,
    this.kind = OutboxKind.text,
    this.state = OutboxState.queued,
    this.nextAttemptAt = 0,
    this.seq = 0,
    this.locked = false,
  });

  /// Builds a row from storage. [payloadOverride] is the decrypted payload;
  /// without it the `message_json` column is read as plaintext JSON (rows
  /// from version 1 of the database, and the web store before sealing).
  factory QueuedMessage.fromRow(
    Map<String, dynamic> row, {
    Map<String, dynamic>? payloadOverride,
    bool locked = false,
  }) {
    Map<String, dynamic> payload;
    if (payloadOverride != null) {
      payload = payloadOverride;
    } else {
      payload = decodePayload(row['message_json']);
    }
    final created = _asInt(row['created_at']);
    final updatedRaw = row['updated_at'];
    final updated = updatedRaw == null ? created : _asInt(updatedRaw);
    return QueuedMessage(
      id: row['id'] as String,
      chatId: row['chat_id'] as String,
      sendPayload: payload,
      attemptCount: _asInt(row['attempt_count']),
      lastError: row['last_error'] as String?,
      createdAt: created,
      updatedAt: updated,
      userId: row['user_id'] as String?,
      kind: (row['kind'] as String?) ?? OutboxKind.text,
      state: outboxStateFromString(row['state'] as String?),
      nextAttemptAt: _asInt(row['next_attempt_at']),
      seq: _asInt(row['seq']),
      locked: locked,
    );
  }

  /// Plaintext payload JSON to a map. Anything else gives an empty map.
  static Map<String, dynamic> decodePayload(Object? raw) {
    if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) return decoded;
      } catch (_) {}
    }
    return <String, dynamic>{};
  }

  static int _asInt(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw) ?? 0;
    return 0;
  }

  final String id;
  final String chatId;
  final Map<String, dynamic> sendPayload;
  final int attemptCount;
  final String? lastError;
  final int createdAt;
  final int updatedAt;

  /// Owner of the row. Null only for rows from version 1 of the database,
  /// until the first signed-in user claims them.
  final String? userId;

  /// [OutboxKind.text] or [OutboxKind.voice].
  final String kind;
  final OutboxState state;

  /// Epoch ms. The flush skips the row until this time.
  final int nextAttemptAt;

  /// Order inside the outbox. A chat drains in ascending [seq].
  final int seq;

  /// True when the stored payload could not be decrypted (wrong or missing
  /// key). Such a row is kept and never sent until it can be opened.
  final bool locked;

  bool get isVoice => kind == OutboxKind.voice;

  QueuedMessage copyWith({
    int? attemptCount,
    String? lastError,
    bool clearLastError = false,
    int? updatedAt,
    OutboxState? state,
    int? nextAttemptAt,
    Map<String, dynamic>? sendPayload,
  }) {
    return QueuedMessage(
      id: id,
      chatId: chatId,
      sendPayload: sendPayload ?? this.sendPayload,
      attemptCount: attemptCount ?? this.attemptCount,
      lastError: clearLastError ? null : (lastError ?? this.lastError),
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      userId: userId,
      kind: kind,
      state: state ?? this.state,
      nextAttemptAt: nextAttemptAt ?? this.nextAttemptAt,
      seq: seq,
      locked: locked,
    );
  }

  /// The row with a plaintext payload. The stores replace `message_json`
  /// with the sealed value before they write.
  Map<String, dynamic> toRow() => <String, dynamic>{
    'id': id,
    'chat_id': chatId,
    'message_json': jsonEncode(sendPayload),
    'attempt_count': attemptCount,
    'last_error': lastError,
    'created_at': createdAt,
    'updated_at': updatedAt,
    'user_id': userId,
    'kind': kind,
    'state': state.name,
    'next_attempt_at': nextAttemptAt,
    'seq': seq,
  };
}
