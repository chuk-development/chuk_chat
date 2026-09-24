// lib/services/chat_storage_crud.dart

import 'dart:async';
import 'dart:convert';

import 'package:chuk_chat/models/chat_message.dart';
import 'package:chuk_chat/models/stored_chat.dart';
import 'package:chuk_chat/services/chat_dirty_store.dart';
import 'package:chuk_chat/services/chat_storage_mutations.dart';
import 'package:chuk_chat/services/chat_storage_state.dart';
import 'package:chuk_chat/services/chat_storage_sync.dart';
import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/image_storage_service.dart';
import 'package:chuk_chat/services/local_chat_cache_service.dart';
import 'package:chuk_chat/services/storage/agents_chat_store.dart';
import 'package:chuk_chat/services/storage/chat_origin.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/utils/tool_parser.dart';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

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

            // Cache plaintext (as v3) for next time
            final title = chat.title ?? extractTitleFromMessages(chat.messages);
            unawaited(() async {
              try {
                await LocalChatCacheService.upsert(
                  user.id,
                  LocalChatCacheService.buildPlaintextRow(
                    id: chatId,
                    payload: await toChatPayloadV3Async(decrypted),
                    createdAt: row['created_at'] as String,
                    isStarred: (row['is_starred'] as bool?) ?? false,
                    updatedAt: row['updated_at'] as String?,
                    title: title.isNotEmpty ? title : null,
                  ),
                );
              } catch (e) {
                if (kDebugMode) {
                  debugPrint('⚠️ [ChatStorage] Cache write failed: $e');
                }
              }
            }());

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

      // A local copy ahead of the cloud is newer whatever the clocks say.
      if (ChatDirtyStore.isDirty(chatId)) return;

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
          payload: await toChatPayloadV3Async(decrypted),
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
      // Indexed single-row lookup — avoid loading and parsing every cached
      // chat payload just to find one (that made each chat open scale with
      // total chat count, flashing the loading spinner on mobile).
      final cachedRow = await LocalChatCacheService.loadById(userId, chatId);

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

    final String userId;
    if (ChatOrigin.agentsEnabled) {
      // AGENTS: the read key, not the live session. On a cold start the app
      // paints long before gotrue has its session back off disk, and
      // upstream's `currentUser == null` branch CLEARED the map — it threw
      // away the very rows the thread was about to paint from. The remembered
      // id keeps the cache readable; with no id at all the map is left
      // exactly as it is, because an empty map is not the same statement as
      // "no chats".
      final cacheUserId = await AgentsChatStore.resolveCacheUserId();
      if (cacheUserId == null) return;
      userId = cacheUserId;
    } else {
      final user = SupabaseService.auth.currentUser;
      if (user == null) {
        ChatStorageState.chatsById.clear();
        ChatStorageState.notifyChanges();
        return;
      }
      userId = user.id;
    }

    try {
      // Migrate from old encrypted cache if needed
      if (await LocalChatCacheService.hasOldEncryptedCache(userId)) {
        if (!EncryptionService.hasKey) {
          await EncryptionService.tryLoadKey();
        }
        if (EncryptionService.hasKey) {
          await LocalChatCacheService.migrateFromEncrypted(userId);
        } else if (kDebugMode) {
          debugPrint(
            '⚠️ [ChatStorage] Cannot migrate cache: encryption key unavailable',
          );
        }
      }

      // Metadata only. The sidebar needs a title, a date and a starred
      // flag; the messages are read from the same cache when a chat is
      // opened (see [loadFullChat]). Reading every payload here is what
      // made startup pull the whole history into memory, and on Android
      // it exceeded what a single platform-channel result can allocate.
      final rows = await LocalChatCacheService.loadMeta(userId);
      if (rows.isEmpty) {
        if (kDebugMode) {
          debugPrint('📦 [ChatStorage] Cache empty');
        }
        return;
      }

      ChatStorageState.chatsById.clear();
      for (final row in rows) {
        final chat = _sidebarChatFromCacheRow(row);
        if (chat != null) {
          ChatStorageState.chatsById[chat.id] = chat;
        }
      }

      ChatStorageState.cacheLoaded = true;
      ChatStorageState.notifyChanges();

      if (kDebugMode) {
        debugPrint(
          '⚡ [ChatStorage] ${ChatStorageState.chatsById.length} chats from '
          'cache metadata',
        );
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('❌ [ChatStorage] Cache load failed: $e');
      }
    }
  }

  /// Build a sidebar entry (no messages) from a cache metadata row.
  ///
  /// Returns null for a row without a usable id or timestamp rather than
  /// throwing — one broken row must not take down the whole sidebar.
  static StoredChat? _sidebarChatFromCacheRow(Map<String, dynamic> row) {
    final id = row['id'];
    if (id is! String || id.isEmpty) return null;

    final createdAt = DateTime.tryParse(row['created_at'] as String? ?? '');
    if (createdAt == null) return null;

    final updatedRaw = row['updated_at'];

    return StoredChat.forSidebar(
      id: id,
      createdAt: createdAt,
      isStarred: (row['is_starred'] as bool?) ?? false,
      title: row['title'] as String?,
      updatedAt: updatedRaw is String ? DateTime.tryParse(updatedRaw) : null,
    );
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
            rows = await LocalChatCacheService.loadMeta(user.id);
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
          rows = await LocalChatCacheService.loadMeta(user.id);
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

      // Clear and rebuild the chats map. A chat whose local copy is ahead of
      // the cloud (or not in it yet) keeps that copy.
      final localAhead = <String, StoredChat>{
        for (final id in ChatDirtyStore.ids)
          id: ?ChatStorageState.chatsById[id],
      };
      ChatStorageState.chatsById
        ..clear()
        ..addAll(localAhead);

      // Cache rows are metadata only: build sidebar entries and let each
      // chat hydrate from the cache when it is opened.
      if (loadedFromCache) {
        for (final row in rows) {
          final chat = _sidebarChatFromCacheRow(row);
          if (chat != null && !localAhead.containsKey(chat.id)) {
            ChatStorageState.chatsById[chat.id] = chat;
          }
        }
        ChatStorageState.notifyChanges();
        if (kDebugMode) {
          debugPrint(
            '⚡ [ChatStorage] ${ChatStorageState.chatsById.length} chats from '
            'cache metadata',
          );
        }
        if (remoteError != null) {
          if (kDebugMode) {
            debugPrint(
              'ChatStorageService loaded chats from offline cache: '
              '$remoteError',
            );
            if (remoteStack != null) {
              debugPrint('Stack trace: $remoteStack');
            }
          }
        }
        return;
      }

      // Progressive loading: decrypt first batch immediately for fast UI,
      // then decrypt remaining chats in background
      const int firstBatchSize = 15;
      final firstBatch = rows.take(firstBatchSize).toList();
      final remainingBatch = rows.skip(firstBatchSize).toList();

      final firstChats = await _decryptChatRowsBatch(firstBatch);
      for (final chat in firstChats) {
        if (chat != null && !ChatDirtyStore.isDirty(chat.id)) {
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
        final remainingChats = await _decryptChatRowsBatch(remainingBatch);
        for (final chat in remainingChats) {
          if (chat != null && !ChatDirtyStore.isDirty(chat.id)) {
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
          // Sidebar entries carry no messages — reading `messages` on one
          // throws, so skip them instead of taking down a debug build.
          final loadedMessages = chat.messagesOrNull;
          if (loadedMessages == null) continue;
          final firstUserMsg = loadedMessages
              .where((m) => m.role == 'user')
              .firstOrNull;
          final title = (firstUserMsg?.text.length ?? 0) > 40
              ? '${firstUserMsg!.text.substring(0, 40)}...'
              : (firstUserMsg?.text ?? 'No user message');
          if (kDebugMode) {
            debugPrint(
              '   - ${entry.key.substring(0, 8)}... : "$title" '
              '(${loadedMessages.length} msgs)',
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
          // A dirty chat's cache row is newer than this cloud row; counting
          // it as skipped also keeps replaceAll from dropping a row the cloud
          // does not hold yet.
          if (chat == null ||
              !chat.isFullyLoaded ||
              ChatDirtyStore.isDirty(chatId)) {
            skippedCount++;
            continue;
          }

          final payload = await encodeChatPayloadAsync(
            chat.messages,
            chat.customName,
          );

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
        imageMetas: m['imageMetas'] as String?,
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
        messageId: m['messageId'] as String?,
        // AGENTS: the Agents transcript carries these timings; upstream's
        // save drops them, so they are kept only with FEATURE_AGENTS on.
        sentAt: ChatOrigin.agentsEnabled ? m['sentAt']?.toString() : null,
        startedAt: ChatOrigin.agentsEnabled ? m['startedAt']?.toString() : null,
        generationMs: ChatOrigin.agentsEnabled
            ? m['generationMs']?.toString()
            : null,
        // Answer-version pager: the variant archive and the active index must
        // survive persist + reload. The UI map stores `variants` as a JSON
        // string and `activeVariant` as a stringified int, so parse the latter
        // back to an int here.
        variants: m['variants'] as String?,
        activeVariant: parseFlexibleInt(m['activeVariant']),
      );
    }).toList();
  }

  // ==========================================================================
  // LOCAL-FIRST SAVES
  //
  // A turn saves its chat many times (per tool round, per stream checkpoint).
  // Those saves go to [saveLocal]: memory, the SQLite cache and a dirty mark,
  // no network. The cloud gets the chat once, at the end of the turn, through
  // [saveChat]/[updateChat]; whatever stays dirty is written by [flushDirty].
  // ==========================================================================

  /// Chat id -> the newest cache row waiting to be written, and the writer
  /// working through them. One writer per chat keeps the rows in order, and
  /// a row that is replaced before its turn is never written. A row is a
  /// future: its payload is encoded off the UI isolate, and the order is the
  /// order of the calls, not the order in which the encodings finish.
  static final Map<String, Future<Map<String, dynamic>>> _pendingLocalRows =
      <String, Future<Map<String, dynamic>>>{};
  static final Map<String, Future<void>> _localRowWriters =
      <String, Future<void>>{};

  static Future<void> _writeLocalRow(
    String userId,
    String chatId,
    Future<Map<String, dynamic>> row,
  ) {
    // A failed row is reported by the writer; nobody else listens to it.
    _pendingLocalRows[chatId] = row..ignore();
    return _localRowWriters[chatId] ??= () async {
      try {
        for (
          var next = _pendingLocalRows.remove(chatId);
          next != null;
          next = _pendingLocalRows.remove(chatId)
        ) {
          try {
            await LocalChatCacheService.upsert(userId, await next);
          } catch (e) {
            // The chat stays dirty and in memory; the flush writes the cloud
            // from there, and the next save writes this row again.
            if (kDebugMode) {
              debugPrint('⚠️ [ChatStorage] Cache write failed for $chatId: $e');
            }
          }
        }
      } finally {
        _localRowWriters.remove(chatId);
      }
    }();
  }

  static String? _customNameOf(StoredChat? chat) {
    final name = chat?.customName?.trim();
    return name != null && name.isNotEmpty ? name : null;
  }

  /// The plaintext payload of a chat (v3). The one encoding for the cache
  /// and the cloud.
  static Future<String> _payloadJson(
    List<ChatMessage> messages,
    String? customName,
  ) => encodeChatPayloadAsync(messages, customName);

  /// The digest that tells two saves of a chat apart: over the messages as
  /// they are in memory, not over the stored encoding, so it is computed
  /// before (and without) the payload.
  static String _digest(List<ChatMessage> messages, String? customName) =>
      sha256
          .convert(
            utf8.encode(
              jsonEncode({
                'messages': messages.map((m) => m.toJson()).toList(),
                'customName': ?customName,
              }),
            ),
          )
          .toString();

  /// Save [messagesMaps] on this device only: memory (sidebar, search and
  /// reopening the chat read it), the SQLite cache and a dirty mark. No
  /// network. A new chat gets its id here; the cloud row is inserted with
  /// its first cloud save. Returns null for a deleted chat or no messages.
  static Future<StoredChat?> saveLocal(
    List<Map<String, dynamic>> messagesMaps, {
    String? chatId,
  }) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to store chats.');
    }
    final id = chatId ?? ChatStorageState.uuid.v4();
    if (ChatStorageState.wasRecentlyDeleted(id)) return null;

    final messages = _mapToChatMessages(messagesMaps);
    if (messages.isEmpty) return null;

    final existing = ChatStorageState.chatsById[id];
    final customName = _customNameOf(existing);
    final digest = _digest(messages, customName);

    // The same messages as the copy in memory: nothing to save. A stream
    // checkpoint or an auto-save tick often carries nothing new.
    final known = ChatStorageState.localDigest[id];
    if (existing != null &&
        existing.isFullyLoaded &&
        known != null &&
        known.digest == digest &&
        known.updatedAt == existing.updatedAt) {
      return existing;
    }

    final now = DateTime.now().toUtc();
    final title = customName ?? extractTitleFromMessages(messages);
    final chat = existing == null
        ? StoredChat(
            id: id,
            messages: messages,
            createdAt: now,
            updatedAt: now,
            isStarred: false,
            title: title.isNotEmpty ? title : null,
          )
        : existing.copyWith(
            messages: messages,
            updatedAt: now,
            title: title.isNotEmpty ? title : null,
          );

    // The cloud still holds what this device last wrote there, so that
    // write stays the one to compare the next cloud save against.
    final lastWrite = ChatStorageState.lastWrite[id];
    if (existing != null &&
        lastWrite != null &&
        lastWrite.updatedAt == existing.updatedAt) {
      ChatStorageState.lastWrite[id] = (
        digest: lastWrite.digest,
        updatedAt: now,
      );
    }

    ChatStorageState.chatsById[id] = chat;
    ChatStorageState.localDigest[id] = (digest: digest, updatedAt: now);
    ChatStorageState.notifyChanges(id);

    // Mark first, then write the row: a kill in between leaves a dirty mark
    // over the previous row, which is harmless; the reverse would leave a
    // newer row that nothing ever sends to the cloud. The mark counts the
    // revision at once; the row is queued at once too (in call order) and
    // waits for the mark before it is written.
    final marked = ChatDirtyStore.markDirty(
      user.id,
      id,
      pendingInsert: existing == null,
    );

    // Web keeps its cache in SharedPreferences, which must not take a whole
    // payload on every checkpoint. There the dirty copy lives in memory.
    if (kIsWeb) {
      await marked;
      return chat;
    }
    final writer = _writeLocalRow(user.id, id, () async {
      final payloadJson = await _payloadJson(messages, customName);
      await marked;
      return LocalChatCacheService.buildPlaintextRow(
        id: id,
        payload: payloadJson,
        createdAt: chat.createdAt.toUtc().toIso8601String(),
        isStarred: chat.isStarred,
        updatedAt: now.toIso8601String(),
        title: chat.title,
      );
    }());
    await marked;
    await writer;
    return chat;
  }

  /// Write every chat whose local copy is ahead of the cloud, once. A chat
  /// whose write fails stays dirty for the next flush.
  /// Never throws: a chat that cannot be written now waits for the next
  /// flush, and there is nothing the user has to act on.
  static Future<void> flushDirty() async {
    try {
      final user = SupabaseService.auth.currentUser;
      if (user == null) return;
      await ChatDirtyStore.flush(user.id, _pushLocalCopy);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ [ChatStorage] Dirty flush failed: $e');
      }
    }
  }

  /// Write the local copy of [chatId] to the cloud: memory, else the cache.
  static Future<void> _pushLocalCopy(String chatId) async {
    if (ChatStorageState.wasRecentlyDeleted(chatId)) return;
    var chat = ChatStorageState.chatsById[chatId];
    if (chat == null || !chat.isFullyLoaded) {
      chat = await loadFullChat(chatId);
    }
    final messages = chat?.messagesOrNull;
    // No local copy at all (web after a reload): nothing to send.
    if (messages == null || messages.isEmpty) return;
    await saveChat(messages.map((m) => m.toJson()).toList(), chatId: chatId);
  }

  /// Save a chat to Supabase: INSERT a chat the cloud does not hold yet,
  /// else UPDATE it (see [updateChat]).
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

    // Let a write of this chat that is under way land first. It may be the
    // insert that creates the row, and then this save is an update. Its
    // failure belongs to its own caller.
    final pending = ChatStorageState.pendingSaves[effectiveChatId];
    if (pending != null) {
      if (kDebugMode) {
        debugPrint(
          '⏳ [ChatStorage] Waiting for pending save: $effectiveChatId',
        );
      }
      try {
        await pending.future;
      } catch (_) {}
    }

    // A chat the cloud already holds is updated instead. A chat made on
    // this device and only saved locally so far is in memory too, but its
    // row still has to be inserted.
    if (ChatStorageState.chatsById.containsKey(effectiveChatId) &&
        !ChatDirtyStore.isPendingInsert(effectiveChatId)) {
      if (kDebugMode) {
        debugPrint('🔄 [ChatStorage] Chat exists, updating: $effectiveChatId');
      }
      return await updateChat(effectiveChatId, messagesMaps);
    }

    final rev = ChatDirtyStore.revision(effectiveChatId);
    // Only a concurrent save for the same chat listens to this future. Mark
    // it handled, so a failed save with no one waiting does not also surface
    // as an "Unhandled Exception": the caller gets the error from the rethrow.
    final completer = Completer<StoredChat?>()..future.ignore();
    ChatStorageState.pendingSaves[effectiveChatId] = completer;
    ChatStorageState.savingChats.add(effectiveChatId);

    try {
      final result = await _doSaveChat(messagesMaps, effectiveChatId, rev);
      completer.complete(result);
      return result;
    } catch (e) {
      completer.completeError(e);
      rethrow;
    } finally {
      if (identical(
        ChatStorageState.pendingSaves[effectiveChatId],
        completer,
      )) {
        ChatStorageState.pendingSaves.remove(effectiveChatId);
      }
      // Keep in savingChats for a bit longer to block realtime events
      Future.delayed(const Duration(seconds: 2), () {
        ChatStorageState.savingChats.remove(effectiveChatId);
      });
    }
  }

  static Future<StoredChat?> _doSaveChat(
    List<Map<String, dynamic>> messagesMaps,
    String effectiveChatId,
    int rev,
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

    // A chat saved locally first may already carry a name and a star.
    final local = ChatStorageState.chatsById[effectiveChatId];
    final customName = _customNameOf(local);
    final payloadJson = await _payloadJson(messages, customName);

    final encryptedPayload = await EncryptionService.encryptChatPayload(
      payloadJson,
    );

    // Extract and encrypt title separately for fast sidebar loading
    final title = customName ?? extractTitleFromMessages(messages);
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
      if (local?.isStarred == true) 'is_starred': true,
    };

    final Map<String, dynamic> inserted;
    try {
      inserted = await SupabaseService.client
          .from('encrypted_chats')
          .insert(insertData)
          .select('id, created_at, is_starred, updated_at, encrypted_title')
          .single()
          .timeout(const Duration(seconds: 15));
    } on PostgrestException catch (e) {
      // 23505: the row exists. An earlier insert landed and only its answer
      // was lost (a timeout on a flaky network). Update it instead.
      if (e.code != '23505') rethrow;
      return _doUpdateChat(effectiveChatId, messagesMaps, rev);
    }

    final chat = await _applyCloudWrite(
      userId: user.id,
      chatId: inserted['id'] as String,
      rev: rev,
      row: inserted,
      messages: messages,
      payloadJson: payloadJson,
      customName: customName,
      title: title,
    );

    if (kDebugMode) {
      debugPrint(
        '✅ [ChatStorage] Saved new chat: ${chat.id} (${messages.length} messages)',
      );
    }

    return chat;
  }

  /// Take a successful cloud write of the messages of local revision [rev]
  /// into memory and the cache, and clear the dirty mark. If a newer local
  /// save came in while the write ran, memory and the cache already hold
  /// newer messages: they are kept, and the chat stays dirty.
  static Future<StoredChat> _applyCloudWrite({
    required String userId,
    required String chatId,
    required int rev,
    required Map<String, dynamic> row,
    required List<ChatMessage> messages,
    required String payloadJson,
    required String? customName,
    required String title,
  }) async {
    final chat = StoredChat.fromRow(
      row,
      messages,
      customName: customName,
      title: title.isNotEmpty ? title : null,
    );
    final digest = _digest(messages, customName);
    ChatStorageState.lastWrite[chatId] = (
      digest: digest,
      updatedAt: chat.updatedAt,
    );

    if (ChatDirtyStore.revision(chatId) != rev) {
      await ChatDirtyStore.markSynced(userId, chatId, rev);
      return ChatStorageState.chatsById[chatId] ?? chat;
    }

    // Update in our map - this is the ONLY place a cloud write lands
    ChatStorageState.chatsById[chatId] = chat;
    ChatStorageState.localDigest[chatId] = (
      digest: digest,
      updatedAt: chat.updatedAt,
    );
    ChatStorageState.notifyChanges(chatId);

    // Cache plaintext row (NOT the encrypted Supabase row)
    unawaited(
      _writeLocalRow(
        userId,
        chatId,
        Future.value(
          LocalChatCacheService.buildPlaintextRow(
            id: chatId,
            payload: payloadJson,
            createdAt: row['created_at'] as String,
            isStarred: (row['is_starred'] as bool?) ?? false,
            updatedAt: row['updated_at'] as String?,
            title: title.isNotEmpty ? title : null,
          ),
        ),
      ),
    );

    await ChatDirtyStore.markSynced(userId, chatId, rev);
    return chat;
  }

  /// Update an existing chat
  static Future<StoredChat?> updateChat(
    String chatId,
    List<Map<String, dynamic>> messagesMaps,
  ) async {
    // If there's already a pending save for this chat, wait for it then try
    // again. Its failure belongs to its own caller, which already got it: this
    // update carries newer messages and must still be written. Rethrowing it
    // here dropped every save queued behind one timeout — a tool turn saves
    // once per round, so one slow write lost all the rounds after it.
    // Another waiter may claim the slot while this one waits, so wait until
    // it is free. A slot this update already waited for is finished even if
    // nobody removed it, so it never makes this loop spin.
    //
    // The local revision is taken now: these are the messages of that
    // revision, whatever is saved locally while this update waits.
    final rev = ChatDirtyStore.revision(chatId);
    final seq = ChatStorageState.nextUpdateSeq();
    final outcome = Completer<StoredChat?>()..future.ignore();
    ChatStorageState.latestUpdate[chatId] = (seq: seq, outcome: outcome);
    try {
      final result = await _queueUpdate(chatId, messagesMaps, seq, rev);
      outcome.complete(result);
      return result;
    } catch (e) {
      outcome.completeError(e);
      rethrow;
    } finally {
      if (ChatStorageState.latestUpdate[chatId]?.seq == seq) {
        ChatStorageState.latestUpdate.remove(chatId);
      }
    }
  }

  static Future<StoredChat?> _queueUpdate(
    String chatId,
    List<Map<String, dynamic>> messagesMaps,
    int seq,
    int rev,
  ) async {
    final waited = <Completer<StoredChat?>>{};
    for (
      var pending = ChatStorageState.pendingSaves[chatId];
      pending != null && waited.add(pending);
      pending = ChatStorageState.pendingSaves[chatId]
    ) {
      try {
        await pending.future;
      } catch (_) {
        // Reported to the caller of that save; see above.
      }
    }

    // A newer update for this chat is queued: it writes the newer messages,
    // so this one's write would only be overwritten a moment later. Its
    // caller gets the newer one's outcome, failure included.
    final latest = ChatStorageState.latestUpdate[chatId];
    if (latest != null && latest.seq > seq) return latest.outcome.future;

    // See [saveChat]: handled here, so a failure with no waiter is not
    // reported twice.
    final completer = Completer<StoredChat?>()..future.ignore();
    ChatStorageState.pendingSaves[chatId] = completer;
    ChatStorageState.savingChats.add(chatId);

    try {
      final result = await _doUpdateChat(chatId, messagesMaps, rev);
      completer.complete(result);
      return result;
    } catch (e) {
      completer.completeError(e);
      rethrow;
    } finally {
      // Only this update's own slot: a later update may already hold it.
      if (identical(ChatStorageState.pendingSaves[chatId], completer)) {
        ChatStorageState.pendingSaves.remove(chatId);
      }
      // Keep in savingChats for a bit longer to block realtime events
      Future.delayed(const Duration(seconds: 2), () {
        ChatStorageState.savingChats.remove(chatId);
      });
    }
  }

  static Future<StoredChat?> _doUpdateChat(
    String chatId,
    List<Map<String, dynamic>> messagesMaps,
    int rev,
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
    final String? normalizedCustomName = _customNameOf(existingChat);

    // Title and image paths derive from the payload, so an equal payload on
    // an unchanged row means an equal row: skip the write.
    final digest = _digest(messages, normalizedCustomName);
    final lastWrite = ChatStorageState.lastWrite[chatId];
    if (existingChat != null &&
        lastWrite != null &&
        lastWrite.digest == digest &&
        lastWrite.updatedAt == existingChat.updatedAt) {
      await ChatDirtyStore.markSynced(user.id, chatId, rev);
      return existingChat;
    }
    final payloadJson = await _payloadJson(messages, normalizedCustomName);
    final encryptedPayload = await EncryptionService.encryptChatPayload(
      payloadJson,
    );

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
        .select('id, created_at, is_starred, updated_at, encrypted_title')
        .timeout(const Duration(seconds: 15));

    if (updatedRows.isEmpty) {
      // The row is gone: the chat was deleted on another device. The delete
      // wins; without the dirty mark the next sync removes the chat here too
      // instead of the flush retrying it for ever.
      if (!ChatDirtyStore.isPendingInsert(chatId)) {
        await ChatDirtyStore.forget(user.id, chatId);
      }
      throw StateError('Chat not found or access denied.');
    }

    return _applyCloudWrite(
      userId: user.id,
      chatId: chatId,
      rev: rev,
      row: updatedRows.first,
      messages: messages,
      payloadJson: payloadJson,
      customName: normalizedCustomName,
      title: title,
    );
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
    unawaited(ChatDirtyStore.forget(user.id, chatId));
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
