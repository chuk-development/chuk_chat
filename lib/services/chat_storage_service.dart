// lib/services/chat_storage_service.dart
import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/local_chat_cache_service.dart';
import 'package:chuk_chat/services/network_status_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';

const _kChatPayloadVersion = 1;

class ChatMessage {
  const ChatMessage({
    required this.sender,
    required this.text,
    this.reasoning = '',
    this.modelId,
    this.provider,
    this.images,
    this.attachments,
  });

  final String sender;
  final String text;
  final String reasoning;
  final String? modelId;
  final String? provider;
  final String? images; // JSON-encoded array of base64 image data URLs
  final String? attachments; // JSON-encoded array of document attachments

  Map<String, String> toJson() {
    final Map<String, String> json = {'sender': sender, 'text': text};
    if (reasoning.isNotEmpty) {
      json['reasoning'] = reasoning;
    }
    if (modelId != null && modelId!.isNotEmpty) {
      json['modelId'] = modelId!;
    }
    if (provider != null && provider!.isNotEmpty) {
      json['provider'] = provider!;
    }
    if (images != null && images!.isNotEmpty) {
      json['images'] = images!;
    }
    if (attachments != null && attachments!.isNotEmpty) {
      json['attachments'] = attachments!;
    }
    return json;
  }

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    String? normalize(String? value) {
      if (value == null) return null;
      final trimmed = value.trim();
      return trimmed.isEmpty ? null : trimmed;
    }

    return ChatMessage(
      sender: json['sender'] as String? ?? 'user',
      text: json['text'] as String? ?? '',
      reasoning: json['reasoning'] as String? ?? '',
      modelId: normalize(json['modelId'] as String?),
      provider: normalize(json['provider'] as String?),
      images: normalize(json['images'] as String?),
      attachments: normalize(json['attachments'] as String?),
    );
  }
}

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

  String get previewText {
    if (customName != null && customName!.trim().isNotEmpty) {
      return customName!.trim();
    }
    if (messages.isEmpty) return 'Chat';
    final text = messages.first.text.trim();
    return text.isEmpty ? 'Chat' : text;
  }

  StoredChat copyWith({
    List<ChatMessage>? messages,
    DateTime? createdAt,
    bool? isStarred,
    String? customName,
  }) {
    return StoredChat(
      id: id,
      messages: messages ?? this.messages,
      createdAt: createdAt ?? this.createdAt,
      isStarred: isStarred ?? this.isStarred,
      customName: customName ?? this.customName,
    );
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
      isStarred: row['is_starred'] as bool? ?? false,
      customName: customName,
    );
  }
}

class ChatStorageService {
  static List<StoredChat> _savedChats = <StoredChat>[];
  static final StreamController<void> _changesController =
      StreamController<void>.broadcast();
  static RealtimeChannel? _realtimeChannel;
  static String? _realtimeUserId;
  static int selectedChatIndex = -1;

  // Debouncing for realtime events to prevent duplicate chat entries
  static final Map<String, DateTime> _lastRealtimeUpdate = <String, DateTime>{};
  static const Duration _realtimeDebounceDuration = Duration(seconds: 1); // Reasonable debouncing
  static final Set<String> _processingChats = <String>{}; // Track chats currently being processed

  // Prevent concurrent save/update operations for the same chat
  static final Map<String, Future<void>> _chatSaveOperations = <String, Future<void>>{};

  static List<StoredChat> get savedChats => List.unmodifiable(_savedChats);
  static Stream<void> get changes => _changesController.stream;

  /// Check network status for offline handling
  static Future<bool> _checkNetworkStatus() async {
    try {
      return await NetworkStatusService.hasInternetConnection(timeout: const Duration(seconds: 2));
    } catch (_) {
      return false; // Assume offline on any error
    }
  }


