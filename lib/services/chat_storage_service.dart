// lib/services/chat_storage_service.dart
import 'dart:async';
import 'dart:convert';

import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/image_storage_service.dart';
import 'package:chuk_chat/services/local_chat_cache_service.dart';
import 'package:chuk_chat/services/network_status_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

const int _kChatPayloadVersion = 2;

/// Pre-cached SharedPreferences instance for fast access
SharedPreferences? _sharedPrefsInstance;

/// Pre-initialize SharedPreferences at app startup for instant cache access
Future<void> initChatStorageCache() async {
  _sharedPrefsInstance ??= await SharedPreferences.getInstance();
}

/// Result from background JSON deserialization
/// Using Maps instead of ChatMessage to cross isolate boundary efficiently
class _DeserializeResult {
  _DeserializeResult(this.messages, {this.customName});
  final List<Map<String, dynamic>> messages;
  final String? customName;
}

/// Top-level function for background JSON deserialization
/// Must be top-level (not a class method) to work with compute()
_DeserializeResult _deserializePayloadIsolate(String json) {
  final Map<String, dynamic> map = jsonDecode(json) as Map<String, dynamic>;
  final int version = (map['v'] as int?) ?? 1;
  final String? customName = map['customName'] as String?;

  if (version == 2) {
    final List<dynamic> rawMessages = map['messages'] as List<dynamic>;
    final messages = rawMessages
        .map((m) => m as Map<String, dynamic>)
        .toList();
    return _DeserializeResult(messages, customName: customName);
  }

  // Version 1 migration - normalize field names
  final List<dynamic> rawMessages = map['messages'] as List<dynamic>;
  final messages = rawMessages.map((m) {
    final msg = m as Map<String, dynamic>;
    return <String, dynamic>{
      'role': msg['role'] as String? ?? 'user',
      'text': msg['text'] as String? ?? '',
      if (msg['reasoning'] != null) 'reasoning': msg['reasoning'],
    };
  }).toList();
  return _DeserializeResult(messages, customName: customName);
}

/// Represents a single message in a chat.
class ChatMessage {
  ChatMessage({
    required this.role,
    required this.text,
    this.reasoning,
    this.images,
    this.attachments,
    this.modelId,
    this.provider,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      role: json['role'] as String? ?? json['sender'] as String? ?? 'user',
      text: json['text'] as String? ?? '',
      reasoning: json['reasoning'] as String?,
      images: json['images'] as String?,
      attachments: json['attachments'] as String?,
      modelId: json['modelId'] as String?,
      provider: json['provider'] as String?,
    );
  }

  final String role;
  final String text;
  final String? reasoning;
  final String? images;
  final String? attachments;
  final String? modelId;
  final String? provider;

  // Alias for backwards compatibility
  String get sender => role == 'assistant' ? 'ai' : role;

  Map<String, dynamic> toJson() => {
    'role': role,
    'text': text,
    if (reasoning != null && reasoning!.isNotEmpty) 'reasoning': reasoning,
    if (images != null && images!.isNotEmpty) 'images': images,
    if (attachments != null && attachments!.isNotEmpty)
      'attachments': attachments,
    if (modelId != null && modelId!.isNotEmpty) 'modelId': modelId,
    if (provider != null && provider!.isNotEmpty) 'provider': provider,
  };
}

class _ChatPayload {
  _ChatPayload(this.messages, {this.customName});
  final List<ChatMessage> messages;
  final String? customName;
}

/// Represents a stored chat with metadata.
/// Supports lazy loading: initially only title is loaded, messages loaded on demand.
class StoredChat {
  StoredChat({
    required this.id,
    List<ChatMessage>? messages,
    required this.createdAt,
    required this.isStarred,
    this.title,
    this.customName,
    this.updatedAt,
  }) : _messages = messages != null ? List<ChatMessage>.unmodifiable(messages) : null;

  /// Create a lightweight chat for sidebar (title only, no messages)
  factory StoredChat.forSidebar({
    required String id,
    required DateTime createdAt,
    required bool isStarred,
    String? title,
    String? customName,
    DateTime? updatedAt,
  }) {
    return StoredChat(
      id: id,
      messages: null, // No messages - lazy loaded
      createdAt: createdAt,
      isStarred: isStarred,
      title: title,
      customName: customName,
      updatedAt: updatedAt,
    );
  }

  final String id;
  final List<ChatMessage>? _messages;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final bool isStarred;
  final String? customName;

  /// Decrypted title for sidebar display (from encrypted_title column)
  final String? title;

  /// Get messages - throws if not fully loaded
  List<ChatMessage> get messages {
    if (_messages == null) {
      throw StateError('Chat messages not loaded. Call ChatStorageService.loadFullChat first.');
    }
    return _messages;
  }

  /// Check if this chat has its messages loaded
  bool get isFullyLoaded => _messages != null;

  /// Get messages or null if not loaded (safe access)
  List<ChatMessage>? get messagesOrNull => _messages;

  /// Get a preview of the chat (first user message or first message text)
  /// Falls back to title if messages not loaded
  String get previewText {
    // If we have a title, use it (faster than iterating messages)
    if (title != null && title!.isNotEmpty) {
      return title!.length > 100 ? '${title!.substring(0, 100)}...' : title!;
    }

    // If messages not loaded, return empty
    if (_messages == null || _messages.isEmpty) return '';

    // Try to find first user message
    for (final msg in _messages) {
      if (msg.role == 'user' && msg.text.isNotEmpty) {
        return msg.text.length > 100
            ? '${msg.text.substring(0, 100)}...'
            : msg.text;
      }
    }
    // Fall back to first message
    final first = _messages.first.text;
    return first.length > 100 ? '${first.substring(0, 100)}...' : first;
  }

  factory StoredChat.fromRow(
    Map<String, dynamic> row,
    List<ChatMessage> messages, {
    String? customName,
    String? title,
  }) {
    return StoredChat(
      id: row['id'] as String,
      messages: messages,
      createdAt: DateTime.parse(row['created_at'] as String),
      updatedAt: row['updated_at'] != null
          ? DateTime.parse(row['updated_at'] as String)
          : null,
      isStarred: (row['is_starred'] as bool?) ?? false,
      customName: customName,
      title: title,
    );
  }

  /// Create from row with title only (for sidebar)
  factory StoredChat.fromRowTitleOnly(
    Map<String, dynamic> row, {
    String? title,
  }) {
    return StoredChat.forSidebar(
      id: row['id'] as String,
      createdAt: DateTime.parse(row['created_at'] as String),
      updatedAt: row['updated_at'] != null
          ? DateTime.parse(row['updated_at'] as String)
          : null,
      isStarred: (row['is_starred'] as bool?) ?? false,
      title: title,
    );
  }

  StoredChat copyWith({
    String? id,
    List<ChatMessage>? messages,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool? isStarred,
    String? customName,
    String? title,
  }) {
    return StoredChat(
      id: id ?? this.id,
      messages: messages ?? _messages,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      isStarred: isStarred ?? this.isStarred,
      customName: customName ?? this.customName,
      title: title ?? this.title,
    );
  }

