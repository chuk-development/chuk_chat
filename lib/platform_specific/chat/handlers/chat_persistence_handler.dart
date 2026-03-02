// lib/platform_specific/chat/handlers/chat_persistence_handler.dart
import 'package:flutter/foundation.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/network_status_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';

/// Handles chat persistence and storage
class ChatPersistenceHandler {
  // Callbacks
  Function(String)? onShowSnackBar;
  Function(String chatId)? onChatIdAssigned;

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

    if (kDebugMode) {
      debugPrint(
        '📝 [ChatPersistence] Starting persist: chatId=$chatId, messages=${messagesCopy.length}, offline=$isOffline, silent=$silent',
      );
    }

    try {
      // Check if chat actually exists in storage
      final bool chatExists =
          chatId != null &&
          ChatStorageService.savedChats.any((chat) => chat.id == chatId);

      if (kDebugMode) {
        debugPrint('📋 [ChatPersistence] Chat exists in storage: $chatExists');
      }

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

      if (kDebugMode) {
        debugPrint(
          '✅ [ChatPersistence] Success: chatId=${stored.id}, messages=${stored.messages.length}',
        );
      }

      // Notify about chat ID assignment (unless silent mode)
      // Silent mode is used when persisting old chat in background after user moved to new chat
      if (!silent && (chatIdAtStart == null || chatIdAtStart != stored.id)) {
        onChatIdAssigned?.call(stored.id);
      } else if (silent) {
        if (kDebugMode) {
          debugPrint(
            '│ 🔇 [ChatPersistence] Silent mode - skipping onChatIdAssigned callback',
          );
        }
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
    String? images,
    String? imageCostEur,
    String? imageGeneratedAt,
    String? tps,
  }) async {
    try {
      // Find the chat in storage
      final chatIndex = ChatStorageService.savedChats.indexWhere(
        (chat) => chat.id == chatId,
      );

      if (chatIndex == -1) {
        if (kDebugMode) {
          debugPrint('Chat $chatId not found in storage');
        }
        return;
      }

      final chat = ChatStorageService.savedChats[chatIndex];
      final messages = chat.messages.map((m) => m.toJson()).toList();

      // Update the message at the specified index
      if (messageIndex >= 0 && messageIndex < messages.length) {
        if (content != null) {
          messages[messageIndex]['text'] = content;
        }
        if (reasoning != null) {
          messages[messageIndex]['reasoning'] = reasoning;
        }
        if (toolCallsJson != null) {
          messages[messageIndex]['toolCalls'] = toolCallsJson;
        }
        if (images != null) {
          messages[messageIndex]['images'] = images;
        }
        if (imageCostEur != null) {
          messages[messageIndex]['imageCostEur'] = imageCostEur;
        }
        if (imageGeneratedAt != null) {
          messages[messageIndex]['imageGeneratedAt'] = imageGeneratedAt;
        }
        if (tps != null) {
          messages[messageIndex]['tps'] = tps;
        }

        // Save back to storage
        await ChatStorageService.updateChat(chatId, messages);
        if (kDebugMode) {
          debugPrint(
            'Updated background chat $chatId message at index $messageIndex',
          );
        }
      } else {
        if (kDebugMode) {
          debugPrint('Invalid message index $messageIndex for chat $chatId');
        }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error updating background chat message: $e');
      }
    }
  }
}
