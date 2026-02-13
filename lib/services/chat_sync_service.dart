// lib/services/chat_sync_service.dart
import 'dart:async';

import 'package:chuk_chat/services/chat_storage_mutations.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/chat_storage_state.dart';
import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/network_status_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:flutter/foundation.dart';

/// Service for syncing chats between local state and Supabase.
/// Uses lightweight polling to detect changes without fetching full payloads.
class ChatSyncService {
  ChatSyncService._();

  static Timer? _syncTimer;
  static bool _isSyncing = false;
  static bool _isEnabled = false;
  static bool _hasCompletedFirstSync = false;

  /// How often to poll for changes (in seconds)
  static const int _pollIntervalSeconds = 5;

  /// Start the sync service
  static void start() {
    if (_isEnabled) return;
    _isEnabled = true;
    if (kDebugMode) {
      debugPrint(
      '🔄 [ChatSync] Starting sync service (${_pollIntervalSeconds}s interval)',
      );
    }

    // Initial sync after short delay
    Future.delayed(const Duration(seconds: 1), () {
      if (_isEnabled) _performSync();
    });

    // Start periodic polling
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(
      Duration(seconds: _pollIntervalSeconds),
      (_) => _performSync(),
    );
  }

  /// Stop the sync service
  static void stop() {
    if (!_isEnabled) return;
    _isEnabled = false;
    _syncTimer?.cancel();
    _syncTimer = null;
    _hasCompletedFirstSync = false; // Reset for next login
    if (kDebugMode) {
      debugPrint('⏹️ [ChatSync] Stopped sync service');
    }
  }

  /// Pause syncing (e.g., when app is backgrounded)
  static void pause() {
    _syncTimer?.cancel();
    _syncTimer = null;
    if (kDebugMode) {
      debugPrint('⏸️ [ChatSync] Paused sync service');
    }
  }

  /// Resume syncing (e.g., when app comes to foreground)
  static void resume() {
    if (!_isEnabled) return;
    if (kDebugMode) {
      debugPrint('▶️ [ChatSync] Resuming sync service');
    }

    // Restart timer first (lightweight)
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(
      Duration(seconds: _pollIntervalSeconds),
      (_) => _performSync(),
    );

    // Defer title sync to avoid blocking the UI on resume
    Future.delayed(const Duration(milliseconds: 500), () {
      if (_isEnabled) _syncTitlesOnResume();
    });
  }

