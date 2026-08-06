// lib/services/workspace_storage_service.dart
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:chuk_chat/constants/file_constants.dart';
import 'package:chuk_chat/models/workspace_model.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/image_storage_service.dart';
import 'package:chuk_chat/services/local_chat_cache_service.dart';
import 'package:chuk_chat/services/file_conversion_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';

/// Service for managing workspace workspaces, chat assignments, and file attachments
class WorkspaceStorageService {
  static const String bucketName = 'workspace-files';
  static const String _cacheKey = 'cached_projects';
  static const Uuid _uuid = Uuid();

  // SINGLE SOURCE OF TRUTH - all projects stored here
  static final Map<String, Workspace> _projectsById = <String, Workspace>{};
  static bool _cacheLoaded = false;
  static bool _isLoadingFromNetwork = false;

  // Prevent concurrent loadProjects() calls
  static Completer<void>? _loadingCompleter;
  static bool get _isLoading =>
      _loadingCompleter != null && !_loadingCompleter!.isCompleted;

  static final StreamController<void> _changesController =
      StreamController<void>.broadcast();

  // Debounce for _notifyChanges to prevent rapid-fire UI rebuilds
  static Timer? _notifyDebounceTimer;
  static bool _hasPendingNotification = false;
  static const Duration _notifyDebounceDelay = Duration(milliseconds: 100);

  // Currently selected workspace (for chat UI context)
  static String? selectedWorkspaceId;

  // Get projects as a sorted list (most recent first)
  static List<Workspace> get projects {
    final list = _projectsById.values.toList();
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return List.unmodifiable(list);
  }

  // Get non-archived projects
  static List<Workspace> get activeProjects {
    return projects.where((p) => !p.isArchived).toList();
  }

  // Get archived projects
  static List<Workspace> get archivedProjects {
    return projects.where((p) => p.isArchived).toList();
  }

  static Stream<void> get changes => _changesController.stream;

  /// Notify listeners of changes with debouncing to prevent rapid-fire UI rebuilds.
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

