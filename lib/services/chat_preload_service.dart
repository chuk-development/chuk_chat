// lib/services/chat_preload_service.dart
//
// Background preload service for loading all chat messages.
// Enables search and export by ensuring all chats are fully decrypted.

import 'dart:async';
import 'dart:convert';

import 'package:chuk_chat/models/chat_message.dart';
import 'package:chuk_chat/models/stored_chat.dart';
import 'package:chuk_chat/services/chat_storage_mutations.dart'
    show kChatPayloadVersion;
import 'package:chuk_chat/services/chat_storage_state.dart';
import 'package:chuk_chat/services/chat_storage_sync.dart';
import 'package:chuk_chat/services/chat_sync_service.dart';
import 'package:chuk_chat/services/diagnostics_log_service.dart';
import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/local_chat_cache_service.dart';
import 'package:chuk_chat/services/network_status_service.dart';
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

  /// Count of failed chat loads (for diagnostics)
  static int _failureCount = 0;
  static int get failureCount => _failureCount;

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

  /// Batch size for loading
  static const int _batchSize = 5;

  /// Delay between batches to yield to UI thread (ms)
  static const int _batchDelayMs = 100;

  /// Start background preload of all chat messages.
  /// Safe to call multiple times - will only run once.
  static Future<void> startBackgroundPreload() async {
    // Already complete or in progress
    if (_isPreloadComplete || _isPreloading) {
      if (kDebugMode) {
        debugPrint(
          '⏭️ [Preload] Already ${_isPreloadComplete ? "complete" : "in progress"}',
        );
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
    _failureCount = 0;

    if (kDebugMode) {
      debugPrint('🔄 [Preload] Starting background preload...');
    }
    final stopwatch = Stopwatch()..start();
    unawaited(
      DiagnosticsLogService.info('preload', 'Background preload started'),
    );

    try {
      // Wait for the first sync cycle to finish so that chatsById has
      // all chats from the server, not just stale sidebar entries.
      try {
        await ChatSyncService.firstSyncComplete.timeout(
          const Duration(seconds: 30),
        );
        if (kDebugMode) {
          debugPrint(
            '✅ [Preload] First sync complete, proceeding with preload '
            '(${ChatStorageState.chatsById.length} chats in sidebar)',
          );
        }
      } on TimeoutException {
        if (kDebugMode) {
          debugPrint(
            '⚠️ [Preload] First sync timed out, preloading available chats',
          );
        }
      }

      // Get list of chats that need full loading
      final chatsToLoad = ChatStorageState.chatsById.values
          .where((chat) => !chat.isFullyLoaded)
          .map((chat) => chat.id)
          .toList();

      _totalCount = chatsToLoad.length;

      if (chatsToLoad.isEmpty) {
        if (kDebugMode) {
          debugPrint(
            '✅ [Preload] All ${ChatStorageState.chatsById.length} chats already loaded',
          );
        }
        _isPreloadComplete = true;
        _progress = 1.0;
        _progressController.add(1.0);
        unawaited(
          DiagnosticsLogService.timing(
            'preload',
            'background_preload',
            stopwatch.elapsedMilliseconds,
            data: {'total': 0, 'loaded': 0, 'failures': _failureCount},
          ),
        );
        // Don't complete here — finally block handles it
        return;
      }

      if (kDebugMode) {
        debugPrint(
          '📦 [Preload] Loading $_totalCount chats in batches of $_batchSize...',
        );
      }

      // Load entire cache once — avoid re-reading SharedPreferences per batch
      final cachedRows = await LocalChatCacheService.load(user.id);
      final cachedRowsById = <String, Map<String, dynamic>>{
        for (final r in cachedRows)
          if (r['id'] is String) r['id'] as String: r,
      };

      // Process in batches to avoid blocking UI
      for (int i = 0; i < chatsToLoad.length; i += _batchSize) {
        final batchEnd = (i + _batchSize).clamp(0, chatsToLoad.length);
        final batchIds = chatsToLoad.sublist(i, batchEnd);

        // Load batch
        await _loadBatch(batchIds, user.id, cachedRowsById);

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
        debugPrint(
          '✅ [Preload] Complete: $_totalCount chats in ${stopwatch.elapsedMilliseconds}ms'
          '${_failureCount > 0 ? ' ($_failureCount failed)' : ''}',
        );
      }

      _isPreloadComplete = true;
      _progress = 1.0;
      _progressController.add(1.0);
      ChatStorageState.notifyChanges();
      unawaited(
        DiagnosticsLogService.timing(
          'preload',
          'background_preload',
          stopwatch.elapsedMilliseconds,
          data: {
            'total': _totalCount,
            'loaded': _loadedCount,
            'failures': _failureCount,
          },
        ),
      );
    } catch (e) {
      unawaited(
        DiagnosticsLogService.error(
          'preload',
          'Background preload failed',
          error: e,
          data: {
            'elapsed_ms': stopwatch.elapsedMilliseconds,
            'loaded': _loadedCount,
            'total': _totalCount,
          },
        ),
      );
      if (kDebugMode) {
        debugPrint('❌ [Preload] Error: $e');
      }
    } finally {
      _isPreloading = false;
      _preloadCompleter?.complete();
      _preloadCompleter = null;
    }
  }

  /// Load a batch of chats by their IDs.
  /// Tries pre-loaded cache map first (instant), then Supabase for misses.
  static Future<void> _loadBatch(
    List<String> chatIds,
    String userId,
    Map<String, Map<String, dynamic>> cachedRowsById,
  ) async {
    if (chatIds.isEmpty) return;

    // Find which chats are in cache
    final matchingRows = <Map<String, dynamic>>[];
    final missingIds = <String>[];

    for (final id in chatIds) {
      final cached = cachedRowsById[id];
      if (cached != null) {
        matchingRows.add(cached);
      } else {
        missingIds.add(id);
      }
    }

    // Parse cached rows (plaintext, no decryption)
    if (matchingRows.isNotEmpty) {
      await _parseAndStoreRows(matchingRows);
    }

    // Fetch missing chats from Supabase
    if (missingIds.isNotEmpty && NetworkStatusService.isOnline) {
      await _fetchFromRemote(missingIds, userId);
    }
  }

  /// Fetch chats from Supabase, decrypt, store, and cache as plaintext.
  static Future<void> _fetchFromRemote(
    List<String> chatIds,
    String userId,
  ) async {
    try {
      final rows = await SupabaseService.client
          .from('encrypted_chats')
          .select(
            'id, encrypted_payload, created_at, is_starred, updated_at, encrypted_title',
          )
          .eq('user_id', userId)
          .inFilter('id', chatIds)
          .timeout(const Duration(seconds: 15));

      if (rows.isNotEmpty) {
        await _decryptAndStoreRows(rows, userId);
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint(
          '⚠️ [Preload] Remote batch load failed: $e',
        );
      }
    }
  }

  /// Decrypt Supabase rows, store them in memory, and write plaintext to cache.
  static Future<void> _decryptAndStoreRows(
    List<Map<String, dynamic>> rows,
    String userId,
  ) async {
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

        // Write plaintext cache row (not encrypted Supabase row)
        final title = chat.title ?? _extractTitle(chatPayload.messages);
        unawaited(LocalChatCacheService.upsert(
          userId,
          LocalChatCacheService.buildPlaintextRow(
            id: chatId,
            payload: _buildPlaintextPayloadJson(chatPayload),
            createdAt: row['created_at'] as String,
            isStarred: (row['is_starred'] as bool?) ?? false,
            updatedAt: row['updated_at'] as String?,
            title: title.isNotEmpty ? title : null,
          ),
        ));
      } catch (e) {
        _failureCount++;
        if (kDebugMode) {
          debugPrint('⚠️ [Preload] Failed to deserialize chat: $e');
        }
      }

      if (j > 0 && j % 2 == 1) {
        await Future<void>.delayed(Duration.zero);
      }
    }
  }

  /// Parse plaintext cache rows and store them in memory (no decryption needed).
  /// Uses a single isolate for batch JSON parsing to avoid spawning hundreds
  /// of isolates during preload.
  static Future<void> _parseAndStoreRows(
    List<Map<String, dynamic>> rows,
  ) async {
    // Collect valid payloads for batch processing in one isolate
    final payloads = <String>[];
    final validIndices = <int>[];

    for (int i = 0; i < rows.length; i++) {
      final payload = rows[i]['payload'] as String?;
      if (payload != null && payload.isNotEmpty) {
        payloads.add(payload);
        validIndices.add(i);
      }
    }

    if (payloads.isEmpty) return;

    // Single isolate for all JSON parsing
    final chatPayloads = await deserializePayloadBatchAsync(payloads);

    for (int j = 0; j < validIndices.length; j++) {
      final chatPayload = chatPayloads[j];
      if (chatPayload == null) {
        _failureCount++;
        continue;
      }

      final row = rows[validIndices[j]];
      final chatId = row['id'] as String;

      final existing = ChatStorageState.chatsById[chatId];
      final chat = StoredChat.fromRow(
        row,
        chatPayload.messages,
        customName: chatPayload.customName,
        title: existing?.title,
      );

      ChatStorageState.chatsById[chatId] = chat;
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

  /// Trigger a follow-up preload for any chats that were added after the
  /// initial preload finished (e.g. by ChatSyncService discovering new chats).
  /// Safe to call multiple times — no-ops if nothing new to load.
  static Future<void> preloadNewChats() async {
    if (_isPreloading) return;

    final unloaded = ChatStorageState.chatsById.values
        .where((chat) => !chat.isFullyLoaded)
        .toList();

    if (unloaded.isEmpty) return;

    if (kDebugMode) {
      debugPrint(
        '🔄 [Preload] Follow-up preload for ${unloaded.length} new chats',
      );
    }

    // Allow startBackgroundPreload to run again
    _isPreloadComplete = false;
    await startBackgroundPreload();
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
    _failureCount = 0;
    _preloadCompleter?.complete();
    _preloadCompleter = null;
  }
}

/// Extract title from messages (first user message, truncated).
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
String _buildPlaintextPayloadJson(ChatPayload chatPayload) {
  return jsonEncode({
    'v': kChatPayloadVersion,
    if (chatPayload.customName != null) 'customName': chatPayload.customName,
    'messages': chatPayload.messages.map((m) => m.toJson()).toList(),
  });
}
