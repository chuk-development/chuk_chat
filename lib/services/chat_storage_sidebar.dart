// lib/services/chat_storage_sidebar.dart

import 'dart:async';
import 'dart:convert';

import 'package:chuk_chat/models/stored_chat.dart';
import 'package:chuk_chat/services/chat_storage_mutations.dart';
import 'package:chuk_chat/services/chat_storage_state.dart';
import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Handles sidebar-specific chat loading and title caching.
/// Optimized for fast sidebar display with lazy loading of full chat content.
class ChatStorageSidebar {
  ChatStorageSidebar._();

  /// Load chats for sidebar - title-only for instant display.
  /// This is the main entry point for loading chats on startup.
  /// Strategy: Load from cache FIRST (instant), then let ChatSyncService handle network sync.
  static Future<void> loadSavedChatsForSidebar() async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      ChatStorageState.chatsById.clear();
      ChatStorageState.notifyChangesImmediate();
      return;
    }

    // Prevent concurrent loads - return existing future if already loading
    if (ChatStorageState.isLoading) {
      if (kDebugMode) {
        debugPrint('⏳ [ChatStorage] Sidebar load already in progress, waiting...');
      }
      return ChatStorageState.loadingCompleter!.future;
    }

    // Already loaded from cache - nothing to do
    if (ChatStorageState.cacheLoaded) {
      if (kDebugMode) {
        debugPrint('✅ [ChatStorage] Cache already loaded, skipping');
      }
      return;
    }

    ChatStorageState.loadingCompleter = Completer<void>();

    try {
      // Load from local cache FIRST (instant UI)
      // ChatSyncService will handle network sync after this completes
      await _loadTitlesFromCache(user.id);

      // Notify UI immediately WITHOUT debounce - critical for instant sidebar
      ChatStorageState.notifyChangesImmediate();
      ChatStorageState.cacheLoaded = true;

      if (kDebugMode) {
        debugPrint('✅ [ChatStorage] Sidebar ready (${ChatStorageState.chatsById.length} chats, UI notified)');
      }

      // Mark initial load complete - ChatSyncService can now start syncing
      ChatStorageState.initialSyncComplete = true;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('❌ [ChatStorage] Sidebar load failed: $e');
      }
      rethrow;
    } finally {
      ChatStorageState.loadingCompleter?.complete();
      ChatStorageState.loadingCompleter = null;
    }
  }

  /// Sync titles from network (public API for ChatSyncService)
  /// Call this after initial cache load to get updates from server.
  static Future<void> syncTitlesFromNetwork() async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) return;
    await _syncTitlesFromNetwork(user.id);
  }

  /// Load titles from local SharedPreferences cache (instant, no network, no decryption)
  static Future<void> _loadTitlesFromCache(String userId) async {
    final stopwatch = Stopwatch()..start();

    // Use pre-cached instance for speed, fallback to getInstance if not ready
    final prefs = sharedPrefsInstance ?? await SharedPreferences.getInstance();
    final prefsTime = stopwatch.elapsedMilliseconds;

    final cacheKey = 'chat_titles_v1_$userId';
    final raw = prefs.getString(cacheKey);

    if (raw == null || raw.isEmpty) {
      if (kDebugMode) {
        debugPrint('📦 [ChatStorage] No title cache found (prefs: ${prefsTime}ms)');
      }
      return;
    }

    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      final parseTime = stopwatch.elapsedMilliseconds;

      for (final item in decoded) {
        if (item is! Map<String, dynamic>) continue;
        final id = item['id'] as String?;
        if (id == null) continue;

        // Skip if we already have a fully loaded version
        final existing = ChatStorageState.chatsById[id];
        if (existing != null && existing.isFullyLoaded) continue;

        ChatStorageState.chatsById[id] = StoredChat.forSidebar(
          id: id,
          createdAt: DateTime.tryParse(item['created_at'] as String? ?? '') ?? DateTime.now(),
          isStarred: item['is_starred'] as bool? ?? false,
          title: item['title'] as String?,
          updatedAt: item['updated_at'] != null
              ? DateTime.tryParse(item['updated_at'] as String)
              : null,
        );
      }
      stopwatch.stop();
      if (kDebugMode) {
        debugPrint('📦 [ChatStorage] Cache: prefs=${prefsTime}ms, parse=${parseTime - prefsTime}ms, objects=${stopwatch.elapsedMilliseconds - parseTime}ms, loaded=${ChatStorageState.chatsById.length} chats');
      }
      // Debug: show sample of cached updatedAt values
      final sample = ChatStorageState.chatsById.values.take(3).map((c) => '${c.id.substring(0, 8)}: updatedAt=${c.updatedAt}').join(', ');
      if (kDebugMode) {
        debugPrint('📦 [ChatStorage] Sample cache timestamps: $sample');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ [ChatStorage] Failed to parse title cache: $e');
      }
    }
  }

  /// Sync titles from network and update cache (runs in background)
  /// Only notifies UI if there are actual changes to prevent unnecessary rebuilds.
  /// Optimized: Only decrypts titles that are new or changed (based on updated_at).
  static Future<void> _syncTitlesFromNetwork(String userId) async {
    final stopwatch = Stopwatch()..start();
    bool hasChanges = false;

    try {
      if (kDebugMode) {
        debugPrint('🔄 [ChatStorage] Syncing titles from network...');
      }

      final rows = await SupabaseService.client
          .from('encrypted_chats')
          .select('id, encrypted_title, created_at, is_starred, updated_at')
          .eq('user_id', userId)
          .order('created_at', ascending: false);

      if (kDebugMode) {
        debugPrint('📦 [ChatStorage] Fetched ${rows.length} chat metadata (${stopwatch.elapsedMilliseconds}ms)');
      }

      if (rows.isEmpty) {
        if (ChatStorageState.chatsById.isNotEmpty) {
          ChatStorageState.chatsById.clear();
          hasChanges = true;
        }
        if (hasChanges) ChatStorageState.notifyChanges();
        await saveTitlesToCache(userId, []);
        return;
      }

      // Track existing IDs for deletion detection
      final oldIds = ChatStorageState.chatsById.keys.toSet();
      final newIds = <String>{};

      // Split rows into: needs decryption vs can use cached title
      final rowsNeedingDecryption = <Map<String, dynamic>>[];
      final rowsWithCachedTitle = <Map<String, dynamic>>[];

      for (final row in rows) {
        final id = row['id'] as String?;
        if (id == null) continue;
        newIds.add(id);

        final existing = ChatStorageState.chatsById[id];
        final rowUpdatedAt = row['updated_at'] != null
            ? DateTime.tryParse(row['updated_at'] as String)
            : null;

        // Check if we need to decrypt this title
        bool needsDecryption = false;
        String? reason;
        if (existing == null) {
          // New chat - needs decryption
          needsDecryption = true;
          reason = 'new';
        } else if (existing.title == null) {
          // No cached title - needs decryption
          needsDecryption = true;
          reason = 'no_title';
        } else if (rowUpdatedAt != null) {
          // Server has updated_at - check if newer than cache
          if (existing.updatedAt == null) {
            // Cache has no timestamp but server does - use cache (title exists)
            needsDecryption = false;
          } else if (rowUpdatedAt.isAfter(existing.updatedAt!)) {
            // Server is newer - needs decryption
            needsDecryption = true;
            reason = 'updated (server: $rowUpdatedAt, cache: ${existing.updatedAt})';
          }
        }
        // If server has no updated_at and we have a cached title, use cache

        if (needsDecryption) {
          if (kDebugMode) {
            debugPrint('🔓 [ChatStorage] Decrypt needed for $id: $reason');
          }
          rowsNeedingDecryption.add(row);
        } else {
          rowsWithCachedTitle.add(row);
        }
      }

      if (kDebugMode) {
        debugPrint('📦 [ChatStorage] ${rowsNeedingDecryption.length} need decryption, ${rowsWithCachedTitle.length} using cache');
      }

      // Only decrypt titles that need it
      final decryptedChats = await _decryptTitlesBatch(rowsNeedingDecryption);

      // Process decrypted chats
      for (final chat in decryptedChats) {
        if (chat == null) continue;
        final existing = ChatStorageState.chatsById[chat.id];

        if (existing == null) {
          ChatStorageState.chatsById[chat.id] = chat;
          hasChanges = true;
        } else if (existing.isStarred != chat.isStarred ||
                   existing.title != chat.title) {
          if (existing.isFullyLoaded) {
            ChatStorageState.chatsById[chat.id] = existing.copyWith(
              isStarred: chat.isStarred,
              title: chat.title,
              updatedAt: chat.updatedAt,
            );
          } else {
            ChatStorageState.chatsById[chat.id] = chat;
          }
          hasChanges = true;
        } else {
          // Title and isStarred unchanged, but we decrypted because updatedAt was newer
          // MUST save new updatedAt to cache so we don't re-decrypt next time!
          if (existing.isFullyLoaded) {
            ChatStorageState.chatsById[chat.id] = existing.copyWith(updatedAt: chat.updatedAt);
          } else {
            ChatStorageState.chatsById[chat.id] = chat;
          }
          if (kDebugMode) {
            debugPrint('📝 [ChatStorage] Updated timestamp only for ${chat.id.substring(0, 8)}');
          }
        }
      }

      // Process cached chats (just update is_starred if changed)
      for (final row in rowsWithCachedTitle) {
        final id = row['id'] as String;
        final isStarred = row['is_starred'] as bool? ?? false;
        final existing = ChatStorageState.chatsById[id];

        if (existing != null && existing.isStarred != isStarred) {
          ChatStorageState.chatsById[id] = existing.copyWith(isStarred: isStarred);
          hasChanges = true;
        }
      }

      // Remove deleted chats
      final deletedIds = oldIds.difference(newIds);
      if (deletedIds.isNotEmpty) {
        for (final id in deletedIds) {
          ChatStorageState.chatsById.remove(id);
        }
        hasChanges = true;
      }

      // Only notify if something changed
      if (hasChanges) {
        if (kDebugMode) {
          debugPrint('🔔 [ChatStorage] Changes detected, notifying UI');
        }
        ChatStorageState.notifyChanges();
      } else {
        if (kDebugMode) {
          debugPrint('✓ [ChatStorage] No changes detected, skipping UI notify');
        }
      }

      // Always update cache (timestamps might have changed)
      await saveTitlesToCache(userId, ChatStorageState.chatsById.values.toList());

      stopwatch.stop();
      if (kDebugMode) {
        debugPrint('✅ [ChatStorage] Network sync complete (${stopwatch.elapsedMilliseconds}ms)');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ [ChatStorage] Network sync failed: $e');
      }
    }
  }

  /// Decrypt title-only batch for sidebar (much faster than full payloads)
  static Future<List<StoredChat?>> _decryptTitlesBatch(
    List<Map<String, dynamic>> rows,
  ) async {
    if (rows.isEmpty) return [];

    // Extract encrypted titles
    final encryptedTitles = <String>[];
    final validIndices = <int>[];

    for (int i = 0; i < rows.length; i++) {
      final encryptedTitle = rows[i]['encrypted_title'] as String?;
      if (encryptedTitle != null && encryptedTitle.isNotEmpty) {
        encryptedTitles.add(encryptedTitle);
        validIndices.add(i);
      }
    }

    // Initialize results with title-only chats (no decryption needed for those without encrypted_title)
    final results = List<StoredChat?>.filled(rows.length, null);

    // Create title-only chats for ALL rows first (even those without encrypted_title)
    for (int i = 0; i < rows.length; i++) {
      results[i] = StoredChat.fromRowTitleOnly(rows[i]);
    }

    // If we have encrypted titles, batch decrypt them
    // BUT only if encryption key is already loaded - don't block waiting for it!
    if (encryptedTitles.isNotEmpty) {
      if (!EncryptionService.hasKey) {
        if (kDebugMode) {
          debugPrint('⏭️ [ChatStorage] Skipping title decryption - key not loaded yet');
        }
        // Keep using cached/fallback titles - decryption will happen on next sync
        return results;
      }

      try {
        final decryptedTitles = await EncryptionService.decryptBatchInBackground(encryptedTitles);

        for (int j = 0; j < validIndices.length; j++) {
          final i = validIndices[j];
          final decryptedTitle = decryptedTitles[j];
          if (decryptedTitle != null) {
            results[i] = StoredChat.fromRowTitleOnly(rows[i], title: decryptedTitle);
          }
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('⚠️ [ChatStorage] Title batch decryption failed: $e');
        }
        // Continue with title-less chats
      }
    }

    return results;
  }
}
