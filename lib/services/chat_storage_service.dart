// lib/services/chat_storage_service.dart
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';

class StoredChat {
  const StoredChat({
    required this.id,
    required this.content,
    required this.createdAt,
  });

  final String id;
  final String content;
  final DateTime createdAt;

  factory StoredChat.fromRow(Map<String, dynamic> row, String decrypted) {
    return StoredChat(
      id: row['id'] as String,
      content: decrypted,
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
        chats.add(StoredChat.fromRow(map, decrypted));
      } on SecretBoxAuthenticationError {
        // Skip corrupted rows silently to keep UI responsive.
        continue;
      } on FormatException {
        continue;
      }
    }
    _savedChats = chats;
  }

  static Future<void> saveChat(String json) async {
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
    final encryptedPayload = await EncryptionService.encrypt(json);
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

    final StoredChat stored = StoredChat.fromRow(inserted, json);
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
            'messages': _decodeMessages(chat.content),
          },
        )
        .toList();
    return jsonEncode(exportPayload);
  }

  static void reset() {
    _savedChats = <StoredChat>[];
    _selectedChatIndex = -1;
  }

  static List<Map<String, String>> _decodeMessages(String content) {
    final segments = content.split('§');
    final messages = <Map<String, String>>[];
    for (final segment in segments) {
      if (segment.isEmpty) continue;
      final parts = segment.split('|');
      if (parts.length != 2) continue;
      messages.add({'sender': parts[0], 'text': parts[1]});
    }
    return messages;
  }
}
