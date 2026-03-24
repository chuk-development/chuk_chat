// lib/services/chat_storage_sync.dart

import 'dart:async';
import 'dart:convert';

import 'package:chuk_chat/models/chat_message.dart';
import 'package:chuk_chat/models/stored_chat.dart';
import 'package:chuk_chat/services/chat_storage_mutations.dart'
    show kChatPayloadVersion, saveTitlesToCache;
import 'package:chuk_chat/services/chat_storage_state.dart';
import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/local_chat_cache_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

/// Internal class for deserialize results from isolate
class DeserializeResult {
  DeserializeResult(this.messages, {this.customName});
  final List<Map<String, dynamic>> messages;
  final String? customName;
}

/// Top-level function for background JSON deserialization
/// Must be top-level (not a class method) to work with compute()
DeserializeResult deserializePayloadIsolate(String json) {
  final Map<String, dynamic> map = jsonDecode(json) as Map<String, dynamic>;
  final int version = (map['v'] as int?) ?? 1;
  final String? customName = map['customName'] as String?;

  if (version == 2) {
    final List<dynamic> rawMessages = map['messages'] as List<dynamic>;
    final messages = rawMessages.map((m) => m as Map<String, dynamic>).toList();
    return DeserializeResult(messages, customName: customName);
  }

  // Version 1 migration - normalize field names, preserving all fields
  final List<dynamic> rawMessages = map['messages'] as List<dynamic>;
  final messages = rawMessages.map((m) {
    final msg = m as Map<String, dynamic>;
    return <String, dynamic>{
      'role': msg['role'] as String? ?? 'user',
      'text': msg['text'] as String? ?? '',
      if (msg['reasoning'] != null) 'reasoning': msg['reasoning'],
      if (msg['images'] != null) 'images': msg['images'],
      if (msg['imageCostEur'] != null) 'imageCostEur': msg['imageCostEur'],
      if (msg['imageGeneratedAt'] != null)
        'imageGeneratedAt': msg['imageGeneratedAt'],
      if (msg['attachments'] != null) 'attachments': msg['attachments'],
      if (msg['attachedFilesJson'] != null)
        'attachedFilesJson': msg['attachedFilesJson'],
      if (msg['toolCalls'] != null) 'toolCalls': msg['toolCalls'],
      if (msg['modelId'] != null) 'modelId': msg['modelId'],
      if (msg['provider'] != null) 'provider': msg['provider'],
    };
  }).toList();
  return DeserializeResult(messages, customName: customName);
}

/// Internal class for chat payload
class ChatPayload {
  ChatPayload(this.messages, {this.customName});
  final List<ChatMessage> messages;
  final String? customName;
}

/// Deserialize chat payload in background isolate to avoid UI blocking
Future<ChatPayload> deserializePayloadAsync(String json) async {
  final result = await compute(deserializePayloadIsolate, json);
  const int yieldEvery = 120;
  final messages = <ChatMessage>[];
  for (int i = 0; i < result.messages.length; i++) {
    messages.add(ChatMessage.fromJson(result.messages[i]));
    if (i > 0 && i % yieldEvery == 0) {
      await Future<void>.delayed(Duration.zero);
    }
  }
  return ChatPayload(messages, customName: result.customName);
}

/// Top-level function for batch deserialization in a single isolate.
/// Performs ALL work in the isolate — JSON parsing AND ChatMessage construction
/// — so the main thread receives ready-to-use objects with zero processing.
List<ChatPayload?> _deserializeBatchIsolate(List<String> jsonPayloads) {
  final results = <ChatPayload?>[];
  for (final json in jsonPayloads) {
    try {
      final result = deserializePayloadIsolate(json);
      final messages = result.messages
          .map((m) => ChatMessage.fromJson(m))
          .toList();
      results.add(ChatPayload(messages, customName: result.customName));
    } catch (_) {
      results.add(null);
    }
  }
  return results;
}

/// Batch deserialize multiple payloads in a single isolate (much faster
/// than one compute() call per chat). All JSON parsing and ChatMessage
/// construction happens in the isolate — main thread gets ready objects.
Future<List<ChatPayload?>> deserializePayloadBatchAsync(
  List<String> jsonPayloads,
) async {
  if (jsonPayloads.isEmpty) return [];
  return await compute(_deserializeBatchIsolate, jsonPayloads);
}

/// Extract title from messages (first user message, truncated).
/// Duplicated here to avoid circular import with chat_storage_crud.dart.
String _extractTitle(List<ChatMessage> messages) {
  if (messages.isEmpty) return '';
  for (final msg in messages) {
    if (msg.role == 'user' && msg.text.isNotEmpty) {
      return msg.text.length > 100
          ? '${msg.text.substring(0, 100)}...'
          : msg.text;
    }
  }
  final first = messages.first.text;
  return first.length > 100 ? '${first.substring(0, 100)}...' : first;
}

/// Build a plaintext payload JSON string from a ChatPayload.
/// Used to store decrypted Supabase data into plaintext local cache.
String _buildPlaintextPayloadJson(ChatPayload chatPayload) {
  return jsonEncode({
    'v': kChatPayloadVersion,
    if (chatPayload.customName != null) 'customName': chatPayload.customName,
    'messages': chatPayload.messages.map((m) => m.toJson()).toList(),
  });
}

