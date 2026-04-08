// lib/services/assistant_storage_service.dart
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/models/assistant_model.dart';
import 'package:chuk_chat/services/image_storage_service.dart';
import 'package:chuk_chat/services/local_chat_cache_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';

/// Service for managing custom AI assistants with configurable system prompts
/// and isolated memory settings.
class AssistantStorageService {
  static const String _cacheKey = 'cached_assistants';

  // SINGLE SOURCE OF TRUTH - all assistants stored here
  static final Map<String, Assistant> _assistantsById = <String, Assistant>{};
  static bool _cacheLoaded = false;
  static bool _isLoadingFromNetwork = false;

  // Prevent concurrent loadAssistants() calls
  static Completer<void>? _loadingCompleter;
  static bool get _isLoading =>
      _loadingCompleter != null && !_loadingCompleter!.isCompleted;

  static final StreamController<void> _changesController =
      StreamController<void>.broadcast();

  // Debounce for _notifyChanges to prevent rapid-fire UI rebuilds
  static Timer? _notifyDebounceTimer;
  static bool _hasPendingNotification = false;
  static const Duration _notifyDebounceDelay = Duration(milliseconds: 100);

  // Currently selected assistant (for chat UI context)
  static String? selectedAssistantId;

  // Cache of assistant-chat relationships (chatId -> assistantId)
  static final Map<String, String> _chatToAssistantMap = <String, String>{};

  // Public assistants from other users (separate cache)
  static final Map<String, Assistant> _publicAssistantsById =
      <String, Assistant>{};

  // Get assistants as a sorted list (most recent first)
  static List<Assistant> get assistants {
    final list = _assistantsById.values.toList();
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return List.unmodifiable(list);
  }

  // Get non-archived assistants
  static List<Assistant> get activeAssistants {
    return assistants.where((a) => !a.isArchived).toList();
  }

  // Get archived assistants
  static List<Assistant> get archivedAssistants {
    return assistants.where((a) => a.isArchived).toList();
  }

  // Get public assistants from other users
  static List<Assistant> get publicAssistants {
    final list = _publicAssistantsById.values.toList();
    list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return List.unmodifiable(list);
  }

  static Stream<void> get changes => _changesController.stream;

  /// Notify listeners of changes with debouncing.
  /// Only saves to cache if explicitly requested and not during network loading.
  static void _notifyChanges({bool updateCache = true}) {
    if (_changesController.isClosed) return;

    _hasPendingNotification = true;

    // Cancel existing timer
    _notifyDebounceTimer?.cancel();

    // Start new debounce timer
    _notifyDebounceTimer = Timer(_notifyDebounceDelay, () {
      if (_changesController.isClosed) return;
      if (_hasPendingNotification) {
        _changesController.add(null);
        _hasPendingNotification = false;
      }
    });

    // Auto-save to cache when data changes
    if (updateCache && _cacheLoaded && !_isLoadingFromNetwork) {
      unawaited(_saveToCache());
    }
  }

  /// Notify immediately without debounce
  static void _notifyChangesImmediate() {
    if (!_changesController.isClosed) {
      _changesController.add(null);
    }
  }

  // ============ LOCAL CACHE ============

  /// Load assistants from local cache (fast, for instant UI)
  static Future<void> loadFromCache() async {
    if (_cacheLoaded) return;

    try {
      final cached = await LocalChatCacheService.kvGet(_cacheKey);
      if (cached != null && cached.isNotEmpty) {
        final List<dynamic> jsonList = jsonDecode(cached);
        _assistantsById.clear();
        for (final json in jsonList) {
          final assistant = Assistant.fromJson(json);
          _assistantsById[assistant.id] = assistant;
        }
        if (kDebugMode) {
          debugPrint(
            '✅ [AssistantStorage] Loaded ${_assistantsById.length} assistants from cache',
          );
        }
        _cacheLoaded = true;
        _notifyChangesImmediate();
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ [AssistantStorage] Failed to load cache: $e');
      }
    }
  }

