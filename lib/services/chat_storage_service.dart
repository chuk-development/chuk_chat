// lib/services/chat_storage_service.dart
//
// Facade for chat storage functionality.
// Re-exports all chat storage components for backward compatibility.

// Re-export models
export 'package:chuk_chat/models/chat_message.dart';
export 'package:chuk_chat/models/stored_chat.dart';

// Re-export state for shared preferences init
export 'package:chuk_chat/services/chat_storage_state.dart'
    show initChatStorageCache;

import 'package:chuk_chat/models/stored_chat.dart';
import 'package:chuk_chat/services/chat_storage_crud.dart';
import 'package:chuk_chat/services/chat_storage_mutations.dart';
import 'package:chuk_chat/services/chat_storage_sidebar.dart';
import 'package:chuk_chat/services/chat_storage_state.dart';
import 'package:chuk_chat/services/chat_storage_sync.dart';
import 'package:flutter/foundation.dart';

/// Facade class providing backward-compatible API for chat storage.
/// Delegates to specialized modules for actual implementation.
class ChatStorageService {
  // ============================================================================
  // STATE PROPERTIES (delegated to ChatStorageState)
  // ============================================================================

  /// Track if initial sync has completed (for ChatSyncService coordination)
  static bool get initialSyncComplete => ChatStorageState.initialSyncComplete;

  /// ValueNotifier for reactive selectedChatId updates
  static ValueNotifier<String?> get selectedChatIdNotifier =>
      ChatStorageState.selectedChatIdNotifier;

  static String? get selectedChatId => ChatStorageState.selectedChatId;
  static set selectedChatId(String? value) =>
      ChatStorageState.selectedChatId = value;

  /// GLOBAL LOCK: Prevents chat switching during message operations.
  static bool get isMessageOperationInProgress =>
      ChatStorageState.isMessageOperationInProgress;
  static set isMessageOperationInProgress(bool value) =>
      ChatStorageState.isMessageOperationInProgress = value;

  /// The chat ID currently being worked on during a message operation.
  static String? get activeMessageChatId =>
      ChatStorageState.activeMessageChatId;
  static set activeMessageChatId(String? value) =>
      ChatStorageState.activeMessageChatId = value;

  /// LOADING LOCK: Prevents rapid chat switching while a chat is loading.
  static bool get isLoadingChat => ChatStorageState.isLoadingChat;
  static set isLoadingChat(bool value) =>
      ChatStorageState.isLoadingChat = value;

  /// Get chats as a sorted list (most recent first)
  static List<StoredChat> get savedChats => ChatStorageState.savedChats;

  /// Get a chat by its ID (returns null if not found)
  static StoredChat? getChatById(String chatId) =>
      ChatStorageState.getChatById(chatId);

  /// Stream of chat changes. Emits the changed chat ID, or null for bulk changes.
  static Stream<String?> get changes => ChatStorageState.changes;

  /// Get a map of chat IDs to their updated_at timestamps for sync comparison.
  static Map<String, DateTime> getChatTimestamps() =>
      ChatStorageState.getChatTimestamps();

  // ============================================================================
  // CRUD OPERATIONS (delegated to ChatStorageCrud)
  // ============================================================================

  /// Load a single chat's full content (messages) on demand.
  static Future<StoredChat?> loadFullChat(String chatId) =>
      ChatStorageCrud.loadFullChat(chatId);

  /// Load chats from local cache only (instant, no network).
  static Future<void> loadFromCache() => ChatStorageCrud.loadFromCache();

  /// Load all chats from Supabase or cache
  static Future<void> loadChats() => ChatStorageCrud.loadChats();

  /// Save a new chat to Supabase
  static Future<StoredChat?> saveChat(
    List<Map<String, dynamic>> messagesMaps, {
    String? chatId,
  }) => ChatStorageCrud.saveChat(messagesMaps, chatId: chatId);

  /// Update an existing chat
  static Future<StoredChat?> updateChat(
    String chatId,
    List<Map<String, dynamic>> messagesMaps,
  ) => ChatStorageCrud.updateChat(chatId, messagesMaps);

  /// Delete a chat and its associated images from storage
  static Future<void> deleteChat(String chatId) =>
      ChatStorageCrud.deleteChat(chatId);

  // ============================================================================
  // SIDEBAR OPERATIONS (delegated to ChatStorageSidebar)
  // ============================================================================

  /// Load chats for sidebar - title-only for instant display.
  static Future<void> loadSavedChatsForSidebar() =>
      ChatStorageSidebar.loadSavedChatsForSidebar();

  /// Sync titles from network (public API for ChatSyncService)
  static Future<void> syncTitlesFromNetwork() =>
      ChatStorageSidebar.syncTitlesFromNetwork();

  // ============================================================================
  // MUTATIONS (delegated to ChatStorageMutations)
  // ============================================================================

  /// Set chat starred status
  static Future<void> setChatStarred(String chatId, bool isStarred) =>
      ChatStorageMutations.setChatStarred(chatId, isStarred);

  /// Rename a chat
  static Future<void> renameChat(String chatId, String newName) async {
    // Ensure chat is fully loaded before renaming
    var chat = ChatStorageState.getChatById(chatId);

    // If chat not in local state or not fully loaded, load it from database
    if (chat == null || !chat.isFullyLoaded) {
      await ChatStorageCrud.loadFullChat(chatId);
      chat = ChatStorageState.getChatById(chatId);
    }

    // If still not found after loading, the chat doesn't exist
    if (chat == null) {
      throw StateError('Chat not found: $chatId');
    }

    await ChatStorageMutations.renameChat(chatId, newName);
  }

  /// Re-encrypt all chats with stored chat data
  static Future<void> reencryptChats(List<StoredChat> chats) =>
      ChatStorageMutations.reencryptChats(chats);

  /// Export all chats
  static Future<String> exportChats() => ChatStorageMutations.exportChats();

  /// Export chats as JSON (alias for exportChats)
  static Future<String> exportChatsAsJson() =>
      ChatStorageMutations.exportChatsAsJson();

  // ============================================================================
  // SYNC SUPPORT METHODS (delegated to ChatStorageSync)
  // ============================================================================

  /// Merge a synced chat from cloud into local state.
  static Future<void> mergeSyncedChat(Map<String, dynamic> row) =>
      ChatStorageSync.mergeSyncedChat(row);

  /// Batch merge multiple synced chats efficiently.
  static Future<void> mergeSyncedChatsBatch(List<Map<String, dynamic>> rows) =>
      ChatStorageSync.mergeSyncedChatsBatch(rows);

  /// Remove a chat from local state only (without database operation).
  static void removeChatLocally(String chatId) =>
      ChatStorageSync.removeChatLocally(chatId);

  // ============================================================================
  // RESET
  // ============================================================================

  /// Reset all state
  static Future<void> reset() => ChatStorageState.reset();
}
