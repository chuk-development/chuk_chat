// lib/models/stored_chat.dart
class StoredChat {
  StoredChat({
    required this.id,
    required this.content,
    required this.createdAt,
  });

  final String id;
  final String content;
  final DateTime createdAt;

  String get previewTitle {
    final segments = content.split('§');
    for (final segment in segments) {
      if (segment.trim().isEmpty) continue;
      final parts = segment.split('|');
      if (parts.length == 2 && parts.first == 'user') {
        final sanitized = parts.last.trim();
        if (sanitized.isNotEmpty) {
          return sanitized.length > 60 ? '${sanitized.substring(0, 60)}…' : sanitized;
        }
      }
    }
    return 'Chat';
  }
}