  /// Create a fully loaded version of this chat
  StoredChat withMessages(List<ChatMessage> messages, {String? customName}) {
    return StoredChat(
      id: id,
      messages: messages,
      createdAt: createdAt,
      updatedAt: updatedAt,
      isStarred: isStarred,
      customName: customName ?? this.customName,
      title: title,
    );
  }
}

class ChatStorageService {
  // SINGLE SOURCE OF TRUTH - all chats stored here
  static final Map<String, StoredChat> _chatsById = <String, StoredChat>{};

  /// Stream controller that emits the changed chat ID, or null for bulk changes.
  /// This allows listeners to only rebuild affected items instead of everything.
  static final StreamController<String?> _changesController =
      StreamController<String?>.broadcast();

  // Debounce for _notifyChanges to prevent rapid-fire UI rebuilds
  static Timer? _notifyDebounceTimer;
  static final Set<String?> _pendingNotifications = <String?>{};
  static const Duration _notifyDebounceDelay = Duration(milliseconds: 100);

  /// Track if initial sync has completed (for ChatSyncService coordination)
  static bool _initialSyncComplete = false;
  static bool get initialSyncComplete => _initialSyncComplete;
  static int selectedChatIndex = -1;

  /// ID-BASED SELECTION: The currently selected chat ID.
  /// null = new chat (no chat selected yet)
  /// This is the primary source of truth for which chat is active.
  static String? _selectedChatId;
  static String? get selectedChatId => _selectedChatId;
  static set selectedChatId(String? value) {
    if (_selectedChatId != value) {
      debugPrint('');
      debugPrint('┌─────────────────────────────────────────────────────────────');
      debugPrint('│ 📍 [SELECTED-CHAT-ID] CHANGED');
      debugPrint('│ 📍 [SELECTED-CHAT-ID] OLD: $_selectedChatId');
      debugPrint('│ 📍 [SELECTED-CHAT-ID] NEW: $value');
      debugPrint('│ 📍 [SELECTED-CHAT-ID] Stack trace:');
      try {
        throw Exception('Stack trace');
      } catch (e, st) {
        final lines = st.toString().split('\n').take(8).join('\n│    ');
        debugPrint('│    $lines');
      }
      debugPrint('└─────────────────────────────────────────────────────────────');
    }
    _selectedChatId = value;
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
  static const Uuid _uuid = Uuid();

  // Track chats we're currently saving to ignore realtime events for them
  static final Set<String> _savingChats = <String>{};

  // Prevent concurrent save operations
  static final Map<String, Completer<StoredChat?>> _pendingSaves =
      <String, Completer<StoredChat?>>{};

  // Cache-first loading: track if cache has been loaded
  static bool _cacheLoaded = false;

  // Prevent concurrent loadChats() calls
  static Completer<void>? _loadingCompleter;
  static bool get _isLoading =>
      _loadingCompleter != null && !_loadingCompleter!.isCompleted;

  // Get chats as a sorted list (most recent first)
  static List<StoredChat> get savedChats {
    final list = _chatsById.values.toList();
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return List.unmodifiable(list);
  }

  /// Get a chat by its ID (returns null if not found)
  static StoredChat? getChatById(String chatId) {
    return _chatsById[chatId];
  }

  /// Extract title from messages (first user message, truncated)
  static String _extractTitleFromMessages(List<ChatMessage> messages) {
    if (messages.isEmpty) return '';
    for (final msg in messages) {
      if (msg.role == 'user' && msg.text.isNotEmpty) {
        // Truncate to reasonable title length (100 chars)
        return msg.text.length > 100
            ? '${msg.text.substring(0, 100)}...'
            : msg.text;
      }
    }
    // Fall back to first message
    final first = messages.first.text;
    return first.length > 100 ? '${first.substring(0, 100)}...' : first;
  }

  /// Load a single chat's full content (messages) on demand.
  /// Used for lazy loading when user clicks on a chat in sidebar.
  /// Returns the fully loaded chat or null if not found/error.
  static Future<StoredChat?> loadFullChat(String chatId) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) return null;

    debugPrint('📂 [ChatStorage] Loading full chat: $chatId');
    final stopwatch = Stopwatch()..start();