/// Handles chat synchronization from cloud to local state.
/// Called by ChatSyncService when new or updated chats are detected.
class ChatStorageSync {
  ChatStorageSync._();

  /// Merge a synced chat from cloud into local state.
  /// IMPORTANT: Uses background decryption to avoid blocking UI.
  static Future<void> mergeSyncedChat(Map<String, dynamic> row) async {
    final chatId = row['id'] as String;

    // Skip if this chat was recently deleted locally
    if (ChatStorageState.wasRecentlyDeleted(chatId)) {
      if (kDebugMode) {
        debugPrint(
          '⏭️ [ChatStorage] Skipping sync for recently deleted chat: $chatId',
        );
      }
      return;
    }

    // Skip if we're currently saving this chat (to avoid conflicts)
    if (ChatStorageState.savingChats.contains(chatId)) {
      if (kDebugMode) {
        debugPrint(
          '⏭️ [ChatStorage] Skipping sync for chat being saved: $chatId',
        );
      }
      return;
    }

    // Skip if there's a pending save operation
    if (ChatStorageState.pendingSaves.containsKey(chatId)) {
      if (kDebugMode) {
        debugPrint(
          '⏭️ [ChatStorage] Skipping sync for chat with pending save: $chatId',
        );
      }
      return;
    }

    final encryptedPayload = row['encrypted_payload'] as String?;
    if (encryptedPayload == null || encryptedPayload.isEmpty) return;

    try {
      // Use background decryption to avoid blocking UI thread
      final decrypted = await EncryptionService.decryptInBackground(
        encryptedPayload,
      );
      // Use async deserialization to avoid blocking UI thread
      final chatPayload = await deserializePayloadAsync(decrypted);
      final chat = StoredChat.fromRow(
        row,
        chatPayload.messages,
        customName: chatPayload.customName,
      );

      final existingChat = ChatStorageState.chatsById[chatId];
      final user = SupabaseService.auth.currentUser;

      if (existingChat != null) {
        // Only update if the synced version is actually newer
        final existingUpdatedAt =
            existingChat.updatedAt ?? existingChat.createdAt;
        final syncedUpdatedAt = chat.updatedAt ?? chat.createdAt;

        if (syncedUpdatedAt.isAfter(existingUpdatedAt)) {
          if (kDebugMode) {
            debugPrint('🔄 [ChatStorage] Updating chat from sync: $chatId');
          }
          ChatStorageState.chatsById[chatId] = chat;
          ChatStorageState.notifyChanges(chatId);
          // Cache plaintext row (not encrypted Supabase row)
          if (user != null) {
            unawaited(_upsertPlaintextCache(user.id, chatId, row, chatPayload, chat));
          }
        }
      } else {
        // New chat from another device
        if (kDebugMode) {
          debugPrint('➕ [ChatStorage] Adding new chat from sync: $chatId');
        }
        ChatStorageState.chatsById[chatId] = chat;
        ChatStorageState.notifyChanges(chatId);
        // Cache plaintext row (not encrypted Supabase row)
        if (user != null) {
          unawaited(_upsertPlaintextCache(user.id, chatId, row, chatPayload, chat));
        }
      }
    } on SecretBoxAuthenticationError {
      if (kDebugMode) {
        debugPrint('🔐 [ChatStorage] Failed to decrypt synced chat: $chatId');
      }
    } on FormatException catch (e) {
      if (kDebugMode) {
        debugPrint(
          '📄 [ChatStorage] Invalid format for synced chat: $chatId - $e',
        );
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('❌ [ChatStorage] Error merging synced chat: $chatId - $e');
      }
    }
  }

  /// Upsert a plaintext cache row from decrypted Supabase data.
  static Future<void> _upsertPlaintextCache(
    String userId,
    String chatId,
    Map<String, dynamic> row,
    ChatPayload chatPayload,
    StoredChat chat,
  ) {
    final title = chat.title ?? _extractTitle(chatPayload.messages);
    return LocalChatCacheService.upsert(
      userId,
      LocalChatCacheService.buildPlaintextRow(
        id: chatId,
        payload: _buildPlaintextPayloadJson(chatPayload),
        createdAt: row['created_at'] as String,
        isStarred: (row['is_starred'] as bool?) ?? false,
        updatedAt: row['updated_at'] as String?,
        title: title.isNotEmpty ? title : null,
      ),
    );
  }

