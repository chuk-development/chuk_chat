// lib/services/chat_sync_service.dart
import 'dart:async';

import 'package:chuk_chat/services/chat_storage_service.dart';
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

  /// How often to poll for changes (in seconds)
  static const int _pollIntervalSeconds = 5;

  /// Start the sync service
  static void start() {
    if (_isEnabled) return;
    _isEnabled = true;
    debugPrint('🔄 [ChatSync] Starting sync service (${_pollIntervalSeconds}s interval)');

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
    debugPrint('⏹️ [ChatSync] Stopped sync service');
  }

  /// Pause syncing (e.g., when app is backgrounded)
  static void pause() {
    _syncTimer?.cancel();
    _syncTimer = null;
    debugPrint('⏸️ [ChatSync] Paused sync service');
  }

  /// Resume syncing (e.g., when app comes to foreground)
  static void resume() {
    if (!_isEnabled) return;
    debugPrint('▶️ [ChatSync] Resuming sync service');

    // Immediate sync on resume
    _performSync();

    // Restart timer
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(
      Duration(seconds: _pollIntervalSeconds),
      (_) => _performSync(),
    );
  }

  /// Force an immediate sync
  static Future<void> syncNow() async {
    await _performSync();
  }

  /// Perform the actual sync operation
  static Future<void> _performSync() async {
    if (_isSyncing) return; // Prevent concurrent syncs
    if (!_isEnabled) return;

    // Skip sync if we know we're offline (use cached status to avoid delays)
    if (!NetworkStatusService.isOnline) {
      debugPrint('⏸️ [ChatSync] Skipping sync - offline');
      return;
    }

    final user = SupabaseService.auth.currentUser;
    if (user == null) return;

    if (!EncryptionService.hasKey) return;

    _isSyncing = true;

    try {
      // Step 1: Fetch lightweight metadata from cloud (id + updated_at only)
      final cloudChats = await SupabaseService.client
          .from('encrypted_chats')
          .select('id, updated_at')
          .eq('user_id', user.id);

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
        debugPrint('🔄 [ChatSync] Fetching ${idsToFetch.length} chats (${newChatIds.length} new, ${updatedChatIds.length} updated)');

        final fullChats = await SupabaseService.client
            .from('encrypted_chats')
            .select('id, encrypted_payload, created_at, is_starred, updated_at')
            .eq('user_id', user.id)
            .inFilter('id', idsToFetch.toList());

        if (!_isEnabled) return; // Check if stopped during await

        // Process fetched chats
        for (final row in fullChats) {
          await ChatStorageService.mergeSyncedChat(row);
        }
      }

      // Step 3: Remove deleted chats from local state
      if (deletedChatIds.isNotEmpty) {
        debugPrint('🗑️ [ChatSync] Removing ${deletedChatIds.length} deleted chats');
        for (final id in deletedChatIds) {
          ChatStorageService.removeChatLocally(id);
        }
      }

      if (idsToFetch.isNotEmpty || deletedChatIds.isNotEmpty) {
        debugPrint('✅ [ChatSync] Sync complete');
      }
    } catch (e) {
      debugPrint('❌ [ChatSync] Sync failed: $e');
      // If this looks like a network error, trigger a network check
      // This updates the offline indicator if we actually lost connectivity
      if (NetworkStatusService.isNetworkError(e)) {
        debugPrint('🌐 [ChatSync] Network error detected, checking connectivity...');
        unawaited(NetworkStatusService.hasInternetConnection(useCache: false));
      }
    } finally {
      _isSyncing = false;
    }
  }
}
