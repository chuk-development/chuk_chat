// lib/platform_specific/chat/handlers/chat_persistence_handler.dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/chat_storage_state.dart';
import 'package:chuk_chat/services/network_status_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';

/// Handles chat persistence and storage
/// Whether [stored] holds more than [patch] would write, i.e. the patch
/// would shrink or empty it. Used to keep a late, stale stream tick from
/// erasing a finished message.
@visibleForTesting
bool keepsMoreThanPatch(String? stored, String? patch) {
  if (patch == null) return false;
  final current = stored ?? '';
  if (current.isEmpty) return false;
  return patch.trim().isEmpty;
}

class ChatPersistenceHandler {
  static const Duration _backgroundUpdateDebounce = Duration(milliseconds: 700);

  /// How often a patch that could not be written yet is retried, and how
  /// many times, before it is finally given up on.
  static const Duration _backgroundRetryDelay = Duration(seconds: 1);
  static const int _maxBackgroundRetries = 5;

  // Callbacks
  Function(String)? onShowSnackBar;
  Function(String chatId)? onChatIdAssigned;

  final Map<String, _PendingBackgroundUpdate> _pendingBackgroundUpdates =
      <String, _PendingBackgroundUpdate>{};
  final Map<String, Timer> _backgroundUpdateTimers = <String, Timer>{};

  void dispose() {
    for (final timer in _backgroundUpdateTimers.values) {
      timer.cancel();
    }
    _backgroundUpdateTimers.clear();

    // Best-effort flush so pending background stream/tool-call updates are not
    // lost when the widget tree is disposed while a response is still running.
    unawaited(flushPending());
  }

  /// Write every pending patch now. With [chatId] only that chat's patches.
  Future<void> flushPending({String? chatId}) async {
    final keys = _pendingBackgroundUpdates.keys
        .where((key) => chatId == null || key.startsWith('$chatId:'))
        .toList(growable: false);
    for (final key in keys) {
      await _flushBackgroundUpdate(key);
    }
  }

  /// Save or update chat in storage
  ///
  /// [silent] - If true, don't call onChatIdAssigned callback.
  /// Use silent=true when persisting an old chat in the background while
  /// user has already moved to a new chat (e.g., in newChat()).
  Future<StoredChat?> persistChat({
    required List<Map<String, String>> messages,
    String? chatId,
    bool waitForCompletion = false,
    bool isOffline = false,
    bool silent = false,
  }) async {
    if (messages.isEmpty) return null;

    // Never persist "Thinking..." placeholders — they are UI-only
    final messagesCopy = messages
        .where((message) => message['text'] != 'Thinking...')
        .map((message) => Map<String, String>.from(message))
        .toList(growable: false);

    if (messagesCopy.isEmpty) return null;

    // Land any pending per-message patch first. Otherwise a debounced patch
    // written afterwards can overwrite this full save with what it knew a
    // moment ago — which is how a finished answer lost its text.
    if (chatId != null) await flushPending(chatId: chatId);

    final operation = _persistChatInternal(
      messagesCopy,
      chatId,
      isOffline: isOffline,
      silent: silent,
    );

    if (waitForCompletion) {
      return await operation;
    } else {
      // Start the operation but don't wait for it
      operation
          .then((result) {
            // We don't use the result here since we're not waiting
          })
          .catchError((error) {
            if (kDebugMode) {
              debugPrint(
                '⚠️ [ChatPersistence] Background operation failed: $error',
              );
            }
          });
      return null;
    }
  }

