// lib/models/stored_chat.dart

import 'chat_message.dart';

/// Represents a stored chat with metadata.
/// Supports lazy loading: initially only title is loaded, messages loaded on demand.
class StoredChat {
  StoredChat({
    required this.id,
    List<ChatMessage>? messages,
    required this.createdAt,
    required this.isStarred,
    this.title,
    this.customName,
    this.updatedAt,
  }) : _messages = messages != null ? List<ChatMessage>.unmodifiable(messages) : null;

  /// Create a lightweight chat for sidebar (title only, no messages)
  factory StoredChat.forSidebar({
    required String id,
    required DateTime createdAt,
    required bool isStarred,
    String? title,
    String? customName,
    DateTime? updatedAt,
  }) {
    return StoredChat(
      id: id,
      messages: null, // No messages - lazy loaded
      createdAt: createdAt,
      isStarred: isStarred,
      title: title,
      customName: customName,
      updatedAt: updatedAt,
    );
  }

  final String id;
  final List<ChatMessage>? _messages;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final bool isStarred;
  final String? customName;

  /// Decrypted title for sidebar display (from encrypted_title column)
  final String? title;

  /// Get messages - throws if not fully loaded
  List<ChatMessage> get messages {
    if (_messages == null) {
      throw StateError('Chat messages not loaded. Call ChatStorageService.loadFullChat first.');
    }
    return _messages;
  }

  /// Check if this chat has its messages loaded
  bool get isFullyLoaded => _messages != null;

  /// Get messages or null if not loaded (safe access)
  List<ChatMessage>? get messagesOrNull => _messages;

  /// Get a preview of the chat (first user message or first message text)
  /// Falls back to title if messages not loaded
  String get previewText {
    // If we have a title, use it (faster than iterating messages)
    if (title != null && title!.isNotEmpty) {
      return title!.length > 100 ? '${title!.substring(0, 100)}...' : title!;
    }

    // If messages not loaded, return empty
    if (_messages == null || _messages.isEmpty) return '';

    // Try to find first user message
    for (final msg in _messages) {
      if (msg.role == 'user' && msg.text.isNotEmpty) {
        return msg.text.length > 100
            ? '${msg.text.substring(0, 100)}...'
            : msg.text;
      }
    }
    // Fall back to first message
    final first = _messages.first.text;
    return first.length > 100 ? '${first.substring(0, 100)}...' : first;
  }

  factory StoredChat.fromRow(
    Map<String, dynamic> row,
    List<ChatMessage> messages, {
    String? customName,
    String? title,
  }) {
    return StoredChat(
      id: row['id'] as String,
      messages: messages,
      createdAt: DateTime.parse(row['created_at'] as String),
      updatedAt: row['updated_at'] != null
          ? DateTime.parse(row['updated_at'] as String)
          : null,
      isStarred: (row['is_starred'] as bool?) ?? false,
      customName: customName,
      title: title,
    );
  }

  /// Create from row with title only (for sidebar)
  factory StoredChat.fromRowTitleOnly(
    Map<String, dynamic> row, {
    String? title,
  }) {
    return StoredChat.forSidebar(
      id: row['id'] as String,
      createdAt: DateTime.parse(row['created_at'] as String),
      updatedAt: row['updated_at'] != null
          ? DateTime.parse(row['updated_at'] as String)
          : null,
      isStarred: (row['is_starred'] as bool?) ?? false,
      title: title,
    );
  }

  StoredChat copyWith({
    String? id,
    List<ChatMessage>? messages,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool? isStarred,
    String? customName,
    String? title,
  }) {
    return StoredChat(
      id: id ?? this.id,
      messages: messages ?? _messages,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      isStarred: isStarred ?? this.isStarred,
      customName: customName ?? this.customName,
      title: title ?? this.title,
    );
  }

  /// Create a fully loaded version of this chat
  StoredChat withMessages(List<ChatMessage> messages, {String? customName}) {
    return StoredChat(
      id: id,
      messages: messages,
      createdAt: createdAt,
      updatedAt: updatedAt,
      isStarred: isStarred,
      customName: customName ?? this.customName,
      title: title,
    );
  }
}
