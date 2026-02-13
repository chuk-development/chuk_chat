// lib/services/chat_preload_service.dart
//
// Background preload service for loading all chat messages.
// Enables search and export by ensuring all chats are fully decrypted.

import 'dart:async';

import 'package:chuk_chat/models/stored_chat.dart';
import 'package:chuk_chat/services/chat_storage_state.dart';
import 'package:chuk_chat/services/chat_storage_sync.dart';
import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:flutter/foundation.dart';

/// Service for background preloading all chat messages.
/// This enables search and export to work correctly by ensuring
/// all chats are fully decrypted without blocking the UI.
class ChatPreloadService {
  ChatPreloadService._();

  /// Whether preload is currently running
  static bool _isPreloading = false;
  static bool get isPreloading => _isPreloading;

  /// Whether all chats have been fully loaded
  static bool _isPreloadComplete = false;
  static bool get isPreloadComplete => _isPreloadComplete;

  /// Completer for awaiting preload completion
  static Completer<void>? _preloadCompleter;

  /// Progress value (0.0 - 1.0)
  static double _progress = 0.0;
  static double get progress => _progress;

  /// Stream controller for progress updates
  static final StreamController<double> _progressController =
      StreamController<double>.broadcast();
  static Stream<double> get progressStream => _progressController.stream;

  /// Number of chats loaded so far
  static int _loadedCount = 0;
  static int get loadedCount => _loadedCount;

  /// Total number of chats to load
  static int _totalCount = 0;
  static int get totalCount => _totalCount;

  /// Batch size for loading (smaller = more responsive UI, larger = faster overall)
  static const int _batchSize = 5;

  /// Delay between batches to yield to UI thread (ms)
  static const int _batchDelayMs = 50;

  /// Start background preload of all chat messages.
  /// Safe to call multiple times - will only run once.
  static Future<void> startBackgroundPreload() async {
    // Already complete or in progress
    if (_isPreloadComplete || _isPreloading) {
      if (kDebugMode) {
        debugPrint('⏭️ [Preload] Already ${_isPreloadComplete ? "complete" : "in progress"}');
      }
      return;
    }

    // Wait for encryption key
    if (!EncryptionService.hasKey) {
      final loaded = await EncryptionService.tryLoadKey();
      if (!loaded) {
        if (kDebugMode) {
          debugPrint('⚠️ [Preload] No encryption key, cannot preload');
        }
        return;
      }
    }

    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      if (kDebugMode) {
        debugPrint('⚠️ [Preload] No user signed in');
      }
      return;
    }

    _isPreloading = true;
    _preloadCompleter = Completer<void>();
    _progress = 0.0;
    _loadedCount = 0;

    if (kDebugMode) {
      debugPrint('🔄 [Preload] Starting background preload...');
    }
    final stopwatch = Stopwatch()..start();

    try {
      // Get list of chats that need full loading
      final chatsToLoad = ChatStorageState.chatsById.values
          .where((chat) => !chat.isFullyLoaded)
          .map((chat) => chat.id)
          .toList();

      _totalCount = chatsToLoad.length;

      if (chatsToLoad.isEmpty) {
        if (kDebugMode) {
          debugPrint('✅ [Preload] All ${ChatStorageState.chatsById.length} chats already loaded');
        }
        _isPreloadComplete = true;
        _progress = 1.0;
        _progressController.add(1.0);
        // Don't complete here — finally block handles it
        return;
      }

      if (kDebugMode) {
        debugPrint('📦 [Preload] Loading $_totalCount chats in batches of $_batchSize...');
      }

      // Process in batches to avoid blocking UI
      for (int i = 0; i < chatsToLoad.length; i += _batchSize) {
        final batchEnd = (i + _batchSize).clamp(0, chatsToLoad.length);
        final batchIds = chatsToLoad.sublist(i, batchEnd);

        // Load batch
        await _loadBatch(batchIds, user.id);

        // Update progress
        _loadedCount = batchEnd;
        _progress = _loadedCount / _totalCount;
        _progressController.add(_progress);

        // Yield to UI thread
        if (batchEnd < chatsToLoad.length) {
          await Future.delayed(const Duration(milliseconds: _batchDelayMs));
        }
      }

      stopwatch.stop();
      if (kDebugMode) {
        debugPrint('✅ [Preload] Complete: $_totalCount chats in ${stopwatch.elapsedMilliseconds}ms');
      }

      _isPreloadComplete = true;
      _progress = 1.0;
      _progressController.add(1.0);
      ChatStorageState.notifyChanges();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('❌ [Preload] Error: $e');
      }
    } finally {
      _isPreloading = false;
      _preloadCompleter?.complete();
      _preloadCompleter = null;
    }
  }

  /// Load a batch of chats by their IDs
  static Future<void> _loadBatch(List<String> chatIds, String userId) async {
    if (chatIds.isEmpty) return;

    try {
      // Fetch full payloads from Supabase
      final rows = await SupabaseService.client
          .from('encrypted_chats')
          .select('id, encrypted_payload, created_at, is_starred, updated_at, encrypted_title')
          .eq('user_id', userId)
          .inFilter('id', chatIds);

      if (rows.isEmpty) return;

      // Extract encrypted payloads
      final encryptedPayloads = <String>[];
      final validRows = <Map<String, dynamic>>[];

      for (final row in rows) {
        final payload = row['encrypted_payload'] as String?;
        if (payload != null && payload.isNotEmpty) {
          encryptedPayloads.add(payload);
          validRows.add(row);
        }
      }

      if (encryptedPayloads.isEmpty) return;

      // Batch decrypt all payloads in one isolate
      final decryptedList = await EncryptionService.decryptBatchInBackground(
        encryptedPayloads,
      );

      // Deserialize and update state
      for (int j = 0; j < validRows.length; j++) {
        final decrypted = decryptedList[j];
        if (decrypted == null) continue;

        try {
          final chatPayload = await deserializePayloadAsync(decrypted);
          final row = validRows[j];
          final chatId = row['id'] as String;

          // Preserve existing chat's title if available
          final existing = ChatStorageState.chatsById[chatId];

          final chat = StoredChat.fromRow(
            row,
            chatPayload.messages,
            customName: chatPayload.customName,
            title: existing?.title,
          );

          ChatStorageState.chatsById[chatId] = chat;
        } catch (e) {
          if (kDebugMode) {
            debugPrint('⚠️ [Preload] Failed to deserialize chat: $e');
          }
        }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ [Preload] Batch load failed: $e');
      }
    }
  }

  /// Wait for preload to complete.
  /// Use this before export or full-text search.
  /// If preload hasn't started, this will start it.
  static Future<void> awaitPreload() async {
    if (_isPreloadComplete) return;

    if (!_isPreloading) {
      await startBackgroundPreload();
      return;
    }

    // Wait for existing preload to complete
    await _preloadCompleter?.future;
  }

  /// Get the number of fully loaded chats
  static int get fullyLoadedCount {
    return ChatStorageState.chatsById.values
        .where((chat) => chat.isFullyLoaded)
        .length;
  }

  /// Reset preload state (call on logout)
  static void reset() {
    _isPreloading = false;
    _isPreloadComplete = false;
    _progress = 0.0;
    _loadedCount = 0;
    _totalCount = 0;
    _preloadCompleter?.complete();
    _preloadCompleter = null;
  }
}
