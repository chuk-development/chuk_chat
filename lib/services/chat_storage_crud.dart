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
import 'package:chuk_chat/utils/tool_parser.dart';
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

  /// Resolve the display/persisted title for a chat.
  /// Priority: customName > fallbackTitle > extracted first-user-message title.
  static String? _resolveStoredTitle({
    required List<ChatMessage> messages,
    String? customName,
    String? fallbackTitle,
  }) {
    final trimmedCustomName = customName?.trim();
    if (trimmedCustomName != null && trimmedCustomName.isNotEmpty) {
      return trimmedCustomName;
    }

    final trimmedFallback = fallbackTitle?.trim();
    if (trimmedFallback != null && trimmedFallback.isNotEmpty) {
      return trimmedFallback;
    }

    final extractedTitle = extractTitleFromMessages(messages).trim();
    return extractedTitle.isEmpty ? null : extractedTitle;
  }

  /// Ensure `encrypted_title` matches payload customName when they diverge.
  /// This repairs stale sidebar titles across devices without waiting for a manual rename.
  static Future<void> _repairEncryptedTitleIfNeeded({
    required String chatId,
    required String userId,
    required String? payloadCustomName,
    required String? currentTitle,
  }) async {
    final customName = payloadCustomName?.trim();
    if (customName == null || customName.isEmpty) return;

    final localTitle = currentTitle?.trim();
    if (localTitle == customName) return;

    try {
      final encryptedTitle = await EncryptionService.encrypt(customName);
      await SupabaseService.client
          .from('encrypted_chats')
          .update({'encrypted_title': encryptedTitle})
          .eq('id', chatId)
          .eq('user_id', userId)
          .timeout(const Duration(seconds: 10));

      if (kDebugMode) {
        debugPrint(
          '🔧 [ChatStorage] Repaired encrypted_title for $chatId to match payload customName',
        );
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint(
          '⚠️ [ChatStorage] Failed to repair encrypted_title for $chatId: $e',
        );
      }
    }
  }

  /// Load a single chat's full content (messages) on demand.
  /// Used for lazy loading when user clicks on a chat in sidebar.
  /// Returns the fully loaded chat or null if not found/error.
  ///
  /// Strategy: Try Supabase first, fall back to local cache if offline/error.
  static Future<StoredChat?> loadFullChat(String chatId) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) return null;

    if (kDebugMode) {
      debugPrint('📂 [ChatStorage] Loading full chat: $chatId');
    }
    final stopwatch = Stopwatch()..start();

    // Check if already fully loaded in memory
    final existing = ChatStorageState.chatsById[chatId];
    if (existing != null && existing.isFullyLoaded) {
      if (kDebugMode) {
        debugPrint(
          '✅ [ChatStorage] Chat already fully loaded (${stopwatch.elapsedMilliseconds}ms)',
        );
      }
      return existing;
    }

    // Try local cache FIRST — it's plaintext JSON, instant load, no decryption.
    // This gives sub-millisecond response for any previously cached chat.
    final cached = await _loadFullChatFromCache(
      chatId,
      user.id,
      existing,
      stopwatch,
    );
    if (cached != null) {
      // Background: sync fresh copy from Supabase to keep cache up-to-date
      unawaited(_syncChatFromRemote(chatId, user.id, existing));
      return cached;
    }

    // Cache miss — load from Supabase
    final isOnline = await ChatStorageState.checkNetworkStatus();

    if (isOnline) {
      try {
        final rows = await SupabaseService.client
            .from('encrypted_chats')
            .select(
              'id, encrypted_payload, created_at, is_starred, updated_at, encrypted_title',
            )
            .eq('id', chatId)
            .eq('user_id', user.id)
            .limit(1)
            .timeout(const Duration(seconds: 10));

        if (rows.isNotEmpty) {
          final row = rows.first;
          final encryptedPayload = row['encrypted_payload'] as String?;
          if (encryptedPayload != null && encryptedPayload.isNotEmpty) {
            final decrypted = await EncryptionService.decryptInBackground(
              encryptedPayload,
            );
            final chatPayload = await deserializePayloadAsync(decrypted);
            final resolvedTitle = _resolveStoredTitle(
              messages: chatPayload.messages,
              customName: chatPayload.customName,
              fallbackTitle: existing?.title,
            );

            final chat = StoredChat.fromRow(
              row,
              chatPayload.messages,
              customName: chatPayload.customName,
              title: resolvedTitle,
            );

            ChatStorageState.chatsById[chatId] = chat;
            ChatStorageState.notifyChanges(chatId);

            unawaited(
              _repairEncryptedTitleIfNeeded(
                chatId: chatId,
                userId: user.id,
                payloadCustomName: chatPayload.customName,
                currentTitle: existing?.title,
              ),
            );

            // Cache plaintext for next time
            final title = chat.title ?? extractTitleFromMessages(chat.messages);
            unawaited(
              LocalChatCacheService.upsert(
                user.id,
                LocalChatCacheService.buildPlaintextRow(
                  id: chatId,
                  payload: decrypted,
                  createdAt: row['created_at'] as String,
                  isStarred: (row['is_starred'] as bool?) ?? false,
                  updatedAt: row['updated_at'] as String?,
                  title: title.isNotEmpty ? title : null,
                ),
              ),
            );

            stopwatch.stop();
            if (kDebugMode) {
              debugPrint(
                '✅ [ChatStorage] Full chat loaded from remote in ${stopwatch.elapsedMilliseconds}ms (${chatPayload.messages.length} messages)',
              );
            }
            return chat;
          }
        }

        if (kDebugMode) {
          debugPrint(
            '⚠️ [ChatStorage] Chat not found on server or in cache: $chatId',
          );
        }
      } on SecretBoxAuthenticationError {
        if (kDebugMode) {
          debugPrint('🔐 [ChatStorage] Failed to decrypt chat: $chatId');
        }
        return null;
      } catch (e) {
        if (kDebugMode) {
          debugPrint('⚠️ [ChatStorage] Remote load failed: $e');
        }
      }
    } else {
      if (kDebugMode) {
        debugPrint('📦 [ChatStorage] Offline and no cache for chat: $chatId');
      }
    }

    return null;
  }

  /// Background sync: fetch latest version from Supabase and update cache.
  /// Called after serving a chat from local cache to keep it fresh.
  static Future<void> _syncChatFromRemote(
    String chatId,
    String userId,
    StoredChat? existing,
  ) async {
    try {
      final isOnline = await ChatStorageState.checkNetworkStatus();
      if (!isOnline) return;

      final rows = await SupabaseService.client
          .from('encrypted_chats')
          .select(
            'id, encrypted_payload, created_at, is_starred, updated_at, encrypted_title',
          )
          .eq('id', chatId)
          .eq('user_id', userId)
          .limit(1)
          .timeout(const Duration(seconds: 10));

      if (rows.isEmpty) return;

      final row = rows.first;
      final encryptedPayload = row['encrypted_payload'] as String?;
      if (encryptedPayload == null || encryptedPayload.isEmpty) return;

      final decrypted = await EncryptionService.decryptInBackground(
        encryptedPayload,
      );
      final chatPayload = await deserializePayloadAsync(decrypted);
      final resolvedTitle = _resolveStoredTitle(
        messages: chatPayload.messages,
        customName: chatPayload.customName,
        fallbackTitle: existing?.title,
      );

      final remoteChat = StoredChat.fromRow(
        row,
        chatPayload.messages,
        customName: chatPayload.customName,
        title: resolvedTitle,
      );

      // Only update if remote is newer
      final current = ChatStorageState.chatsById[chatId];
      if (current != null) {
        final currentUpdated = current.updatedAt ?? current.createdAt;
        final remoteUpdated = remoteChat.updatedAt ?? remoteChat.createdAt;
        if (!remoteUpdated.isAfter(currentUpdated)) return;
      }

      ChatStorageState.chatsById[chatId] = remoteChat;
      ChatStorageState.notifyChanges(chatId);

      unawaited(
        _repairEncryptedTitleIfNeeded(
          chatId: chatId,
          userId: userId,
          payloadCustomName: chatPayload.customName,
          currentTitle: existing?.title,
        ),
      );

      // Update plaintext cache
      final title =
          remoteChat.title ?? extractTitleFromMessages(remoteChat.messages);
      await LocalChatCacheService.upsert(
        userId,
        LocalChatCacheService.buildPlaintextRow(
          id: chatId,
          payload: decrypted,
          createdAt: row['created_at'] as String,
          isStarred: (row['is_starred'] as bool?) ?? false,
          updatedAt: row['updated_at'] as String?,
          title: title.isNotEmpty ? title : null,
        ),
      );

      if (kDebugMode) {
        debugPrint('🔄 [ChatStorage] Background sync updated chat: $chatId');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ [ChatStorage] Background sync failed for $chatId: $e');
      }
    }
  }

  /// Load a single chat from local cache (SharedPreferences).
  /// Used as fallback when Supabase is unreachable (offline mode).
  /// Cache stores plaintext — no decryption needed.
  static Future<StoredChat?> _loadFullChatFromCache(
    String chatId,
    String userId,
    StoredChat? existing,
    Stopwatch stopwatch,
  ) async {
    try {
      final cachedRows = await LocalChatCacheService.load(userId);
      final cachedRow = cachedRows.cast<Map<String, dynamic>?>().firstWhere(
        (r) => r?['id'] == chatId,
        orElse: () => null,
      );

      if (cachedRow == null) {
        if (kDebugMode) {
          debugPrint('⚠️ [ChatStorage] Chat not found in local cache: $chatId');
        }
        return null;
      }

      final payload = cachedRow['payload'] as String?;
      if (payload == null || payload.isEmpty) {
        if (kDebugMode) {
          debugPrint(
            '⚠️ [ChatStorage] Chat has no payload in local cache: $chatId',
          );
        }
        return null;
      }

      // Plaintext cache — deserialize directly, no decryption needed
      final chatPayload = await deserializePayloadAsync(payload);
      final resolvedTitle = _resolveStoredTitle(
        messages: chatPayload.messages,
        customName: chatPayload.customName,
        fallbackTitle: existing?.title,
      );

      final chat = StoredChat.fromRow(
        cachedRow,
        chatPayload.messages,
        customName: chatPayload.customName,
        title: resolvedTitle,
      );

      ChatStorageState.chatsById[chatId] = chat;
      ChatStorageState.notifyChanges(chatId);

      stopwatch.stop();
      if (kDebugMode) {
        debugPrint(
          '✅ [ChatStorage] Full chat loaded from LOCAL CACHE in ${stopwatch.elapsedMilliseconds}ms (${chatPayload.messages.length} messages)',
        );
      }
      return chat;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('❌ [ChatStorage] Local cache fallback failed: $e');
      }
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
      // Migrate from old encrypted cache if needed
      if (await LocalChatCacheService.hasOldEncryptedCache(user.id)) {
        if (!EncryptionService.hasKey) {
          await EncryptionService.tryLoadKey();
        }
        if (EncryptionService.hasKey) {
          await LocalChatCacheService.migrateFromEncrypted(user.id);
        } else if (kDebugMode) {
          debugPrint(
            '⚠️ [ChatStorage] Cannot migrate cache: encryption key unavailable',
          );
        }
      }

      final rows = await LocalChatCacheService.load(user.id);
      if (rows.isEmpty) {
        if (kDebugMode) {
          debugPrint('📦 [ChatStorage] Cache empty');
        }
        return;
      }

      if (kDebugMode) {
        debugPrint(
          '📦 [ChatStorage] Loading ${rows.length} chats from cache...',
        );
      }

      // Progressive loading: first batch for fast UI, then rest in background
      const int firstBatchSize = 15;
      final firstBatch = rows.take(firstBatchSize).toList();
      final remainingBatch = rows.skip(firstBatchSize).toList();

      ChatStorageState.chatsById.clear();

      // Parse first 15 chats (plaintext — no decryption needed!)
      final firstChats = await _parseChatRowsBatch(firstBatch);
      for (final chat in firstChats) {
        if (chat != null) {
          ChatStorageState.chatsById[chat.id] = chat;
        }
      }

      ChatStorageState.cacheLoaded = true;

      // Notify UI immediately with first batch
      if (ChatStorageState.chatsById.isNotEmpty) {
        ChatStorageState.notifyChanges();
        if (kDebugMode) {
          debugPrint(
            '⚡ [ChatStorage] First ${ChatStorageState.chatsById.length} chats from cache (fast)',
          );
        }
      }

      // Parse remaining (also fast — no decryption)
      if (remainingBatch.isNotEmpty) {
        final remainingChats = await _parseChatRowsBatch(remainingBatch);
        for (final chat in remainingChats) {
          if (chat != null) {
            ChatStorageState.chatsById[chat.id] = chat;
          }
        }
        ChatStorageState.notifyChanges();
      }

      if (kDebugMode) {
        debugPrint(
          '✅ [ChatStorage] Loaded ${ChatStorageState.chatsById.length} chats from cache',
        );
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('❌ [ChatStorage] Cache load failed: $e');
      }
    }
  }

  /// Parse plaintext cache rows into StoredChat objects (no decryption needed).
  /// Uses a single isolate for batch JSON parsing.
  static Future<List<StoredChat?>> _parseChatRowsBatch(
    List<Map<String, dynamic>> rows,
  ) async {
    if (rows.isEmpty) return [];

    final results = List<StoredChat?>.filled(rows.length, null);

    // Collect valid payloads for batch processing
    final payloads = <String>[];
    final validIndices = <int>[];

    for (int i = 0; i < rows.length; i++) {
      final payload = rows[i]['payload'] as String?;
      if (payload != null && payload.isNotEmpty) {
        payloads.add(payload);
        validIndices.add(i);
      }
    }

    if (payloads.isEmpty) return results;

    // Single isolate for all JSON parsing
    final chatPayloads = await deserializePayloadBatchAsync(payloads);

    for (int j = 0; j < validIndices.length; j++) {
      final chatPayload = chatPayloads[j];
      if (chatPayload == null) continue;

      final i = validIndices[j];
      final resolvedTitle = _resolveStoredTitle(
        messages: chatPayload.messages,
        customName: chatPayload.customName,
      );
      results[i] = StoredChat.fromRow(
        rows[i],
        chatPayload.messages,
        customName: chatPayload.customName,
        title: resolvedTitle,
      );
    }

    return results;
  }

  /// Batch decrypt multiple Supabase chat rows in a single isolate.
  /// Used for Supabase rows which are still encrypted.
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
        final resolvedTitle = _resolveStoredTitle(
          messages: chatPayload.messages,
          customName: chatPayload.customName,
        );
        results[i] = StoredChat.fromRow(
          rows[i],
          chatPayload.messages,
          customName: chatPayload.customName,
          title: resolvedTitle,
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
      if (kDebugMode) {
        debugPrint('⏳ [ChatStorage] Load already in progress, waiting...');
      }
      return ChatStorageState.loadingCompleter!.future;
    }
    ChatStorageState.loadingCompleter = Completer<void>();

    try {
      final user = SupabaseService.auth.currentUser;
      if (user == null) {
        if (kDebugMode) {
          debugPrint('⚠️ [ChatStorage] No user signed in, clearing chats');
        }
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
          if (kDebugMode) {
            debugPrint('🌐 [ChatStorage] Network status: ONLINE');
          }
          rows = await SupabaseService.client
              .from('encrypted_chats')
              .select(
                'id, encrypted_payload, created_at, is_starred, updated_at',
              )
              .eq('user_id', user.id)
              .order('created_at', ascending: false)
              .timeout(const Duration(seconds: 30));
          if (kDebugMode) {
            debugPrint(
              '✅ [ChatStorage] Loaded ${rows.length} chats from remote',
            );
          }

          // Decrypt Supabase rows and build plaintext cache rows
          // (done after in-memory state is built below)
        } catch (error, stackTrace) {
          remoteError = error;
          remoteStack = stackTrace;
          if (kDebugMode) {
            debugPrint('❌ [ChatStorage] Failed to load from remote: $error');
          }

          // Fall back to cache (plaintext)
          try {
            rows = await LocalChatCacheService.load(user.id);
            loadedFromCache = true;
            if (kDebugMode) {
              debugPrint(
                '📦 [ChatStorage] Loaded ${rows.length} chats from cache (fallback)',
              );
            }
          } catch (cacheError) {
            if (kDebugMode) {
              debugPrint(
                '❌ [ChatStorage] Failed to load from cache: $cacheError',
              );
            }
            rows = [];
          }
        }
      } else {
        if (kDebugMode) {
          debugPrint('🌐 [ChatStorage] Network status: OFFLINE');
        }
        try {
          rows = await LocalChatCacheService.load(user.id);
          loadedFromCache = true;
          if (kDebugMode) {
            debugPrint(
              '📦 [ChatStorage] Loaded ${rows.length} chats from cache (offline)',
            );
          }
        } catch (error) {
          if (kDebugMode) {
            debugPrint('❌ [ChatStorage] Failed to load from cache: $error');
          }
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

      // Use appropriate parser: cache rows are plaintext, Supabase rows need decryption
      final firstChats = loadedFromCache
          ? await _parseChatRowsBatch(firstBatch)
          : await _decryptChatRowsBatch(firstBatch);
      for (final chat in firstChats) {
        if (chat != null) {
          ChatStorageState.chatsById[chat.id] = chat;
        }
      }

      // Notify UI immediately so sidebar shows first chats
      if (ChatStorageState.chatsById.isNotEmpty) {
        ChatStorageState.notifyChanges();
        if (kDebugMode) {
          debugPrint(
            '⚡ [ChatStorage] First ${ChatStorageState.chatsById.length} chats ready (fast path)',
          );
        }
      }

      // Process remaining chats
      if (remainingBatch.isNotEmpty) {
        if (kDebugMode) {
          debugPrint(
            '🔄 [ChatStorage] Processing ${remainingBatch.length} more chats in background...',
          );
        }
        final remainingChats = loadedFromCache
            ? await _parseChatRowsBatch(remainingBatch)
            : await _decryptChatRowsBatch(remainingBatch);
        for (final chat in remainingChats) {
          if (chat != null) {
            ChatStorageState.chatsById[chat.id] = chat;
          }
        }
        ChatStorageState.notifyChanges();
        if (kDebugMode) {
          debugPrint(
            '✅ [ChatStorage] All ${ChatStorageState.chatsById.length} chats loaded',
          );
        }
      } else if (ChatStorageState.chatsById.isEmpty) {
        // No chats at all - still notify
        ChatStorageState.notifyChanges();
      }

      // If loaded from Supabase, build plaintext cache rows and save
      if (!loadedFromCache && rows.isNotEmpty) {
        _buildAndCachePlaintextRows(user.id, rows);
      }

      // Log all loaded chats for debugging
      if (ChatStorageState.chatsById.isNotEmpty) {
        if (kDebugMode) {
          debugPrint(
            '📋 [ChatStorage] Current chats in memory (${ChatStorageState.chatsById.length}):',
          );
        }
        for (final entry in ChatStorageState.chatsById.entries) {
          final chat = entry.value;
          final firstUserMsg = chat.messages
              .where((m) => m.role == 'user')
              .firstOrNull;
          final title = (firstUserMsg?.text.length ?? 0) > 40
              ? '${firstUserMsg!.text.substring(0, 40)}...'
              : (firstUserMsg?.text ?? 'No user message');
          if (kDebugMode) {
            debugPrint(
              '   - ${entry.key.substring(0, 8)}... : "$title" (${chat.messages.length} msgs)',
            );
          }
        }
      }

      if (loadedFromCache && remoteError != null) {
        if (kDebugMode) {
          debugPrint(
            'ChatStorageService loaded chats from offline cache: $remoteError',
          );
        }
        if (remoteStack != null) {
          if (kDebugMode) {
            debugPrint('Stack trace: $remoteStack');
          }
        }
      }
    } finally {
      ChatStorageState.loadingCompleter?.complete();
      ChatStorageState.loadingCompleter = null;
    }
  }

  /// Build plaintext cache rows from already-decrypted in-memory chats
  /// and replace the local cache. Runs in background (fire-and-forget).
  static void _buildAndCachePlaintextRows(
    String userId,
    List<Map<String, dynamic>> supabaseRows,
  ) {
    unawaited(() async {
      try {
        final plaintextRows = <Map<String, dynamic>>[];
        int skippedCount = 0;
        for (final row in supabaseRows) {
          final chatId = row['id'] as String;
          final chat = ChatStorageState.chatsById[chatId];
          if (chat == null || !chat.isFullyLoaded) {
            skippedCount++;
            continue;
          }

          final payload = jsonEncode({
            'v': kChatPayloadVersion,
            if (chat.customName != null) 'customName': chat.customName,
            'messages': chat.messages.map((m) => m.toJson()).toList(),
          });

          plaintextRows.add(
            LocalChatCacheService.buildPlaintextRow(
              id: chatId,
              payload: payload,
              createdAt: row['created_at'] as String,
              isStarred: (row['is_starred'] as bool?) ?? false,
              updatedAt: row['updated_at'] as String?,
              title: chat.title,
            ),
          );
        }
        if (plaintextRows.isNotEmpty && skippedCount == 0) {
          // All chats processed — safe to replace entire cache
          await LocalChatCacheService.replaceAll(userId, plaintextRows);
        } else if (plaintextRows.isNotEmpty) {
          // Partial success — upsert individually to preserve existing cache
          for (final row in plaintextRows) {
            await LocalChatCacheService.upsert(userId, row);
          }
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('⚠️ [ChatStorage] Failed to build plaintext cache: $e');
        }
      }
    }());
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

      final rawText = m['text'] as String? ?? '';
      final text = role == 'assistant'
          ? stripToolCallBlocksForDisplay(rawText)
          : rawText;

      // Preserve local-only delivery status (pending/failed/interrupted) so
      // it survives the round-trip through the chat cache. Without this the
      // `interrupted` flag set during a backgrounded stream would be lost on
      // the next chat reload, defeating the "Continue generation" affordance.
      ChatMessageStatus? status;
      final statusRaw = m['status'];
      if (statusRaw is String && statusRaw.isNotEmpty) {
        switch (statusRaw) {
          case 'pending':
            status = ChatMessageStatus.pending;
            break;
          case 'failed':
            status = ChatMessageStatus.failed;
            break;
          case 'sent':
            status = ChatMessageStatus.sent;
            break;
          case 'interrupted':
            status = ChatMessageStatus.interrupted;
            break;
        }
      }

      return ChatMessage(
        role: role,
        text: text,
        reasoning: m['reasoning'] as String?,
        replyContext: m['replyContext'] as String?,
        images: m['images'] as String?,
        imageCostEur: m['imageCostEur'] as String?,
        imageGeneratedAt: m['imageGeneratedAt'] as String?,
        attachments: m['attachments'] as String?,
        attachedFilesJson: m['attachedFilesJson'] as String?,
        toolCalls: m['toolCalls'] as String?,
        contentBlocks: m['contentBlocks'] as String?,
        modelId: m['modelId'] as String?,
        provider: m['provider'] as String?,
        status: status,
        queueId: m['queueId'] as String?,
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
    if (kDebugMode) {
      debugPrint(
        '💾 [ChatStorage] saveChat: $effectiveChatId (${messagesMaps.length} messages)',
      );
    }

    // If there's already a pending save for this chat, wait for it
    if (ChatStorageState.pendingSaves.containsKey(effectiveChatId)) {
      if (kDebugMode) {
        debugPrint(
          '⏳ [ChatStorage] Waiting for pending save: $effectiveChatId',
        );
      }
      return await ChatStorageState.pendingSaves[effectiveChatId]!.future;
    }

    // If chat already exists, update it instead
    if (ChatStorageState.chatsById.containsKey(effectiveChatId)) {
      if (kDebugMode) {
        debugPrint('🔄 [ChatStorage] Chat exists, updating: $effectiveChatId');
      }
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
      if (kDebugMode) {
        debugPrint('⚠️ [ChatStorage] No messages to save');
      }
      return null;
    }

    final payloadJson = jsonEncode({
      'v': kChatPayloadVersion,
      'messages': messages.map((m) => m.toJson()).toList(),
    });

    final encryptedPayload = await EncryptionService.encrypt(payloadJson);

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
      ...?encryptedTitle == null ? null : {'encrypted_title': encryptedTitle},
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

    // Cache plaintext row (NOT the encrypted Supabase row)
    unawaited(
      LocalChatCacheService.upsert(
        user.id,
        LocalChatCacheService.buildPlaintextRow(
          id: finalId,
          payload: payloadJson,
          createdAt: inserted['created_at'] as String,
          isStarred: (inserted['is_starred'] as bool?) ?? false,
          updatedAt: inserted['updated_at'] as String?,
          title: title.isNotEmpty ? title : null,
        ),
      ),
    );

    // Log with title for debugging
    final displayTitle = title.length > 50
        ? '${title.substring(0, 50)}...'
        : title;
    if (kDebugMode) {
      debugPrint('✅ [ChatStorage] Saved new chat: $finalId');
    }
    if (kDebugMode) {
      debugPrint('   📝 Title: "$displayTitle"');
    }
    if (kDebugMode) {
      debugPrint(
        '   📊 Messages: ${messages.length} (${messages.where((m) => m.role == "user").length} user, ${messages.where((m) => m.role == "assistant").length} assistant)',
      );
    }

    return chat;
  }

  /// Update an existing chat
  static Future<StoredChat?> updateChat(
    String chatId,
    List<Map<String, dynamic>> messagesMaps,
  ) async {
    // If there's already a pending save for this chat, wait for it then try again
    if (ChatStorageState.pendingSaves.containsKey(chatId)) {
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
      if (kDebugMode) {
        debugPrint('⚠️ [ChatStorage] No messages to update');
      }
      return null;
    }

    // Preserve existing customName
    final existingChat = ChatStorageState.chatsById[chatId];
    final String? existingCustomName = existingChat?.customName;
    final String? normalizedCustomName =
        existingCustomName?.trim().isNotEmpty == true
        ? existingCustomName!.trim()
        : null;

    final Map<String, dynamic> payloadMap = {
      'v': kChatPayloadVersion,
      'messages': messages.map((m) => m.toJson()).toList(),
    };
    if (normalizedCustomName != null) {
      payloadMap['customName'] = normalizedCustomName;
    }

    final payloadJson = jsonEncode(payloadMap);
    final encryptedPayload = await EncryptionService.encrypt(payloadJson);

    // Extract and encrypt title separately for fast sidebar loading
    final String title =
        normalizedCustomName ?? extractTitleFromMessages(messages);
    final encryptedTitle = title.isNotEmpty
        ? await EncryptionService.encrypt(title)
        : null;

    // Extract image paths for cleanup on delete
    final imagePaths = _extractImagePaths(messages);

    final updatedRows = await SupabaseService.client
        .from('encrypted_chats')
        .update({
          'encrypted_payload': encryptedPayload,
          ...?encryptedTitle == null
              ? null
              : {'encrypted_title': encryptedTitle},
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
      customName: normalizedCustomName,
      title: title.isNotEmpty ? title : null,
    );

    // Update in our map - this is the ONLY place we update chats
    ChatStorageState.chatsById[chatId] = chat;
    ChatStorageState.notifyChanges(chatId);

    // Cache plaintext row (NOT the encrypted Supabase row)
    unawaited(
      LocalChatCacheService.upsert(
        user.id,
        LocalChatCacheService.buildPlaintextRow(
          id: chatId,
          payload: payloadJson,
          createdAt: updatedRow['created_at'] as String,
          isStarred: (updatedRow['is_starred'] as bool?) ?? false,
          updatedAt: updatedRow['updated_at'] as String?,
          title: title.isNotEmpty ? title : null,
        ),
      ),
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
      if (kDebugMode) {
        debugPrint('⚠️ [ChatStorage] Failed to fetch image_paths: $e');
      }
      // Continue with deletion even if fetching paths fails
    }

    // Delete associated images from storage (best effort, don't block on failures)
    if (imagePaths.isNotEmpty) {
      if (kDebugMode) {
        debugPrint(
          '🖼️ [ChatStorage] Deleting ${imagePaths.length} images for chat: $chatId',
        );
      }
      for (final path in imagePaths) {
        try {
          await ImageStorageService.deleteEncryptedImage(path);
          if (kDebugMode) {
            debugPrint('   ✅ Deleted image: $path');
          }
        } catch (e) {
          if (kDebugMode) {
            debugPrint('   ⚠️ Failed to delete image $path: $e');
          }
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

    // Mark as recently deleted FIRST to prevent sync from resurrecting
    ChatStorageState.markDeleted(chatId);

    ChatStorageState.chatsById.remove(chatId);
    ChatStorageState.savingChats.remove(chatId);
    ChatStorageState.pendingSaves.remove(chatId);

    // Clear selection if the deleted chat was selected
    if (ChatStorageState.selectedChatId == chatId) {
      ChatStorageState.selectedChatId = null;
    }

    ChatStorageState.notifyChanges(chatId);
    unawaited(LocalChatCacheService.delete(user.id, chatId));

    // Update title cache to remove the deleted chat
    unawaited(
      saveTitlesToCache(user.id, ChatStorageState.chatsById.values.toList()),
    );

    if (kDebugMode) {
      debugPrint('🗑️ [ChatStorage] Deleted chat: $chatId');
    }
  }
}