  Future<StoredChat?> _persistChatInternal(
    List<Map<String, String>> messagesCopy,
    String? chatId, {
    required bool isOffline,
    bool silent = false,
  }) async {
    // CRITICAL: Capture chatId at the start to prevent race conditions
    final String? chatIdAtStart = chatId;

    try {
      // CRITICAL: Never persist a recently deleted chat — it would resurrect it
      if (chatId != null && ChatStorageState.wasRecentlyDeleted(chatId)) {
        if (kDebugMode) {
          debugPrint(
            '🚫 [ChatPersistence] Skipping persist for deleted chat: $chatId',
          );
        }
        return null;
      }

      // Check if chat actually exists in storage
      final bool chatExists =
          chatId != null &&
          ChatStorageService.savedChats.any((chat) => chat.id == chatId);

      // If chatId is provided but chat doesn't exist in storage, we need to INSERT not UPDATE
      final stored = chatExists
          ? await ChatStorageService.updateChat(chatId, messagesCopy)
          : await ChatStorageService.saveChat(messagesCopy, chatId: chatId);

      if (stored == null) {
        if (kDebugMode) {
          debugPrint(
            '❌ [ChatPersistence] Failed: ChatStorageService returned null',
          );
        }
        return null;
      }

      // Notify about chat ID assignment (unless silent mode)
      // Silent mode is used when persisting old chat in background after user moved to new chat
      if (!silent && (chatIdAtStart == null || chatIdAtStart != stored.id)) {
        onChatIdAssigned?.call(stored.id);
      }

      return stored;
    } catch (error, stackTrace) {
      final String errorStr = error.toString().toLowerCase();
      if (kDebugMode) {
        debugPrint('❌ [ChatPersistence] Exception: $error');
      }
      if (kDebugMode) {
        debugPrint('Stack trace: $stackTrace');
      }

      // Don't show errors for network issues or when offline
      if (NetworkStatusService.isNetworkError(error) || isOffline) {
        if (kDebugMode) {
          debugPrint(
            '🌐 [ChatPersistence] Network/offline error (expected when offline)',
          );
        }
        // Silently fail - chats will sync when back online
        return null;
      }

      // Check if it's a permission/auth error
      if (errorStr.contains('permission') ||
          errorStr.contains('access') ||
          errorStr.contains('denied') ||
          errorStr.contains('unauthorized')) {
        if (kDebugMode) {
          debugPrint('🔒 [ChatPersistence] Permission/auth error');
        }

        // Check if we actually have a valid session
        final session = SupabaseService.auth.currentSession;
        if (session == null) {
          if (kDebugMode) {
            debugPrint('❌ [ChatPersistence] No session found');
          }
          onShowSnackBar?.call('Please sign in to save chats');
        } else {
          if (kDebugMode) {
            debugPrint(
              '⚠️ [ChatPersistence] Has session but permission denied - RLS policy issue?',
            );
          }
        }
        return null;
      }

      // Check if it's an encryption error
      if (errorStr.contains('encryption') || errorStr.contains('key')) {
        if (kDebugMode) {
          debugPrint('🔐 [ChatPersistence] Encryption error');
        }
        onShowSnackBar?.call(
          'Error saving chat. Your messages are still visible.',
        );
        return null;
      }

      // For other errors, log but don't show to user (too disruptive)
      if (kDebugMode) {
        debugPrint('⚠️ [ChatPersistence] Unknown error type: $errorStr');
      }
      return null;
    }
  }

  /// Update a specific message in storage for a background chat
  Future<void> updateBackgroundChatMessage({
    required String chatId,
    required int messageIndex,
    String? content,
    String? reasoning,
    String? toolCallsJson,
    String? contentBlocksJson,
    String? images,
    String? imageMetas,
    String? imageCostEur,
    String? imageGeneratedAt,
    String? tps,
    String? status,
    bool immediate = false,
  }) async {
    final key = '$chatId:$messageIndex';
    final existing =
        _pendingBackgroundUpdates[key] ??
        _PendingBackgroundUpdate(chatId: chatId, messageIndex: messageIndex);

    existing
      ..content = content ?? existing.content
      ..reasoning = reasoning ?? existing.reasoning
      ..toolCallsJson = toolCallsJson ?? existing.toolCallsJson
      ..contentBlocksJson = contentBlocksJson ?? existing.contentBlocksJson
      ..images = images ?? existing.images
      ..imageMetas = imageMetas ?? existing.imageMetas
      ..imageCostEur = imageCostEur ?? existing.imageCostEur
      ..imageGeneratedAt = imageGeneratedAt ?? existing.imageGeneratedAt
      ..tps = tps ?? existing.tps
      ..status = status ?? existing.status;

    _pendingBackgroundUpdates[key] = existing;

    if (immediate) {
      _backgroundUpdateTimers.remove(key)?.cancel();
      await _flushBackgroundUpdate(key);
      return;
    }

    _backgroundUpdateTimers.remove(key)?.cancel();
    _backgroundUpdateTimers[key] = Timer(_backgroundUpdateDebounce, () {
      unawaited(_flushBackgroundUpdate(key));
    });
  }

