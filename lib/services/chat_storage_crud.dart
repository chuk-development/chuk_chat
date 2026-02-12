// lib/services/chat_storage_crud.dart

import 'dart:async';
import 'dart:convert';

import 'package:chuk_chat/models/chat_message.dart';
import 'package:chuk_chat/models/stored_chat.dart';
import 'package:chuk_chat/services/chat_storage_mutations.dart';
import 'package:chuk_chat/services/chat_storage_state.dart';
import 'package:chuk_chat/services/chat_storage_sync.dart';
import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/image_storage_service.dart';
import 'package:chuk_chat/services/local_chat_cache_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

/// Handles CRUD operations for chat storage: save, update, delete, load.
class ChatStorageCrud {
  ChatStorageCrud._();

  /// Extract title from messages (first user message, truncated)
  static String extractTitleFromMessages(List<ChatMessage> messages) {
    if (messages.isEmpty) return '';
    for (final msg in messages) {
      if (msg.role == 'user' && msg.text.isNotEmpty) {
        // Truncate to reasonable title length (100 chars)
        return msg.text.length > 100
            ? '${msg.text.substring(0, 100)}...'
            : msg.text;
      }
    }
    // Fall back to first message
    final first = messages.first.text;
    return first.length > 100 ? '${first.substring(0, 100)}...' : first;
  }

