// lib/platform_specific/chat/handlers/chat_persistence_handler.dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/network_status_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';

/// Handles chat persistence and storage
class ChatPersistenceHandler {
  static const Duration _backgroundUpdateDebounce = Duration(milliseconds: 700);

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
    _pendingBackgroundUpdates.clear();
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

    final messagesCopy = messages
        .map((message) => Map<String, String>.from(message))
        .toList(growable: false);

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
    String? imageCostEur,
    String? imageGeneratedAt,
    String? tps,
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
      ..imageCostEur = imageCostEur ?? existing.imageCostEur
      ..imageGeneratedAt = imageGeneratedAt ?? existing.imageGeneratedAt
      ..tps = tps ?? existing.tps;

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

    try {
      final chatIndex = ChatStorageService.savedChats.indexWhere(
        (chat) => chat.id == pending.chatId,
      );
      if (chatIndex == -1) {
        return;
      }

      final chat = ChatStorageService.savedChats[chatIndex];
      if (!chat.isFullyLoaded) {
        final loaded = await ChatStorageService.loadFullChat(pending.chatId);
        if (loaded == null || !loaded.isFullyLoaded) {
          return;
        }
      }

      final refreshed = ChatStorageService.getChatById(pending.chatId);
      if (refreshed == null || !refreshed.isFullyLoaded) {
        return;
      }

      final messages = refreshed.messages.map((m) => m.toJson()).toList();
      if (pending.messageIndex < 0 || pending.messageIndex >= messages.length) {
        return;
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
  String? imageCostEur;
  String? imageGeneratedAt;
  String? tps;
}
