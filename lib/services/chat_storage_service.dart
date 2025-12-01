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
import 'package:uuid/uuid.dart';

const int _kChatPayloadVersion = 2;

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
class StoredChat {
  StoredChat({
    required this.id,
    required List<ChatMessage> messages,
    required this.createdAt,
    required this.isStarred,
    this.customName,
  }) : messages = List<ChatMessage>.unmodifiable(messages);

  final String id;
  final List<ChatMessage> messages;
  final DateTime createdAt;
  final bool isStarred;
  final String? customName;

  /// Get a preview of the chat (first user message or first message text)
  String get previewText {
    if (messages.isEmpty) return '';
    // Try to find first user message
    for (final msg in messages) {
      if (msg.role == 'user' && msg.text.isNotEmpty) {
        return msg.text.length > 100
            ? '${msg.text.substring(0, 100)}...'
            : msg.text;
      }
    }
    // Fall back to first message
    final first = messages.first.text;
    return first.length > 100 ? '${first.substring(0, 100)}...' : first;
  }

  factory StoredChat.fromRow(
    Map<String, dynamic> row,
    List<ChatMessage> messages, {
    String? customName,
  }) {
    return StoredChat(
      id: row['id'] as String,
      messages: messages,
      createdAt: DateTime.parse(row['created_at'] as String),
      isStarred: (row['is_starred'] as bool?) ?? false,
      customName: customName,
    );
  }

  StoredChat copyWith({
    String? id,
    List<ChatMessage>? messages,
    DateTime? createdAt,
    bool? isStarred,
    String? customName,
  }) {
    return StoredChat(
      id: id ?? this.id,
      messages: messages ?? this.messages,
      createdAt: createdAt ?? this.createdAt,
      isStarred: isStarred ?? this.isStarred,
      customName: customName ?? this.customName,
    );
  }
}

class ChatStorageService {
  // SINGLE SOURCE OF TRUTH - all chats stored here
  static final Map<String, StoredChat> _chatsById = <String, StoredChat>{};

  static final StreamController<void> _changesController =
      StreamController<void>.broadcast();
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

  // UUID generator for chat IDs
  static const Uuid _uuid = Uuid();

  // Track chats we're currently saving to ignore realtime events for them
  static final Set<String> _savingChats = <String>{};

  // Prevent concurrent save operations
  static final Map<String, Completer<StoredChat?>> _pendingSaves =
      <String, Completer<StoredChat?>>{};

  // Get chats as a sorted list (most recent first)
  static List<StoredChat> get savedChats {
    final list = _chatsById.values.toList();
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return List.unmodifiable(list);
  }

  static Stream<void> get changes => _changesController.stream;