  Future<void> _flushBackgroundUpdate(String key) async {
    final pending = _pendingBackgroundUpdates.remove(key);
    _backgroundUpdateTimers.remove(key)?.cancel();
    if (pending == null) {
      return;
    }

    /// Put the patch back and try again shortly. Every early return below
    /// used to drop it, and a dropped patch is a lost answer.
    void retry() {
      if (pending.attempts >= _maxBackgroundRetries) return;
      pending.attempts++;
      _pendingBackgroundUpdates.putIfAbsent(key, () => pending);
      _backgroundUpdateTimers.remove(key)?.cancel();
      _backgroundUpdateTimers[key] = Timer(
        _backgroundRetryDelay,
        () => unawaited(_flushBackgroundUpdate(key)),
      );
    }

    try {
      // Skip if chat was recently deleted
      if (ChatStorageState.wasRecentlyDeleted(pending.chatId)) {
        if (kDebugMode) {
          debugPrint(
            '🚫 [ChatPersistence] Skipping background update for deleted chat: ${pending.chatId}',
          );
        }
        return;
      }

      final chatIndex = ChatStorageService.savedChats.indexWhere(
        (chat) => chat.id == pending.chatId,
      );
      if (chatIndex == -1) {
        retry();
        return;
      }

      final chat = ChatStorageService.savedChats[chatIndex];
      if (!chat.isFullyLoaded) {
        final loaded = await ChatStorageService.loadFullChat(pending.chatId);
        if (loaded == null || !loaded.isFullyLoaded) {
          retry();
          return;
        }
      }

      final refreshed = ChatStorageService.getChatById(pending.chatId);
      if (refreshed == null || !refreshed.isFullyLoaded) {
        retry();
        return;
      }

      final messages = refreshed.messages.map((m) => m.toJson()).toList();
      if (pending.messageIndex < 0 || pending.messageIndex >= messages.length) {
        retry();
        return;
      }

      // A patch may only add to what is stored, never empty it. A tick that
      // was queued before the final text arrived would otherwise overwrite
      // the finished answer with the nothing it knew at the time.
      if (keepsMoreThanPatch(
        messages[pending.messageIndex]['text'],
        pending.content,
      )) {
        pending.content = null;
      }
      if (keepsMoreThanPatch(
        messages[pending.messageIndex]['contentBlocks'],
        pending.contentBlocksJson,
      )) {
        pending.contentBlocksJson = null;
      }

      if (pending.content != null) {
        messages[pending.messageIndex]['text'] = pending.content;
      }
      if (pending.reasoning != null) {
        messages[pending.messageIndex]['reasoning'] = pending.reasoning;
      }
      if (pending.toolCallsJson != null) {
        messages[pending.messageIndex]['toolCalls'] = pending.toolCallsJson;
      }
      if (pending.contentBlocksJson != null) {
        messages[pending.messageIndex]['contentBlocks'] =
            pending.contentBlocksJson;
      }
      if (pending.images != null) {
        messages[pending.messageIndex]['images'] = pending.images;
      }
      if (pending.imageMetas != null) {
        messages[pending.messageIndex]['imageMetas'] = pending.imageMetas;
      }
      if (pending.imageCostEur != null) {
        messages[pending.messageIndex]['imageCostEur'] = pending.imageCostEur;
      }
      if (pending.imageGeneratedAt != null) {
        messages[pending.messageIndex]['imageGeneratedAt'] =
            pending.imageGeneratedAt;
      }
      if (pending.tps != null) {
        messages[pending.messageIndex]['tps'] = pending.tps;
      }
      if (pending.status != null) {
        messages[pending.messageIndex]['status'] = pending.status;
      }

      await ChatStorageService.updateChat(pending.chatId, messages);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ [ChatPersistence] Background update failed: $e');
      }
    }
  }
}

class _PendingBackgroundUpdate {
  _PendingBackgroundUpdate({required this.chatId, required this.messageIndex});

  final String chatId;
  final int messageIndex;
  String? content;
  String? reasoning;
  String? toolCallsJson;
  String? contentBlocksJson;
  String? images;
  String? imageMetas;
  String? imageCostEur;
  String? imageGeneratedAt;
  String? tps;
  int attempts = 0;
  String? status;
}
