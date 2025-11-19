// lib/platform_specific/chat/handlers/chat_persistence_handler.dart
import 'package:flutter/material.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/network_status_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';

/// Handles chat persistence and storage
class ChatPersistenceHandler {
  // Callbacks
  Function(String)? onShowSnackBar;
  Function(String chatId)? onChatIdAssigned;

  /// Save or update chat in storage
  Future<void> persistChat({
    required List<Map<String, String>> messages,
    String? chatId,
    bool waitForCompletion = false,
    bool isOffline = false,
  }) async {
    if (messages.isEmpty) return;

    final messagesCopy = messages
        .map((message) => Map<String, String>.from(message))
        .toList(growable: false);

    final operation = _persistChatInternal(
      messagesCopy,
      chatId,
      isOffline: isOffline,
    );

    if (waitForCompletion) {
      await operation;
    }
  }

  Future<void> _persistChatInternal(
    List<Map<String, String>> messagesCopy,
    String? chatId, {
    required bool isOffline,
  }) async {
    // CRITICAL: Capture chatId at the start to prevent race conditions
    final String? chatIdAtStart = chatId;

    try {
      final stored = chatId == null
          ? await ChatStorageService.saveChat(messagesCopy)
          : await ChatStorageService.updateChat(chatId, messagesCopy);

      if (stored == null) return;

      // Notify about chat ID assignment
      if (chatIdAtStart == null || chatIdAtStart != stored.id) {
        onChatIdAssigned?.call(stored.id);
      }

      final index = ChatStorageService.savedChats.indexWhere(
        (chat) => chat.id == stored.id,
      );
      if (index != -1) {
        ChatStorageService.selectedChatIndex = index;
      }
    } catch (error) {
      final String errorStr = error.toString().toLowerCase();

      // Don't show errors for network issues or when offline
      if (NetworkStatusService.isNetworkError(error) || isOffline) {
        debugPrint('Chat persist failed (offline/network): $error');
        // Silently fail - chats will sync when back online
        return;
      }

      // Check if it's a permission/auth error
      if (errorStr.contains('permission') ||
          errorStr.contains('access') ||
          errorStr.contains('denied') ||
          errorStr.contains('unauthorized')) {
        debugPrint('Chat persist failed (permissions): $error');

        // Check if we actually have a valid session
        final session = SupabaseService.auth.currentSession;
        if (session == null) {
          onShowSnackBar?.call('Please sign in to save chats');
        } else {
          debugPrint('Permission error despite valid session - may be RLS policy issue');
        }
        return;
      }

      // For other errors, log but don't show to user (too disruptive)
      debugPrint('Chat persist failed: $error');
      if (errorStr.contains('encryption')) {
        onShowSnackBar?.call('Error saving chat. Your messages are still visible.');
      }
    }
  }

  /// Update a specific message in storage for a background chat
  Future<void> updateBackgroundChatMessage({
    required String chatId,
    required int messageIndex,
    required String content,
    required String reasoning,
  }) async {
    try {
      // Find the chat in storage
      final chatIndex = ChatStorageService.savedChats.indexWhere(
        (chat) => chat.id == chatId,
      );

      if (chatIndex == -1) {
        debugPrint('Chat $chatId not found in storage');
        return;
      }

      final chat = ChatStorageService.savedChats[chatIndex];
      final messages = chat.messages.map((m) => m.toJson()).toList();

      // Update the message at the specified index
      if (messageIndex >= 0 && messageIndex < messages.length) {
        messages[messageIndex]['text'] = content;
        messages[messageIndex]['reasoning'] = reasoning;

        // Save back to storage
        await ChatStorageService.updateChat(chatId, messages);
        debugPrint('Updated background chat $chatId message at index $messageIndex');
      } else {
        debugPrint('Invalid message index $messageIndex for chat $chatId');
      }
    } catch (e) {
      debugPrint('Error updating background chat message: $e');
    }
  }
}
