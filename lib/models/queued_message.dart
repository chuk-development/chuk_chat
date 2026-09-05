// lib/models/queued_message.dart
import 'dart:convert';

/// A message persisted in the offline queue, waiting for connectivity so it
/// can be retried.  Local-only — never synced.
class QueuedMessage {
  QueuedMessage({
    required this.id,
    required this.chatId,
    required this.sendPayload,
    required this.attemptCount,
    required this.createdAt,
    required this.updatedAt,
    this.lastError,
  });

  factory QueuedMessage.fromRow(Map<String, dynamic> row) {
    final raw = row['message_json'];
    Map<String, dynamic> payload;
    if (raw is String && raw.isNotEmpty) {
      final decoded = jsonDecode(raw);
      payload = decoded is Map<String, dynamic>
          ? decoded
          : <String, dynamic>{};
    } else {
      payload = <String, dynamic>{};
    }
    final createdRaw = row['created_at'];
    final updatedRaw = row['updated_at'];
    int created = 0;
    int updated = 0;
    if (createdRaw is int) {
      created = createdRaw;
    } else if (createdRaw is num) {
      created = createdRaw.toInt();
    } else if (createdRaw is String) {
      created = int.tryParse(createdRaw) ?? 0;
    }
    if (updatedRaw is int) {
      updated = updatedRaw;
    } else if (updatedRaw is num) {
      updated = updatedRaw.toInt();
    } else if (updatedRaw is String) {
      updated = int.tryParse(updatedRaw) ?? created;
    } else {
      updated = created;
    }

    final attemptRaw = row['attempt_count'];
    int attempts = 0;
    if (attemptRaw is int) {
      attempts = attemptRaw;
    } else if (attemptRaw is num) {
      attempts = attemptRaw.toInt();
    } else if (attemptRaw is String) {
      attempts = int.tryParse(attemptRaw) ?? 0;
    }

    return QueuedMessage(
      id: row['id'] as String,
      chatId: row['chat_id'] as String,
      sendPayload: payload,
      attemptCount: attempts,
      lastError: row['last_error'] as String?,
      createdAt: created,
      updatedAt: updated,
    );
  }

  final String id;
  final String chatId;
  final Map<String, dynamic> sendPayload;
  final int attemptCount;
  final String? lastError;
  final int createdAt;
  final int updatedAt;

  QueuedMessage copyWith({
    int? attemptCount,
    String? lastError,
    bool clearLastError = false,
    int? updatedAt,
  }) {
    return QueuedMessage(
      id: id,
      chatId: chatId,
      sendPayload: sendPayload,
      attemptCount: attemptCount ?? this.attemptCount,
      lastError: clearLastError ? null : (lastError ?? this.lastError),
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toRow() => <String, dynamic>{
    'id': id,
    'chat_id': chatId,
    'message_json': jsonEncode(sendPayload),
    'attempt_count': attemptCount,
    'last_error': lastError,
    'created_at': createdAt,
    'updated_at': updatedAt,
  };
}