  /// Load a single chat's full content (messages) on demand.
  /// Used for lazy loading when user clicks on a chat in sidebar.
  /// Returns the fully loaded chat or null if not found/error.
  static Future<StoredChat?> loadFullChat(String chatId) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) return null;

    debugPrint('📂 [ChatStorage] Loading full chat: $chatId');
    final stopwatch = Stopwatch()..start();

    try {
      // Check if already fully loaded
      final existing = ChatStorageState.chatsById[chatId];
      if (existing != null && existing.isFullyLoaded) {
        debugPrint(
          '✅ [ChatStorage] Chat already fully loaded (${stopwatch.elapsedMilliseconds}ms)',
        );
        return existing;
      }

      // Fetch full payload from Supabase
      final rows = await SupabaseService.client
          .from('encrypted_chats')
          .select(
            'id, encrypted_payload, created_at, is_starred, updated_at, encrypted_title',
          )
          .eq('id', chatId)
          .eq('user_id', user.id)
          .limit(1)
          .timeout(const Duration(seconds: 10));

      if (rows.isEmpty) {
        debugPrint('⚠️ [ChatStorage] Chat not found: $chatId');
        return null;
      }

      final row = rows.first;
      final encryptedPayload = row['encrypted_payload'] as String?;
      if (encryptedPayload == null || encryptedPayload.isEmpty) {
        debugPrint('⚠️ [ChatStorage] Chat has no payload: $chatId');
        return null;
      }

      // Decrypt payload in background isolate
      final decrypted = await EncryptionService.decryptInBackground(
        encryptedPayload,
      );
      final chatPayload = await deserializePayloadAsync(decrypted);

      // Create fully loaded chat
      final chat = StoredChat.fromRow(
        row,
        chatPayload.messages,
        customName: chatPayload.customName,
        title: existing?.title, // Preserve existing title
      );

      // Update in memory
      ChatStorageState.chatsById[chatId] = chat;
      ChatStorageState.notifyChanges(chatId);

      stopwatch.stop();
      debugPrint(
        '✅ [ChatStorage] Full chat loaded in ${stopwatch.elapsedMilliseconds}ms (${chatPayload.messages.length} messages)',
      );

      return chat;
    } on SecretBoxAuthenticationError {
      debugPrint('🔐 [ChatStorage] Failed to decrypt chat: $chatId');
      return null;
    } catch (e) {
      debugPrint('❌ [ChatStorage] Error loading full chat: $e');
      return null;
    }
  }

  /// Load chats from local cache only (instant, no network).
  /// Call this for immediate UI population, then sync in background.
  static Future<void> loadFromCache() async {
    if (ChatStorageState.cacheLoaded && ChatStorageState.chatsById.isNotEmpty) {
      return;
    }

    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      ChatStorageState.chatsById.clear();
      ChatStorageState.notifyChanges();
      return;
    }

    try {
      final rows = await LocalChatCacheService.load(user.id);
      if (rows.isEmpty) {
        debugPrint('📦 [ChatStorage] Cache empty');
        return;
      }

      debugPrint('📦 [ChatStorage] Loading ${rows.length} chats from cache...');

      // Progressive loading: first batch for fast UI, then rest in background
      const int firstBatchSize = 15;
      final firstBatch = rows.take(firstBatchSize).toList();
      final remainingBatch = rows.skip(firstBatchSize).toList();

      ChatStorageState.chatsById.clear();

      // Batch decrypt first 15 chats in ONE isolate (much faster!)
      final firstChats = await _decryptChatRowsBatch(firstBatch);
      for (final chat in firstChats) {
        if (chat != null) {
          ChatStorageState.chatsById[chat.id] = chat;
        }
      }

      ChatStorageState.cacheLoaded = true;

      // Notify UI immediately with first batch
      if (ChatStorageState.chatsById.isNotEmpty) {
        ChatStorageState.notifyChanges();
        debugPrint(
          '⚡ [ChatStorage] First ${ChatStorageState.chatsById.length} chats from cache (fast)',
        );
      }

      // Decrypt remaining in background (also batched)
      if (remainingBatch.isNotEmpty) {
        final remainingChats = await _decryptChatRowsBatch(remainingBatch);
        for (final chat in remainingChats) {
          if (chat != null) {
            ChatStorageState.chatsById[chat.id] = chat;
          }
        }
        ChatStorageState.notifyChanges();
      }

      debugPrint(
        '✅ [ChatStorage] Loaded ${ChatStorageState.chatsById.length} chats from cache',
      );
    } catch (e) {
      debugPrint('❌ [ChatStorage] Cache load failed: $e');
    }
  }

  /// Batch decrypt multiple chat rows in a single isolate
  /// Much faster than decrypting one by one
  static Future<List<StoredChat?>> _decryptChatRowsBatch(
    List<Map<String, dynamic>> rows,
  ) async {
    if (rows.isEmpty) return [];

    // Extract encrypted payloads
    final encryptedPayloads = <String>[];
    final validIndices = <int>[];

    for (int i = 0; i < rows.length; i++) {
      final payload = rows[i]['encrypted_payload'] as String?;
      if (payload != null && payload.isNotEmpty) {
        encryptedPayloads.add(payload);
        validIndices.add(i);
      }
    }

    if (encryptedPayloads.isEmpty) return List.filled(rows.length, null);

    // Batch decrypt all payloads in one isolate
    final decryptedList = await EncryptionService.decryptBatchInBackground(
      encryptedPayloads,
    );

    // Deserialize and create StoredChat objects
    final results = List<StoredChat?>.filled(rows.length, null);

    for (int j = 0; j < validIndices.length; j++) {
      final i = validIndices[j];
      final decrypted = decryptedList[j];
      if (decrypted == null) continue;

      try {
        final chatPayload = await deserializePayloadAsync(decrypted);
        results[i] = StoredChat.fromRow(
          rows[i],
          chatPayload.messages,
          customName: chatPayload.customName,
        );
      } catch (_) {
        // Skip invalid chats
      }
    }

    return results;
  }

  /// Load all chats from Supabase or cache
  static Future<void> loadChats() async {
    // Prevent concurrent loads - wait for existing operation
    if (ChatStorageState.isLoading) {
      debugPrint('⏳ [ChatStorage] Load already in progress, waiting...');
      return ChatStorageState.loadingCompleter!.future;
    }
    ChatStorageState.loadingCompleter = Completer<void>();

    try {
      final user = SupabaseService.auth.currentUser;
      if (user == null) {
        debugPrint('⚠️ [ChatStorage] No user signed in, clearing chats');
        ChatStorageState.chatsById.clear();
        ChatStorageState.notifyChanges();
        return;
      }

      List<Map<String, dynamic>> rows = [];
      bool loadedFromCache = false;
      Object? remoteError;
      StackTrace? remoteStack;

      final isOnline = await ChatStorageState.checkNetworkStatus();

      if (isOnline) {
        try {
          debugPrint('🌐 [ChatStorage] Network status: ONLINE');
          rows = await SupabaseService.client
              .from('encrypted_chats')
              .select(
                'id, encrypted_payload, created_at, is_starred, updated_at',
              )
              .eq('user_id', user.id)
              .order('created_at', ascending: false)
              .timeout(const Duration(seconds: 30));
          debugPrint('✅ [ChatStorage] Loaded ${rows.length} chats from remote');

          // Update cache with remote data (use replaceAll to avoid race conditions)
          unawaited(LocalChatCacheService.replaceAll(user.id, rows));
        } catch (error, stackTrace) {
          remoteError = error;
          remoteStack = stackTrace;
          debugPrint('❌ [ChatStorage] Failed to load from remote: $error');

          // Fall back to cache
          try {
            rows = await LocalChatCacheService.load(user.id);
            loadedFromCache = true;
            debugPrint(
              '📦 [ChatStorage] Loaded ${rows.length} chats from cache (fallback)',
            );
          } catch (cacheError) {
            debugPrint(
              '❌ [ChatStorage] Failed to load from cache: $cacheError',
            );
            rows = [];
          }
        }
      } else {
        debugPrint('🌐 [ChatStorage] Network status: OFFLINE');
        try {
          rows = await LocalChatCacheService.load(user.id);
          loadedFromCache = true;
          debugPrint(
            '📦 [ChatStorage] Loaded ${rows.length} chats from cache (offline)',
          );
        } catch (error) {
          debugPrint('❌ [ChatStorage] Failed to load from cache: $error');
          rows = [];
        }
      }

      // Clear and rebuild the chats map
      ChatStorageState.chatsById.clear();

      // Progressive loading: decrypt first batch immediately for fast UI,
      // then decrypt remaining chats in background
      const int firstBatchSize = 15;
      final firstBatch = rows.take(firstBatchSize).toList();
      final remainingBatch = rows.skip(firstBatchSize).toList();

      // Batch decrypt first 15 chats in ONE isolate (much faster!)
      final firstChats = await _decryptChatRowsBatch(firstBatch);
      for (final chat in firstChats) {
        if (chat != null) {
          ChatStorageState.chatsById[chat.id] = chat;
        }
      }

      // Notify UI immediately so sidebar shows first chats
      if (ChatStorageState.chatsById.isNotEmpty) {
        ChatStorageState.notifyChanges();
        debugPrint(
          '⚡ [ChatStorage] First ${ChatStorageState.chatsById.length} chats ready (fast path)',
        );
      }

      // Decrypt remaining chats in background (also batched)
      if (remainingBatch.isNotEmpty) {
        debugPrint(
          '🔄 [ChatStorage] Decrypting ${remainingBatch.length} more chats in background...',
        );
        final remainingChats = await _decryptChatRowsBatch(remainingBatch);
        for (final chat in remainingChats) {
          if (chat != null) {
            ChatStorageState.chatsById[chat.id] = chat;
          }
        }
        ChatStorageState.notifyChanges();
        debugPrint(
          '✅ [ChatStorage] All ${ChatStorageState.chatsById.length} chats loaded',
        );
      } else if (ChatStorageState.chatsById.isEmpty) {
        // No chats at all - still notify
        ChatStorageState.notifyChanges();
      }

      // Log all loaded chats for debugging
      if (ChatStorageState.chatsById.isNotEmpty) {
        debugPrint(
          '📋 [ChatStorage] Current chats in memory (${ChatStorageState.chatsById.length}):',
        );
        for (final entry in ChatStorageState.chatsById.entries) {
          final chat = entry.value;
          final firstUserMsg = chat.messages
              .where((m) => m.role == 'user')
              .firstOrNull;
          final title = (firstUserMsg?.text.length ?? 0) > 40
              ? '${firstUserMsg!.text.substring(0, 40)}...'
              : (firstUserMsg?.text ?? 'No user message');
          debugPrint(
            '   - ${entry.key.substring(0, 8)}... : "$title" (${chat.messages.length} msgs)',
          );
        }
      }

      if (loadedFromCache && remoteError != null) {
        debugPrint(
          'ChatStorageService loaded chats from offline cache: $remoteError',
        );
        if (remoteStack != null) {
          debugPrint('Stack trace: $remoteStack');
        }
      }
    } finally {
      ChatStorageState.loadingCompleter?.complete();
      ChatStorageState.loadingCompleter = null;
    }
  }

  /// Extract image storage paths from messages
  /// Images are stored as JSON arrays in the 'images' field of messages
  /// Each entry can be a storage path (like "user-id/uuid.enc") or a base64 data URL
  /// We only want storage paths for cleanup purposes
  static List<String> _extractImagePaths(List<ChatMessage> messages) {
    final paths = <String>[];
    for (final msg in messages) {
      if (msg.images != null && msg.images!.isNotEmpty) {
        try {
          final imagesData = jsonDecode(msg.images!) as List<dynamic>;
          for (final img in imagesData) {
            final imgStr = img.toString();
            // Storage paths end with .enc and contain a user ID pattern
            // They look like: "user-uuid/image-uuid.enc"
            if (imgStr.endsWith('.enc') && imgStr.contains('/')) {
              paths.add(imgStr);
            }
          }
        } catch (_) {
          // Invalid JSON, skip
        }
      }
    }
    return paths;
  }

  static List<ChatMessage> _mapToChatMessages(
    List<Map<String, dynamic>> messagesMaps,
  ) {
    return messagesMaps.where((m) => m['text']?.toString() != 'Thinking...').map((
      m,
    ) {
      // UI uses 'sender' with 'user'/'ai', convert to 'role' with 'user'/'assistant'
      String role;
      final sender = m['sender'] as String?;
      final rawRole = m['role'] as String?;

      if (sender != null) {
        // Convert sender format to role format
        role = sender == 'ai' ? 'assistant' : sender;
      } else if (rawRole != null) {
        role = rawRole;
      } else {
        role = 'user';
      }

      return ChatMessage(
        role: role,
        text: m['text'] as String? ?? '',
        reasoning: m['reasoning'] as String?,
        images: m['images'] as String?,
        attachments: m['attachments'] as String?,
        modelId: m['modelId'] as String?,
        provider: m['provider'] as String?,
      );
    }).toList();
  }

  /// Save a new chat to Supabase
  static Future<StoredChat?> saveChat(
    List<Map<String, dynamic>> messagesMaps, {
    String? chatId,
  }) async {
    // CRITICAL: Always use a proper UUID to ensure savingChats tracks the same ID
    // that gets inserted into Supabase. This prevents race conditions with realtime events.
    final effectiveChatId = chatId ?? ChatStorageState.uuid.v4();
    debugPrint(
      '💾 [ChatStorage] saveChat: $effectiveChatId (${messagesMaps.length} messages)',
    );

    // If there's already a pending save for this chat, wait for it
    if (ChatStorageState.pendingSaves.containsKey(effectiveChatId)) {
      debugPrint('⏳ [ChatStorage] Waiting for pending save: $effectiveChatId');
      return await ChatStorageState.pendingSaves[effectiveChatId]!.future;
    }

    // If chat already exists, update it instead
    if (ChatStorageState.chatsById.containsKey(effectiveChatId)) {
      debugPrint('🔄 [ChatStorage] Chat exists, updating: $effectiveChatId');
      return await updateChat(effectiveChatId, messagesMaps);
    }

    final completer = Completer<StoredChat?>();
    ChatStorageState.pendingSaves[effectiveChatId] = completer;
    ChatStorageState.savingChats.add(effectiveChatId);

    try {
      final result = await _doSaveChat(messagesMaps, effectiveChatId);
      completer.complete(result);
      return result;
    } catch (e) {
      completer.completeError(e);
      rethrow;
    } finally {
      ChatStorageState.pendingSaves.remove(effectiveChatId);
      // Keep in savingChats for a bit longer to block realtime events
      Future.delayed(const Duration(seconds: 2), () {
        ChatStorageState.savingChats.remove(effectiveChatId);
      });
    }
  }

  static Future<StoredChat?> _doSaveChat(
    List<Map<String, dynamic>> messagesMaps,
    String effectiveChatId,
  ) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to store chats.');
    }

    if (!EncryptionService.hasKey) {
      final loaded = await EncryptionService.tryLoadKey();
      if (!loaded) {
        throw StateError('Encryption key is missing. Please sign in again.');
      }
    }

    final messages = _mapToChatMessages(messagesMaps);
    if (messages.isEmpty) {
      debugPrint('⚠️ [ChatStorage] No messages to save');
      return null;
    }

    final payload = jsonEncode({
      'v': kChatPayloadVersion,
      'messages': messages.map((m) => m.toJson()).toList(),
    });

    final encryptedPayload = await EncryptionService.encrypt(payload);

    // Extract and encrypt title separately for fast sidebar loading
    final title = extractTitleFromMessages(messages);
    final encryptedTitle = title.isNotEmpty
        ? await EncryptionService.encrypt(title)
        : null;

    // Extract image paths for cleanup on delete
    final imagePaths = _extractImagePaths(messages);

    // CRITICAL: Always include the effectiveChatId in the insert.
    // This ensures the ID we track in savingChats matches the ID in Supabase,
    // preventing race conditions with realtime events that could cause duplicates.
    final Map<String, dynamic> insertData = {
      'id': effectiveChatId,
      'user_id': user.id,
      'encrypted_payload': encryptedPayload,
      if (encryptedTitle != null) 'encrypted_title': encryptedTitle,
      if (imagePaths.isNotEmpty) 'image_paths': imagePaths,
    };

    final inserted = await SupabaseService.client
        .from('encrypted_chats')
        .insert(insertData)
        .select(
          'id, encrypted_payload, created_at, is_starred, updated_at, encrypted_title',
        )
        .single()
        .timeout(const Duration(seconds: 15));

    final String finalId = inserted['id'] as String;
    final chat = StoredChat.fromRow(inserted, messages, title: title);

    // Add to our map - this is the ONLY place we add new chats
    ChatStorageState.chatsById[finalId] = chat;
    ChatStorageState.notifyChanges(finalId);

    unawaited(LocalChatCacheService.upsert(user.id, inserted));

    // Log with title for debugging
    final displayTitle = title.length > 50
        ? '${title.substring(0, 50)}...'
        : title;
    debugPrint('✅ [ChatStorage] Saved new chat: $finalId');
    debugPrint('   📝 Title: "$displayTitle"');
    debugPrint(
      '   📊 Messages: ${messages.length} (${messages.where((m) => m.role == "user").length} user, ${messages.where((m) => m.role == "assistant").length} assistant)',
    );

    return chat;
  }

  /// Update an existing chat
  static Future<StoredChat?> updateChat(
    String chatId,
    List<Map<String, dynamic>> messagesMaps,
  ) async {
    debugPrint(
      '🔄 [ChatStorage] updateChat: $chatId (${messagesMaps.length} messages)',
    );

    // If there's already a pending save for this chat, wait for it then try again
    if (ChatStorageState.pendingSaves.containsKey(chatId)) {
      debugPrint('⏳ [ChatStorage] Waiting for pending operation: $chatId');
      await ChatStorageState.pendingSaves[chatId]!.future;
    }

    final completer = Completer<StoredChat?>();
    ChatStorageState.pendingSaves[chatId] = completer;
    ChatStorageState.savingChats.add(chatId);

    try {
      final result = await _doUpdateChat(chatId, messagesMaps);
      completer.complete(result);
      return result;
    } catch (e) {
      completer.completeError(e);
      rethrow;
    } finally {
      ChatStorageState.pendingSaves.remove(chatId);
      // Keep in savingChats for a bit longer to block realtime events
      Future.delayed(const Duration(seconds: 2), () {
        ChatStorageState.savingChats.remove(chatId);
      });
    }
  }

  static Future<StoredChat?> _doUpdateChat(
    String chatId,
    List<Map<String, dynamic>> messagesMaps,
  ) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to store chats.');
    }

    if (!EncryptionService.hasKey) {
      final loaded = await EncryptionService.tryLoadKey();
      if (!loaded) {
        throw StateError('Encryption key is missing. Please sign in again.');
      }
    }

    final messages = _mapToChatMessages(messagesMaps);
    if (messages.isEmpty) {
      debugPrint('⚠️ [ChatStorage] No messages to update');
      return null;
    }

    // Preserve existing customName
    final existingChat = ChatStorageState.chatsById[chatId];
    final String? existingCustomName = existingChat?.customName;

    final Map<String, dynamic> payloadMap = {
      'v': kChatPayloadVersion,
      'messages': messages.map((m) => m.toJson()).toList(),
    };
    if (existingCustomName != null) {
      payloadMap['customName'] = existingCustomName;
    }

    final encryptedPayload = await EncryptionService.encrypt(
      jsonEncode(payloadMap),
    );

    // Extract and encrypt title separately for fast sidebar loading
    final title = extractTitleFromMessages(messages);
    final encryptedTitle = title.isNotEmpty
        ? await EncryptionService.encrypt(title)
        : null;

    // Extract image paths for cleanup on delete
    final imagePaths = _extractImagePaths(messages);

    final updatedRows = await SupabaseService.client
        .from('encrypted_chats')
        .update({
          'encrypted_payload': encryptedPayload,
          if (encryptedTitle != null) 'encrypted_title': encryptedTitle,
          'image_paths': imagePaths.isNotEmpty ? imagePaths : null,
        })
        .eq('id', chatId)
        .eq('user_id', user.id)
        .select(
          'id, encrypted_payload, created_at, is_starred, updated_at, encrypted_title',
        )
        .timeout(const Duration(seconds: 15));

    if (updatedRows.isEmpty) {
      throw StateError('Chat not found or access denied.');
    }

    final updatedRow = updatedRows.first;
    final chat = StoredChat.fromRow(
      updatedRow,
      messages,
      customName: existingCustomName,
      title: title,
    );

    // Update in our map - this is the ONLY place we update chats
    ChatStorageState.chatsById[chatId] = chat;
    ChatStorageState.notifyChanges(chatId);

    unawaited(LocalChatCacheService.upsert(user.id, updatedRow));

    // Log with title for debugging
    final displayTitle = title.length > 50
        ? '${title.substring(0, 50)}...'
        : title;
    debugPrint('✅ [ChatStorage] Updated chat: $chatId');
    debugPrint('   📝 Title: "$displayTitle"');
    debugPrint(
      '   📊 Messages: ${messages.length} (${messages.where((m) => m.role == "user").length} user, ${messages.where((m) => m.role == "assistant").length} assistant)',
    );

    return chat;
  }

  /// Delete a chat and its associated images from storage
  static Future<void> deleteChat(String chatId) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to delete chats.');
    }

    // First, fetch the image_paths before deleting the row
    List<String> imagePaths = [];
    try {
      final rows = await SupabaseService.client
          .from('encrypted_chats')
          .select('image_paths')
          .eq('id', chatId)
          .eq('user_id', user.id)
          .timeout(const Duration(seconds: 10));

      if (rows.isNotEmpty && rows.first['image_paths'] != null) {
        final pathsData = rows.first['image_paths'];
        if (pathsData is List) {
          imagePaths = pathsData.cast<String>();
        }
      }
    } catch (e) {
      debugPrint('⚠️ [ChatStorage] Failed to fetch image_paths: $e');
      // Continue with deletion even if fetching paths fails
    }

    // Delete associated images from storage (best effort, don't block on failures)
    if (imagePaths.isNotEmpty) {
      debugPrint(
        '🖼️ [ChatStorage] Deleting ${imagePaths.length} images for chat: $chatId',
      );
      for (final path in imagePaths) {
        try {
          await ImageStorageService.deleteEncryptedImage(path);
          debugPrint('   ✅ Deleted image: $path');
        } catch (e) {
          debugPrint('   ⚠️ Failed to delete image $path: $e');
          // Continue deleting other images even if one fails
        }
      }
    }

    // Delete the chat row
    await SupabaseService.client
        .from('encrypted_chats')
        .delete()
        .eq('id', chatId)
        .eq('user_id', user.id)
        .timeout(const Duration(seconds: 10));

    // Find the index of the chat being deleted BEFORE removal
    final deletedIndex = ChatStorageState.savedChats.indexWhere(
      (c) => c.id == chatId,
    );

    ChatStorageState.chatsById.remove(chatId);
    ChatStorageState.savingChats.remove(chatId);
    ChatStorageState.pendingSaves.remove(chatId);

    // Adjust selectedChatIndex to account for index shifts
    if (deletedIndex != -1 &&
        deletedIndex < ChatStorageState.selectedChatIndex) {
      // Chat was deleted before the selected one, shift index down
      ChatStorageState.selectedChatIndex -= 1;
    }

    // Always ensure selectedChatIndex is in bounds (handles concurrent deletions too)
    if (ChatStorageState.selectedChatIndex >=
        ChatStorageState.savedChats.length) {
      ChatStorageState.selectedChatIndex = ChatStorageState.savedChats.isEmpty
          ? -1
          : ChatStorageState.savedChats.length - 1;
    }

    ChatStorageState.notifyChanges(chatId);
    unawaited(LocalChatCacheService.delete(user.id, chatId));
    debugPrint('🗑️ [ChatStorage] Deleted chat: $chatId');
  }
}