    try {
      // Check if already fully loaded
      final existing = _chatsById[chatId];
      if (existing != null && existing.isFullyLoaded) {
        debugPrint('✅ [ChatStorage] Chat already fully loaded (${stopwatch.elapsedMilliseconds}ms)');
        return existing;
      }

      // Fetch full payload from Supabase
      final rows = await SupabaseService.client
          .from('encrypted_chats')
          .select('id, encrypted_payload, created_at, is_starred, updated_at, encrypted_title')
          .eq('id', chatId)
          .eq('user_id', user.id)
          .limit(1);

      if (rows.isEmpty) {
        debugPrint('⚠️ [ChatStorage] Chat not found: $chatId');
        return null;
      }

      final row = rows.first;
      final encryptedPayload = row['encrypted_payload'] as String?;
      if (encryptedPayload == null || encryptedPayload.isEmpty) {
        debugPrint('⚠️ [ChatStorage] Chat has no payload: $chatId');
        return null;
      }

      // Decrypt payload in background isolate
      final decrypted = await EncryptionService.decryptInBackground(encryptedPayload);
      final chatPayload = await _deserializePayloadAsync(decrypted);

      // Create fully loaded chat
      final chat = StoredChat.fromRow(
        row,
        chatPayload.messages,
        customName: chatPayload.customName,
        title: existing?.title, // Preserve existing title
      );

      // Update in memory
      _chatsById[chatId] = chat;
      _notifyChanges(chatId);

      stopwatch.stop();
      debugPrint('✅ [ChatStorage] Full chat loaded in ${stopwatch.elapsedMilliseconds}ms (${chatPayload.messages.length} messages)');

      return chat;
    } on SecretBoxAuthenticationError {
      debugPrint('🔐 [ChatStorage] Failed to decrypt chat: $chatId');
      return null;
    } catch (e) {
      debugPrint('❌ [ChatStorage] Error loading full chat: $e');
      return null;
    }
  }

  /// Decrypt title-only batch for sidebar (much faster than full payloads)
  static Future<List<StoredChat?>> _decryptTitlesBatch(
    List<Map<String, dynamic>> rows,
  ) async {
    if (rows.isEmpty) return [];

    // Extract encrypted titles
    final encryptedTitles = <String>[];
    final validIndices = <int>[];

    for (int i = 0; i < rows.length; i++) {
      final encryptedTitle = rows[i]['encrypted_title'] as String?;
      if (encryptedTitle != null && encryptedTitle.isNotEmpty) {
        encryptedTitles.add(encryptedTitle);
        validIndices.add(i);
      }
    }

    // Initialize results with title-only chats (no decryption needed for those without encrypted_title)
    final results = List<StoredChat?>.filled(rows.length, null);

    // Create title-only chats for ALL rows first (even those without encrypted_title)
    for (int i = 0; i < rows.length; i++) {
      results[i] = StoredChat.fromRowTitleOnly(rows[i]);
    }

    // If we have encrypted titles, batch decrypt them
    if (encryptedTitles.isNotEmpty) {
      try {
        final decryptedTitles = await EncryptionService.decryptBatchInBackground(encryptedTitles);

        for (int j = 0; j < validIndices.length; j++) {
          final i = validIndices[j];
          final decryptedTitle = decryptedTitles[j];
          if (decryptedTitle != null) {
            results[i] = StoredChat.fromRowTitleOnly(rows[i], title: decryptedTitle);
          }
        }
      } catch (e) {
        debugPrint('⚠️ [ChatStorage] Title batch decryption failed: $e');
        // Continue with title-less chats
      }
    }

    return results;
  }

  /// Stream of chat changes. Emits the changed chat ID, or null for bulk changes.
  /// Listeners can use this to only rebuild affected items.
  static Stream<String?> get changes => _changesController.stream;

  /// Notify listeners of a change. Pass chatId for single-chat updates,
  /// or null for bulk changes (e.g., initial load, sync).
  /// Uses debouncing to prevent rapid-fire UI rebuilds during sync operations.
  static void _notifyChanges([String? chatId]) {
    if (_changesController.isClosed) return;

    // Collect pending notifications
    _pendingNotifications.add(chatId);

    // Cancel existing timer
    _notifyDebounceTimer?.cancel();

    // Start new debounce timer
    _notifyDebounceTimer = Timer(_notifyDebounceDelay, () {
      if (_changesController.isClosed) return;

      // If any notification is null (bulk change), just emit null once
      if (_pendingNotifications.contains(null)) {
        _changesController.add(null);
      } else {
        // Emit individual chat IDs
        for (final id in _pendingNotifications) {
          _changesController.add(id);
        }
      }
      _pendingNotifications.clear();
    });
  }

  /// Notify immediately without debounce (for critical updates like cache load)
  static void _notifyChangesImmediate([String? chatId]) {
    if (!_changesController.isClosed) {
      _changesController.add(chatId);
    }
  }

  /// Check network status for offline handling
  static Future<bool> _checkNetworkStatus() async {
    try {
      return await NetworkStatusService.hasInternetConnection(
        timeout: const Duration(seconds: 2),
      );
    } catch (_) {
      return false;
    }
  }

  /// Decrypt a single chat row. Returns null if decryption fails.
  /// Note: Use _decryptChatRowsBatch for multiple rows (better performance).
  // ignore: unused_element
  static Future<StoredChat?> _decryptChatRow(Map<String, dynamic> row) async {
    final encryptedPayload = row['encrypted_payload'] as String?;
    if (encryptedPayload == null || encryptedPayload.isEmpty) return null;

    try {
      final decrypted =
          await EncryptionService.decryptInBackground(encryptedPayload);
      final chatPayload = await _deserializePayloadAsync(decrypted);
      return StoredChat.fromRow(
        row,
        chatPayload.messages,
        customName: chatPayload.customName,
      );
    } on SecretBoxAuthenticationError {
      return null;
    } on FormatException {
      return null;
    } on StateError {
      return null;
    }
  }

  /// Load chats from local cache only (instant, no network).
  /// Call this for immediate UI population, then sync in background.
  static Future<void> loadFromCache() async {
    if (_cacheLoaded && _chatsById.isNotEmpty) return;

    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      _chatsById.clear();
      _notifyChanges();
      return;
    }

    try {
      final rows = await LocalChatCacheService.load(user.id);
      if (rows.isEmpty) {
        debugPrint('📦 [ChatStorage] Cache empty');
        return;
      }

      debugPrint('📦 [ChatStorage] Loading ${rows.length} chats from cache...');

      // Progressive loading: first batch for fast UI, then rest in background
      const int firstBatchSize = 15;
      final firstBatch = rows.take(firstBatchSize).toList();
      final remainingBatch = rows.skip(firstBatchSize).toList();

      _chatsById.clear();

      // Batch decrypt first 15 chats in ONE isolate (much faster!)
      final firstChats = await _decryptChatRowsBatch(firstBatch);
      for (final chat in firstChats) {
        if (chat != null) {
          _chatsById[chat.id] = chat;
        }
      }

      _cacheLoaded = true;

      // Notify UI immediately with first batch
      if (_chatsById.isNotEmpty) {
        _notifyChanges();
        debugPrint(
          '⚡ [ChatStorage] First ${_chatsById.length} chats from cache (fast)',
        );
      }

      // Decrypt remaining in background (also batched)
      if (remainingBatch.isNotEmpty) {
        final remainingChats = await _decryptChatRowsBatch(remainingBatch);
        for (final chat in remainingChats) {
          if (chat != null) {
            _chatsById[chat.id] = chat;
          }
        }
        _notifyChanges();
      }

      debugPrint('✅ [ChatStorage] Loaded ${_chatsById.length} chats from cache');
    } catch (e) {
      debugPrint('❌ [ChatStorage] Cache load failed: $e');
    }
  }

  /// Batch decrypt multiple chat rows in a single isolate
  /// Much faster than decrypting one by one
  static Future<List<StoredChat?>> _decryptChatRowsBatch(
    List<Map<String, dynamic>> rows,
  ) async {
    if (rows.isEmpty) return [];

    // Extract encrypted payloads
    final encryptedPayloads = <String>[];
    final validIndices = <int>[];

    for (int i = 0; i < rows.length; i++) {
      final payload = rows[i]['encrypted_payload'] as String?;
      if (payload != null && payload.isNotEmpty) {
        encryptedPayloads.add(payload);
        validIndices.add(i);
      }
    }

    if (encryptedPayloads.isEmpty) return List.filled(rows.length, null);

    // Batch decrypt all payloads in one isolate
    final decryptedList = await EncryptionService.decryptBatchInBackground(
      encryptedPayloads,
    );

    // Deserialize and create StoredChat objects
    final results = List<StoredChat?>.filled(rows.length, null);

    for (int j = 0; j < validIndices.length; j++) {
      final i = validIndices[j];
      final decrypted = decryptedList[j];
      if (decrypted == null) continue;

      try {
        final chatPayload = await _deserializePayloadAsync(decrypted);
        results[i] = StoredChat.fromRow(
          rows[i],
          chatPayload.messages,
          customName: chatPayload.customName,
        );
      } catch (_) {
        // Skip invalid chats
      }
    }

    return results;
  }

  /// Load all chats from Supabase or cache
  static Future<void> loadChats() async {
    // Prevent concurrent loads - wait for existing operation
    if (_isLoading) {
      debugPrint('⏳ [ChatStorage] Load already in progress, waiting...');
      return _loadingCompleter!.future;
    }
    _loadingCompleter = Completer<void>();

    try {
      final user = SupabaseService.auth.currentUser;
      if (user == null) {
        debugPrint('⚠️ [ChatStorage] No user signed in, clearing chats');
        _chatsById.clear();
        _notifyChanges();
        return;
      }

      List<Map<String, dynamic>> rows = [];
      bool loadedFromCache = false;
      Object? remoteError;
      StackTrace? remoteStack;

      final isOnline = await _checkNetworkStatus();

      if (isOnline) {
        try {
          debugPrint('🌐 [ChatStorage] Network status: ONLINE');
          rows = await SupabaseService.client
              .from('encrypted_chats')
              .select('id, encrypted_payload, created_at, is_starred, updated_at')
              .eq('user_id', user.id)
              .order('created_at', ascending: false);
          debugPrint('✅ [ChatStorage] Loaded ${rows.length} chats from remote');

          // Update cache with remote data (use replaceAll to avoid race conditions)
          unawaited(LocalChatCacheService.replaceAll(user.id, rows));
        } catch (error, stackTrace) {
          remoteError = error;
          remoteStack = stackTrace;
          debugPrint('❌ [ChatStorage] Failed to load from remote: $error');

          // Fall back to cache
          try {
            rows = await LocalChatCacheService.load(user.id);
            loadedFromCache = true;
            debugPrint(
              '📦 [ChatStorage] Loaded ${rows.length} chats from cache (fallback)',
            );
          } catch (cacheError) {
            debugPrint('❌ [ChatStorage] Failed to load from cache: $cacheError');
            rows = [];
          }
        }
      } else {
        debugPrint('🌐 [ChatStorage] Network status: OFFLINE');
        try {
          rows = await LocalChatCacheService.load(user.id);
          loadedFromCache = true;
          debugPrint(
            '📦 [ChatStorage] Loaded ${rows.length} chats from cache (offline)',
          );
        } catch (error) {
          debugPrint('❌ [ChatStorage] Failed to load from cache: $error');
          rows = [];
        }
      }

      // Clear and rebuild the chats map
      _chatsById.clear();

      // Progressive loading: decrypt first batch immediately for fast UI,
      // then decrypt remaining chats in background
      const int firstBatchSize = 15;
      final firstBatch = rows.take(firstBatchSize).toList();
      final remainingBatch = rows.skip(firstBatchSize).toList();

      // Batch decrypt first 15 chats in ONE isolate (much faster!)
      final firstChats = await _decryptChatRowsBatch(firstBatch);
      for (final chat in firstChats) {
        if (chat != null) {
          _chatsById[chat.id] = chat;
        }
      }

      // Notify UI immediately so sidebar shows first chats
      if (_chatsById.isNotEmpty) {
        _notifyChanges();
        debugPrint(
          '⚡ [ChatStorage] First ${_chatsById.length} chats ready (fast path)',
        );
      }

      // Decrypt remaining chats in background (also batched)
      if (remainingBatch.isNotEmpty) {
        debugPrint(
          '🔄 [ChatStorage] Decrypting ${remainingBatch.length} more chats in background...',
        );
        final remainingChats = await _decryptChatRowsBatch(remainingBatch);
        for (final chat in remainingChats) {
          if (chat != null) {
            _chatsById[chat.id] = chat;
          }
        }
        _notifyChanges();
        debugPrint(
          '✅ [ChatStorage] All ${_chatsById.length} chats loaded',
        );
      } else if (_chatsById.isEmpty) {
        // No chats at all - still notify
        _notifyChanges();
      }

      // Log all loaded chats for debugging
      if (_chatsById.isNotEmpty) {
        debugPrint(
            '📋 [ChatStorage] Current chats in memory (${_chatsById.length}):');
        for (final entry in _chatsById.entries) {
          final chat = entry.value;
          final firstUserMsg =
              chat.messages.where((m) => m.role == 'user').firstOrNull;
          final title = (firstUserMsg?.text.length ?? 0) > 40
              ? '${firstUserMsg!.text.substring(0, 40)}...'
              : (firstUserMsg?.text ?? 'No user message');
          debugPrint(
              '   - ${entry.key.substring(0, 8)}... : "$title" (${chat.messages.length} msgs)');
        }
      }

      if (loadedFromCache && remoteError != null) {
        debugPrint(
          'ChatStorageService loaded chats from offline cache: $remoteError',
        );
        if (remoteStack != null) {
          debugPrint('Stack trace: $remoteStack');
        }
      }
    } finally {
      _loadingCompleter?.complete();
      _loadingCompleter = null;
    }
  }

  // ignore: unused_element
  static _ChatPayload _deserializePayload(String json) {
    final Map<String, dynamic> map = jsonDecode(json) as Map<String, dynamic>;
    final int version = (map['v'] as int?) ?? 1;
    final String? customName = map['customName'] as String?;

    if (version == 2) {
      final List<dynamic> rawMessages = map['messages'] as List<dynamic>;
      final messages = rawMessages
          .map((m) => ChatMessage.fromJson(m as Map<String, dynamic>))
          .toList();
      return _ChatPayload(messages, customName: customName);
    }

    // Version 1 migration
    final List<dynamic> rawMessages = map['messages'] as List<dynamic>;
    final messages = rawMessages.map((m) {
      final msg = m as Map<String, dynamic>;
      return ChatMessage(
        role: msg['role'] as String? ?? 'user',
        text: msg['text'] as String? ?? '',
        reasoning: msg['reasoning'] as String?,
      );
    }).toList();
    return _ChatPayload(messages, customName: customName);
  }

  /// Deserialize chat payload in background isolate to avoid UI blocking
  static Future<_ChatPayload> _deserializePayloadAsync(String json) async {
    final result = await compute(_deserializePayloadIsolate, json);
    // Convert maps to ChatMessage objects (fast, just object instantiation)
    final messages = result.messages
        .map((m) => ChatMessage.fromJson(m))
        .toList();
    return _ChatPayload(messages, customName: result.customName);
  }

  /// Extract image storage paths from messages
  /// Images are stored as JSON arrays in the 'images' field of messages
  /// Each entry can be a storage path (like "user-id/uuid.enc") or a base64 data URL
  /// We only want storage paths for cleanup purposes
  static List<String> _extractImagePaths(List<ChatMessage> messages) {
    final paths = <String>[];
    for (final msg in messages) {
      if (msg.images != null && msg.images!.isNotEmpty) {
        try {
          final imagesData = jsonDecode(msg.images!) as List<dynamic>;
          for (final img in imagesData) {
            final imgStr = img.toString();
            // Storage paths end with .enc and contain a user ID pattern
            // They look like: "user-uuid/image-uuid.enc"
            if (imgStr.endsWith('.enc') && imgStr.contains('/')) {
              paths.add(imgStr);
            }
          }
        } catch (_) {
          // Invalid JSON, skip
        }
      }
    }
    return paths;
  }

  static List<ChatMessage> _mapToChatMessages(
    List<Map<String, dynamic>> messagesMaps,
  ) {
    return messagesMaps.where((m) => m['text']?.toString() != 'Thinking...').map((
      m,
    ) {
      // UI uses 'sender' with 'user'/'ai', convert to 'role' with 'user'/'assistant'
      String role;
      final sender = m['sender'] as String?;
      final rawRole = m['role'] as String?;

      if (sender != null) {
        // Convert sender format to role format
        role = sender == 'ai' ? 'assistant' : sender;
      } else if (rawRole != null) {
        role = rawRole;
      } else {
        role = 'user';
      }

      return ChatMessage(
        role: role,
        text: m['text'] as String? ?? '',
        reasoning: m['reasoning'] as String?,
        images: m['images'] as String?,
        attachments: m['attachments'] as String?,
        modelId: m['modelId'] as String?,
        provider: m['provider'] as String?,
      );
    }).toList();
  }

  /// Save a new chat to Supabase
  static Future<StoredChat?> saveChat(
    List<Map<String, dynamic>> messagesMaps, {
    String? chatId,
  }) async {
    // CRITICAL: Always use a proper UUID to ensure _savingChats tracks the same ID
    // that gets inserted into Supabase. This prevents race conditions with realtime events.
    final effectiveChatId = chatId ?? _uuid.v4();
    debugPrint(
      '💾 [ChatStorage] saveChat: $effectiveChatId (${messagesMaps.length} messages)',
    );

    // If there's already a pending save for this chat, wait for it
    if (_pendingSaves.containsKey(effectiveChatId)) {
      debugPrint('⏳ [ChatStorage] Waiting for pending save: $effectiveChatId');
      return await _pendingSaves[effectiveChatId]!.future;
    }

    // If chat already exists, update it instead
    if (_chatsById.containsKey(effectiveChatId)) {
      debugPrint('🔄 [ChatStorage] Chat exists, updating: $effectiveChatId');
      return await updateChat(effectiveChatId, messagesMaps);
    }

    final completer = Completer<StoredChat?>();
    _pendingSaves[effectiveChatId] = completer;
    _savingChats.add(effectiveChatId);

    try {
      final result = await _doSaveChat(messagesMaps, effectiveChatId);
      completer.complete(result);
      return result;
    } catch (e) {
      completer.completeError(e);
      rethrow;
    } finally {
      _pendingSaves.remove(effectiveChatId);
      // Keep in _savingChats for a bit longer to block realtime events
      Future.delayed(const Duration(seconds: 2), () {
        _savingChats.remove(effectiveChatId);
      });
    }
  }

  static Future<StoredChat?> _doSaveChat(
    List<Map<String, dynamic>> messagesMaps,
    String effectiveChatId,
  ) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to store chats.');
    }

    if (!EncryptionService.hasKey) {
      final loaded = await EncryptionService.tryLoadKey();
      if (!loaded) {
        throw StateError('Encryption key is missing. Please sign in again.');
      }
    }

    final messages = _mapToChatMessages(messagesMaps);
    if (messages.isEmpty) {
      debugPrint('⚠️ [ChatStorage] No messages to save');
      return null;
    }

    final payload = jsonEncode({
      'v': _kChatPayloadVersion,
      'messages': messages.map((m) => m.toJson()).toList(),
    });

    final encryptedPayload = await EncryptionService.encrypt(payload);

    // Extract and encrypt title separately for fast sidebar loading
    final title = _extractTitleFromMessages(messages);
    final encryptedTitle = title.isNotEmpty
        ? await EncryptionService.encrypt(title)
        : null;

    // Extract image paths for cleanup on delete
    final imagePaths = _extractImagePaths(messages);

    // CRITICAL: Always include the effectiveChatId in the insert.
    // This ensures the ID we track in _savingChats matches the ID in Supabase,
    // preventing race conditions with realtime events that could cause duplicates.
    final Map<String, dynamic> insertData = {
      'id': effectiveChatId,
      'user_id': user.id,
      'encrypted_payload': encryptedPayload,
      if (encryptedTitle != null) 'encrypted_title': encryptedTitle,
      if (imagePaths.isNotEmpty) 'image_paths': imagePaths,
    };

    final inserted = await SupabaseService.client
        .from('encrypted_chats')
        .insert(insertData)
        .select('id, encrypted_payload, created_at, is_starred, updated_at, encrypted_title')
        .single();

    final String finalId = inserted['id'] as String;
    final chat = StoredChat.fromRow(inserted, messages, title: title);

    // Add to our map - this is the ONLY place we add new chats
    _chatsById[finalId] = chat;
    _notifyChanges(finalId);

    unawaited(LocalChatCacheService.upsert(user.id, inserted));

    // Log with title for debugging
    final displayTitle = title.length > 50 ? '${title.substring(0, 50)}...' : title;
    debugPrint('✅ [ChatStorage] Saved new chat: $finalId');
    debugPrint('   📝 Title: "$displayTitle"');
    debugPrint('   📊 Messages: ${messages.length} (${messages.where((m) => m.role == "user").length} user, ${messages.where((m) => m.role == "assistant").length} assistant)');

    return chat;
  }

  /// Update an existing chat
  static Future<StoredChat?> updateChat(
    String chatId,
    List<Map<String, dynamic>> messagesMaps,
  ) async {
    debugPrint(
      '🔄 [ChatStorage] updateChat: $chatId (${messagesMaps.length} messages)',
    );

    // If there's already a pending save for this chat, wait for it then try again
    if (_pendingSaves.containsKey(chatId)) {
      debugPrint('⏳ [ChatStorage] Waiting for pending operation: $chatId');
      await _pendingSaves[chatId]!.future;
    }

    final completer = Completer<StoredChat?>();
    _pendingSaves[chatId] = completer;
    _savingChats.add(chatId);

    try {
      final result = await _doUpdateChat(chatId, messagesMaps);
      completer.complete(result);
      return result;
    } catch (e) {
      completer.completeError(e);
      rethrow;
    } finally {
      _pendingSaves.remove(chatId);
      // Keep in _savingChats for a bit longer to block realtime events
      Future.delayed(const Duration(seconds: 2), () {
        _savingChats.remove(chatId);
      });
    }
  }

  static Future<StoredChat?> _doUpdateChat(
    String chatId,
    List<Map<String, dynamic>> messagesMaps,
  ) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to store chats.');
    }

    if (!EncryptionService.hasKey) {
      final loaded = await EncryptionService.tryLoadKey();
      if (!loaded) {
        throw StateError('Encryption key is missing. Please sign in again.');
      }
    }

    final messages = _mapToChatMessages(messagesMaps);
    if (messages.isEmpty) {
      debugPrint('⚠️ [ChatStorage] No messages to update');
      return null;
    }

    // Preserve existing customName
    final existingChat = _chatsById[chatId];
    final String? existingCustomName = existingChat?.customName;

    final Map<String, dynamic> payloadMap = {
      'v': _kChatPayloadVersion,
      'messages': messages.map((m) => m.toJson()).toList(),
    };
    if (existingCustomName != null) {
      payloadMap['customName'] = existingCustomName;
    }

    final encryptedPayload = await EncryptionService.encrypt(
      jsonEncode(payloadMap),
    );

    // Extract and encrypt title separately for fast sidebar loading
    final title = _extractTitleFromMessages(messages);
    final encryptedTitle = title.isNotEmpty
        ? await EncryptionService.encrypt(title)
        : null;

    // Extract image paths for cleanup on delete
    final imagePaths = _extractImagePaths(messages);

    final updatedRows = await SupabaseService.client
        .from('encrypted_chats')
        .update({
          'encrypted_payload': encryptedPayload,
          if (encryptedTitle != null) 'encrypted_title': encryptedTitle,
          'image_paths': imagePaths.isNotEmpty ? imagePaths : null,
        })
        .eq('id', chatId)
        .eq('user_id', user.id)
        .select('id, encrypted_payload, created_at, is_starred, updated_at, encrypted_title');

    if (updatedRows.isEmpty) {
      throw StateError('Chat not found or access denied.');
    }

    final updatedRow = updatedRows.first;
    final chat = StoredChat.fromRow(
      updatedRow,
      messages,
      customName: existingCustomName,
      title: title,
    );

    // Update in our map - this is the ONLY place we update chats
    _chatsById[chatId] = chat;
    _notifyChanges(chatId);

    unawaited(LocalChatCacheService.upsert(user.id, updatedRow));

    // Log with title for debugging
    final displayTitle = title.length > 50 ? '${title.substring(0, 50)}...' : title;
    debugPrint('✅ [ChatStorage] Updated chat: $chatId');
    debugPrint('   📝 Title: "$displayTitle"');
    debugPrint('   📊 Messages: ${messages.length} (${messages.where((m) => m.role == "user").length} user, ${messages.where((m) => m.role == "assistant").length} assistant)');

    return chat;
  }

  /// Delete a chat and its associated images from storage
  static Future<void> deleteChat(String chatId) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to delete chats.');
    }

    // First, fetch the image_paths before deleting the row
    List<String> imagePaths = [];
    try {
      final rows = await SupabaseService.client
          .from('encrypted_chats')
          .select('image_paths')
          .eq('id', chatId)
          .eq('user_id', user.id);

      if (rows.isNotEmpty && rows.first['image_paths'] != null) {
        final pathsData = rows.first['image_paths'];
        if (pathsData is List) {
          imagePaths = pathsData.cast<String>();
        }
      }
    } catch (e) {
      debugPrint('⚠️ [ChatStorage] Failed to fetch image_paths: $e');
      // Continue with deletion even if fetching paths fails
    }

    // Delete associated images from storage (best effort, don't block on failures)
    if (imagePaths.isNotEmpty) {
      debugPrint('🖼️ [ChatStorage] Deleting ${imagePaths.length} images for chat: $chatId');
      for (final path in imagePaths) {
        try {
          await ImageStorageService.deleteEncryptedImage(path);
          debugPrint('   ✅ Deleted image: $path');
        } catch (e) {
          debugPrint('   ⚠️ Failed to delete image $path: $e');
          // Continue deleting other images even if one fails
        }
      }
    }

    // Delete the chat row
    await SupabaseService.client
        .from('encrypted_chats')
        .delete()
        .eq('id', chatId)
        .eq('user_id', user.id);

    // Find the index of the chat being deleted BEFORE removal
    final deletedIndex = savedChats.indexWhere((c) => c.id == chatId);

    _chatsById.remove(chatId);
    _savingChats.remove(chatId);
    _pendingSaves.remove(chatId);

    // Adjust selectedChatIndex to account for index shifts
    if (deletedIndex != -1 && deletedIndex < selectedChatIndex) {
      // Chat was deleted before the selected one, shift index down
      selectedChatIndex -= 1;
    }

    // Always ensure selectedChatIndex is in bounds (handles concurrent deletions too)
    if (selectedChatIndex >= savedChats.length) {
      selectedChatIndex = savedChats.isEmpty ? -1 : savedChats.length - 1;
    }

    _notifyChanges(chatId);
    unawaited(LocalChatCacheService.delete(user.id, chatId));
    debugPrint('🗑️ [ChatStorage] Deleted chat: $chatId');
  }

  /// Load chats for sidebar - title-only for instant display.
  /// This is the main entry point for loading chats on startup.
  /// Strategy: Load from cache FIRST (instant), then let ChatSyncService handle network sync.
  static Future<void> loadSavedChatsForSidebar() async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      _chatsById.clear();
      _notifyChangesImmediate();
      return;
    }

    // Prevent concurrent loads
    if (_isLoading) {
      debugPrint('⏳ [ChatStorage] Sidebar load already in progress, waiting...');
      return _loadingCompleter!.future;
    }
    _loadingCompleter = Completer<void>();

    final stopwatch = Stopwatch()..start();

    try {
      // Load from local cache FIRST (instant UI)
      // ChatSyncService will handle network sync after this completes
      if (!_cacheLoaded) {
        await _loadTitlesFromCache(user.id);
        final cacheTime = stopwatch.elapsedMilliseconds;
        debugPrint('📦 [ChatStorage] Loaded ${_chatsById.length} chats from cache (${cacheTime}ms)');

        // Notify UI immediately WITHOUT debounce - critical for instant sidebar
        _notifyChangesImmediate();
        _cacheLoaded = true;

        debugPrint('✅ [ChatStorage] Sidebar ready in ${cacheTime}ms (UI notified)');
      }

      // Mark initial load complete - ChatSyncService can now start syncing
      _initialSyncComplete = true;

      stopwatch.stop();
    } catch (e) {
      debugPrint('❌ [ChatStorage] Sidebar load failed: $e');
      rethrow;
    } finally {
      _loadingCompleter?.complete();
      _loadingCompleter = null;
    }
  }

  /// Sync titles from network (public API for ChatSyncService)
  /// Call this after initial cache load to get updates from server.
  static Future<void> syncTitlesFromNetwork() async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) return;
    await _syncTitlesFromNetwork(user.id);
  }

  /// Load titles from local SharedPreferences cache (instant, no network, no decryption)
  static Future<void> _loadTitlesFromCache(String userId) async {
    final stopwatch = Stopwatch()..start();

    // Use pre-cached instance for speed, fallback to getInstance if not ready
    final prefs = _sharedPrefsInstance ?? await SharedPreferences.getInstance();
    final prefsTime = stopwatch.elapsedMilliseconds;

    final cacheKey = 'chat_titles_v1_$userId';
    final raw = prefs.getString(cacheKey);

    if (raw == null || raw.isEmpty) {
      debugPrint('📦 [ChatStorage] No title cache found (prefs: ${prefsTime}ms)');
      return;
    }

    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      final parseTime = stopwatch.elapsedMilliseconds;

      for (final item in decoded) {
        if (item is! Map<String, dynamic>) continue;
        final id = item['id'] as String?;
        if (id == null) continue;

        // Skip if we already have a fully loaded version
        final existing = _chatsById[id];
        if (existing != null && existing.isFullyLoaded) continue;

        _chatsById[id] = StoredChat.forSidebar(
          id: id,
          createdAt: DateTime.tryParse(item['created_at'] as String? ?? '') ?? DateTime.now(),
          isStarred: item['is_starred'] as bool? ?? false,
          title: item['title'] as String?,
          updatedAt: item['updated_at'] != null
              ? DateTime.tryParse(item['updated_at'] as String)
              : null,
        );
      }
      stopwatch.stop();
      debugPrint('📦 [ChatStorage] Cache: prefs=${prefsTime}ms, parse=${parseTime - prefsTime}ms, objects=${stopwatch.elapsedMilliseconds - parseTime}ms');
    } catch (e) {
      debugPrint('⚠️ [ChatStorage] Failed to parse title cache: $e');
    }
  }

  /// Sync titles from network and update cache (runs in background)
  /// Only notifies UI if there are actual changes to prevent unnecessary rebuilds.
  static Future<void> _syncTitlesFromNetwork(String userId) async {
    final stopwatch = Stopwatch()..start();
    bool hasChanges = false;

    try {
      debugPrint('🔄 [ChatStorage] Syncing titles from network...');

      final rows = await SupabaseService.client
          .from('encrypted_chats')
          .select('id, encrypted_title, created_at, is_starred, updated_at')
          .eq('user_id', userId)
          .order('created_at', ascending: false);

      debugPrint('📦 [ChatStorage] Fetched ${rows.length} chat metadata (${stopwatch.elapsedMilliseconds}ms)');

      if (rows.isEmpty) {
        if (_chatsById.isNotEmpty) {
          _chatsById.clear();
          hasChanges = true;
        }
        if (hasChanges) _notifyChanges();
        await _saveTitlesToCache(userId, []);
        return;
      }

      // Batch decrypt titles
      final chats = await _decryptTitlesBatch(rows);

      // Track existing IDs for deletion detection
      final oldIds = _chatsById.keys.toSet();
      final newIds = <String>{};

      // Merge with existing fully-loaded chats
      for (final chat in chats) {
        if (chat == null) continue;
        newIds.add(chat.id);

        final existing = _chatsById[chat.id];

        // Check if this is a new chat or has changes
        if (existing == null) {
          _chatsById[chat.id] = chat;
          hasChanges = true;
        } else if (existing.isStarred != chat.isStarred ||
                   existing.title != chat.title) {
          // Chat exists but has changes
          if (existing.isFullyLoaded) {
            _chatsById[chat.id] = existing.copyWith(
              isStarred: chat.isStarred,
              title: chat.title,
            );
          } else {
            _chatsById[chat.id] = chat;
          }
          hasChanges = true;
        }
        // If no changes, keep existing (preserves fully loaded state)
      }

      // Remove deleted chats
      final deletedIds = oldIds.difference(newIds);
      if (deletedIds.isNotEmpty) {
        for (final id in deletedIds) {
          _chatsById.remove(id);
        }
        hasChanges = true;
      }

      // Only notify if something changed
      if (hasChanges) {
        debugPrint('🔔 [ChatStorage] Changes detected, notifying UI');
        _notifyChanges();
      } else {
        debugPrint('✓ [ChatStorage] No changes detected, skipping UI notify');
      }

      // Always update cache (timestamps might have changed)
      await _saveTitlesToCache(userId, _chatsById.values.toList());

      stopwatch.stop();
      debugPrint('✅ [ChatStorage] Network sync complete (${stopwatch.elapsedMilliseconds}ms)');
    } catch (e) {
      debugPrint('⚠️ [ChatStorage] Network sync failed: $e');
    }
  }

  /// Save decrypted titles to local cache for instant loading
  static Future<void> _saveTitlesToCache(String userId, List<StoredChat> chats) async {
    // Use pre-cached instance for speed
    final prefs = _sharedPrefsInstance ?? await SharedPreferences.getInstance();
    final cacheKey = 'chat_titles_v1_$userId';

    final data = chats.map((chat) => {
      'id': chat.id,
      'title': chat.title ?? chat.previewText,
      'created_at': chat.createdAt.toIso8601String(),
      'is_starred': chat.isStarred,
      if (chat.updatedAt != null) 'updated_at': chat.updatedAt!.toIso8601String(),
    }).toList();

    await prefs.setString(cacheKey, jsonEncode(data));
    debugPrint('💾 [ChatStorage] Saved ${chats.length} titles to cache');
  }

  /// Set chat starred status
  static Future<void> setChatStarred(String chatId, bool isStarred) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to update chat favorites.');
    }

    final updatedRows = await SupabaseService.client
        .from('encrypted_chats')
        .update({'is_starred': isStarred})
        .eq('id', chatId)
        .eq('user_id', user.id)
        .select('is_starred');

    if (updatedRows.isEmpty) {
      throw StateError('Chat was not found or access is denied.');
    }

    final remoteStar = updatedRows.first['is_starred'] as bool;
    final existingChat = _chatsById[chatId];
    if (existingChat != null) {
      _chatsById[chatId] = existingChat.copyWith(isStarred: remoteStar);
      _notifyChanges(chatId);
    }

    unawaited(LocalChatCacheService.updateStarred(user.id, chatId, remoteStar));
  }

  /// Rename a chat
  static Future<void> renameChat(String chatId, String newName) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to rename chats.');
    }

    final chat = _chatsById[chatId];
    if (chat == null) {
      throw StateError('Chat not found.');
    }

    final updatedChat = chat.copyWith(customName: newName);
    final payload = jsonEncode({
      'v': _kChatPayloadVersion,
      'customName': newName,
      'messages': updatedChat.messages.map((m) => m.toJson()).toList(),
    });

    final encryptedPayload = await EncryptionService.encrypt(payload);
    final updatedRows = await SupabaseService.client
        .from('encrypted_chats')
        .update({'encrypted_payload': encryptedPayload})
        .eq('id', chatId)
        .eq('user_id', user.id)
        .select('id, encrypted_payload, created_at, is_starred, updated_at');

    if (updatedRows.isEmpty) {
      throw StateError('Chat was not found or access is denied.');
    }

    _chatsById[chatId] = updatedChat;
    _notifyChanges(chatId);
    unawaited(LocalChatCacheService.upsert(user.id, updatedRows.first));
  }

  /// Re-encrypt all chats with stored chat data
  static Future<void> reencryptChats(List<StoredChat> chats) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) return;

    for (final chat in chats) {
      final payload = jsonEncode({
        'v': _kChatPayloadVersion,
        'customName': chat.customName,
        'messages': chat.messages.map((m) => m.toJson()).toList(),
      });
      final encryptedPayload = await EncryptionService.encrypt(payload);

      final updatedRows = await SupabaseService.client
          .from('encrypted_chats')
          .update({'encrypted_payload': encryptedPayload})
          .eq('id', chat.id)
          .eq('user_id', user.id)
          .select('id, encrypted_payload, created_at, is_starred, updated_at');

      if (updatedRows.isNotEmpty) {
        final updatedRow = updatedRows.first;
        _chatsById[chat.id] = StoredChat.fromRow(
          updatedRow,
          chat.messages,
          customName: chat.customName,
        );
      }
    }
    _notifyChanges();
  }

  /// Export all chats
  static Future<String> exportChats() async {
    await loadChats();
    final exportPayload = savedChats
        .map(
          (chat) => {
            'id': chat.id,
            'createdAt': chat.createdAt.toIso8601String(),
            'messages': chat.messages.map((m) => m.toJson()).toList(),
            if (chat.customName != null) 'customName': chat.customName,
          },
        )
        .toList();
    return jsonEncode(exportPayload);
  }

  /// Export chats as JSON (alias for exportChats)
  static Future<String> exportChatsAsJson() async {
    return exportChats();
  }

  /// Reset all state
  static Future<void> reset() async {
    _chatsById.clear();
    selectedChatIndex = -1;
    selectedChatId = null;
    isMessageOperationInProgress = false;
    activeMessageChatId = null;
    _savingChats.clear();
    _pendingSaves.clear();
    _cacheLoaded = false;
    _initialSyncComplete = false;
    _loadingCompleter = null;
    _notifyDebounceTimer?.cancel();
    _pendingNotifications.clear();
    _notifyChangesImmediate();
  }

  // ============================================================================
  // SYNC SUPPORT METHODS
  // ============================================================================

  /// Merge a synced chat from cloud into local state.
  /// Called by ChatSyncService when new or updated chats are detected.
  /// IMPORTANT: Uses background decryption to avoid blocking UI.
  static Future<void> mergeSyncedChat(Map<String, dynamic> row) async {
    final chatId = row['id'] as String;

    // Skip if we're currently saving this chat (to avoid conflicts)
    if (_savingChats.contains(chatId)) {
      debugPrint('⏭️ [ChatStorage] Skipping sync for chat being saved: $chatId');
      return;
    }

    // Skip if there's a pending save operation
    if (_pendingSaves.containsKey(chatId)) {
      debugPrint('⏭️ [ChatStorage] Skipping sync for chat with pending save: $chatId');
      return;
    }

    final encryptedPayload = row['encrypted_payload'] as String?;
    if (encryptedPayload == null || encryptedPayload.isEmpty) return;

    try {
      // Use background decryption to avoid blocking UI thread
      final decrypted = await EncryptionService.decryptInBackground(encryptedPayload);
      // Use async deserialization to avoid blocking UI thread
      final chatPayload = await _deserializePayloadAsync(decrypted);
      final chat = StoredChat.fromRow(
        row,
        chatPayload.messages,
        customName: chatPayload.customName,
      );

      final existingChat = _chatsById[chatId];
      final user = SupabaseService.auth.currentUser;

      if (existingChat != null) {
        // Only update if the synced version is actually newer
        final existingUpdatedAt = existingChat.updatedAt ?? existingChat.createdAt;
        final syncedUpdatedAt = chat.updatedAt ?? chat.createdAt;

        if (syncedUpdatedAt.isAfter(existingUpdatedAt)) {
          debugPrint('🔄 [ChatStorage] Updating chat from sync: $chatId');
          _chatsById[chatId] = chat;
          _notifyChanges(chatId);
          // Also update local cache for offline access
          if (user != null) {
            unawaited(LocalChatCacheService.upsert(user.id, row));
          }
        }
      } else {
        // New chat from another device
        debugPrint('➕ [ChatStorage] Adding new chat from sync: $chatId');
        _chatsById[chatId] = chat;
        _notifyChanges(chatId);
        // Also add to local cache for offline access
        if (user != null) {
          unawaited(LocalChatCacheService.upsert(user.id, row));
        }
      }
    } on SecretBoxAuthenticationError {
      debugPrint('🔐 [ChatStorage] Failed to decrypt synced chat: $chatId');
    } on FormatException catch (e) {
      debugPrint('📄 [ChatStorage] Invalid format for synced chat: $chatId - $e');
    } catch (e) {
      debugPrint('❌ [ChatStorage] Error merging synced chat: $chatId - $e');
    }
  }

  /// Batch merge multiple synced chats efficiently.
  /// Uses batch decryption in a single isolate to avoid UI blocking.
  static Future<void> mergeSyncedChatsBatch(List<Map<String, dynamic>> rows) async {
    if (rows.isEmpty) return;

    // Filter out chats we're currently saving or have pending saves
    final validRows = rows.where((row) {
      final chatId = row['id'] as String;
      if (_savingChats.contains(chatId)) {
        debugPrint('⏭️ [ChatStorage] Skipping sync for chat being saved: $chatId');
        return false;
      }
      if (_pendingSaves.containsKey(chatId)) {
        debugPrint('⏭️ [ChatStorage] Skipping sync for chat with pending save: $chatId');
        return false;
      }
      final payload = row['encrypted_payload'] as String?;
      return payload != null && payload.isNotEmpty;
    }).toList();

    if (validRows.isEmpty) return;

    debugPrint('🔄 [ChatStorage] Batch merging ${validRows.length} chats...');

    // Extract payloads for batch decryption
    final payloads = validRows.map((r) => r['encrypted_payload'] as String).toList();

    try {
      // Batch decrypt all payloads in a single isolate (much faster!)
      final decryptedList = await EncryptionService.decryptBatchInBackground(payloads);

      final user = SupabaseService.auth.currentUser;
      int addedCount = 0;
      int updatedCount = 0;

      for (int i = 0; i < validRows.length; i++) {
        final row = validRows[i];
        final decrypted = decryptedList[i];
        if (decrypted == null) continue;

        final chatId = row['id'] as String;

        try {
          final chatPayload = await _deserializePayloadAsync(decrypted);
          final chat = StoredChat.fromRow(
            row,
            chatPayload.messages,
            customName: chatPayload.customName,
          );

          final existingChat = _chatsById[chatId];

          if (existingChat != null) {
            final existingUpdatedAt = existingChat.updatedAt ?? existingChat.createdAt;
            final syncedUpdatedAt = chat.updatedAt ?? chat.createdAt;

            if (syncedUpdatedAt.isAfter(existingUpdatedAt)) {
              _chatsById[chatId] = chat;
              if (user != null) {
                unawaited(LocalChatCacheService.upsert(user.id, row));
              }
              updatedCount++;
            }
          } else {
            _chatsById[chatId] = chat;
            if (user != null) {
              unawaited(LocalChatCacheService.upsert(user.id, row));
            }
            addedCount++;
          }

          // Yield to UI thread periodically to prevent jank
          if (i % 10 == 0) {
            await Future.delayed(Duration.zero);
          }
        } catch (e) {
          debugPrint('❌ [ChatStorage] Error processing synced chat $chatId: $e');
        }
      }

      // Single notification after all chats processed
      if (addedCount > 0 || updatedCount > 0) {
        _notifyChanges();
        debugPrint('✅ [ChatStorage] Batch sync complete: $addedCount added, $updatedCount updated');
      }
    } catch (e) {
      debugPrint('❌ [ChatStorage] Batch merge failed: $e');
      // Fall back to individual processing
      for (final row in validRows) {
        await mergeSyncedChat(row);
      }
    }
  }

  /// Remove a chat from local state only (without database operation).
  /// Called by ChatSyncService when a chat was deleted on another device.
  static void removeChatLocally(String chatId) {
    if (!_chatsById.containsKey(chatId)) return;

    debugPrint('🗑️ [ChatStorage] Removing locally deleted chat: $chatId');

    // Find the index before removal
    final deletedIndex = savedChats.indexWhere((c) => c.id == chatId);

    _chatsById.remove(chatId);
    _savingChats.remove(chatId);
    _pendingSaves.remove(chatId);

    // Adjust selectedChatIndex
    if (deletedIndex != -1 && deletedIndex < selectedChatIndex) {
      selectedChatIndex -= 1;
    }
    if (selectedChatIndex >= savedChats.length) {
      selectedChatIndex = savedChats.isEmpty ? -1 : savedChats.length - 1;
    }

    // Clear selection if the deleted chat was selected
    if (selectedChatId == chatId) {
      selectedChatId = null;
    }

    _notifyChanges(chatId);
  }

  /// Get a map of chat IDs to their updated_at timestamps for sync comparison.
  static Map<String, DateTime> getChatTimestamps() {
    final timestamps = <String, DateTime>{};
    for (final chat in _chatsById.values) {
      timestamps[chat.id] = chat.updatedAt ?? chat.createdAt;
    }
    return timestamps;
  }

}

