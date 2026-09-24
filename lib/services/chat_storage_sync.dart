// lib/services/chat_storage_sync.dart

import 'dart:async';

import 'package:chuk_chat/models/chat_message.dart';
import 'package:chuk_chat/models/stored_chat.dart';
import 'package:chuk_chat/services/chat_dirty_store.dart';
import 'package:chuk_chat/services/chat_payload_codec.dart';
import 'package:chuk_chat/services/chat_storage_mutations.dart'
    show saveTitlesToCache;
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
/// Reads every payload version (v1, v2, v3) into v2-shaped message maps.
DeserializeResult deserializePayloadIsolate(String json) {
  final decoded = decodeChatPayload(json);
  return DeserializeResult(decoded.messages, customName: decoded.customName);
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

/// The title a chat gets when nobody named it: its first user message,
/// truncated to 100 characters.
String chatTitleFromMessages(List<ChatMessage> messages) {
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

/// Payload JSON shorter than this is encoded on the calling isolate.
const int _backgroundEncodeMinChars = 32 * 1024;

String _encodeChatPayloadIsolate(_EncodeArgs args) =>
    encodeChatPayload(args.messages, customName: args.customName);

class _EncodeArgs {
  const _EncodeArgs(this.messages, this.customName);
  final List<Map<String, dynamic>> messages;
  final String? customName;
}

/// The v3 payload JSON of [messages], encoded off the UI isolate when the
/// chat is long. The one encoding for the cloud, the cache and the digests
/// that compare them.
Future<String> encodeChatPayloadAsync(
  List<ChatMessage> messages,
  String? customName,
) async {
  final maps = messages.map((m) => m.toJson()).toList();
  var chars = 0;
  for (final m in messages) {
    chars +=
        m.text.length +
        (m.reasoning?.length ?? 0) +
        (m.toolCalls?.length ?? 0) +
        (m.contentBlocks?.length ?? 0);
    if (chars >= _backgroundEncodeMinChars) break;
  }
  if (chars < _backgroundEncodeMinChars) {
    return encodeChatPayload(maps, customName: customName);
  }
  return compute(_encodeChatPayloadIsolate, _EncodeArgs(maps, customName));
}

/// [json] (a payload of any version) as a v3 payload JSON. A v3 input is
/// returned at once; an older one is converted off the UI isolate.
Future<String> toChatPayloadV3Async(String json) async {
  if (peekChatPayloadVersion(json) == kChatPayloadVersion) return json;
  if (json.length < _backgroundEncodeMinChars) return toChatPayloadV3(json);
  return compute(toChatPayloadV3, json);
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

    // Skip if the local copy is ahead of the cloud: the cloud row is older.
    if (ChatDirtyStore.isDirty(chatId)) return;

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
            unawaited(
              _upsertPlaintextCache(user.id, chatId, row, chatPayload, chat),
            );
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
          unawaited(
            _upsertPlaintextCache(user.id, chatId, row, chatPayload, chat),
          );
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
  ) async {
    final title = chat.title ?? chatTitleFromMessages(chatPayload.messages);
    final payload = await encodeChatPayloadAsync(
      chatPayload.messages,
      chatPayload.customName,
    );
    await LocalChatCacheService.upsert(
      userId,
      LocalChatCacheService.buildPlaintextRow(
        id: chatId,
        payload: payload,
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
      if (ChatDirtyStore.isDirty(chatId)) return false;
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
          try {
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
          } catch (e) {
            if (kDebugMode) {
              debugPrint(
                '🔐 [ChatStorage] Failed to create locked placeholder for $chatId: $e',
              );
            }
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
                unawaited(
                  _upsertPlaintextCache(
                    user.id,
                    chatId,
                    row,
                    chatPayload,
                    chat,
                  ),
                );
              }
              updatedCount++;
            }
          } else {
            ChatStorageState.chatsById[chatId] = chat;
            if (user != null) {
              unawaited(
                _upsertPlaintextCache(user.id, chatId, row, chatPayload, chat),
              );
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
  ///
  /// A dirty chat is kept: the cloud may not hold it yet, or not its newest
  /// messages, and the next flush writes it.
  static void removeChatLocally(String chatId) {
    if (!ChatStorageState.chatsById.containsKey(chatId)) return;
    if (ChatDirtyStore.isDirty(chatId)) return;

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
