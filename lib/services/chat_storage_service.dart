// lib/services/chat_storage_service.dart
import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
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
  static final StreamController<void> _changesController =
      StreamController<void>.broadcast();
  static RealtimeChannel? _realtimeChannel;
  static String? _realtimeUserId;
  static int selectedChatIndex = -1;

  static List<StoredChat> get savedChats => List.unmodifiable(_savedChats);
  static Stream<void> get changes => _changesController.stream;

  static Future<void> loadChats() async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      reset();
      return;
    }
    await _ensureRealtimeSubscription(user.id);
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
    _notifyChanges();
  }

  static Future<StoredChat?> saveChat(
    List<Map<String, String>> messagesMaps,
  ) async {
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

    final messages = _mapToChatMessages(messagesMaps);

    if (messages.isEmpty) {
      return null;
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

    final stored = StoredChat.fromRow(inserted, messages);
    _savedChats = <StoredChat>[stored, ..._savedChats];
    _notifyChanges();
    return stored;
  }

  static Future<StoredChat?> updateChat(
    String chatId,
    List<Map<String, String>> messagesMaps,
  ) async {
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

    final messages = _mapToChatMessages(messagesMaps);
    if (messages.isEmpty) {
      return null;
    }

    final payload = jsonEncode({
      'v': _kChatPayloadVersion,
      'messages': messages.map((message) => message.toJson()).toList(),
    });

    final encryptedPayload = await EncryptionService.encrypt(payload);
    Map<String, dynamic> updated;
    try {
      updated = await SupabaseService.client
          .from('encrypted_chats')
          .update({'encrypted_payload': encryptedPayload})
          .eq('id', chatId)
          .eq('user_id', user.id)
          .select('id, encrypted_payload, created_at')
          .single();
    } on PostgrestException catch (error) {
      throw StateError('Failed to update chat: ${error.message}');
    }

    final stored = StoredChat.fromRow(updated, messages);
    final index = _savedChats.indexWhere((chat) => chat.id == chatId);
    if (index != -1) {
      final updatedChats = List<StoredChat>.from(_savedChats);
      updatedChats[index] = stored;
      _savedChats = updatedChats;
    } else {
      _savedChats = <StoredChat>[stored, ..._savedChats];
    }
    _notifyChanges();
    return stored;
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
      if (selectedChatIndex == removedIndex) {
        selectedChatIndex = -1;
      } else if (selectedChatIndex > removedIndex) {
        selectedChatIndex -= 1;
      }
    }

    if (selectedChatIndex >= _savedChats.length) {
      selectedChatIndex = _savedChats.isEmpty ? -1 : _savedChats.length - 1;
    }
    _notifyChanges();
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
    selectedChatIndex = -1;
    _notifyChanges();
    unawaited(_stopRealtimeSubscription());
  }

  static List<ChatMessage> _mapToChatMessages(
    List<Map<String, String>> messagesMaps,
  ) {
    return messagesMaps
        .map(
          (entry) => ChatMessage(
            sender: entry['sender'] ?? 'user',
            text: entry['text'] ?? '',
          ),
        )
        .where((message) => message.text.trim().isNotEmpty)
        .toList();
  }

  static List<ChatMessage> _deserializeMessages(String payload) {
    try {
      final dynamic decoded = jsonDecode(payload);
      if (decoded is Map<String, dynamic>) {
        final dynamic versionValue = decoded['v'];
        int? version;
        if (versionValue is int) {
          version = versionValue;
        } else if (versionValue is String) {
          version = int.tryParse(versionValue);
        }
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

  static void _notifyChanges() {
    if (_changesController.isClosed) {
      return;
    }
    _changesController.add(null);
  }

  static Future<void> _ensureRealtimeSubscription(String userId) async {
    if (_realtimeUserId == userId && _realtimeChannel != null) {
      return;
    }
    await _stopRealtimeSubscription();

    final channelName = 'public:encrypted_chats_user_$userId';
    final channel = SupabaseService.client.channel(channelName);
    void handleChange(PostgresChangePayload payload) {
      unawaited(_reloadChatsFromRealtime());
    }

    channel
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'encrypted_chats',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: userId,
          ),
          callback: handleChange,
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'encrypted_chats',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: userId,
          ),
          callback: handleChange,
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'encrypted_chats',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: userId,
          ),
          callback: handleChange,
        );

    channel.subscribe();
    _realtimeChannel = channel;
    _realtimeUserId = userId;
  }

  static Future<void> _reloadChatsFromRealtime() async {
    try {
      await loadChats();
    } catch (error, stackTrace) {
      debugPrint('Realtime chat sync failed: $error');
      debugPrint('$stackTrace');
    }
  }

  static Future<void> _stopRealtimeSubscription() async {
    if (_realtimeChannel == null) {
      _realtimeUserId = null;
      return;
    }
    try {
      await _realtimeChannel!.unsubscribe();
    } catch (error, stackTrace) {
      debugPrint('Failed to unsubscribe from chat realtime: $error');
      debugPrint('$stackTrace');
    } finally {
      _realtimeChannel = null;
      _realtimeUserId = null;
    }
  }
}
