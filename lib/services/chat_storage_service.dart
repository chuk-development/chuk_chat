// lib/services/chat_storage_service.dart
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';

const _kChatPayloadVersion = 1;

class ChatMessage {
  const ChatMessage({required this.sender, required this.text});

  final String sender;
  final String text;

  Map<String, String> toJson() => {'sender': sender, 'text': text};

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      sender: json['sender'] as String? ?? 'user',
      text: json['text'] as String? ?? '',
    );
  }
}

class StoredChat {
  StoredChat({
    required this.id,
    required List<ChatMessage> messages,
    required this.createdAt,
  }) : messages = List<ChatMessage>.unmodifiable(messages);

  final String id;
  final List<ChatMessage> messages;
  final DateTime createdAt;

  String get previewText {
    if (messages.isEmpty) return 'Chat';
    final text = messages.first.text.trim();
    return text.isEmpty ? 'Chat' : text;
  }

  factory StoredChat.fromRow(
    Map<String, dynamic> row,
    List<ChatMessage> messages,
  ) {
    return StoredChat(
      id: row['id'] as String,
      messages: messages,
      createdAt: DateTime.parse(row['created_at'] as String),
    );
  }
}

class ChatStorageService {
  static List<StoredChat> _savedChats = <StoredChat>[];
  static int _selectedChatIndex = -1;

  static List<StoredChat> get savedChats => List.unmodifiable(_savedChats);
  static int get selectedChatIndex => _selectedChatIndex;
  static set selectedChatIndex(int index) => _selectedChatIndex = index;

  static Future<void> loadChats() async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      reset();
      return;
    }
    if (!EncryptionService.hasKey) {
      final loaded = await EncryptionService.tryLoadKey();
      if (!loaded) {
        await EncryptionService.clearKey();
        reset();
        return;
      }
    }
    List<dynamic> data;
    try {
      data = await SupabaseService.client
          .from('encrypted_chats')
          .select('id, encrypted_payload, created_at')
          .eq('user_id', user.id)
          .order('created_at', ascending: false);
    } on PostgrestException catch (error) {
      throw StateError('Failed to load chats: ${error.message}');
    }

    final List<StoredChat> chats = [];
    for (final row in data) {
      final map = row as Map<String, dynamic>;
      final encryptedPayload = map['encrypted_payload'] as String?;
      if (encryptedPayload == null) continue;
      try {
        final decrypted = await EncryptionService.decrypt(encryptedPayload);
        final messages = _deserializeMessages(decrypted);
        chats.add(StoredChat.fromRow(map, messages));
      } on SecretBoxAuthenticationError {
        // Skip corrupted rows silently to keep UI responsive.
        continue;
      } on FormatException {
        continue;
      } on StateError {
        continue;
      }
    }
    _savedChats = chats;
  }

  static Future<void> saveChat(List<Map<String, String>> messagesMaps) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to store chats.');
    }
    if (!EncryptionService.hasKey) {
      final loaded = await EncryptionService.tryLoadKey();
      if (!loaded) {
        throw StateError(
          'Encrypted chats could not be saved because the encryption key is missing. Please sign in again.',
        );
      }
    }

    final messages = messagesMaps
        .map(
          (entry) => ChatMessage(
            sender: entry['sender'] ?? 'user',
            text: entry['text'] ?? '',
          ),
        )
        .where((message) => message.text.trim().isNotEmpty)
        .toList();

    if (messages.isEmpty) {
      return;
    }

    final payload = jsonEncode({
      'v': _kChatPayloadVersion,
      'messages': messages.map((message) => message.toJson()).toList(),
    });

    final encryptedPayload = await EncryptionService.encrypt(payload);
    Map<String, dynamic> inserted;
    try {
      inserted = await SupabaseService.client
          .from('encrypted_chats')
          .insert({'user_id': user.id, 'encrypted_payload': encryptedPayload})
          .select('id, encrypted_payload, created_at')
          .single();
    } on PostgrestException catch (error) {
      throw StateError('Failed to save chat: ${error.message}');
    }

    final StoredChat stored = StoredChat.fromRow(inserted, messages);
    _savedChats = <StoredChat>[stored, ..._savedChats];
  }

  static Future<void> deleteChat(String chatId) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to delete chats.');
    }
    try {
      await SupabaseService.client
          .from('encrypted_chats')
          .delete()
          .eq('id', chatId)
          .eq('user_id', user.id);
    } on PostgrestException catch (error) {
      throw StateError('Failed to delete chat: ${error.message}');
    }

    final removedIndex = _savedChats.indexWhere(
      (storedChat) => storedChat.id == chatId,
    );
    if (removedIndex != -1) {
      _savedChats.removeAt(removedIndex);
      if (_selectedChatIndex == removedIndex) {
        _selectedChatIndex = -1;
      } else if (_selectedChatIndex > removedIndex) {
        _selectedChatIndex -= 1;
      }
    }

    if (_selectedChatIndex >= _savedChats.length) {
      _selectedChatIndex = _savedChats.isEmpty ? -1 : _savedChats.length - 1;
    }
  }

  static Future<void> loadSavedChatsForSidebar() async {
    await loadChats();
  }

  static Future<String> exportChatsAsJson() async {
    await loadChats();
    final exportPayload = _savedChats
        .map(
          (chat) => {
            'id': chat.id,
            'createdAt': chat.createdAt.toIso8601String(),
            'messages': chat.messages
                .map((message) => message.toJson())
                .toList(),
          },
        )
        .toList();
    return jsonEncode(exportPayload);
  }

  static void reset() {
    _savedChats = <StoredChat>[];
    _selectedChatIndex = -1;
  }

  static List<ChatMessage> _deserializeMessages(String payload) {
    try {
      final dynamic decoded = jsonDecode(payload);
      if (decoded is Map<String, dynamic>) {
        final version = decoded['v'];
        if (version != _kChatPayloadVersion) {
          throw StateError('Unsupported chat payload version: $version');
        }
        final rawMessages =
            decoded['messages'] as List<dynamic>? ?? <dynamic>[];
        return rawMessages
            .whereType<Map<String, dynamic>>()
            .map(ChatMessage.fromJson)
            .toList();
      }
    } catch (_) {
      // Fall back to legacy pipe/section delimited format.
    }

    final legacySegments = payload.split('§');
    final legacyMessages = <ChatMessage>[];
    for (final segment in legacySegments) {
      if (segment.isEmpty) continue;
      final separatorIndex = segment.indexOf('|');
      if (separatorIndex == -1) continue;
      final sender = segment.substring(0, separatorIndex);
      final text = segment.substring(separatorIndex + 1);
      legacyMessages.add(ChatMessage(sender: sender, text: text));
    }
    return legacyMessages;
  }
}
