// lib/services/chat_storage_mutations.dart

import 'dart:async';
import 'dart:convert';

import 'package:chuk_chat/models/chat_message.dart';
import 'package:chuk_chat/models/stored_chat.dart';
import 'package:chuk_chat/services/chat_preload_service.dart';
import 'package:chuk_chat/services/chat_storage_state.dart';
import 'package:chuk_chat/services/chat_storage_sync.dart'
    show deserializePayloadAsync;
import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/local_chat_cache_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

const int kChatPayloadVersion = 2;

/// Handles chat mutations: star, rename, re-encrypt, export
class ChatStorageMutations {
  ChatStorageMutations._();

  /// Set chat starred status
  static Future<void> setChatStarred(String chatId, bool isStarred) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to update chat favorites.');
    }

    final updatedRows = await SupabaseService.client
        .from('encrypted_chats')
        .update({'is_starred': isStarred})
        .eq('id', chatId)
        .eq('user_id', user.id)
        .select('is_starred');

    if (updatedRows.isEmpty) {
      throw StateError('Chat was not found or access is denied.');
    }

    final remoteStar = updatedRows.first['is_starred'] as bool;
    final existingChat = ChatStorageState.getChatById(chatId);
    if (existingChat != null) {
      ChatStorageState.chatsById[chatId] = existingChat.copyWith(
        isStarred: remoteStar,
      );
      ChatStorageState.notifyChanges(chatId);
    }

    unawaited(LocalChatCacheService.updateStarred(user.id, chatId, remoteStar));
  }

  /// Rename a chat (requires full chat to be loaded)
  static Future<void> renameChat(String chatId, String newName) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to rename chats.');
    }

    final chat = ChatStorageState.getChatById(chatId);
    if (chat == null) {
      throw StateError('Chat not found.');
    }

    if (!chat.isFullyLoaded) {
      throw StateError(
        'Chat must be fully loaded to rename. Call loadFullChat first.',
      );
    }

    final updatedChat = chat.copyWith(customName: newName, title: newName);
    final payload = jsonEncode({
      'v': kChatPayloadVersion,
      'customName': newName,
      'messages': updatedChat.messages.map((m) => m.toJson()).toList(),
    });

    // Encrypt BOTH payload AND title (title is used for fast sidebar loading)
    final encryptedPayload = await EncryptionService.encrypt(payload);
    final encryptedTitle = await EncryptionService.encrypt(newName);

    final updatedRows = await SupabaseService.client
        .from('encrypted_chats')
        .update({
          'encrypted_payload': encryptedPayload,
          'encrypted_title': encryptedTitle,
        })
        .eq('id', chatId)
        .eq('user_id', user.id)
        .select(
          'id, encrypted_payload, created_at, is_starred, updated_at, encrypted_title',
        );

    if (updatedRows.isEmpty) {
      throw StateError('Chat was not found or access is denied.');
    }

    // Get the new updated_at from Supabase response
    final updatedRow = updatedRows.first;
    final newUpdatedAt = updatedRow['updated_at'] != null
        ? DateTime.parse(updatedRow['updated_at'] as String)
        : DateTime.now();

    // Update in-memory state with new title AND new timestamp
    ChatStorageState.chatsById[chatId] = updatedChat.copyWith(
      updatedAt: newUpdatedAt,
    );
    ChatStorageState.notifyChanges(chatId);

    // Update local cache with plaintext row (not encrypted Supabase row)
    await LocalChatCacheService.upsert(
      user.id,
      LocalChatCacheService.buildPlaintextRow(
        id: chatId,
        payload: payload,
        createdAt: updatedRow['created_at'] as String,
        isStarred: (updatedRow['is_starred'] as bool?) ?? false,
        updatedAt: updatedRow['updated_at'] as String?,
        title: newName,
      ),
    );

    // Also update the title cache for sidebar persistence
    await saveTitlesToCache(
      user.id,
      ChatStorageState.chatsById.values.toList(),
    );
    if (kDebugMode) {
      debugPrint(
        '✅ [ChatStorage] Renamed chat $chatId to "$newName" (updatedAt: $newUpdatedAt)',
      );
    }
  }

  /// Re-encrypt all chats with stored chat data
  static Future<void> reencryptChats(List<StoredChat> chats) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) return;

    for (final chat in chats) {
      final payload = jsonEncode({
        'v': kChatPayloadVersion,
        'customName': chat.customName,
        'messages': chat.messages.map((m) => m.toJson()).toList(),
      });
      final encryptedPayload = await EncryptionService.encrypt(payload);

      final updatedRows = await SupabaseService.client
          .from('encrypted_chats')
          .update({'encrypted_payload': encryptedPayload})
          .eq('id', chat.id)
          .eq('user_id', user.id)
          .select('id, encrypted_payload, created_at, is_starred, updated_at');

      if (updatedRows.isNotEmpty) {
        final updatedRow = updatedRows.first;
        ChatStorageState.chatsById[chat.id] = StoredChat.fromRow(
          updatedRow,
          chat.messages,
          customName: chat.customName,
        );

        // Update local cache with plaintext row
        unawaited(LocalChatCacheService.upsert(
          user.id,
          LocalChatCacheService.buildPlaintextRow(
            id: chat.id,
            payload: payload,
            createdAt: updatedRow['created_at'] as String,
            isStarred: (updatedRow['is_starred'] as bool?) ?? false,
            updatedAt: updatedRow['updated_at'] as String?,
            title: chat.title,
          ),
        ));
      }
    }
    ChatStorageState.notifyChanges();
  }

  /// Export all chats as JSON string.
  /// This will wait for all chats to be fully loaded before exporting.
  static Future<String> exportChats() async {
    if (kDebugMode) {
      debugPrint('📤 [Export] Starting export...');
    }

    // Wait for any pending loads
    if (ChatStorageState.loadingCompleter != null) {
      if (kDebugMode) {
        debugPrint('📤 [Export] Waiting for pending loads...');
      }
      await ChatStorageState.loadingCompleter!.future;
    }

    // Make sure every chat's payload is in the local cache.
    if (kDebugMode) {
      debugPrint('📤 [Export] Ensuring the local cache is complete...');
    }
    await ChatPreloadService.awaitPreload();

    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to export chats.');
    }

    // Read each chat's messages one at a time. Chats are not held in
    // memory any more — an export of a long history would otherwise mean
    // hundreds of megabytes of parsed messages resident at once.
    final chats = ChatStorageState.savedChats;
    final exportPayload = <Map<String, dynamic>>[];
    int missing = 0;

    for (final chat in chats) {
      List<ChatMessage>? messages;
      String? customName = chat.customName;

      if (chat.isFullyLoaded) {
        messages = chat.messages;
      } else {
        final row = await LocalChatCacheService.loadById(user.id, chat.id);
        final payload = row?['payload'];
        if (payload is String && payload.isNotEmpty) {
          final decoded = await deserializePayloadAsync(payload);
          messages = decoded.messages;
          customName ??= decoded.customName;
        }
      }

      if (messages == null) {
        missing++;
        continue;
      }

      exportPayload.add({
        'id': chat.id,
        'createdAt': chat.createdAt.toIso8601String(),
        'messages': messages.map((m) => m.toJson()).toList(),
        'customName': ?customName,
      });
    }

    if (kDebugMode) {
      debugPrint(
        '📤 [Export] Exported ${exportPayload.length} chats'
        '${missing > 0 ? ' ($missing without a cached payload)' : ''}',
      );
    }
    return jsonEncode(exportPayload);
  }

  /// Export chats as JSON (alias for exportChats)
  static Future<String> exportChatsAsJson() async {
    return exportChats();
  }
}

/// Save decrypted titles to local cache for instant loading.
/// Shared by mutations and sidebar modules.
Future<void> saveTitlesToCache(String userId, List<StoredChat> chats) async {
  final prefs = sharedPrefsInstance ?? await SharedPreferences.getInstance();
  final cacheKey = 'chat_titles_v1_$userId';

  final data = chats
      .map(
        (chat) => {
          'id': chat.id,
          'title': chat.title ?? chat.previewText,
          'created_at': chat.createdAt.toIso8601String(),
          'is_starred': chat.isStarred,
          if (chat.updatedAt != null)
            'updated_at': chat.updatedAt!.toIso8601String(),
        },
      )
      .toList();

  await prefs.setString(cacheKey, jsonEncode(data));
  final withTimestamp = chats.where((c) => c.updatedAt != null).length;
  if (kDebugMode) {
    debugPrint(
      '💾 [ChatStorage] Saved ${chats.length} titles to cache ($withTimestamp with updatedAt)',
    );
  }
}
