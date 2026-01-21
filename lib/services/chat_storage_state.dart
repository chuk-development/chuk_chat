// lib/services/chat_storage_state.dart

import 'dart:async';

import 'package:chuk_chat/models/stored_chat.dart';
import 'package:chuk_chat/services/network_status_service.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Pre-cached SharedPreferences instance for fast access
SharedPreferences? sharedPrefsInstance;

/// Pre-initialize SharedPreferences at app startup for instant cache access
Future<void> initChatStorageCache() async {
  sharedPrefsInstance ??= await SharedPreferences.getInstance();
}

/// Central state management for chat storage.
/// Provides the single source of truth for all chats and notification handling.
///
/// Note: Internal state is exposed via getters for use by other chat_storage_* modules.
/// These should not be accessed directly from outside the chat storage module group.
class ChatStorageState {
  // SINGLE SOURCE OF TRUTH - all chats stored here
  // Exposed for internal module access
  static final Map<String, StoredChat> chatsById = <String, StoredChat>{};

  /// Stream controller that emits the changed chat ID, or null for bulk changes.
  /// This allows listeners to only rebuild affected items instead of everything.
  static final StreamController<String?> changesController =
      StreamController<String?>.broadcast();

  // Debounce for notifyChanges to prevent rapid-fire UI rebuilds
  static Timer? _notifyDebounceTimer;
  static final Set<String?> _pendingNotifications = <String?>{};
  static const Duration _notifyDebounceDelay = Duration(milliseconds: 100);

  /// Track if initial sync has completed (for ChatSyncService coordination)
  static bool initialSyncComplete = false;

  static int selectedChatIndex = -1;

  /// ID-BASED SELECTION: The currently selected chat ID.
  /// null = new chat (no chat selected yet)
  /// This is the primary source of truth for which chat is active.
  /// ValueNotifier for reactive selectedChatId updates
  static final ValueNotifier<String?> selectedChatIdNotifier = ValueNotifier<String?>(null);

  static String? get selectedChatId => selectedChatIdNotifier.value;
  static set selectedChatId(String? value) {
    if (selectedChatIdNotifier.value != value) {
      debugPrint('');
      debugPrint('┌─────────────────────────────────────────────────────────────');
      debugPrint('│ 📍 [SELECTED-CHAT-ID] CHANGED');
      debugPrint('│ 📍 [SELECTED-CHAT-ID] OLD: ${selectedChatIdNotifier.value}');
      debugPrint('│ 📍 [SELECTED-CHAT-ID] NEW: $value');
      debugPrint('│ 📍 [SELECTED-CHAT-ID] Stack trace:');
      try {
        throw Exception('Stack trace');
      } catch (e, st) {
        final lines = st.toString().split('\n').take(8).join('\n│    ');
        debugPrint('│    $lines');
      }
      debugPrint('└─────────────────────────────────────────────────────────────');
      selectedChatIdNotifier.value = value;
    }
  }

  /// GLOBAL LOCK: Prevents chat switching during message operations.
  /// Set to true when a message send starts, cleared when streaming completes.
  /// Check this in didUpdateWidget to prevent loading wrong chat.
  static bool isMessageOperationInProgress = false;

  /// The chat ID currently being worked on during a message operation.
  /// Used to verify we don't accidentally switch away from an active chat.
  static String? activeMessageChatId;

  /// LOADING LOCK: Prevents rapid chat switching while a chat is loading.
  /// Set to true when _loadChatById starts, cleared when loading completes.
  /// Sidebar should check this before allowing chat selection.
  static bool isLoadingChat = false;

  // UUID generator for chat IDs
  static const Uuid uuid = Uuid();

  // Track chats we're currently saving to ignore realtime events for them
  static final Set<String> savingChats = <String>{};

  // Prevent concurrent save operations
  static final Map<String, Completer<StoredChat?>> pendingSaves =
      <String, Completer<StoredChat?>>{};

  // Cache-first loading: track if cache has been loaded
  static bool cacheLoaded = false;

  // Prevent concurrent loadChats() calls
  static Completer<void>? loadingCompleter;
  static bool get isLoading =>
      loadingCompleter != null && !loadingCompleter!.isCompleted;

  // Get chats as a sorted list (most recent first)
  static List<StoredChat> get savedChats {
    final list = chatsById.values.toList();
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return List.unmodifiable(list);
  }

  /// Get a chat by its ID (returns null if not found)
  static StoredChat? getChatById(String chatId) {
    return chatsById[chatId];
  }

  /// Stream of chat changes. Emits the changed chat ID, or null for bulk changes.
  /// Listeners can use this to only rebuild affected items.
  static Stream<String?> get changes => changesController.stream;

  /// Notify listeners of a change. Pass chatId for single-chat updates,
  /// or null for bulk changes (e.g., initial load, sync).
  /// Uses debouncing to prevent rapid-fire UI rebuilds during sync operations.
  static void notifyChanges([String? chatId]) {
    if (changesController.isClosed) return;

    // Collect pending notifications
    _pendingNotifications.add(chatId);

    // Cancel existing timer
    _notifyDebounceTimer?.cancel();

    // Start new debounce timer
    _notifyDebounceTimer = Timer(_notifyDebounceDelay, () {
      if (changesController.isClosed) return;

      // If any notification is null (bulk change), just emit null once
      if (_pendingNotifications.contains(null)) {
        changesController.add(null);
      } else {
        // Emit individual chat IDs
        for (final id in _pendingNotifications) {
          changesController.add(id);
        }
      }
      _pendingNotifications.clear();
    });
  }

  /// Notify immediately without debounce (for critical updates like cache load)
  static void notifyChangesImmediate([String? chatId]) {
    if (!changesController.isClosed) {
      changesController.add(chatId);
    }
  }

  /// Check network status for offline handling
  static Future<bool> checkNetworkStatus() async {
    try {
      return await NetworkStatusService.hasInternetConnection(
        timeout: const Duration(seconds: 2),
      );
    } catch (_) {
      return false;
    }
  }

  /// Get a map of chat IDs to their updated_at timestamps for sync comparison.
  static Map<String, DateTime> getChatTimestamps() {
    final timestamps = <String, DateTime>{};
    for (final chat in chatsById.values) {
      timestamps[chat.id] = chat.updatedAt ?? chat.createdAt;
    }
    return timestamps;
  }

  /// Reset all state
  static Future<void> reset() async {
    chatsById.clear();
    selectedChatIndex = -1;
    selectedChatIdNotifier.value = null;
    isMessageOperationInProgress = false;
    activeMessageChatId = null;
    savingChats.clear();
    pendingSaves.clear();
    cacheLoaded = false;
    initialSyncComplete = false;
    loadingCompleter = null;
    _notifyDebounceTimer?.cancel();
    _pendingNotifications.clear();
    notifyChangesImmediate();
  }
}
