// lib/services/chat_cache_search_text.dart
// One definition of what "searchable" means for a cached chat, shared by
// the native (SQLite) and web (SharedPreferences) cache implementations.

import 'dart:convert';

/// Build the searchable text of a chat payload: message text only.
///
/// A payload is dominated by tool results and reasoning traces. Indexing
/// those makes search large and noisy — a query matches scraped pages the
/// user never read. Message text is what "search my chats" means, and it
/// is about 5% of the bytes.
///
/// Returns lowercase text, or `null` when the payload holds no message
/// text or cannot be parsed.
String? buildChatSearchText(String payload) {
  try {
    final decoded = jsonDecode(payload);
    final messages = decoded is Map<String, dynamic>
        ? decoded['messages']
        : decoded;
    if (messages is! List) return null;

    final buffer = StringBuffer();
    for (final message in messages) {
      if (message is! Map) continue;
      final text = message['text'];
      if (text is String && text.isNotEmpty) {
        buffer
          ..write(text)
          ..write('\n');
      }
    }
    if (buffer.isEmpty) return null;
    return buffer.toString().toLowerCase();
  } catch (_) {
    // Unparseable payload: not searchable rather than a failed write.
    return null;
  }
}