  /// Batch merge multiple synced chats efficiently.
  /// Uses batch decryption in a single isolate to avoid UI blocking.
  static Future<void> mergeSyncedChatsBatch(
    List<Map<String, dynamic>> rows,
  ) async {
    if (rows.isEmpty) return;

    // Filter out chats that are recently deleted, currently saving, or have pending saves
    final validRows = rows.where((row) {
      final chatId = row['id'] as String;
      if (ChatStorageState.wasRecentlyDeleted(chatId)) {
        if (kDebugMode) {
          debugPrint(
            '⏭️ [ChatStorage] Skipping sync for recently deleted chat: $chatId',
          );
        }
        return false;
      }
      if (ChatStorageState.savingChats.contains(chatId)) {
        if (kDebugMode) {
          debugPrint(
            '⏭️ [ChatStorage] Skipping sync for chat being saved: $chatId',
          );
        }
        return false;
      }
      if (ChatStorageState.pendingSaves.containsKey(chatId)) {
        if (kDebugMode) {
          debugPrint(
            '⏭️ [ChatStorage] Skipping sync for chat with pending save: $chatId',
          );
        }
        return false;
      }
      final payload = row['encrypted_payload'] as String?;
      return payload != null && payload.isNotEmpty;
    }).toList();

    if (validRows.isEmpty) return;

    if (kDebugMode) {
      debugPrint('🔄 [ChatStorage] Batch merging ${validRows.length} chats...');
    }

    // Extract payloads for batch decryption
    final payloads = validRows
        .map((r) => r['encrypted_payload'] as String)
        .toList();

    try {
      // Batch decrypt all payloads in a single isolate (much faster!)
      final decryptedList = await EncryptionService.decryptBatchInBackground(
        payloads,
      );

      final user = SupabaseService.auth.currentUser;
      int addedCount = 0;
      int updatedCount = 0;

      for (int i = 0; i < validRows.length; i++) {
        final row = validRows[i];
        final decrypted = decryptedList[i];
        final chatId = row['id'] as String;

        // Chat failed to decrypt — create a locked placeholder
        if (decrypted == null) {
          final encPayload = payloads[i];
          final kv = EncryptionService.extractKeyVersion(encPayload);
          if (!ChatStorageState.chatsById.containsKey(chatId)) {
            ChatStorageState.chatsById[chatId] = StoredChat.forSidebar(
              id: chatId,
              createdAt: DateTime.parse(row['created_at'] as String),
              updatedAt: row['updated_at'] != null
                  ? DateTime.parse(row['updated_at'] as String)
                  : null,
              isStarred: (row['is_starred'] as bool?) ?? false,
              keyVersion: kv,
              isLocked: true,
            );
            addedCount++;
          }
          continue;
        }

        try {
          final chatPayload = await deserializePayloadAsync(decrypted);
          final chat = StoredChat.fromRow(
            row,
            chatPayload.messages,
            customName: chatPayload.customName,
          );

          final existingChat = ChatStorageState.chatsById[chatId];

          if (existingChat != null) {
            final existingUpdatedAt =
                existingChat.updatedAt ?? existingChat.createdAt;
            final syncedUpdatedAt = chat.updatedAt ?? chat.createdAt;

            if (syncedUpdatedAt.isAfter(existingUpdatedAt)) {
              ChatStorageState.chatsById[chatId] = chat;
              if (user != null) {
                unawaited(_upsertPlaintextCache(user.id, chatId, row, chatPayload, chat));
              }
              updatedCount++;
            }
          } else {
            ChatStorageState.chatsById[chatId] = chat;
            if (user != null) {
              unawaited(_upsertPlaintextCache(user.id, chatId, row, chatPayload, chat));
            }
            addedCount++;
          }

          // Yield to UI thread periodically to prevent jank
          if (i % 10 == 0) {
            await Future.delayed(Duration.zero);
          }
        } catch (e) {
          if (kDebugMode) {
            debugPrint(
              '❌ [ChatStorage] Error processing synced chat $chatId: $e',
            );
          }
        }
      }

      // Single notification after all chats processed
      if (addedCount > 0 || updatedCount > 0) {
        ChatStorageState.notifyChanges();
        if (kDebugMode) {
          debugPrint(
            '✅ [ChatStorage] Batch sync complete: $addedCount added, $updatedCount updated',
          );
        }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('❌ [ChatStorage] Batch merge failed: $e');
      }
      // Fall back to individual processing
      for (final row in validRows) {
        await mergeSyncedChat(row);
      }
    }
  }

  /// Remove a chat from local state only (without database operation).
  /// Called by ChatSyncService when a chat was deleted on another device.
  static void removeChatLocally(String chatId) {
    if (!ChatStorageState.chatsById.containsKey(chatId)) return;

    if (kDebugMode) {
      debugPrint('🗑️ [ChatStorage] Removing locally deleted chat: $chatId');
    }

    // Mark as recently deleted to prevent re-addition during sync
    ChatStorageState.markDeleted(chatId);

    ChatStorageState.chatsById.remove(chatId);
    ChatStorageState.savingChats.remove(chatId);
    ChatStorageState.pendingSaves.remove(chatId);

    // Clear selection if the deleted chat was selected
    if (ChatStorageState.selectedChatId == chatId) {
      ChatStorageState.selectedChatId = null;
    }

    ChatStorageState.notifyChanges(chatId);

    // Also remove from local cache and update title cache
    final user = SupabaseService.auth.currentUser;
    if (user != null) {
      unawaited(LocalChatCacheService.delete(user.id, chatId));
      unawaited(
        saveTitlesToCache(user.id, ChatStorageState.chatsById.values.toList()),
      );
    }
  }
}
