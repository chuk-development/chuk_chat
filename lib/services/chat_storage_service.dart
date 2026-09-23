// lib/services/chat_storage_service.dart
//
// AGENTS ADAPTATION. Upstream: chuk_chat/lib/services/chat_storage_service.dart.
//
// With FEATURE_AGENTS off every member delegates exactly as upstream does.
//
// With it on, the facade routes by chat kind ([ChatOrigin]):
//
// * a chuk_chat chat (UUID id) takes upstream's path unchanged: INSERT/UPDATE
//   of `encrypted_chats` through [ChatStorageCrud];
// * an Agents thread (the executor's session key) goes through
//   [AgentsChatStore]: a host-authoritative REPLACE into memory, the SQLite
//   cache and an encrypted upsert of `cowork_chats`. Such a thread may arrive
//   with no cloud at all (offline, a widget test, a fresh install), so its
//   read answers from memory first, then SQLite, then `cowork_chats`, and
//   never throws. Its delete removes the `cowork_chats` row.
//
// chuk_chat's cloud sync only knows `encrypted_chats`. So an Agents thread is
// never merged from it and never removed locally because that table lacks
// it; `AgentsChatStore.pullFromCloud` polls `cowork_chats` instead. The three
// list loaders are no-ops and deleteChat is memory-only while there is no
// Supabase client at all (upstream throws).
//
// Facade for chat storage functionality.
// Re-exports all chat storage components for backward compatibility.