    // Auto-save to cache when data changes (but not during network load - that saves at the end)
    if (updateCache && _cacheLoaded && !_isLoadingFromNetwork) {
      unawaited(_saveToCache());
    }
  }

  /// Notify immediately without debounce (for critical updates like initial cache load)
  static void _notifyChangesImmediate() {
    if (!_changesController.isClosed) {
      _changesController.add(null);
    }
  }

  // ============ LOCAL CACHE ============

  /// Load projects from local cache (fast, for instant UI)
  static Future<void> loadFromCache() async {
    if (_cacheLoaded) return;

    try {
      final cached = await LocalChatCacheService.kvGet(_cacheKey);
      if (cached != null && cached.isNotEmpty) {
        final List<dynamic> jsonList = jsonDecode(cached);
        _projectsById.clear();
        for (final json in jsonList) {
          final workspace = Workspace.fromJson(json);
          _projectsById[workspace.id] = workspace;
        }
        if (kDebugMode) {
          debugPrint(
            '✅ [ProjectStorage] Loaded ${_projectsById.length} projects from cache',
          );
        }
        _cacheLoaded = true;
        _notifyChangesImmediate();
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ [ProjectStorage] Failed to load cache: $e');
      }
    }
  }

  /// Save projects to local cache
  static Future<void> _saveToCache() async {
    try {
      final jsonList = _projectsById.values.map((p) => p.toJson()).toList();
      await LocalChatCacheService.kvSet(_cacheKey, jsonEncode(jsonList));
      if (kDebugMode) {
        debugPrint(
          '✅ [ProjectStorage] Saved ${jsonList.length} projects to cache',
        );
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ [ProjectStorage] Failed to save cache: $e');
      }
    }
  }

  // ============ PROJECT CRUD OPERATIONS ============

  /// Load all projects from Supabase (updates cache)
  /// Uses cache-first pattern: loads from cache immediately, then syncs from network.
  static Future<void> loadProjects() async {
    // First load from cache for instant UI (if not already loaded)
    if (!_cacheLoaded) {
      await loadFromCache();
    }

    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      if (kDebugMode) {
        debugPrint('⚠️ [ProjectStorage] No user signed in, clearing projects');
      }
      _projectsById.clear();
      _notifyChanges(updateCache: false);
      return;
    }

    // Prevent concurrent loads - wait for existing load to finish
    if (_isLoading) {
      if (kDebugMode) {
        debugPrint('⏳ [ProjectStorage] Load already in progress, waiting...');
      }
      return _loadingCompleter!.future;
    }
    _loadingCompleter = Completer<void>();
    _isLoadingFromNetwork = true;

    try {
      // Load projects from server
      final projectRows = await SupabaseService.client
          .from('projects')
          .select('*')
          .eq('user_id', user.id)
          .order('created_at', ascending: false);

      if (kDebugMode) {
        debugPrint(
          '✅ [ProjectStorage] Loaded ${projectRows.length} projects from server',
        );
      }

      // Skip network fetch work if no projects
      if (projectRows.isEmpty) {
        if (_projectsById.isNotEmpty) {
          _projectsById.clear();
          await _saveToCache();
          _notifyChanges(updateCache: false);
        }
        return;
      }

      // Load workspace-chat relationships AND workspace files in PARALLEL
      final workspaceIds = projectRows.map((p) => p['id'] as String).toList();
      final chatsFuture = SupabaseService.client
          .from('project_chats')
          .select('project_id, chat_id')
          .inFilter('project_id', workspaceIds);
      final filesFuture = SupabaseService.client
          .from('project_files')
          .select('*')
          .inFilter('project_id', workspaceIds);

      final results = await Future.wait<dynamic>([chatsFuture, filesFuture]);
      final projectChatRows = results[0] as List<dynamic>;
      final fileRows = results[1] as List<dynamic>;

      // Group chat IDs by workspace ID
      final Map<String, List<String>> chatIdsByProject = {};
      for (final row in projectChatRows) {
        final workspaceId = row['project_id'] as String;
        final chatId = row['chat_id'] as String;
        chatIdsByProject.putIfAbsent(workspaceId, () => []).add(chatId);
      }

      // Group files by workspace ID
      final Map<String, List<WorkspaceFile>> filesByProject = {};
      for (final row in fileRows) {
        final workspaceId = row['project_id'] as String;
        final file = WorkspaceFile.fromJson(row);
        filesByProject.putIfAbsent(workspaceId, () => []).add(file);
      }

      // Build Workspace objects
      _projectsById.clear();
      for (final row in projectRows) {
        final workspaceId = row['id'] as String;
        final workspace = Workspace.fromJson({
          ...row,
          'chatIds': chatIdsByProject[workspaceId] ?? [],
          'files':
              filesByProject[workspaceId]?.map((f) => f.toJson()).toList() ?? [],
        });
        _projectsById[workspaceId] = workspace;
      }

      // Save to cache for next time (only once, not via _notifyChanges)
      await _saveToCache();
      // Notify without auto-save since we just saved
      _notifyChanges(updateCache: false);
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('❌ [ProjectStorage] Failed to load projects: $e\n$st');
      }
      // Don't rethrow if we have cached data
      if (_projectsById.isEmpty) rethrow;
    } finally {
      _isLoadingFromNetwork = false;
      _loadingCompleter?.complete();
      _loadingCompleter = null;
    }
  }

  /// Create a new workspace
  static Future<Workspace> createProject(
    String name, {
    String? description,
    String? customSystemPrompt,
  }) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to create projects.');
    }

    try {
      final Map<String, dynamic> insertData = {
        'user_id': user.id,
        'name': name.trim(),
        if (description != null && description.trim().isNotEmpty)
          'description': description.trim(),
        if (customSystemPrompt != null && customSystemPrompt.trim().isNotEmpty)
          'custom_system_prompt': customSystemPrompt.trim(),
      };

      final inserted = await SupabaseService.client
          .from('projects')
          .insert(insertData)
          .select()
          .single();

      final workspace = Workspace.fromJson(inserted);
      _projectsById[workspace.id] = workspace;
      _notifyChanges();

      if (kDebugMode) {
        debugPrint('✅ [ProjectStorage] Created workspace: ${workspace.id}');
      }
      return workspace;
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('❌ [ProjectStorage] Failed to create workspace: $e\n$st');
      }
      rethrow;
    }
  }

  /// Update an existing workspace
  static Future<Workspace> updateProject(
    String workspaceId, {
    String? name,
    String? description,
    String? customSystemPrompt,
  }) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to update projects.');
    }

    try {
      final Map<String, dynamic> updateData = {};
      if (name != null) updateData['name'] = name.trim();
      if (description != null) updateData['description'] = description.trim();
      if (customSystemPrompt != null) {
        updateData['custom_system_prompt'] = customSystemPrompt.trim();
      }

      if (updateData.isEmpty) {
        throw ArgumentError('At least one field must be updated');
      }

      final updated = await SupabaseService.client
          .from('projects')
          .update(updateData)
          .eq('id', workspaceId)
          .eq('user_id', user.id)
          .select()
          .single();

      final existingProject = _projectsById[workspaceId];
      final workspace = Workspace.fromJson({
        ...updated,
        'chatIds': existingProject?.chatIds ?? [],
        'files': existingProject?.files.map((f) => f.toJson()).toList() ?? [],
      });

      _projectsById[workspaceId] = workspace;
      _notifyChanges();

      if (kDebugMode) {
        debugPrint('✅ [ProjectStorage] Updated workspace: $workspaceId');
      }
      return workspace;
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('❌ [ProjectStorage] Failed to update workspace: $e\n$st');
      }
      rethrow;
    }
  }

  /// Delete a workspace (cascades to project_chats and project_files via DB)
  static Future<void> deleteProject(String workspaceId) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to delete projects.');
    }

    try {
      await SupabaseService.client
          .from('projects')
          .delete()
          .eq('id', workspaceId)
          .eq('user_id', user.id);

      _projectsById.remove(workspaceId);
      if (selectedWorkspaceId == workspaceId) {
        selectedWorkspaceId = null;
      }
      _notifyChanges();

      if (kDebugMode) {
        debugPrint('🗑️ [ProjectStorage] Deleted workspace: $workspaceId');
      }
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('❌ [ProjectStorage] Failed to delete workspace: $e\n$st');
      }
      rethrow;
    }
  }

  /// Archive or unarchive a workspace
  static Future<void> archiveProject(String workspaceId, bool archived) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to archive projects.');
    }

    try {
      await SupabaseService.client
          .from('projects')
          .update({'is_archived': archived})
          .eq('id', workspaceId)
          .eq('user_id', user.id);

      final existingProject = _projectsById[workspaceId];
      if (existingProject != null) {
        _projectsById[workspaceId] = existingProject.copyWith(
          isArchived: archived,
        );
        _notifyChanges();
      }

      if (kDebugMode) {
        debugPrint(
          '📦 [ProjectStorage] ${archived ? 'Archived' : 'Unarchived'} workspace: $workspaceId',
        );
      }
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('❌ [ProjectStorage] Failed to archive workspace: $e\n$st');
      }
      rethrow;
    }
  }

  /// Get a specific workspace by ID
  static Workspace? getWorkspace(String workspaceId) {
    return _projectsById[workspaceId];
  }

  /// Get the workspace associated with a specific chat (if any)
  static Workspace? getWorkspaceForChat(String chatId) {
    for (final ws in _projectsById.values) {
      if (ws.chatIds.contains(chatId)) return ws;
    }
    return null;
  }

  /// Link a chat to a workspace (alias for addChatToProject)
  static Future<void> linkChatToWorkspace(
    String workspaceId,
    String chatId,
  ) => addChatToProject(workspaceId, chatId);

  // ============ CHAT MANAGEMENT ============

  /// Add a chat to a workspace
  static Future<void> addChatToProject(String workspaceId, String chatId) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to manage workspace chats.');
    }

    try {
      await SupabaseService.client.from('project_chats').insert({
        'project_id': workspaceId,
        'chat_id': chatId,
      });

      final workspace = _projectsById[workspaceId];
      if (workspace != null && !workspace.chatIds.contains(chatId)) {
        _projectsById[workspaceId] = workspace.copyWith(
          chatIds: [...workspace.chatIds, chatId],
        );
        _notifyChanges();
      }

      if (kDebugMode) {
        debugPrint(
          '✅ [ProjectStorage] Added chat $chatId to workspace $workspaceId',
        );
      }
    } catch (e, st) {
      // Ignore unique constraint violations (chat already in workspace)
      if (e.toString().contains('unique_project_chat')) {
        if (kDebugMode) {
          debugPrint('⚠️ [ProjectStorage] Chat already in workspace');
        }
        return;
      }
      if (kDebugMode) {
        debugPrint('❌ [ProjectStorage] Failed to add chat to workspace: $e\n$st');
      }
      rethrow;
    }
  }

  /// Remove a chat from a workspace
  static Future<void> removeChatFromProject(
    String workspaceId,
    String chatId,
  ) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to manage workspace chats.');
    }

    try {
      await SupabaseService.client
          .from('project_chats')
          .delete()
          .eq('project_id', workspaceId)
          .eq('chat_id', chatId);

      final workspace = _projectsById[workspaceId];
      if (workspace != null) {
        _projectsById[workspaceId] = workspace.copyWith(
          chatIds: workspace.chatIds.where((id) => id != chatId).toList(),
        );
        _notifyChanges();
      }

      if (kDebugMode) {
        debugPrint(
          '✅ [ProjectStorage] Removed chat $chatId from workspace $workspaceId',
        );
      }
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint(
          '❌ [ProjectStorage] Failed to remove chat from workspace: $e\n$st',
        );
      }
      rethrow;
    }
  }

  /// Get all chats in a workspace
  static Future<List<StoredChat>> getProjectChats(String workspaceId) async {
    final workspace = _projectsById[workspaceId];
    if (workspace == null) return [];

    // Get chats from ChatStorageService
    final allChats = ChatStorageService.savedChats;
    return allChats.where((chat) => workspace.chatIds.contains(chat.id)).toList();
  }

  /// Get all projects that contain a specific chat
  static List<Workspace> getChatProjects(String chatId) {
    return projects.where((p) => p.chatIds.contains(chatId)).toList();
  }

  // ============ AVATAR IMAGE MANAGEMENT ============

  /// Upload an avatar image for a workspace.
  static Future<void> uploadAvatar(
    String workspaceId,
    Uint8List imageBytes,
  ) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) throw StateError('User must be signed in.');

    // Delete existing avatar if present
    final existing = _projectsById[workspaceId];
    if (existing?.avatarImagePath != null) {
      try {
        await ImageStorageService.deleteEncryptedImage(
          existing!.avatarImagePath!,
        );
      } catch (_) {}
    }

    final storagePath =
        await ImageStorageService.uploadEncryptedImage(imageBytes);

    try {
      await SupabaseService.client
          .from('projects')
          .update({'avatar_image_path': storagePath})
          .eq('id', workspaceId)
          .eq('user_id', user.id);

      if (_projectsById.containsKey(workspaceId)) {
        _projectsById[workspaceId] = _projectsById[workspaceId]!.copyWith(
          avatarImagePath: storagePath,
        );
        _notifyChanges();
      }
    } catch (e) {
      // Clean up uploaded image on DB failure
      try {
        await ImageStorageService.deleteEncryptedImage(storagePath);
      } catch (_) {}
      rethrow;
    }
  }

  /// Delete the avatar image for a workspace.
  static Future<void> deleteAvatar(String workspaceId) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) throw StateError('User must be signed in.');

    final existing = _projectsById[workspaceId];
    if (existing?.avatarImagePath != null) {
      try {
        await ImageStorageService.deleteEncryptedImage(
          existing!.avatarImagePath!,
        );
      } catch (_) {}
    }

    await SupabaseService.client
        .from('projects')
        .update({'avatar_image_path': null})
        .eq('id', workspaceId)
        .eq('user_id', user.id);

    if (_projectsById.containsKey(workspaceId)) {
      _projectsById[workspaceId] = _projectsById[workspaceId]!.copyWith(
        avatarImagePath: null,
      );
      _notifyChanges();
    }
  }

  // ============ FILE MANAGEMENT ============

  /// Upload a file to a workspace (encrypted in Supabase Storage)
  /// If [filePath] is provided and [generateMarkdown] is true, will also generate
  /// an AI markdown summary of the file content.
  ///
  /// [onUploadProgress] is called with progress (0.0-1.0) during upload
  /// [onConversionStart] is called when markdown conversion begins
  static Future<WorkspaceFile> uploadFile(
    String workspaceId,
    String fileName,
    Uint8List fileBytes,
    String fileType, {
    String? filePath,
    bool generateMarkdown = true,
    void Function(double progress)? onUploadProgress,
    void Function()? onConversionStart,
  }) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to upload files.');
    }

    final session = SupabaseService.auth.currentSession;
    if (session == null) {
      throw StateError('No active session. Please sign in again.');
    }

    if (!EncryptionService.hasKey) {
      final loaded = await EncryptionService.tryLoadKey();
      if (!loaded) {
        throw StateError('Encryption key is missing. Please sign in again.');
      }
    }

    try {
      // Step 1: Encrypt file content (0-20%)
      onUploadProgress?.call(0.05);
      final fileContent = utf8.decode(fileBytes, allowMalformed: true);
      final encryptedJson = await EncryptionService.encrypt(fileContent);
      final encryptedBytes = Uint8List.fromList(utf8.encode(encryptedJson));
      onUploadProgress?.call(0.20);

      // Step 2: Upload to Supabase Storage (20-90%)
      final fileId = _uuid.v4();
      final storageFileName = '$fileId.enc';
      final storagePath = '${user.id}/$storageFileName';

      // Simulate upload progress in chunks
      onUploadProgress?.call(0.30);
      await SupabaseService.client.storage
          .from(bucketName)
          .uploadBinary(
            storagePath,
            encryptedBytes,
            fileOptions: const FileOptions(
              contentType: 'application/octet-stream',
              upsert: false,
            ),
          );
      onUploadProgress?.call(0.90);

      // Step 3: Generate markdown summary
      // Plain text files: read directly (no API call needed)
      // Binary files (PDF, Office docs): use convert-file API
      String? markdownSummary;
      if (generateMarkdown) {
        final extension = fileType.toLowerCase();

        if (FileConstants.isPlainText(extension)) {
          // Plain text file: use content directly
          final content = utf8.decode(fileBytes, allowMalformed: true);

          // Check token limit (40k tokens ≈ 160k chars)
          if (content.length > FileConversionService.maxCharsPerFile) {
            final estimatedTokens = (content.length / 4).round();
            throw StateError(
              'File is too large (~$estimatedTokens tokens). '
              'Maximum allowed is ${FileConversionService.maxTokensPerFile} tokens. '
              'Try a smaller file.',
            );
          }

          markdownSummary =
              '**File: $fileName**\n\n```$extension\n$content\n```';
          if (kDebugMode) {
            debugPrint(
              '📝 [ProjectStorage] Plain text file read directly: $fileName',
            );
          }
        } else if (filePath != null &&
            FileConstants.requiresConversion(extension)) {
          // Binary file: use convert-file API - notify UI
          onConversionStart?.call();
          try {
            if (kDebugMode) {
              debugPrint(
                '📝 [ProjectStorage] Generating markdown via API for: $fileName',
              );
            }
            final result = await FileConversionService.convertFile(
              filePath: filePath,
              accessToken: session.accessToken,
              userId: user.id,
            );
            if (result['success'] == true && result['markdown'] != null) {
              final pageImages = result['pageImages'] as List?;
              if (pageImages != null && pageImages.isNotEmpty) {
                // Scanned PDF: the API returns page images for a chat
                // message to attach. A workspace file holds text only, so
                // say what the file is instead of repeating a note that
                // promises images nobody attached here.
                markdownSummary =
                    '**$fileName** is a scanned document (${pageImages.length} '
                    'page images, no text layer). Attach it to a chat message '
                    'to have its pages read.';
              } else {
                markdownSummary = result['markdown'] as String;
              }
              if (kDebugMode) {
                debugPrint(
                  '✅ [ProjectStorage] Markdown generated successfully',
                );
              }
            } else {
              // Propagate the error to the UI instead of silently continuing
              final error = result['error'] as String?;
              if (error != null && error.contains('tokens')) {
                // Token limit error - throw to show to user
                throw StateError(error);
              }
              if (kDebugMode) {
                debugPrint(
                  '⚠️ [ProjectStorage] Markdown generation failed: $error',
                );
              }
            }
          } catch (e) {
            if (e is StateError) {
              rethrow; // Re-throw token limit errors
            }
            if (kDebugMode) {
              debugPrint('⚠️ [ProjectStorage] Markdown generation error: $e');
            }
            // Continue without markdown - don't fail the upload for other errors
          }
        }
      }
      onUploadProgress?.call(1.0);

      // Step 4: Save metadata to database
      final insertData = {
        'project_id': workspaceId,
        'file_name': fileName,
        'storage_path': storagePath,
        'file_type': fileType,
        'file_size': fileBytes.length,
      };
      if (markdownSummary != null) {
        insertData['markdown_summary'] = markdownSummary;
      }

      final inserted = await SupabaseService.client
          .from('project_files')
          .insert(insertData)
          .select()
          .single();

      final projectFile = WorkspaceFile.fromJson(inserted);

      // Update workspace in cache
      final workspace = _projectsById[workspaceId];
      if (workspace != null) {
        _projectsById[workspaceId] = workspace.copyWith(
          files: [...workspace.files, projectFile],
        );
        _notifyChanges();
      }

      if (kDebugMode) {
        debugPrint('✅ [ProjectStorage] Uploaded file: $fileName to $workspaceId');
      }
      return projectFile;
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('❌ [ProjectStorage] Failed to upload file: $e\n$st');
      }
      rethrow;
    }
  }

  /// Delete a file from a workspace (also deletes from storage)
  static Future<void> deleteFile(String workspaceId, String fileId) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to delete files.');
    }

    try {
      // Find file to get storage path
      final workspace = _projectsById[workspaceId];
      final file = workspace?.files.firstWhere((f) => f.id == fileId);

      // Delete from database first
      await SupabaseService.client
          .from('project_files')
          .delete()
          .eq('id', fileId);

      // Delete from storage
      if (file != null) {
        try {
          await SupabaseService.client.storage.from(bucketName).remove([
            file.storagePath,
          ]);
        } catch (e) {
          if (kDebugMode) {
            debugPrint(
              '⚠️ [ProjectStorage] Failed to delete file from storage: $e',
            );
          }
          // Continue even if storage deletion fails
        }
      }

      // Update cache
      if (workspace != null) {
        _projectsById[workspaceId] = workspace.copyWith(
          files: workspace.files.where((f) => f.id != fileId).toList(),
        );
        _notifyChanges();
      }

      if (kDebugMode) {
        debugPrint('🗑️ [ProjectStorage] Deleted file: $fileId');
      }
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('❌ [ProjectStorage] Failed to delete file: $e\n$st');
      }
      rethrow;
    }
  }

  /// Get all files for a workspace
  static List<WorkspaceFile> getProjectFiles(String workspaceId) {
    final workspace = _projectsById[workspaceId];
    return workspace?.files ?? [];
  }

  /// Download and decrypt a file's content from Supabase Storage
  static Future<String> decryptFile(String fileId) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to download files.');
    }

    if (!EncryptionService.hasKey) {
      final loaded = await EncryptionService.tryLoadKey();
      if (!loaded) {
        throw StateError('Encryption key is missing. Please sign in again.');
      }
    }

    try {
      // Find file in all projects to get storage path
      WorkspaceFile? file;
      for (final workspace in _projectsById.values) {
        try {
          file = workspace.files.firstWhere((f) => f.id == fileId);
          break;
        } catch (_) {
          // File not in this workspace, continue searching
        }
      }

      if (file == null) {
        throw StateError('File not found');
      }

      // Download encrypted file from storage
      final encryptedBytes = await SupabaseService.client.storage
          .from(bucketName)
          .download(file.storagePath);

      // Convert bytes to string (JSON format)
      final encryptedJson = utf8.decode(encryptedBytes);

      // Decrypt the file content
      final decryptedContent = await EncryptionService.decrypt(encryptedJson);

      return decryptedContent;
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint(
          '❌ [ProjectStorage] Failed to download/decrypt file: $e\n$st',
        );
      }
      rethrow;
    }
  }

  /// Download and decrypt a file, returning raw bytes
  static Future<Uint8List> downloadFile(String workspaceId, String fileId) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to download files.');
    }

    if (!EncryptionService.hasKey) {
      final loaded = await EncryptionService.tryLoadKey();
      if (!loaded) {
        throw StateError('Encryption key is missing. Please sign in again.');
      }
    }

    try {
      // Find file in workspace
      final workspace = _projectsById[workspaceId];
      final file = workspace?.files.firstWhere((f) => f.id == fileId);

      if (file == null) {
        throw StateError('File not found');
      }

      // Download encrypted file from storage
      final encryptedBytes = await SupabaseService.client.storage
          .from(bucketName)
          .download(file.storagePath);

      // Convert bytes to string (JSON format)
      final encryptedJson = utf8.decode(encryptedBytes);

      // Decrypt the file content
      final decryptedContent = await EncryptionService.decrypt(encryptedJson);

      // Return as bytes
      return Uint8List.fromList(utf8.encode(decryptedContent));
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('❌ [ProjectStorage] Failed to download file: $e\n$st');
      }
      rethrow;
    }
  }

  /// Update a file's encrypted content
  static Future<void> updateFileContent(
    String workspaceId,
    String fileId,
    Uint8List newBytes,
  ) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to update files.');
    }

    if (!EncryptionService.hasKey) {
      final loaded = await EncryptionService.tryLoadKey();
      if (!loaded) {
        throw StateError('Encryption key is missing. Please sign in again.');
      }
    }

    try {
      // Find file in workspace
      final workspace = _projectsById[workspaceId];
      final file = workspace?.files.firstWhere((f) => f.id == fileId);

      if (file == null) {
        throw StateError('File not found');
      }

      // Encrypt new content
      final fileContent = utf8.decode(newBytes);
      final encryptedJson = await EncryptionService.encrypt(fileContent);
      final encryptedBytes = Uint8List.fromList(utf8.encode(encryptedJson));

      // Upload to storage (upsert to replace existing)
      await SupabaseService.client.storage
          .from(bucketName)
          .uploadBinary(
            file.storagePath,
            encryptedBytes,
            fileOptions: const FileOptions(
              contentType: 'application/octet-stream',
              upsert: true,
            ),
          );

      // Update file size in database
      await SupabaseService.client
          .from('project_files')
          .update({'file_size': newBytes.length})
          .eq('id', fileId);

      // Update cache
      if (workspace != null) {
        final updatedFiles = workspace.files.map((f) {
          if (f.id == fileId) {
            return WorkspaceFile(
              id: f.id,
              workspaceId: f.workspaceId,
              fileName: f.fileName,
              storagePath: f.storagePath,
              fileType: f.fileType,
              fileSize: newBytes.length,
              uploadedAt: f.uploadedAt,
              markdownSummary: f.markdownSummary,
            );
          }
          return f;
        }).toList();

        _projectsById[workspaceId] = workspace.copyWith(files: updatedFiles);
        _notifyChanges();
      }

      if (kDebugMode) {
        debugPrint('✅ [ProjectStorage] Updated file content: $fileId');
      }
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('❌ [ProjectStorage] Failed to update file: $e\n$st');
      }
      rethrow;
    }
  }

  /// Update a file's markdown summary
  static Future<void> updateFileMarkdown(
    String workspaceId,
    String fileId,
    String? markdown,
  ) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to update files.');
    }

    try {
      // Update in database
      await SupabaseService.client
          .from('project_files')
          .update({'markdown_summary': markdown})
          .eq('id', fileId);

      // Update cache
      final workspace = _projectsById[workspaceId];
      if (workspace != null) {
        final updatedFiles = workspace.files.map((f) {
          if (f.id == fileId) {
            return f.copyWith(markdownSummary: markdown);
          }
          return f;
        }).toList();

        _projectsById[workspaceId] = workspace.copyWith(files: updatedFiles);
        _notifyChanges();
      }

      if (kDebugMode) {
        debugPrint('✅ [ProjectStorage] Updated file markdown: $fileId');
      }
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('❌ [ProjectStorage] Failed to update markdown: $e\n$st');
      }
      rethrow;
    }
  }

  // ============ STATE MANAGEMENT ============

  /// Reset all state (on logout)
  static Future<void> reset() async {
    _projectsById.clear();
    selectedWorkspaceId = null;
    _cacheLoaded = false;
    _isLoadingFromNetwork = false;
    _loadingCompleter = null;
    _notifyDebounceTimer?.cancel();
    _hasPendingNotification = false;
    _notifyChangesImmediate();
  }

  /// Load projects for sidebar (only if empty)
  static Future<void> loadProjectsForSidebar() async {
    if (_projectsById.isEmpty) {
      await loadProjects();
    }
  }
}
