/// Puts the queue mark on the user's bubble, and takes it off again.
///
/// The imported bubble only offers **Retry** for a row whose status is
/// `failed` (`widgets/message_bubble/chrome.dart`, imported — not ours to
/// change). A prompt that could not reach the host is exactly such a row: it
/// is queued in [AgentsTaskOutbox], and until it goes out the user must be
/// able to ask for it again. So the stored row is marked `failed` with the
/// outbox entry's id as its `queueId`, and the mark is taken off the moment
/// the prompt actually goes out.
///
/// The mark lives in the stored transcript, not in the screen's own list: the
/// screen is imported and rebuilds from what the store holds. Keeping it there
/// is also what makes it survive a restart — the row is on disk with its mark,
/// so the Retry button is still there after the app was killed.
library;

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/services/chat_storage_service.dart';

/// Reads and writes the transcript. Tests replace both.
typedef QueuedMarkReader =
    List<Map<String, dynamic>>? Function(String sessionKey);
typedef QueuedMarkWriter =
    Future<void> Function(String sessionKey, List<Map<String, dynamic>> rows);

class AgentsQueuedMarks {
  AgentsQueuedMarks._();

  @visibleForTesting
  static QueuedMarkReader? readRows;
  @visibleForTesting
  static QueuedMarkWriter? writeRows;

  /// Marks the newest user row whose text is [prompt] as `failed`, and links
  /// it to its outbox entry through [queueId].
  ///
  /// Returns true when a row was found and changed. A miss is not an error:
  /// the queue still holds the prompt and still sends it. Only the button on
  /// screen is missing, and the next replay puts the row back anyway.
  static Future<bool> markQueued({
    required String sessionKey,
    required String prompt,
    required String queueId,
  }) async {
    if (sessionKey.isEmpty || queueId.isEmpty) return false;
    return _mutate(sessionKey, (List<Map<String, dynamic>> rows) {
      final int index = _lastUserRow(rows, prompt);
      if (index < 0) return false;
      if (rows[index]['status'] == 'failed' &&
          rows[index]['queueId'] == queueId) {
        return false;
      }
      rows[index]['status'] = 'failed';
      rows[index]['queueId'] = queueId;
      return true;
    });
  }

  /// Takes the mark off the row that carries [queueId]. Called when the prompt
  /// has gone out, so the bubble stops offering Retry for something that is
  /// already on its way.
  static Future<bool> clearMark({
    required String sessionKey,
    required String queueId,
  }) async {
    if (sessionKey.isEmpty || queueId.isEmpty) return false;
    return _mutate(sessionKey, (List<Map<String, dynamic>> rows) {
      bool changed = false;
      for (final Map<String, dynamic> row in rows) {
        if (row['queueId'] != queueId) continue;
        row.remove('queueId');
        row['status'] = 'sent';
        changed = true;
      }
      return changed;
    });
  }

  /// The status/queueId pairs the stored transcript holds right now, keyed by
  /// the user row they sit on.
  ///
  /// [AgentsChatStore.replaceThread] uses it to carry a mark across a write
  /// that does not know about it — the imported screen persists its own list
  /// of messages, and that list has no queue mark in it.
  static Map<String, Map<String, String>> marksIn(List<ChatMessage> messages) {
    final Map<String, Map<String, String>> marks =
        <String, Map<String, String>>{};
    for (final ChatMessage message in messages) {
      final String? queueId = message.queueId;
      if (queueId == null || queueId.isEmpty) continue;
      if (!isUserRole(message.role)) continue;
      final String? status = _statusName(message.status);
      if (status == null) continue;
      marks[message.text] = <String, String>{
        'status': status,
        'queueId': queueId,
      };
    }
    return marks;
  }

  /// The imported screen writes `sender: 'user'`; older rows say `me`.
  static bool isUserRole(String role) => role == 'user' || role == 'me';

  static String? _statusName(ChatMessageStatus? status) {
    switch (status) {
      case ChatMessageStatus.pending:
        return 'pending';
      case ChatMessageStatus.failed:
        return 'failed';
      case ChatMessageStatus.sent:
      case ChatMessageStatus.interrupted:
      case null:
        return null;
    }
  }

  static int _lastUserRow(List<Map<String, dynamic>> rows, String prompt) {
    for (int i = rows.length - 1; i >= 0; i--) {
      final Object? role = rows[i]['role'] ?? rows[i]['sender'];
      if (role is! String || !isUserRole(role)) continue;
      if ((rows[i]['text'] as String? ?? '') != prompt) continue;
      return i;
    }
    return -1;
  }

  static Future<bool> _mutate(
    String sessionKey,
    bool Function(List<Map<String, dynamic>> rows) change,
  ) async {
    try {
      final List<Map<String, dynamic>>? rows = (readRows ?? _readFromStore)(
        sessionKey,
      );
      if (rows == null || rows.isEmpty) return false;
      if (!change(rows)) return false;
      await (writeRows ?? _writeToStore)(sessionKey, rows);
      return true;
    } catch (error) {
      // A transcript that cannot be read or written is not worth a crash on a
      // send path. The prompt is queued either way.
      if (kDebugMode) {
        debugPrint('[agents-outbox] queue mark failed for $sessionKey: $error');
      }
      return false;
    }
  }

  static List<Map<String, dynamic>>? _readFromStore(String sessionKey) {
    final StoredChat? chat = ChatStorageService.getChatById(sessionKey);
    final List<ChatMessage>? messages = chat?.messagesOrNull;
    if (messages == null) return null;
    return <Map<String, dynamic>>[
      for (final ChatMessage message in messages)
        Map<String, dynamic>.from(message.toJson()),
    ];
  }

  static Future<void> _writeToStore(
    String sessionKey,
    List<Map<String, dynamic>> rows,
  ) async {
    await ChatStorageService.updateChat(sessionKey, rows);
  }
}
