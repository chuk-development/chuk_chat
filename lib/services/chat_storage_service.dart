// lib/services/chat_storage_service.dart
import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/local_chat_cache_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';

const _kChatPayloadVersion = 1;

class ChatMessage {
  const ChatMessage({required this.sender, required this.text});

  final String sender;
  final String text;

  Map<String, String> toJson() => {'sender': sender, 'text': text};

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      sender: json['sender'] as String? ?? 'user',
      text: json['text'] as String? ?? '',
    );
  }
}

class StoredChat {
  StoredChat({
    required this.id,
    required List<ChatMessage> messages,
    required this.createdAt,
    required this.isStarred,
  }) : messages = List<ChatMessage>.unmodifiable(messages);

  final String id;
  final List<ChatMessage> messages;
  final DateTime createdAt;
  final bool isStarred;

  String get previewText {
    if (messages.isEmpty) return 'Chat';
    final text = messages.first.text.trim();
    return text.isEmpty ? 'Chat' : text;
  }

  StoredChat copyWith({
    List<ChatMessage>? messages,
    DateTime? createdAt,
    bool? isStarred,
  }) {
    return StoredChat(
      id: id,
      messages: messages ?? this.messages,
      createdAt: createdAt ?? this.createdAt,
      isStarred: isStarred ?? this.isStarred,
    );
  }

  factory StoredChat.fromRow(
    Map<String, dynamic> row,
    List<ChatMessage> messages,
  ) {
    return StoredChat(
      id: row['id'] as String,
      messages: messages,
      createdAt: DateTime.parse(row['created_at'] as String),
      isStarred: row['is_starred'] as bool? ?? false,
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

  static List<StoredChat> get savedChats => List.unmodifiable(_savedChats);
  static Stream<void> get changes => _changesController.stream;

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
    await _ensureRealtimeSubscription(user.id);

    List<Map<String, dynamic>> rows = <Map<String, dynamic>>[];
    bool loadedFromCache = false;
    Object? remoteError;
    StackTrace? remoteStack;

    try {
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
    } catch (error, stackTrace) {
      remoteError = error;
      remoteStack = stackTrace;
      try {
        rows = await LocalChatCacheService.load(user.id);
        if (rows.isEmpty) {
          if (error is PostgrestException) {
            throw StateError('Failed to load chats: ${error.message}');
          }
          throw StateError('Failed to load chats.');
        }
        loadedFromCache = true;
      } catch (_) {
        if (error is PostgrestException) {
          throw StateError('Failed to load chats: ${error.message}');
        }
        rethrow;
      }
    }

    final List<StoredChat> chats = [];
    for (final map in rows) {
      final encryptedPayload = map['encrypted_payload'] as String?;
      if (encryptedPayload == null) continue;
      try {
        final decrypted = await EncryptionService.decrypt(encryptedPayload);
        final messages = _deserializeMessages(decrypted);
        chats.add(StoredChat.fromRow(map, messages));
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
        final payload = jsonEncode({
          'v': _kChatPayloadVersion,
          'messages': chat.messages.map((message) => message.toJson()).toList(),
        });
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
        updatedChats.add(StoredChat.fromRow(updatedRow, chat.messages));
      }
    } finally {
      for (final updated in updatedChats) {
        _upsertChatLocally(updated);
      }
    }
  }

  static Future<StoredChat?> saveChat(
    List<Map<String, String>> messagesMaps,
  ) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to store chats.');
    }
    if (!EncryptionService.hasKey) {
      final loaded = await EncryptionService.tryLoadKey();
      if (!loaded) {
        throw StateError(
          'Encrypted chats could not be saved because the encryption key is missing. Please sign in again.',
        );
      }
    }

    final messages = _mapToChatMessages(messagesMaps);

    if (messages.isEmpty) {
      return null;
    }

    final payload = jsonEncode({
      'v': _kChatPayloadVersion,
      'messages': messages.map((message) => message.toJson()).toList(),
    });

    final encryptedPayload = await EncryptionService.encrypt(payload);
    Map<String, dynamic> inserted;
    try {
      inserted = await SupabaseService.client
          .from('encrypted_chats')
          .insert({'user_id': user.id, 'encrypted_payload': encryptedPayload})
          .select('id, encrypted_payload, created_at, is_starred')
          .single();
    } on PostgrestException catch (error) {
      throw StateError('Failed to save chat: ${error.message}');
    }

    final stored = StoredChat.fromRow(inserted, messages);
    _upsertChatLocally(stored);
    unawaited(LocalChatCacheService.upsert(user.id, inserted));
    return stored;
  }

  static Future<StoredChat?> updateChat(
    String chatId,
    List<Map<String, String>> messagesMaps,
  ) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to store chats.');
    }
    if (!EncryptionService.hasKey) {
      final loaded = await EncryptionService.tryLoadKey();
      if (!loaded) {
        throw StateError(
          'Encrypted chats could not be saved because the encryption key is missing. Please sign in again.',
        );
      }
    }

    final messages = _mapToChatMessages(messagesMaps);
    if (messages.isEmpty) {
      return null;
    }

    final payload = jsonEncode({
      'v': _kChatPayloadVersion,
      'messages': messages.map((message) => message.toJson()).toList(),
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
      throw StateError('Failed to update chat: ${error.message}');
    }

    if (updatedRows.isEmpty) {
      throw StateError(
        'Failed to update chat: Chat was not found or access is denied.',
      );
    }
    final updated = updatedRows.first as Map<String, dynamic>;

    final stored = StoredChat.fromRow(updated, messages);
    _upsertChatLocally(stored);
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
    List<Map<String, String>> messagesMaps,
  ) {
    return messagesMaps
        .map(
          (entry) => ChatMessage(
            sender: entry['sender'] ?? 'user',
            text: entry['text'] ?? '',
          ),
        )
        .where((message) => message.text.trim().isNotEmpty)
        .toList();
  }

  static List<ChatMessage> _deserializeMessages(String payload) {
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
        return rawMessages
            .whereType<Map<String, dynamic>>()
            .map(ChatMessage.fromJson)
            .toList();
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
      legacyMessages.add(ChatMessage(sender: sender, text: text));
    }
    return legacyMessages;
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
          final messages = _deserializeMessages(decrypted);
          final stored = StoredChat.fromRow(record, messages);
          _upsertChatLocally(stored);
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
    if (existingIndex != -1) {
      updatedChats[existingIndex] = chat;
    } else {
      updatedChats.add(chat);
    }
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

  static void _removeChatLocally(String chatId) {
    final removedIndex = _savedChats.indexWhere((chat) => chat.id == chatId);
    if (removedIndex == -1) {
      return;
    }
    _savedChats.removeAt(removedIndex);
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
