// lib/services/chat_storage_service.dart
//
// AGENTS ADAPTATION. Upstream: chuk_chat/lib/services/chat_storage_service.dart @ d31526a229fdde27c82adf3661d5d3a149db8340.
// Verbatim except the recorded divergences (docs/CHAT_UI_IMPORT.md, "Allowed
// divergences"): `saveChat` and `updateChat` go through `AgentsChatStore`
// instead of `ChatStorageCrud`; `loadFullChat` answers from memory first; the
// three list loaders are no-ops and deleteChat is memory-only while there is
// no Supabase client at all;
// the sync's merge and local-remove skip threads still in the cloud outbox. Upstream's write path INSERTs a new chat and
// UPDATEs a known one, and both refuse to run without a signed-in Supabase
// session and an unlocked key. A Agents thread is host-authoritative and may
// arrive with no cloud at all (offline, a widget test, a fresh install whose
// row already exists on the server), so its write is a REPLACE: memory, then
// the SQLite cache, then an encrypted upsert — best-effort, never throwing.
// Every read, the sidebar, the sync and every mutation stay upstream's.
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
  /// AGENTS: memory first, then upstream's cache-first load; never throws
  /// for want of a Supabase client.
  static Future<StoredChat?> loadFullChat(String chatId) =>
      AgentsChatStore.loadThread(chatId);

  /// AGENTS: does this device hold a local copy of [chatId] (memory or the
  /// SQLite row)? No cloud, no payload decode. Not an upstream member.
  static Future<bool> hasLocalThread(String chatId) =>
      AgentsChatStore.hasThread(chatId);

  /// Load chats from local cache only (instant, no network).
  /// AGENTS: a no-op with no Supabase client (upstream throws).
  static Future<void> loadFromCache() async {
    if (!AgentsChatStore.cloudAvailable) return;
    await ChatStorageCrud.loadFromCache();
  }

  /// Load all chats from Supabase or cache
  /// AGENTS: a no-op with no Supabase client (upstream throws).
  static Future<void> loadChats() async {
    if (!AgentsChatStore.cloudAvailable) return;
    await ChatStorageCrud.loadChats();
  }

  /// Save a chat. AGENTS: a host-authoritative replace through
  /// [AgentsChatStore] (memory → SQLite → encrypted upsert), not upstream's
  /// Supabase INSERT. The id is the executor session key; a missing one gets
  /// a UUID as upstream does.
  static Future<StoredChat?> saveChat(
    List<Map<String, dynamic>> messagesMaps, {
    String? chatId,
  }) => AgentsChatStore.replaceThread(
    chatId ?? ChatStorageState.uuid.v4(),
    messagesMaps,
  );

  /// Update an existing chat. AGENTS: same replace as [saveChat]; upstream's
  /// UPDATE would refuse a row the cloud does not hold yet.
  static Future<StoredChat?> updateChat(
    String chatId,
    List<Map<String, dynamic>> messagesMaps,
  ) => AgentsChatStore.replaceThread(chatId, messagesMaps);

  /// Delete a chat and its associated images from storage
  /// AGENTS: with no Supabase client the chat is dropped from memory only
  /// (upstream throws before it touches anything).
  static Future<void> deleteChat(String chatId) async {
    if (!AgentsChatStore.cloudAvailable) {
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
    if (!AgentsChatStore.cloudAvailable) return;
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
  /// AGENTS: a thread whose local copy is still waiting for its cloud write
  /// (the outbox) is never overwritten by the cloud's older picture.
  static Future<void> mergeSyncedChat(Map<String, dynamic> row) {
    final id = row['id'];
    if (id is String && AgentsChatStore.isDirty(id)) return Future.value();
    return ChatStorageSync.mergeSyncedChat(row);
  }

  /// Batch merge multiple synced chats efficiently.
  /// AGENTS: dirty threads are dropped from the batch (see above).
  static Future<void> mergeSyncedChatsBatch(List<Map<String, dynamic>> rows) {
    final clean = <Map<String, dynamic>>[
      for (final row in rows)
        if (row['id'] is! String ||
            !AgentsChatStore.isDirty(row['id'] as String))
          row,
    ];
    if (clean.isEmpty) return Future.value();
    return ChatStorageSync.mergeSyncedChatsBatch(clean);
  }

  /// Remove a chat from local state only (without database operation).
  /// AGENTS: the sync calls this when it finds no cloud row for a local
  /// chat. A dirty thread has no cloud row BECAUSE it has not been uploaded
  /// yet, so it is kept and the outbox is flushed instead.
  static void removeChatLocally(String chatId) {
    if (AgentsChatStore.isDirty(chatId)) {
      unawaited(AgentsChatStore.flushOutbox());
      return;
    }
    ChatStorageSync.removeChatLocally(chatId);
  }

  // ============================================================================
  // RESET
  // ============================================================================

  /// Reset all state
  static Future<void> reset() => ChatStorageState.reset();
}