  static Future<void> loadChats() async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      await reset();
      return;
    }
    if (!EncryptionService.hasKey) {
      final loaded = await EncryptionService.tryLoadKey();
      if (!loaded) {
        await EncryptionService.clearKey();
        await reset();
        return;
      }
    }

    List<Map<String, dynamic>> rows = <Map<String, dynamic>>[];
    bool loadedFromCache = false;
    Object? remoteError;
    StackTrace? remoteStack;

    // Check if we're offline first
    final isOnline = await _checkNetworkStatus();
    debugPrint('🌐 [ChatStorage] Network status: ${isOnline ? 'ONLINE' : 'OFFLINE'}');

    if (isOnline) {
      // Try to load from remote first when online
      try {
        await _ensureRealtimeSubscription(user.id);
        final data = await SupabaseService.client
            .from('encrypted_chats')
            .select('id, encrypted_payload, created_at, is_starred')
            .eq('user_id', user.id)
            .order('created_at', ascending: false);
        rows = data
            .whereType<Map<String, dynamic>>()
            .map((raw) => Map<String, dynamic>.from(raw))
            .toList(growable: false);
        await LocalChatCacheService.replaceAll(user.id, rows);
        debugPrint('✅ [ChatStorage] Loaded ${rows.length} chats from remote');
      } catch (error, stackTrace) {
        remoteError = error;
        remoteStack = stackTrace;
        debugPrint('❌ [ChatStorage] Remote load failed, falling back to cache: $error');
        // Fall back to cache when remote fails
        try {
          rows = await LocalChatCacheService.load(user.id);
          loadedFromCache = true;
          if (rows.isNotEmpty) {
            debugPrint('✅ [ChatStorage] Loaded ${rows.length} chats from cache (remote failed)');
          } else {
            debugPrint('⚠️ [ChatStorage] No cached chats available');
          }
        } catch (cacheError) {
          debugPrint('❌ [ChatStorage] Cache load also failed: $cacheError');
          if (cacheError is PostgrestException) {
            throw StateError('Failed to load chats: ${cacheError.message}');
          }
          throw StateError('Failed to load chats.');
        }
      }
    } else {
      // Load from cache immediately when offline
      debugPrint('📱 [ChatStorage] Offline - loading chats from cache');
      try {
        rows = await LocalChatCacheService.load(user.id);
        loadedFromCache = true;
        if (rows.isNotEmpty) {
          debugPrint('✅ [ChatStorage] Loaded ${rows.length} chats from cache (offline mode)');
        } else {
          debugPrint('⚠️ [ChatStorage] No cached chats available (offline mode)');
        }
      } catch (error) {
        debugPrint('❌ [ChatStorage] Failed to load cached chats: $error');
        // Don't throw error for cache failures when offline - just show empty state
        rows = [];
        loadedFromCache = true;
      }
    }

    final List<StoredChat> chats = [];
    for (final map in rows) {
      final encryptedPayload = map['encrypted_payload'] as String?;
      if (encryptedPayload == null) continue;
      try {
        final decrypted = await EncryptionService.decrypt(encryptedPayload);
        final chatPayload = _deserializePayload(decrypted);
        chats.add(StoredChat.fromRow(
          map,
          chatPayload.messages,
          customName: chatPayload.customName,
        ));
      } on SecretBoxAuthenticationError {
        // Skip corrupted rows silently to keep UI responsive.
        continue;
      } on FormatException {
        continue;
      } on StateError {
        continue;
      }
    }
    _savedChats = chats;
    _notifyChanges();

    if (loadedFromCache && remoteError != null) {
      debugPrint(
        'ChatStorageService loaded chats from offline cache: $remoteError',
      );
      if (remoteStack != null) {
        debugPrint('$remoteStack');
      }
    }
  }

  static Future<void> reencryptChats(List<StoredChat> chats) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to migrate chats.');
    }
    if (!EncryptionService.hasKey) {
      final loaded = await EncryptionService.tryLoadKey();
      if (!loaded) {
        throw StateError(
          'Cannot re-encrypt chats because the encryption key is missing. Please sign in again.',
        );
      }
    }

    final List<StoredChat> updatedChats = [];

    try {
      for (final chat in chats) {
        final Map<String, dynamic> payloadMap = {
          'v': _kChatPayloadVersion,
          'messages': chat.messages.map((message) => message.toJson()).toList(),
        };
        if (chat.customName != null) {
          payloadMap['customName'] = chat.customName;
        }
        final payload = jsonEncode(payloadMap);
        final encryptedPayload = await EncryptionService.encrypt(payload);
        List<dynamic> updatedRows;
        try {
          updatedRows = await SupabaseService.client
              .from('encrypted_chats')
              .update({'encrypted_payload': encryptedPayload})
              .eq('id', chat.id)
              .eq('user_id', user.id)
              .select('id, encrypted_payload, created_at, is_starred');
        } on PostgrestException catch (error) {
          throw StateError(
            'Failed to re-encrypt chat ${chat.id}: ${error.message}',
          );
        }
        if (updatedRows.isEmpty) {
          throw StateError(
            'Failed to re-encrypt chat ${chat.id}: chat was not found.',
          );
        }
        final updatedRow = updatedRows.first as Map<String, dynamic>;
        updatedChats.add(StoredChat.fromRow(updatedRow, chat.messages, customName: chat.customName));
      }
    } finally {
      for (final updated in updatedChats) {
        _upsertChatLocally(updated);
      }
    }
  }

  static Future<StoredChat?> saveChat(
    List<Map<String, dynamic>> messagesMaps, {
    String? chatId,
  }) async {
    final effectiveChatId = chatId ?? 'new-chat-${DateTime.now().millisecondsSinceEpoch}';
    debugPrint('💾 [ChatStorage] saveChat called with ${messagesMaps.length} messages, chatId=$effectiveChatId');

    // Prevent concurrent operations on the same chat
    final existingOperation = _chatSaveOperations[effectiveChatId];
    if (existingOperation != null) {
      debugPrint('⏳ [ChatStorage] Waiting for existing save operation on chat $effectiveChatId');
      await existingOperation;
      debugPrint('✅ [ChatStorage] Previous save operation completed for chat $effectiveChatId');
      // Return the existing chat if it exists
      final existingChat = _savedChats.cast<StoredChat?>().firstWhere(
        (chat) => chat?.id == effectiveChatId,
        orElse: () => null,
      );
      return existingChat;
    }

    final operation = _performSaveChat(messagesMaps, effectiveChatId, chatId);
    _chatSaveOperations[effectiveChatId] = operation;

    try {
      final result = await operation;
      return result;
    } finally {
      _chatSaveOperations.remove(effectiveChatId);
    }
  }

  static Future<StoredChat?> _performSaveChat(
    List<Map<String, dynamic>> messagesMaps,
    String effectiveChatId,
    String? originalChatId,
  ) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      debugPrint('❌ [ChatStorage] No user signed in');
      throw StateError('User must be signed in to store chats.');
    }

    debugPrint('✅ [ChatStorage] User authenticated: ${user.id}');

    if (!EncryptionService.hasKey) {
      debugPrint('🔐 [ChatStorage] No encryption key, attempting to load...');
      final loaded = await EncryptionService.tryLoadKey();
      if (!loaded) {
        debugPrint('❌ [ChatStorage] Failed to load encryption key');
        throw StateError(
          'Encrypted chats could not be saved because the encryption key is missing. Please sign in again.',
        );
      }
      debugPrint('✅ [ChatStorage] Encryption key loaded');
    }

    final messages = _mapToChatMessages(messagesMaps);
    debugPrint('📝 [ChatStorage] After filtering: ${messages.length} messages (removed "Thinking..." placeholders)');

    if (messages.isEmpty) {
      debugPrint('⚠️ [ChatStorage] No messages after filtering, returning null');
      return null;
    }

    final payload = jsonEncode({
      'v': _kChatPayloadVersion,
      'messages': messages.map((message) => message.toJson()).toList(),
    });

    debugPrint('🔐 [ChatStorage] Encrypting payload (${payload.length} bytes)...');
    final encryptedPayload = await EncryptionService.encrypt(payload);
    debugPrint('✅ [ChatStorage] Encrypted payload (${encryptedPayload.length} bytes)');

    Map<String, dynamic> inserted;
    try {
      debugPrint('📤 [ChatStorage] Inserting into Supabase...');

      // Build insert map - include chatId if provided
      final Map<String, dynamic> insertData = {
        'user_id': user.id,
        'encrypted_payload': encryptedPayload,
      };
      if (originalChatId != null) {
        insertData['id'] = originalChatId;
        debugPrint('   Using provided chatId: $originalChatId');
      }

      inserted = await SupabaseService.client
          .from('encrypted_chats')
          .insert(insertData)
          .select('id, encrypted_payload, created_at, is_starred')
          .single();
      debugPrint('✅ [ChatStorage] Insert successful! Chat ID: ${inserted['id']}');
    } on PostgrestException catch (error) {
      debugPrint('❌ [ChatStorage] Supabase insert failed: ${error.message}');
      debugPrint('   Code: ${error.code}, Details: ${error.details}');
      throw StateError('Failed to save chat: ${error.message}');
    } catch (error) {
      debugPrint('❌ [ChatStorage] Unexpected error during insert: $error');
      rethrow;
    }

    final stored = StoredChat.fromRow(inserted, messages);
    _upsertChatLocally(stored);
    debugPrint('✅ [ChatStorage] Chat saved locally and added to sidebar');
    unawaited(LocalChatCacheService.upsert(user.id, inserted));
    return stored;
  }

  static Future<StoredChat?> updateChat(
    String chatId,
    List<Map<String, dynamic>> messagesMaps,
  ) async {
    debugPrint('🔄 [ChatStorage] updateChat called for chatId=$chatId with ${messagesMaps.length} messages');

    // Prevent concurrent operations on the same chat
    final existingOperation = _chatSaveOperations[chatId];
    if (existingOperation != null) {
      debugPrint('⏳ [ChatStorage] Waiting for existing update operation on chat $chatId');
      await existingOperation;
      debugPrint('✅ [ChatStorage] Previous update operation completed for chat $chatId');
      // Return the existing chat
      final existingChat = _savedChats.cast<StoredChat?>().firstWhere(
        (chat) => chat?.id == chatId,
        orElse: () => null,
      );
      return existingChat;
    }

    final operation = _performUpdateChat(chatId, messagesMaps);
    _chatSaveOperations[chatId] = operation;

    try {
      final result = await operation;
      return result;
    } finally {
      _chatSaveOperations.remove(chatId);
    }
  }

  static Future<StoredChat?> _performUpdateChat(
    String chatId,
    List<Map<String, dynamic>> messagesMaps,
  ) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      debugPrint('❌ [ChatStorage] No user signed in');
      throw StateError('User must be signed in to store chats.');
    }

    if (!EncryptionService.hasKey) {
      debugPrint('🔐 [ChatStorage] No encryption key, attempting to load...');
      final loaded = await EncryptionService.tryLoadKey();
      if (!loaded) {
        debugPrint('❌ [ChatStorage] Failed to load encryption key');
        throw StateError(
          'Encrypted chats could not be saved because the encryption key is missing. Please sign in again.',
        );
      }
      debugPrint('✅ [ChatStorage] Encryption key loaded');
    }

    final messages = _mapToChatMessages(messagesMaps);
    debugPrint('📝 [ChatStorage] After filtering: ${messages.length} messages');

    if (messages.isEmpty) {
      debugPrint('⚠️ [ChatStorage] No messages after filtering, returning null');
      return null;
    }

    // Preserve existing customName from the chat being updated
    final existingChatIndex = _savedChats.indexWhere((chat) => chat.id == chatId);
    final String? existingCustomName = existingChatIndex != -1
        ? _savedChats[existingChatIndex].customName
        : null;

    final Map<String, dynamic> payloadMap = {
      'v': _kChatPayloadVersion,
      'messages': messages.map((message) => message.toJson()).toList(),
    };
    if (existingCustomName != null) {
      payloadMap['customName'] = existingCustomName;
    }
    final payload = jsonEncode(payloadMap);

    debugPrint('🔐 [ChatStorage] Encrypting payload...');
    final encryptedPayload = await EncryptionService.encrypt(payload);
    debugPrint('✅ [ChatStorage] Encrypted payload');

    List<dynamic> updatedRows;
    try {
      debugPrint('📤 [ChatStorage] Updating chat in Supabase...');
      updatedRows = await SupabaseService.client
          .from('encrypted_chats')
          .update({'encrypted_payload': encryptedPayload})
          .eq('id', chatId)
          .eq('user_id', user.id)
          .select('id, encrypted_payload, created_at, is_starred');
      debugPrint('✅ [ChatStorage] Update successful! ${updatedRows.length} rows affected');
    } on PostgrestException catch (error) {
      debugPrint('❌ [ChatStorage] Supabase update failed: ${error.message}');
      debugPrint('   Code: ${error.code}, Details: ${error.details}');
      throw StateError('Failed to update chat: ${error.message}');
    } catch (error) {
      debugPrint('❌ [ChatStorage] Unexpected error during update: $error');
      rethrow;
    }

    if (updatedRows.isEmpty) {
      debugPrint('❌ [ChatStorage] No rows updated - chat not found or access denied');
      throw StateError(
        'Failed to update chat: Chat was not found or access is denied.',
      );
    }
    final updated = updatedRows.first as Map<String, dynamic>;

    final stored = StoredChat.fromRow(updated, messages, customName: existingCustomName);
    _upsertChatLocally(stored);
    debugPrint('✅ [ChatStorage] Chat updated locally');
    unawaited(LocalChatCacheService.upsert(user.id, updated));
    return stored;
  }

  static Future<void> deleteChat(String chatId) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to delete chats.');
    }
    try {
      await SupabaseService.client
          .from('encrypted_chats')
          .delete()
          .eq('id', chatId)
          .eq('user_id', user.id);
    } on PostgrestException catch (error) {
      throw StateError('Failed to delete chat: ${error.message}');
    }

    unawaited(LocalChatCacheService.delete(user.id, chatId));

    final removedIndex = _savedChats.indexWhere(
      (storedChat) => storedChat.id == chatId,
    );
    if (removedIndex != -1) {
      _savedChats.removeAt(removedIndex);
      if (selectedChatIndex == removedIndex) {
        selectedChatIndex = -1;
      } else if (selectedChatIndex > removedIndex) {
        selectedChatIndex -= 1;
      }
    }

    if (selectedChatIndex >= _savedChats.length) {
      selectedChatIndex = _savedChats.isEmpty ? -1 : _savedChats.length - 1;
    }
    _notifyChanges();

    final userId = SupabaseService.auth.currentUser?.id;
    if (userId != null) {
      unawaited(LocalChatCacheService.delete(userId, chatId));
    }
  }

  static Future<void> loadSavedChatsForSidebar() async {
    await loadChats();
  }

  static Future<void> setChatStarred(String chatId, bool isStarred) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to update chat favorites.');
    }
    List<dynamic> updatedRows;
    try {
      updatedRows = await SupabaseService.client
          .from('encrypted_chats')
          .update({'is_starred': isStarred})
          .eq('id', chatId)
          .eq('user_id', user.id)
          .select('id, is_starred');
    } on PostgrestException catch (error) {
      throw StateError('Failed to update chat star: ${error.message}');
    }

    if (updatedRows.isEmpty) {
      throw StateError(
        'Failed to update chat star: Chat was not found or access is denied.',
      );
    }

    final Map<String, dynamic> updatedRow =
        updatedRows.first as Map<String, dynamic>;

    final bool remoteStar = updatedRow['is_starred'] as bool? ?? isStarred;

    final index = _savedChats.indexWhere((chat) => chat.id == chatId);
    if (index != -1) {
      final updatedChats = List<StoredChat>.from(_savedChats);
      final current = updatedChats[index];
      updatedChats[index] = current.copyWith(isStarred: remoteStar);
      _savedChats = updatedChats;
    }
    unawaited(LocalChatCacheService.updateStarred(user.id, chatId, remoteStar));
    _notifyChanges();
  }

  static Future<void> renameChat(String chatId, String newName) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to rename chats.');
    }
    if (!EncryptionService.hasKey) {
      final loaded = await EncryptionService.tryLoadKey();
      if (!loaded) {
        throw StateError(
          'Cannot rename chat because the encryption key is missing. Please sign in again.',
        );
      }
    }

    final index = _savedChats.indexWhere((chat) => chat.id == chatId);
    if (index == -1) {
      throw StateError('Chat not found.');
    }

    final chat = _savedChats[index];
    final updatedChat = chat.copyWith(customName: newName);

    final payload = jsonEncode({
      'v': _kChatPayloadVersion,
      'customName': newName,
      'messages': updatedChat.messages.map((message) => message.toJson()).toList(),
    });

    final encryptedPayload = await EncryptionService.encrypt(payload);
    List<dynamic> updatedRows;
    try {
      updatedRows = await SupabaseService.client
          .from('encrypted_chats')
          .update({'encrypted_payload': encryptedPayload})
          .eq('id', chatId)
          .eq('user_id', user.id)
          .select('id, encrypted_payload, created_at, is_starred');
    } on PostgrestException catch (error) {
      throw StateError('Failed to rename chat: ${error.message}');
    }

    if (updatedRows.isEmpty) {
      throw StateError(
        'Failed to rename chat: Chat was not found or access is denied.',
      );
    }

    final updated = updatedRows.first as Map<String, dynamic>;
    final stored = StoredChat.fromRow(
      updated,
      updatedChat.messages,
      customName: newName,
    );
    _upsertChatLocally(stored);
    unawaited(LocalChatCacheService.upsert(user.id, updated));
  }

  static Future<String> exportChatsAsJson() async {
    await loadChats();
    final exportPayload = _savedChats
        .map(
          (chat) => {
            'id': chat.id,
            'createdAt': chat.createdAt.toIso8601String(),
            'messages': chat.messages
                .map((message) => message.toJson())
                .toList(),
          },
        )
        .toList();
    return jsonEncode(exportPayload);
  }

  static Future<void> reset() async {
    _savedChats = <StoredChat>[];
    selectedChatIndex = -1;
    _notifyChanges();
    await _stopRealtimeSubscription();
  }

  static List<ChatMessage> _mapToChatMessages(
    List<Map<String, dynamic>> messagesMaps,
  ) {
    return messagesMaps
        .map(
          (entry) => ChatMessage(
            sender: entry['sender'] as String? ?? 'user',
            text: entry['text'] as String? ?? '',
            reasoning: entry['reasoning'] as String? ?? '',
            modelId: entry['modelId'] as String?,
            provider: entry['provider'] as String?,
            images: entry['images'] as String?,
            attachments: entry['attachments'] as String?,
          ),
        )
        .where((message) {
          final text = message.text.trim();
          // Filter out empty messages and "Thinking..." placeholders
          return text.isNotEmpty && text != 'Thinking...';
        })
        .toList();
  }

  static ({List<ChatMessage> messages, String? customName}) _deserializePayload(String payload) {
    try {
      final dynamic decoded = jsonDecode(payload);
      if (decoded is Map<String, dynamic>) {
        final dynamic versionValue = decoded['v'];
        int? version;
        if (versionValue is int) {
          version = versionValue;
        } else if (versionValue is String) {
          version = int.tryParse(versionValue);
        }
        if (version != _kChatPayloadVersion) {
          throw StateError('Unsupported chat payload version: $version');
        }
        final rawMessages =
            decoded['messages'] as List<dynamic>? ?? <dynamic>[];
        final messages = rawMessages
            .whereType<Map<String, dynamic>>()
            .map(ChatMessage.fromJson)
            .where((message) {
              // Filter out "Thinking..." placeholders that may have been saved
              final text = message.text.trim();
              return text.isNotEmpty && text != 'Thinking...';
            })
            .toList();
        final customName = decoded['customName'] as String?;
        return (messages: messages, customName: customName);
      }
    } catch (_) {
      // Fall back to legacy pipe/section delimited format.
    }

    final legacySegments = payload.split('§');
    final legacyMessages = <ChatMessage>[];
    for (final segment in legacySegments) {
      if (segment.isEmpty) continue;
      final separatorIndex = segment.indexOf('|');
      if (separatorIndex == -1) continue;
      final sender = segment.substring(0, separatorIndex);
      final text = segment.substring(separatorIndex + 1);
      // Filter out "Thinking..." placeholders
      if (text.trim().isNotEmpty && text.trim() != 'Thinking...') {
        legacyMessages.add(ChatMessage(sender: sender, text: text));
      }
    }
    return (messages: legacyMessages, customName: null);
  }

  static void _notifyChanges() {
    if (_changesController.isClosed) {
      return;
    }
    _changesController.add(null);
  }

  static Future<void> _ensureRealtimeSubscription(String userId) async {
    if (_realtimeUserId == userId && _realtimeChannel != null) {
      return;
    }
    await _stopRealtimeSubscription();

    final channelName = 'public:encrypted_chats_user_$userId';
    final channel = SupabaseService.client.channel(channelName);
    void handleChange(PostgresChangePayload payload) {
      unawaited(_handleRealtimeChange(payload));
    }

    channel
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'encrypted_chats',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: userId,
          ),
          callback: handleChange,
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'encrypted_chats',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: userId,
          ),
          callback: handleChange,
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'encrypted_chats',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: userId,
          ),
          callback: handleChange,
        );

    channel.subscribe();
    _realtimeChannel = channel;
    _realtimeUserId = userId;
  }

  static Future<void> _reloadChatsFromRealtime() async {
    try {
      await loadChats();
    } catch (error, stackTrace) {
      _reportRealtimeError(
        error,
        stackTrace,
        context: 'reloading chats after realtime event',
      );
    }
  }

  static Future<void> _stopRealtimeSubscription() async {
    if (_realtimeChannel == null) {
      _realtimeUserId = null;
      return;
    }
    try {
      await _realtimeChannel!.unsubscribe();
    } catch (error, stackTrace) {
      _reportRealtimeError(
        error,
        stackTrace,
        context: 'stopping realtime subscription',
      );
    } finally {
      _realtimeChannel = null;
      _realtimeUserId = null;
      // Clean up debouncing and processing maps when subscription stops
      _lastRealtimeUpdate.clear();
      _processingChats.clear();
      _chatSaveOperations.clear();
    }
  }

  static Future<void> _handleRealtimeChange(
    PostgresChangePayload payload,
  ) async {
    try {
      switch (payload.eventType) {
        case PostgresChangeEvent.delete:
          final Map<String, dynamic> oldRecord = payload.oldRecord;
          final chatId =
              (oldRecord['id'] ?? payload.newRecord['id']) as String?;
          if (chatId == null) return;
          _removeChatLocally(chatId);
          return;
        case PostgresChangeEvent.insert:
        case PostgresChangeEvent.update:
          final Map<String, dynamic> record = payload.newRecord;
          final chatId = record['id'] as String?;
          if (chatId == null) return;

          // Prevent concurrent processing of the same chat
          if (_processingChats.contains(chatId)) {
            debugPrint('🔄 [Realtime] Skipping concurrent update for chat $chatId (already processing)');
            return;
          }

          // Debounce realtime updates for the same chat to prevent duplicates
          final now = DateTime.now();
          final lastUpdate = _lastRealtimeUpdate[chatId];
          if (lastUpdate != null &&
              now.difference(lastUpdate) < _realtimeDebounceDuration) {
            debugPrint('🔄 [Realtime] Skipping duplicate update for chat $chatId (debounced)');
            return;
          }

          // Mark as processing and update timestamp
          _processingChats.add(chatId);
          _lastRealtimeUpdate[chatId] = now;
          debugPrint('🔄 [Realtime] Processing ${payload.eventType} event for chat $chatId');

          try {
            final encryptedPayload = record['encrypted_payload'] as String?;
            if (encryptedPayload == null) {
              return;
            }
            final userId = SupabaseService.auth.currentUser?.id;
            if (userId != null) {
              unawaited(LocalChatCacheService.upsert(userId, record));
            }
            if (!EncryptionService.hasKey) {
              final loaded = await EncryptionService.tryLoadKey();
              if (!loaded) {
                return;
              }
            }
            final decrypted = await EncryptionService.decrypt(encryptedPayload);
            final chatPayload = _deserializePayload(decrypted);
            final stored = StoredChat.fromRow(
              record,
              chatPayload.messages,
              customName: chatPayload.customName,
            );
            _upsertChatLocally(stored);
          } finally {
            // Always remove from processing set
            _processingChats.remove(chatId);
          }
          return;
        case PostgresChangeEvent.all:
          break;
      }
      await _reloadChatsFromRealtime();
    } catch (error, stackTrace) {
      _reportRealtimeError(
        error,
        stackTrace,
        context: 'processing realtime change',
      );
    }
  }

  static void _upsertChatLocally(StoredChat chat) {
    final bool hadValidSelection =
        selectedChatIndex >= 0 && selectedChatIndex < _savedChats.length;
    final bool hadAnySelection = selectedChatIndex >= 0;
    final String? selectedChatId = hadValidSelection
        ? _savedChats[selectedChatIndex].id
        : null;

    final updatedChats = List<StoredChat>.from(_savedChats);
    final existingIndex = updatedChats.indexWhere((c) => c.id == chat.id);
    bool shouldNotify = false;

    if (existingIndex != -1) {
      // Only update if the chat data has actually changed
      final existingChat = updatedChats[existingIndex];
      if (existingChat.messages.length != chat.messages.length ||
          existingChat.customName != chat.customName ||
          existingChat.isStarred != chat.isStarred) {
        updatedChats[existingIndex] = chat;
        shouldNotify = true;
        debugPrint('💾 [ChatStorage] Updated existing chat ${chat.id} (metadata changed) - ${chat.messages.length} messages');
      } else {
        // Check if message contents have changed
        bool hasChanges = false;
        for (int i = 0; i < chat.messages.length && !hasChanges; i++) {
          if (i >= existingChat.messages.length ||
              existingChat.messages[i].text != chat.messages[i].text ||
              existingChat.messages[i].images != chat.messages[i].images ||
              existingChat.messages[i].attachments != chat.messages[i].attachments) {
            hasChanges = true;
          }
        }
        if (hasChanges) {
          updatedChats[existingIndex] = chat;
          shouldNotify = true;
          debugPrint('💾 [ChatStorage] Updated existing chat ${chat.id} (messages changed) - ${chat.messages.length} messages');
        } else {
          // No changes, skip the update to avoid unnecessary notifications
          debugPrint('💾 [ChatStorage] Skipped update for chat ${chat.id} (no changes) - ${chat.messages.length} messages');
          return;
        }
      }
    } else {
      updatedChats.add(chat);
      shouldNotify = true;
      debugPrint('💾 [ChatStorage] Added new chat ${chat.id} - ${chat.messages.length} messages, created: ${chat.createdAt}');
    }

    if (shouldNotify) {
      updatedChats.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      _savedChats = updatedChats;

      if (selectedChatId != null) {
        final newIndex = _savedChats.indexWhere(
          (storedChat) => storedChat.id == selectedChatId,
        );
        selectedChatIndex = newIndex >= 0 ? newIndex : -1;
      } else if (!hadAnySelection) {
        selectedChatIndex = -1;
      }

      if (selectedChatIndex >= _savedChats.length) {
        selectedChatIndex = _savedChats.isEmpty ? -1 : _savedChats.length - 1;
      } else if (selectedChatIndex < 0) {
        selectedChatIndex = -1;
      }
      _notifyChanges();
    }
  }

  static void _removeChatLocally(String chatId) {
    final removedIndex = _savedChats.indexWhere((chat) => chat.id == chatId);
    if (removedIndex == -1) {
      return;
    }
    _savedChats.removeAt(removedIndex);
    // Clean up debouncing and processing maps when chat is removed
    _lastRealtimeUpdate.remove(chatId);
    _processingChats.remove(chatId);
    _chatSaveOperations.remove(chatId);
    if (selectedChatIndex == removedIndex) {
      selectedChatIndex = -1;
    } else if (selectedChatIndex > removedIndex) {
      selectedChatIndex -= 1;
    }
    if (selectedChatIndex >= _savedChats.length) {
      selectedChatIndex = _savedChats.isEmpty ? -1 : _savedChats.length - 1;
    }
    _notifyChanges();

    final userId = SupabaseService.auth.currentUser?.id;
    if (userId != null) {
      unawaited(LocalChatCacheService.delete(userId, chatId));
    }
  }

  static void _reportRealtimeError(
    Object error,
    StackTrace stackTrace, {
    required String context,
  }) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'ChatStorageService',
        context: ErrorDescription(context),
        informationCollector: () sync* {
          yield DiagnosticsNode.message(
            'Active realtime user: ${_realtimeUserId ?? 'none'}',
          );
        },
      ),
    );
  }
}