  /// Save assistants to local cache
  static Future<void> _saveToCache() async {
    try {
      final jsonList = _assistantsById.values.map((a) => a.toJson()).toList();
      await LocalChatCacheService.kvSet(_cacheKey, jsonEncode(jsonList));
      if (kDebugMode) {
        debugPrint(
          '✅ [AssistantStorage] Saved ${jsonList.length} assistants to cache',
        );
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ [AssistantStorage] Failed to save cache: $e');
      }
    }
  }

  // ============ ASSISTANT CRUD OPERATIONS ============

  /// Load all assistants from Supabase (updates cache)
  static Future<void> loadAssistants() async {
    // First load from cache for instant UI
    if (!_cacheLoaded) {
      await loadFromCache();
    }

    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      if (kDebugMode) {
        debugPrint(
          '⚠️ [AssistantStorage] No user signed in, clearing assistants',
        );
      }
      _assistantsById.clear();
      _notifyChanges(updateCache: false);
      return;
    }

    // Prevent concurrent loads
    if (_isLoading) {
      if (kDebugMode) {
        debugPrint('⏳ [AssistantStorage] Load already in progress, waiting...');
      }
      return _loadingCompleter!.future;
    }
    _loadingCompleter = Completer<void>();
    _isLoadingFromNetwork = true;