  /// Sync titles when app resumes - fetches latest from network
  static Future<void> _syncTitlesOnResume() async {
    if (_isSyncing) return;
    if (!ChatStorageService.initialSyncComplete) return;
    if (!NetworkStatusService.isOnline) return;

    final user = SupabaseService.auth.currentUser;
    if (user == null) return;
    if (!EncryptionService.hasKey) return;

    _isSyncing = true;
    try {
      if (kDebugMode) {
        debugPrint('🔄 [ChatSync] Resume sync - fetching latest titles...');
      }
      await ChatStorageService.syncTitlesFromNetwork();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ [ChatSync] Resume sync failed: $e');
      }
    } finally {
      _isSyncing = false;
    }
  }

  /// Force an immediate sync
  static Future<void> syncNow() async {
    await _performSync();
  }

  /// Perform the actual sync operation
  static Future<void> _performSync() async {
    if (_isSyncing) return; // Prevent concurrent syncs
    if (!_isEnabled) return;

    // Wait for initial cache load to complete before syncing
    // This prevents race conditions and duplicate work on startup
    if (!ChatStorageService.initialSyncComplete) {
      if (kDebugMode) {
        debugPrint('⏳ [ChatSync] Waiting for initial cache load...');
      }
      return;
    }

    // Skip sync if we know we're offline (use cached status to avoid delays)
    if (!NetworkStatusService.isOnline) {
      if (kDebugMode) {
        debugPrint('⏸️ [ChatSync] Skipping sync - offline');
      }
      return;
    }

    final user = SupabaseService.auth.currentUser;
    if (user == null) return;

    if (!EncryptionService.hasKey) return;

    _isSyncing = true;

    // On first sync after startup, sync titles from network
    // This ensures we have the latest titles without full payload fetch
    if (!_hasCompletedFirstSync) {
      if (kDebugMode) {
        debugPrint('🔄 [ChatSync] First sync - syncing titles from network...');
      }
      await ChatStorageService.syncTitlesFromNetwork();
      _hasCompletedFirstSync = true;
    }

    try {
      // Step 1: Fetch lightweight metadata from cloud (id + updated_at only)
      final cloudChats = await SupabaseService.client
          .from('encrypted_chats')
          .select('id, updated_at')
          .eq('user_id', user.id)
          .timeout(const Duration(seconds: 15));

      if (!_isEnabled) return; // Check if stopped during await

      // Build cloud state map: id -> updated_at
      final Map<String, DateTime> cloudState = {};
      for (final row in cloudChats) {
        final id = row['id'] as String;
        final updatedAt = DateTime.parse(row['updated_at'] as String);
        cloudState[id] = updatedAt;
      }

      // Get local state
      final localChats = ChatStorageService.savedChats;
      final Set<String> localIds = localChats.map((c) => c.id).toSet();
      final Set<String> cloudIds = cloudState.keys.toSet();

      // Find differences
      final Set<String> newChatIds = cloudIds.difference(localIds);
      final Set<String> deletedChatIds = localIds.difference(cloudIds);
      final Set<String> potentiallyUpdatedIds = cloudIds.intersection(localIds);

      // Check for updated chats by comparing timestamps
      final localTimestamps = ChatStorageService.getChatTimestamps();
      final Set<String> updatedChatIds = {};
      for (final id in potentiallyUpdatedIds) {
        final cloudUpdatedAt = cloudState[id]!;
        final localUpdatedAt = localTimestamps[id];

        // If cloud is newer than local, fetch the update
        if (localUpdatedAt == null || cloudUpdatedAt.isAfter(localUpdatedAt)) {
          updatedChatIds.add(id);
        }
      }

      // Step 2: Fetch full payload for new and updated chats
      final idsToFetch = {...newChatIds, ...updatedChatIds};

      if (idsToFetch.isNotEmpty) {
        if (kDebugMode) {
          debugPrint(
          '🔄 [ChatSync] Fetching ${idsToFetch.length} chats (${newChatIds.length} new, ${updatedChatIds.length} updated)',
          );
        }

        final fullChats = await SupabaseService.client
            .from('encrypted_chats')
            .select('id, encrypted_payload, created_at, is_starred, updated_at')
            .eq('user_id', user.id)
            .inFilter('id', idsToFetch.toList())
            .timeout(const Duration(seconds: 30));

        if (!_isEnabled) return; // Check if stopped during await

        // Process fetched chats using batch method for better performance
        // This decrypts all chats in a single isolate, avoiding UI blocking
        await ChatStorageService.mergeSyncedChatsBatch(
          fullChats.cast<Map<String, dynamic>>(),
        );

        // Persist updated titles to cache so they survive app restart
        await saveTitlesToCache(
          user.id,
          ChatStorageState.chatsById.values.toList(),
        );
      }

      // Step 3: Remove deleted chats from local state
      if (deletedChatIds.isNotEmpty) {
        if (kDebugMode) {
          debugPrint(
          '🗑️ [ChatSync] Removing ${deletedChatIds.length} deleted chats',
          );
        }
        for (final id in deletedChatIds) {
          ChatStorageService.removeChatLocally(id);
        }
      }

      if (idsToFetch.isNotEmpty || deletedChatIds.isNotEmpty) {
        if (kDebugMode) {
          debugPrint('✅ [ChatSync] Sync complete');
        }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('❌ [ChatSync] Sync failed: $e');
      }
      // If this looks like a network error, trigger a network check
      // This updates the offline indicator if we actually lost connectivity
      if (NetworkStatusService.isNetworkError(e)) {
        if (kDebugMode) {
          debugPrint(
          '🌐 [ChatSync] Network error detected, checking connectivity...',
          );
        }
        unawaited(NetworkStatusService.hasInternetConnection(useCache: false));
      }
    } finally {
      _isSyncing = false;
    }
  }
}
