// lib/services/chat_storage_service.dart
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chuk_chat/models/stored_chat.dart';
import 'package:chuk_chat/services/encryption_service.dart';

class ChatStorageService {
  ChatStorageService._();

  static final SupabaseClient _client = Supabase.instance.client;
  static List<StoredChat> _savedChats = [];
  static int _selectedChatIndex = -1;

  static List<StoredChat> get savedChats => List.unmodifiable(_savedChats);
  static int get selectedChatIndex => _selectedChatIndex;
  static set selectedChatIndex(int index) => _selectedChatIndex = index;

  static String get _tableName =>
      dotenv.env['SUPABASE_CHATS_TABLE'] ?? 'user_chats';

  static Future<void> loadChats() async {
    final user = _client.auth.currentUser;
    if (user == null || user.email == null) {
      _savedChats = [];
      return;
    }

    final List<dynamic> response = await _client
        .from(_tableName)
        .select('id, chat_json, created_at')
        .eq('user_id', user.id)
        .order('created_at', ascending: false);

    final List<StoredChat> chats = [];
    for (final dynamic row in response) {
      if (row is! Map<String, dynamic>) continue;
      try {
        final encrypted = row['chat_json'] as String;
        final decrypted = EncryptionService.decryptForUser(
          email: user.email!,
          payload: encrypted,
        );
        final createdAtRaw = row['created_at'];
        DateTime createdAt;
        if (createdAtRaw is String) {
          createdAt = DateTime.parse(createdAtRaw);
        } else if (createdAtRaw is DateTime) {
          createdAt = createdAtRaw.toUtc();
        } else {
          createdAt = DateTime.now().toUtc();
        }
        chats.add(
          StoredChat(
            id: row['id'].toString(),
            content: decrypted,
            createdAt: createdAt,
          ),
        );
      } catch (error) {
        // Skip malformed entries but keep going for the rest.
      }
    }

    _savedChats = chats;
    _selectedChatIndex = -1;
  }

  static Future<void> saveChat(String json) async {
    final user = _client.auth.currentUser;
    if (user == null || user.email == null) {
      return;
    }

    final encrypted = EncryptionService.encryptForUser(
      email: user.email!,
      plaintext: json,
    );

    final Map<String, dynamic> inserted = await _client
        .from(_tableName)
        .insert({
          'user_id': user.id,
          'chat_json': encrypted,
        })
        .select('id, created_at')
        .single();

    final storedChat = StoredChat(
      id: inserted['id'].toString(),
      content: json,
      createdAt: DateTime.parse(inserted['created_at'] as String).toUtc(),
    );

    _savedChats = [storedChat, ..._savedChats];
  }

  static Future<void> loadSavedChatsForSidebar() async {
    await loadChats();
  }

  static void clearCachedChats() {
    _savedChats = [];
    _selectedChatIndex = -1;
  }
}
