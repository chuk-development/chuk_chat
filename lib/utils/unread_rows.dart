// lib/utils/unread_rows.dart
//
// Which rows of a thread the reader has not seen yet (bead chuk_chat-f5wd).
//
// The app knows when the reader last had a thread open (`AgentReadMarks`)
// and when each row was written (`sentAt`, else `startedAt`). A row the
// agent wrote after that moment is unread. The reader's own rows never are:
// they wrote them, maybe on another device.

import 'package:chuk_chat/platform_specific/chat/chat_ui_helpers.dart'
    show messageRowTime;

bool _isUnread(Map<String, String> row, DateTime since) {
  if ((row['sender'] ?? 'ai') == 'user') return false;
  final DateTime? at = messageRowTime(row);
  return at != null && at.isAfter(since);
}

/// The index of the first row written after [since], or -1.
int firstUnreadRowIndex(List<Map<String, String>> rows, DateTime? since) {
  if (since == null) return -1;
  for (int i = 0; i < rows.length; i++) {
    if (_isUnread(rows[i], since)) return i;
  }
  return -1;
}

/// How many rows were written after [since] by someone other than the
/// reader.
int unreadRowCount(List<Map<String, String>> rows, DateTime? since) {
  if (since == null) return 0;
  int count = 0;
  for (final Map<String, String> row in rows) {
    if (_isUnread(row, since)) count++;
  }
  return count;
}