    try {
      // Load assistants from server
      final assistantRows = await SupabaseService.client
          .from('assistants')
          .select('*')
          .eq('user_id', user.id)
          .order('created_at', ascending: false);

      if (kDebugMode) {
        debugPrint(
          '✅ [AssistantStorage] Loaded ${assistantRows.length} assistants from server',
        );
      }

      // Load assistant-chat relationships in parallel
      final assistantIds = assistantRows.map((a) => a['id'] as String).toList();
      if (assistantIds.isNotEmpty) {
        final chatRows = await SupabaseService.client
            .from('assistant_chats')
            .select('assistant_id, chat_id')
            .inFilter('assistant_id', assistantIds);

        // Build chat-to-assistant mapping
        _chatToAssistantMap.clear();
        for (final row in chatRows) {
          final assistantId = row['assistant_id'] as String;
          final chatId = row['chat_id'] as String;
          _chatToAssistantMap[chatId] = assistantId;
        }
      }

      // Build Assistant objects
      _assistantsById.clear();
      for (final row in assistantRows) {
        final assistantId = row['id'] as String;
        final assistant = Assistant.fromJson(row);
        _assistantsById[assistantId] = assistant;
      }

      // Save to cache
      await _saveToCache();
      _notifyChanges(updateCache: false);
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('❌ [AssistantStorage] Failed to load assistants: $e\n$st');
      }
      // Don't rethrow if we have cached data
      if (_assistantsById.isEmpty) rethrow;
    } finally {
      _isLoadingFromNetwork = false;
      _loadingCompleter?.complete();
      _loadingCompleter = null;
    }
  }

  /// Load public assistants from other users
  static Future<void> loadPublicAssistants() async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) return;

    try {
      // Fetch public assistants that aren't owned by the current user
      // and join with profiles to get owner display name
      final rows = await SupabaseService.client
          .from('assistants')
          .select('*, profiles!inner(display_name)')
          .eq('is_public', true)
          .neq('user_id', user.id)
          .eq('is_archived', false)
          .order('updated_at', ascending: false);

      _publicAssistantsById.clear();
      for (final row in rows) {
        // Extract owner display name from the joined profiles table
        String? ownerName;
        final profiles = row['profiles'];
        if (profiles is Map<String, dynamic>) {
          ownerName = profiles['display_name'] as String?;
        }

        // Inject owner_display_name into the row for fromJson
        final enrichedRow = Map<String, dynamic>.from(row);
        enrichedRow['owner_display_name'] = ownerName;
        enrichedRow.remove('profiles'); // Remove the join data

        final assistant = Assistant.fromJson(enrichedRow);
        _publicAssistantsById[assistant.id] = assistant;
      }

      _notifyChangesImmediate();

      if (kDebugMode) {
        debugPrint(
          '✅ [AssistantStorage] Loaded ${_publicAssistantsById.length} public assistants',
        );
      }
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint(
          '❌ [AssistantStorage] Failed to load public assistants: $e\n$st',
        );
      }
    }
  }

  /// Make an assistant public (visible to all users)
  static Future<Assistant> makePublic(String assistantId) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in.');
    }

    final updated = await SupabaseService.client
        .from('assistants')
        .update({'is_public': true})
        .eq('id', assistantId)
        .eq('user_id', user.id)
        .select()
        .single();

    final assistant = Assistant.fromJson(updated);
    _assistantsById[assistantId] = assistant;
    _notifyChanges();

    if (kDebugMode) {
      debugPrint('🌐 [AssistantStorage] Made assistant public: $assistantId');
    }
    return assistant;
  }

  /// Make an assistant private again
  static Future<Assistant> makePrivate(String assistantId) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in.');
    }

    final updated = await SupabaseService.client
        .from('assistants')
        .update({'is_public': false})
        .eq('id', assistantId)
        .eq('user_id', user.id)
        .select()
        .single();

    final assistant = Assistant.fromJson(updated);
    _assistantsById[assistantId] = assistant;
    _notifyChanges();

    if (kDebugMode) {
      debugPrint('🔒 [AssistantStorage] Made assistant private: $assistantId');
    }
    return assistant;
  }

  /// Create a new assistant
  static Future<Assistant> createAssistant({
    required String name,
    required String systemPrompt,
    String? description,
    bool memoryEnabled = true,
    String? modelId,
    String? avatarColor,
    String? avatarIcon,
  }) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to create assistants.');
    }

    try {
      final Map<String, dynamic> insertData = {
        'user_id': user.id,
        'name': name.trim(),
        'system_prompt': systemPrompt.trim(),
        if (description != null && description.trim().isNotEmpty)
          'description': description.trim(),
        'memory_enabled': memoryEnabled,
        if (modelId != null && modelId.trim().isNotEmpty)
          'model_id': modelId.trim(),
        if (avatarColor != null && avatarColor.trim().isNotEmpty)
          'avatar_color': avatarColor.trim(),
        if (avatarIcon != null && avatarIcon.trim().isNotEmpty)
          'avatar_icon': avatarIcon.trim(),
      };

      final inserted = await SupabaseService.client
          .from('assistants')
          .insert(insertData)
          .select()
          .single();

      final assistant = Assistant.fromJson(inserted);
      _assistantsById[assistant.id] = assistant;
      _notifyChanges();

      if (kDebugMode) {
        debugPrint('✅ [AssistantStorage] Created assistant: ${assistant.id}');
      }
      return assistant;
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('❌ [AssistantStorage] Failed to create assistant: $e\n$st');
      }
      rethrow;
    }
  }

  /// Update an existing assistant
  static Future<Assistant> updateAssistant(
    String assistantId, {
    String? name,
    String? systemPrompt,
    String? description,
    bool? memoryEnabled,
    String? modelId,
    String? avatarColor,
    String? avatarIcon,
    String? avatarImagePath,
  }) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to update assistants.');
    }

    try {
      final Map<String, dynamic> updateData = {};
      if (name != null) updateData['name'] = name.trim();
      if (systemPrompt != null) {
        updateData['system_prompt'] = systemPrompt.trim();
      }
      if (description != null) updateData['description'] = description.trim();
      if (memoryEnabled != null) updateData['memory_enabled'] = memoryEnabled;
      if (modelId != null) updateData['model_id'] = modelId.trim();
      if (avatarColor != null) updateData['avatar_color'] = avatarColor.trim();
      if (avatarIcon != null) updateData['avatar_icon'] = avatarIcon.trim();
      if (avatarImagePath != null) {
        updateData['avatar_image_path'] = avatarImagePath.trim();
      }

      if (updateData.isEmpty) {
        throw ArgumentError('At least one field must be updated');
      }

      final updated = await SupabaseService.client
          .from('assistants')
          .update(updateData)
          .eq('id', assistantId)
          .eq('user_id', user.id)
          .select()
          .single();

      final assistant = Assistant.fromJson(updated);
      _assistantsById[assistantId] = assistant;
      _notifyChanges();

      if (kDebugMode) {
        debugPrint('✅ [AssistantStorage] Updated assistant: $assistantId');
      }
      return assistant;
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('❌ [AssistantStorage] Failed to update assistant: $e\n$st');
      }
      rethrow;
    }
  }

  /// Delete an assistant (cascades to assistant_chats via DB)
  static Future<void> deleteAssistant(String assistantId) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to delete assistants.');
    }

    try {
      await SupabaseService.client
          .from('assistants')
          .delete()
          .eq('id', assistantId)
          .eq('user_id', user.id);

      _assistantsById.remove(assistantId);

      // Remove from chat mappings
      _chatToAssistantMap.removeWhere((_, aId) => aId == assistantId);

      if (selectedAssistantId == assistantId) {
        selectedAssistantId = null;
      }
      _notifyChanges();

      if (kDebugMode) {
        debugPrint('🗑️ [AssistantStorage] Deleted assistant: $assistantId');
      }
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('❌ [AssistantStorage] Failed to delete assistant: $e\n$st');
      }
      rethrow;
    }
  }

  /// Archive or unarchive an assistant
  static Future<void> archiveAssistant(
    String assistantId,
    bool archived,
  ) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to archive assistants.');
    }

    try {
      await SupabaseService.client
          .from('assistants')
          .update({'is_archived': archived})
          .eq('id', assistantId)
          .eq('user_id', user.id);

      final existingAssistant = _assistantsById[assistantId];
      if (existingAssistant != null) {
        _assistantsById[assistantId] = existingAssistant.copyWith(
          isArchived: archived,
        );
        _notifyChanges();
      }

      if (kDebugMode) {
        debugPrint(
          '📦 [AssistantStorage] ${archived ? 'Archived' : 'Unarchived'} assistant: $assistantId',
        );
      }
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('❌ [AssistantStorage] Failed to archive assistant: $e\n$st');
      }
      rethrow;
    }
  }

  /// Get a specific assistant by ID (checks own + public cache)
  static Assistant? getAssistant(String assistantId) {
    return _assistantsById[assistantId] ??
        _publicAssistantsById[assistantId];
  }

  /// Get assistant for a specific chat
  static Assistant? getAssistantForChat(String chatId) {
    final assistantId = _chatToAssistantMap[chatId];
    if (assistantId == null) return null;
    return _assistantsById[assistantId];
  }

  // ============ CHAT MANAGEMENT ============

  /// Link a chat to an assistant
  static Future<void> linkChatToAssistant(
    String assistantId,
    String chatId,
  ) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to link chats.');
    }

    try {
      // First check if chat is already linked to another assistant
      final existing = await SupabaseService.client
          .from('assistant_chats')
          .select('id')
          .eq('chat_id', chatId)
          .maybeSingle();

      if (existing != null) {
        // Update existing link
        await SupabaseService.client
            .from('assistant_chats')
            .update({'assistant_id': assistantId})
            .eq('id', existing['id']);
      } else {
        // Create new link
        await SupabaseService.client.from('assistant_chats').insert({
          'assistant_id': assistantId,
          'chat_id': chatId,
        });
      }

      // Update local cache
      _chatToAssistantMap[chatId] = assistantId;

      if (kDebugMode) {
        debugPrint(
          '✅ [AssistantStorage] Linked chat $chatId to assistant $assistantId',
        );
      }
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('❌ [AssistantStorage] Failed to link chat: $e\n$st');
      }
      rethrow;
    }
  }

  /// Unlink a chat from its assistant
  static Future<void> unlinkChat(String chatId) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to unlink chats.');
    }

    try {
      await SupabaseService.client
          .from('assistant_chats')
          .delete()
          .eq('chat_id', chatId);

      _chatToAssistantMap.remove(chatId);

      if (kDebugMode) {
        debugPrint('✅ [AssistantStorage] Unlinked chat $chatId from assistant');
      }
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('❌ [AssistantStorage] Failed to unlink chat: $e\n$st');
      }
      rethrow;
    }
  }

  /// Check if a chat is linked to an assistant
  static bool isChatLinked(String chatId) {
    return _chatToAssistantMap.containsKey(chatId);
  }

  /// Get the assistant ID for a chat (if linked)
  static String? getAssistantIdForChat(String chatId) {
    return _chatToAssistantMap[chatId];
  }

  /// Load assistant-chat relationships (called during chat loading)
  static Future<void> loadAssistantChatLinks() async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) return;

    try {
      final rows = await SupabaseService.client
          .from('assistant_chats')
          .select('chat_id, assistant_id');

      _chatToAssistantMap.clear();
      for (final row in rows) {
        final chatId = row['chat_id'] as String;
        final assistantId = row['assistant_id'] as String;
        _chatToAssistantMap[chatId] = assistantId;
      }

      if (kDebugMode) {
        debugPrint(
          '✅ [AssistantStorage] Loaded ${rows.length} assistant-chat links',
        );
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ [AssistantStorage] Failed to load chat links: $e');
      }
    }
  }

  // ============ AVATAR IMAGE MANAGEMENT ============

  /// Upload an avatar image for an assistant.
  /// Compresses, encrypts, and stores in the images bucket.
  /// Returns the updated assistant.
  static Future<Assistant> uploadAvatar(
    String assistantId,
    Uint8List imageBytes,
  ) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to upload avatar.');
    }

    try {
      // Delete existing avatar if present
      final existing = _assistantsById[assistantId];
      if (existing?.avatarImagePath != null) {
        try {
          await ImageStorageService.deleteEncryptedImage(
            existing!.avatarImagePath!,
          );
        } catch (e) {
          if (kDebugMode) {
            debugPrint('⚠️ [AssistantStorage] Failed to delete old avatar: $e');
          }
        }
      }

      // Upload new avatar using existing encrypted image pipeline
      final storagePath =
          await ImageStorageService.uploadEncryptedImage(imageBytes);

      // Update the assistant record with the new path
      try {
        return await updateAssistant(
          assistantId,
          avatarImagePath: storagePath,
        );
      } catch (e) {
        // Clean up uploaded image if DB update fails
        try {
          await ImageStorageService.deleteEncryptedImage(storagePath);
        } catch (_) {
          // Best-effort cleanup
        }
        rethrow;
      }
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('❌ [AssistantStorage] Failed to upload avatar: $e\n$st');
      }
      rethrow;
    }
  }

  /// Delete the avatar image for an assistant.
  static Future<Assistant> deleteAvatar(String assistantId) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to delete avatar.');
    }

    final existing = _assistantsById[assistantId];
    if (existing?.avatarImagePath != null) {
      try {
        await ImageStorageService.deleteEncryptedImage(
          existing!.avatarImagePath!,
        );
      } catch (e) {
        if (kDebugMode) {
          debugPrint('⚠️ [AssistantStorage] Failed to delete avatar file: $e');
        }
      }
    }

    final updated = await SupabaseService.client
        .from('assistants')
        .update({'avatar_image_path': null})
        .eq('id', assistantId)
        .eq('user_id', user.id)
        .select()
        .single();

    final assistant = Assistant.fromJson(updated);
    _assistantsById[assistantId] = assistant;
    _notifyChanges();

    if (kDebugMode) {
      debugPrint('🗑️ [AssistantStorage] Deleted avatar for: $assistantId');
    }
    return assistant;
  }

  // ============ SYSTEM PROMPT SELF-UPDATE ============

  /// Update system prompt (called by the assistant itself via tool)
  static Future<Assistant> updateSystemPrompt(
    String assistantId,
    String newSystemPrompt,
  ) async {
    return updateAssistant(assistantId, systemPrompt: newSystemPrompt);
  }

  // ============ STATE MANAGEMENT ============

  /// Reset all state (on logout)
  static Future<void> reset() async {
    _assistantsById.clear();
    _publicAssistantsById.clear();
    _chatToAssistantMap.clear();
    selectedAssistantId = null;
    _cacheLoaded = false;
    _isLoadingFromNetwork = false;
    _loadingCompleter = null;
    _notifyDebounceTimer?.cancel();
    _hasPendingNotification = false;
    _notifyChangesImmediate();
  }

  /// Load assistants for sidebar (only if empty)
  static Future<void> loadAssistantsForSidebar() async {
    if (_assistantsById.isEmpty) {
      await loadAssistants();
    }
  }
}
