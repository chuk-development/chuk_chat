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

    debugPrint('📝 [ChatPersistence] Starting persist: chatId=$chatId, messages=${messagesCopy.length}, offline=$isOffline');

    try {
      // Check if chat actually exists in storage
      final bool chatExists = chatId != null &&
          ChatStorageService.savedChats.any((chat) => chat.id == chatId);

      debugPrint('📋 [ChatPersistence] Chat exists in storage: $chatExists');

      // If chatId is provided but chat doesn't exist in storage, we need to INSERT not UPDATE
      final stored = chatExists
          ? await ChatStorageService.updateChat(chatId, messagesCopy)
          : await ChatStorageService.saveChat(messagesCopy, chatId: chatId);

      if (stored == null) {
        debugPrint('❌ [ChatPersistence] Failed: ChatStorageService returned null');
        return;
      }

      debugPrint('✅ [ChatPersistence] Success: chatId=${stored.id}, messages=${stored.messages.length}');

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
    } catch (error, stackTrace) {
      final String errorStr = error.toString().toLowerCase();
      debugPrint('❌ [ChatPersistence] Exception: $error');
      debugPrint('Stack trace: $stackTrace');

      // Don't show errors for network issues or when offline
      if (NetworkStatusService.isNetworkError(error) || isOffline) {
        debugPrint('🌐 [ChatPersistence] Network/offline error (expected when offline)');
        // Silently fail - chats will sync when back online
        return;
      }

      // Check if it's a permission/auth error
      if (errorStr.contains('permission') ||
          errorStr.contains('access') ||
          errorStr.contains('denied') ||
          errorStr.contains('unauthorized')) {
        debugPrint('🔒 [ChatPersistence] Permission/auth error');

        // Check if we actually have a valid session
        final session = SupabaseService.auth.currentSession;
        if (session == null) {
          debugPrint('❌ [ChatPersistence] No session found');
          onShowSnackBar?.call('Please sign in to save chats');
        } else {
          debugPrint('⚠️ [ChatPersistence] Has session but permission denied - RLS policy issue?');
        }
        return;
      }

      // Check if it's an encryption error
      if (errorStr.contains('encryption') || errorStr.contains('key')) {
        debugPrint('🔐 [ChatPersistence] Encryption error');
        onShowSnackBar?.call('Error saving chat. Your messages are still visible.');
        return;
      }

      // For other errors, log but don't show to user (too disruptive)
      debugPrint('⚠️ [ChatPersistence] Unknown error type: $errorStr');
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