  static void _notifyChanges() {
    if (!_changesController.isClosed) {
      _changesController.add(null);
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

  /// Load all chats from Supabase or cache
  static Future<void> loadChats() async {
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
            .select('id, encrypted_payload, created_at, is_starred')
            .eq('user_id', user.id)
            .order('created_at', ascending: false);
        debugPrint('✅ [ChatStorage] Loaded ${rows.length} chats from remote');

        // Update cache with remote data
        for (final row in rows) {
          unawaited(LocalChatCacheService.upsert(user.id, row));
        }
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

    for (final map in rows) {
      final encryptedPayload = map['encrypted_payload'] as String?;
      if (encryptedPayload == null || encryptedPayload.isEmpty) continue;

      try {
        final decrypted = await EncryptionService.decrypt(encryptedPayload);
        final chatPayload = _deserializePayload(decrypted);
        final chat = StoredChat.fromRow(
          map,
          chatPayload.messages,
          customName: chatPayload.customName,
        );
        _chatsById[chat.id] = chat;
      } on SecretBoxAuthenticationError {
        continue;
      } on FormatException {
        continue;
      } on StateError {
        continue;
      }
    }

    _notifyChanges();

    // Log all loaded chats for debugging
    if (_chatsById.isNotEmpty) {
      debugPrint('📋 [ChatStorage] Current chats in memory (${_chatsById.length}):');
      for (final entry in _chatsById.entries) {
        final chat = entry.value;
        final firstUserMsg = chat.messages.where((m) => m.role == 'user').firstOrNull;
        final title = (firstUserMsg?.text.length ?? 0) > 40
            ? '${firstUserMsg!.text.substring(0, 40)}...'
            : (firstUserMsg?.text ?? 'No user message');
        debugPrint('   - ${entry.key.substring(0, 8)}... : "$title" (${chat.messages.length} msgs)');
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
  }

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

    // Extract image paths for cleanup on delete
    final imagePaths = _extractImagePaths(messages);

    // CRITICAL: Always include the effectiveChatId in the insert.
    // This ensures the ID we track in _savingChats matches the ID in Supabase,
    // preventing race conditions with realtime events that could cause duplicates.
    final Map<String, dynamic> insertData = {
      'id': effectiveChatId,
      'user_id': user.id,
      'encrypted_payload': encryptedPayload,
      if (imagePaths.isNotEmpty) 'image_paths': imagePaths,
    };

    final inserted = await SupabaseService.client
        .from('encrypted_chats')
        .insert(insertData)
        .select('id, encrypted_payload, created_at, is_starred')
        .single();

    final String finalId = inserted['id'] as String;
    final chat = StoredChat.fromRow(inserted, messages);

    // Add to our map - this is the ONLY place we add new chats
    _chatsById[finalId] = chat;
    _notifyChanges();

    unawaited(LocalChatCacheService.upsert(user.id, inserted));

    // Log with title for debugging
    final firstUserMsg = messages.where((m) => m.role == 'user').firstOrNull;
    final title = (firstUserMsg?.text.length ?? 0) > 50
        ? '${firstUserMsg!.text.substring(0, 50)}...'
        : (firstUserMsg?.text ?? 'No user message');
    debugPrint('✅ [ChatStorage] Saved new chat: $finalId');
    debugPrint('   📝 Title: "$title"');
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

    // Extract image paths for cleanup on delete
    final imagePaths = _extractImagePaths(messages);

    final updatedRows = await SupabaseService.client
        .from('encrypted_chats')
        .update({
          'encrypted_payload': encryptedPayload,
          'image_paths': imagePaths.isNotEmpty ? imagePaths : null,
        })
        .eq('id', chatId)
        .eq('user_id', user.id)
        .select('id, encrypted_payload, created_at, is_starred');

    if (updatedRows.isEmpty) {
      throw StateError('Chat not found or access denied.');
    }

    final updatedRow = updatedRows.first;
    final chat = StoredChat.fromRow(
      updatedRow,
      messages,
      customName: existingCustomName,
    );

    // Update in our map - this is the ONLY place we update chats
    _chatsById[chatId] = chat;
    _notifyChanges();

    unawaited(LocalChatCacheService.upsert(user.id, updatedRow));

    // Log with title for debugging
    final firstUserMsg = messages.where((m) => m.role == 'user').firstOrNull;
    final title = (firstUserMsg?.text.length ?? 0) > 50
        ? '${firstUserMsg!.text.substring(0, 50)}...'
        : (firstUserMsg?.text ?? 'No user message');
    debugPrint('✅ [ChatStorage] Updated chat: $chatId');
    debugPrint('   📝 Title: "$title"');
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

    _notifyChanges();
    unawaited(LocalChatCacheService.delete(user.id, chatId));
    debugPrint('🗑️ [ChatStorage] Deleted chat: $chatId');
  }

  /// Load chats for sidebar (only if empty)
  static Future<void> loadSavedChatsForSidebar() async {
    if (_chatsById.isEmpty) {
      await loadChats();
    }
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
      _notifyChanges();
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
        .select('id, encrypted_payload, created_at, is_starred');

    if (updatedRows.isEmpty) {
      throw StateError('Chat was not found or access is denied.');
    }

    _chatsById[chatId] = updatedChat;
    _notifyChanges();
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
          .select('id, encrypted_payload, created_at, is_starred');

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
    _notifyChanges();
  }

}