import 'dart:async';

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
import 'package:chuk_chat/services/storage/agents_chat_store.dart';
import 'package:chuk_chat/services/storage/chat_origin.dart';
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
  /// AGENTS: an Agents thread is read memory first, then cache-first; it never
  /// throws for want of a Supabase client.
  static Future<StoredChat?> loadFullChat(String chatId) =>
      ChatOrigin.isAgentsThread(chatId)
      ? AgentsChatStore.loadThread(chatId)
      : ChatStorageCrud.loadFullChat(chatId);

  /// AGENTS: does this device hold a local copy of [chatId] (memory or the
  /// SQLite row)? No cloud, no payload decode. Not an upstream member.
  static Future<bool> hasLocalThread(String chatId) =>
      AgentsChatStore.hasThread(chatId);

  /// Load chats from local cache only (instant, no network).
  /// AGENTS: a no-op with no Supabase client (upstream throws).
  static Future<void> loadFromCache() async {
    if (ChatOrigin.agentsEnabled && !AgentsChatStore.cloudAvailable) return;
    await ChatStorageCrud.loadFromCache();
  }

  /// Load all chats from Supabase or cache
  /// AGENTS: a no-op with no Supabase client (upstream throws).
  static Future<void> loadChats() async {
    if (ChatOrigin.agentsEnabled && !AgentsChatStore.cloudAvailable) return;
    await ChatStorageCrud.loadChats();
  }

  /// Save a new chat to Supabase.
  /// AGENTS: an Agents thread is a host-authoritative replace through
  /// [AgentsChatStore] into `cowork_chats`; a chuk_chat chat is upstream's
  /// INSERT into `encrypted_chats`.
  static Future<StoredChat?> saveChat(
    List<Map<String, dynamic>> messagesMaps, {
    String? chatId,
  }) => ChatOrigin.isAgentsThread(chatId)
      ? AgentsChatStore.replaceThread(chatId!, messagesMaps)
      : debugCrudSave(messagesMaps, chatId: chatId);

  /// Update an existing chat.
  /// AGENTS: an Agents thread takes the same replace as [saveChat];
  /// upstream's UPDATE would refuse a row the cloud does not hold yet.
  static Future<StoredChat?> updateChat(
    String chatId,
    List<Map<String, dynamic>> messagesMaps,
  ) => ChatOrigin.isAgentsThread(chatId)
      ? AgentsChatStore.replaceThread(chatId, messagesMaps)
      : debugCrudUpdate(chatId, messagesMaps);

  /// Test seams: upstream's write into `encrypted_chats`. A test swaps them
  /// to see which store a chat reaches without a network.
  @visibleForTesting
  static Future<StoredChat?> Function(
    List<Map<String, dynamic>> messagesMaps, {
    String? chatId,
  })
  debugCrudSave = ChatStorageCrud.saveChat;
  @visibleForTesting
  static Future<StoredChat?> Function(
    String chatId,
    List<Map<String, dynamic>> messagesMaps,
  )
  debugCrudUpdate = ChatStorageCrud.updateChat;

  /// Delete a chat and its associated images from storage
  /// AGENTS: an Agents thread is deleted from `cowork_chats` (and the SQLite
  /// cache and the outbox) through [AgentsChatStore.deleteThread]; upstream's
  /// delete targets `encrypted_chats`, which never holds it. With no
  /// Supabase client a chat is dropped from memory only (upstream throws
  /// before it touches anything).
  static Future<void> deleteChat(String chatId) async {
    if (ChatOrigin.isAgentsThread(chatId)) {
      await AgentsChatStore.deleteThread(chatId);
      return;
    }
    if (ChatOrigin.agentsEnabled && !AgentsChatStore.cloudAvailable) {
      ChatStorageState.markDeleted(chatId);
      ChatStorageState.chatsById.remove(chatId);
      ChatStorageState.notifyChanges(chatId);
      return;
    }
    await ChatStorageCrud.deleteChat(chatId);
  }

  // ============================================================================
  // SIDEBAR OPERATIONS (delegated to ChatStorageSidebar)
  // ============================================================================

  /// Load chats for sidebar - title-only for instant display.
  /// AGENTS: a no-op with no Supabase client (upstream throws).
  static Future<void> loadSavedChatsForSidebar() async {
    if (ChatOrigin.agentsEnabled && !AgentsChatStore.cloudAvailable) return;
    await ChatStorageSidebar.loadSavedChatsForSidebar();
  }

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
  /// AGENTS: the sync reads `encrypted_chats`, which never holds an Agents
  /// thread; a row under such an id is not merged over the thread.
  static Future<void> mergeSyncedChat(Map<String, dynamic> row) {
    if (_isAgentsRow(row)) return Future.value();
    return ChatStorageSync.mergeSyncedChat(row);
  }

  /// Batch merge multiple synced chats efficiently.
  /// AGENTS: Agents threads are dropped from the batch (see above).
  static Future<void> mergeSyncedChatsBatch(List<Map<String, dynamic>> rows) {
    if (!ChatOrigin.agentsEnabled) {
      return ChatStorageSync.mergeSyncedChatsBatch(rows);
    }
    final clean = <Map<String, dynamic>>[
      for (final row in rows)
        if (!_isAgentsRow(row)) row,
    ];
    if (clean.isEmpty) return Future.value();
    return ChatStorageSync.mergeSyncedChatsBatch(clean);
  }

  /// Remove a chat from local state only (without database operation).
  /// AGENTS: the sync calls this when `encrypted_chats` has no row for a
  /// local chat. An Agents thread lives in `cowork_chats`, so that table
  /// never has its row; the thread is kept. A dirty one also gets its
  /// outbox flushed.
  static void removeChatLocally(String chatId) {
    if (ChatOrigin.isAgentsThread(chatId)) {
      if (AgentsChatStore.isDirty(chatId)) {
        unawaited(AgentsChatStore.flushOutbox());
      }
      return;
    }
    ChatStorageSync.removeChatLocally(chatId);
  }

  static bool _isAgentsRow(Map<String, dynamic> row) {
    final id = row['id'];
    return id is String && ChatOrigin.isAgentsThread(id);
  }

  // ============================================================================
  // RESET
  // ============================================================================

  /// Reset all state
  static Future<void> reset() => ChatStorageState.reset();
}
