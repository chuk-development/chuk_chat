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
import 'package:chuk_chat/services/chat_dirty_store.dart';
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
  /// A chat that was only saved locally so far has no cloud row yet; it is
  /// inserted instead.
  /// AGENTS: an Agents thread takes the same replace as [saveChat];
  /// upstream's UPDATE would refuse a row the cloud does not hold yet.
  static Future<StoredChat?> updateChat(
    String chatId,
    List<Map<String, dynamic>> messagesMaps,
  ) {
    if (ChatOrigin.isAgentsThread(chatId)) {
      return AgentsChatStore.replaceThread(chatId, messagesMaps);
    }
    return ChatDirtyStore.isPendingInsert(chatId)
        ? debugCrudSave(messagesMaps, chatId: chatId)
        : debugCrudUpdate(chatId, messagesMaps);
  }

  /// Save a chat on this device only: memory, the SQLite cache and a dirty
  /// mark, no network. This is the save for every checkpoint inside a turn
  /// (tool rounds, stream ticks, auto-save). The chat reaches the cloud with
  /// [syncChat] at the end of the turn, or with [flushDirty]. A new chat
  /// ([chatId] null) gets its id here.
  /// AGENTS: an Agents thread is replaced through [AgentsChatStore], which
  /// has its own outbox.
  static Future<StoredChat?> saveLocal(
    List<Map<String, dynamic>> messagesMaps, {
    String? chatId,
  }) => ChatOrigin.isAgentsThread(chatId)
      ? AgentsChatStore.replaceThread(chatId!, messagesMaps)
      : debugCrudSaveLocal(messagesMaps, chatId: chatId);

  /// End of a turn: write [messagesMaps], which [saveLocal] stored a moment
  /// ago, to the cloud. One INSERT for a new chat, else one UPDATE. On
  /// success the chat is no longer dirty; on failure it stays dirty and the
  /// next [flushDirty] retries it.
  /// AGENTS: an Agents thread was already replaced by [saveLocal].
  static Future<StoredChat?> syncChat(
    String chatId,
    List<Map<String, dynamic>> messagesMaps,
  ) => ChatOrigin.isAgentsThread(chatId)
      ? Future<StoredChat?>.value(ChatStorageState.getChatById(chatId))
      : updateChat(chatId, messagesMaps);

  /// Write every chat whose local copy is ahead of the cloud, once: at app
  /// start after sign-in, when the app goes to the background, and when the
  /// network comes back.
  static Future<void> flushDirty() => debugFlushDirty();

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
  @visibleForTesting
  static Future<StoredChat?> Function(
    List<Map<String, dynamic>> messagesMaps, {
    String? chatId,
  })
  debugCrudSaveLocal = ChatStorageCrud.saveLocal;
  @visibleForTesting
  static Future<void> Function() debugFlushDirty = ChatStorageCrud.flushDirty;

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

  /// Set chat starred status. A chat the cloud does not hold yet is starred
  /// locally; its insert carries the star.
  static Future<void> setChatStarred(String chatId, bool isStarred) async {
    final chat = ChatStorageState.getChatById(chatId);
    if (chat != null && ChatDirtyStore.isPendingInsert(chatId)) {
      ChatStorageState.chatsById[chatId] = chat.copyWith(isStarred: isStarred);
      ChatStorageState.notifyChanges(chatId);
      return;
    }
    await ChatStorageMutations.setChatStarred(chatId, isStarred);
  }

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

    // A chat whose local copy is ahead of the cloud (a turn is running, or
    // its cloud save failed) is renamed locally. Its next cloud save carries
    // the name: renaming it in the cloud now would rewrite the whole payload
    // once more, and fail for a chat the cloud does not hold yet.
    if (!ChatOrigin.isAgentsThread(chatId) && ChatDirtyStore.isDirty(chatId)) {
      ChatStorageState.chatsById[chatId] = chat.copyWith(
        customName: newName,
        title: newName,
      );
      await saveLocal(
        chat.messages.map((m) => m.toJson()).toList(),
        chatId: chatId,
      );
      return;
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
