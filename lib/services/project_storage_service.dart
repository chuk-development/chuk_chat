// lib/services/project_storage_service.dart
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:chuk_chat/models/project_model.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';

/// Service for managing project workspaces, chat assignments, and file attachments
class ProjectStorageService {
  static const String bucketName = 'project-files';
  static const String _cacheKey = 'cached_projects';
  static const Uuid _uuid = Uuid();

  // SINGLE SOURCE OF TRUTH - all projects stored here
  static final Map<String, Project> _projectsById = <String, Project>{};
  static bool _cacheLoaded = false;

  static final StreamController<void> _changesController =
      StreamController<void>.broadcast();

  // Currently selected project (for chat UI context)
  static String? selectedProjectId;

  // Get projects as a sorted list (most recent first)
  static List<Project> get projects {
    final list = _projectsById.values.toList();
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return List.unmodifiable(list);
  }

  // Get non-archived projects
  static List<Project> get activeProjects {
    return projects.where((p) => !p.isArchived).toList();
  }

  // Get archived projects
  static List<Project> get archivedProjects {
    return projects.where((p) => p.isArchived).toList();
  }

  static Stream<void> get changes => _changesController.stream;

  static void _notifyChanges({bool updateCache = true}) {
    if (!_changesController.isClosed) {
      _changesController.add(null);
    }
    // Auto-save to cache when data changes
    if (updateCache && _cacheLoaded) {
      _saveToCache();
    }
  }

  // ============ LOCAL CACHE ============

  /// Load projects from local cache (fast, for instant UI)
  static Future<void> loadFromCache() async {
    if (_cacheLoaded) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString(_cacheKey);
      if (cached != null && cached.isNotEmpty) {
        final List<dynamic> jsonList = jsonDecode(cached);
        _projectsById.clear();
        for (final json in jsonList) {
          final project = Project.fromJson(json);
          _projectsById[project.id] = project;
        }
        debugPrint('✅ [ProjectStorage] Loaded ${_projectsById.length} projects from cache');
        _cacheLoaded = true;
        _notifyChanges();
      }
    } catch (e) {
      debugPrint('⚠️ [ProjectStorage] Failed to load cache: $e');
    }
  }

  /// Save projects to local cache
  static Future<void> _saveToCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonList = _projectsById.values.map((p) => p.toJson()).toList();
      await prefs.setString(_cacheKey, jsonEncode(jsonList));
      debugPrint('✅ [ProjectStorage] Saved ${jsonList.length} projects to cache');
    } catch (e) {
      debugPrint('⚠️ [ProjectStorage] Failed to save cache: $e');
    }
  }

  // ============ PROJECT CRUD OPERATIONS ============

  /// Load all projects from Supabase (updates cache)
  static Future<void> loadProjects() async {
    // First load from cache for instant UI
    if (!_cacheLoaded) {
      await loadFromCache();
    }

    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      debugPrint('⚠️ [ProjectStorage] No user signed in, clearing projects');
      _projectsById.clear();
      _notifyChanges();
      return;
    }

    try {
      // Load projects from server
      final projectRows = await SupabaseService.client
          .from('projects')
          .select('*')
          .eq('user_id', user.id)
          .order('created_at', ascending: false);

      debugPrint('✅ [ProjectStorage] Loaded ${projectRows.length} projects from server');

      // Load all project-chat relationships
      final projectChatRows = await SupabaseService.client
          .from('project_chats')
          .select('project_id, chat_id')
          .inFilter(
        'project_id',
        projectRows.map((p) => p['id'] as String).toList(),
      );

      // Group chat IDs by project ID
      final Map<String, List<String>> chatIdsByProject = {};
      for (final row in projectChatRows) {
        final projectId = row['project_id'] as String;
        final chatId = row['chat_id'] as String;
        chatIdsByProject.putIfAbsent(projectId, () => []).add(chatId);
      }

      // Load all project files
      final fileRows = await SupabaseService.client
          .from('project_files')
          .select('*')
          .inFilter(
        'project_id',
        projectRows.map((p) => p['id'] as String).toList(),
      );

      // Group files by project ID
      final Map<String, List<ProjectFile>> filesByProject = {};
      for (final row in fileRows) {
        final projectId = row['project_id'] as String;
        final file = ProjectFile.fromJson(row);
        filesByProject.putIfAbsent(projectId, () => []).add(file);
      }

      // Build Project objects
      _projectsById.clear();
      for (final row in projectRows) {
        final projectId = row['id'] as String;
        final project = Project.fromJson({
          ...row,
          'chatIds': chatIdsByProject[projectId] ?? [],
          'files': filesByProject[projectId]?.map((f) => f.toJson()).toList() ??
              [],
        });
        _projectsById[projectId] = project;
      }

      // Save to cache for next time
      await _saveToCache();
      _notifyChanges();
    } catch (e, st) {
      debugPrint('❌ [ProjectStorage] Failed to load projects: $e\n$st');
      // Don't rethrow if we have cached data
      if (_projectsById.isEmpty) rethrow;
    }
  }

  /// Create a new project
  static Future<Project> createProject(
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

      final project = Project.fromJson(inserted);
      _projectsById[project.id] = project;
      _notifyChanges();

      debugPrint('✅ [ProjectStorage] Created project: ${project.id}');
      return project;
    } catch (e, st) {
      debugPrint('❌ [ProjectStorage] Failed to create project: $e\n$st');
      rethrow;
    }
  }

  /// Update an existing project
  static Future<Project> updateProject(
    String projectId, {
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
          .eq('id', projectId)
          .eq('user_id', user.id)
          .select()
          .single();

      final existingProject = _projectsById[projectId];
      final project = Project.fromJson({
        ...updated,
        'chatIds': existingProject?.chatIds ?? [],
        'files': existingProject?.files.map((f) => f.toJson()).toList() ?? [],
      });

      _projectsById[projectId] = project;
      _notifyChanges();

      debugPrint('✅ [ProjectStorage] Updated project: $projectId');
      return project;
    } catch (e, st) {
      debugPrint('❌ [ProjectStorage] Failed to update project: $e\n$st');
      rethrow;
    }
  }

  /// Delete a project (cascades to project_chats and project_files via DB)
  static Future<void> deleteProject(String projectId) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to delete projects.');
    }

    try {
      await SupabaseService.client
          .from('projects')
          .delete()
          .eq('id', projectId)
          .eq('user_id', user.id);

      _projectsById.remove(projectId);
      if (selectedProjectId == projectId) {
        selectedProjectId = null;
      }
      _notifyChanges();

      debugPrint('🗑️ [ProjectStorage] Deleted project: $projectId');
    } catch (e, st) {
      debugPrint('❌ [ProjectStorage] Failed to delete project: $e\n$st');
      rethrow;
    }
  }

  /// Archive or unarchive a project
  static Future<void> archiveProject(String projectId, bool archived) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to archive projects.');
    }

    try {
      await SupabaseService.client
          .from('projects')
          .update({'is_archived': archived})
          .eq('id', projectId)
          .eq('user_id', user.id);

      final existingProject = _projectsById[projectId];
      if (existingProject != null) {
        _projectsById[projectId] = existingProject.copyWith(isArchived: archived);
        _notifyChanges();
      }

      debugPrint(
        '📦 [ProjectStorage] ${archived ? 'Archived' : 'Unarchived'} project: $projectId',
      );
    } catch (e, st) {
      debugPrint('❌ [ProjectStorage] Failed to archive project: $e\n$st');
      rethrow;
    }
  }

  /// Get a specific project by ID
  static Project? getProject(String projectId) {
    return _projectsById[projectId];
  }

  // ============ CHAT MANAGEMENT ============

  /// Add a chat to a project
  static Future<void> addChatToProject(String projectId, String chatId) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to manage project chats.');
    }

    try {
      await SupabaseService.client.from('project_chats').insert({
        'project_id': projectId,
        'chat_id': chatId,
      });

      final project = _projectsById[projectId];
      if (project != null && !project.chatIds.contains(chatId)) {
        _projectsById[projectId] = project.copyWith(
          chatIds: [...project.chatIds, chatId],
        );
        _notifyChanges();
      }

      debugPrint('✅ [ProjectStorage] Added chat $chatId to project $projectId');
    } catch (e, st) {
      // Ignore unique constraint violations (chat already in project)
      if (e.toString().contains('unique_project_chat')) {
        debugPrint('⚠️ [ProjectStorage] Chat already in project');
        return;
      }
      debugPrint('❌ [ProjectStorage] Failed to add chat to project: $e\n$st');
      rethrow;
    }
  }

  /// Remove a chat from a project
  static Future<void> removeChatFromProject(
    String projectId,
    String chatId,
  ) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to manage project chats.');
    }

    try {
      await SupabaseService.client
          .from('project_chats')
          .delete()
          .eq('project_id', projectId)
          .eq('chat_id', chatId);

      final project = _projectsById[projectId];
      if (project != null) {
        _projectsById[projectId] = project.copyWith(
          chatIds: project.chatIds.where((id) => id != chatId).toList(),
        );
        _notifyChanges();
      }

      debugPrint(
        '✅ [ProjectStorage] Removed chat $chatId from project $projectId',
      );
    } catch (e, st) {
      debugPrint(
        '❌ [ProjectStorage] Failed to remove chat from project: $e\n$st',
      );
      rethrow;
    }
  }

  /// Get all chats in a project
  static Future<List<StoredChat>> getProjectChats(String projectId) async {
    final project = _projectsById[projectId];
    if (project == null) return [];

    // Get chats from ChatStorageService
    final allChats = ChatStorageService.savedChats;
    return allChats
        .where((chat) => project.chatIds.contains(chat.id))
        .toList();
  }

  /// Get all projects that contain a specific chat
  static List<Project> getChatProjects(String chatId) {
    return projects.where((p) => p.chatIds.contains(chatId)).toList();
  }

  // ============ FILE MANAGEMENT ============

  /// Upload a file to a project (encrypted in Supabase Storage)
  static Future<ProjectFile> uploadFile(
    String projectId,
    String fileName,
    Uint8List fileBytes,
    String fileType,
  ) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to upload files.');
    }

    if (!EncryptionService.hasKey) {
      final loaded = await EncryptionService.tryLoadKey();
      if (!loaded) {
        throw StateError('Encryption key is missing. Please sign in again.');
      }
    }

    try {
      // Step 1: Encrypt file content
      final fileContent = utf8.decode(fileBytes);
      final encryptedJson = await EncryptionService.encrypt(fileContent);
      final encryptedBytes = Uint8List.fromList(utf8.encode(encryptedJson));

      // Step 2: Upload to Supabase Storage
      final fileId = _uuid.v4();
      final storageFileName = '$fileId.enc';
      final storagePath = '${user.id}/$storageFileName';

      await SupabaseService.client.storage.from(bucketName).uploadBinary(
            storagePath,
            encryptedBytes,
            fileOptions: const FileOptions(
              contentType: 'application/octet-stream',
              upsert: false,
            ),
          );

      // Step 3: Save metadata to database
      final inserted = await SupabaseService.client
          .from('project_files')
          .insert({
            'project_id': projectId,
            'file_name': fileName,
            'storage_path': storagePath,
            'file_type': fileType,
            'file_size': fileBytes.length,
          })
          .select()
          .single();

      final projectFile = ProjectFile.fromJson(inserted);

      // Update project in cache
      final project = _projectsById[projectId];
      if (project != null) {
        _projectsById[projectId] = project.copyWith(
          files: [...project.files, projectFile],
        );
        _notifyChanges();
      }

      debugPrint('✅ [ProjectStorage] Uploaded file: $fileName to $projectId');
      return projectFile;
    } catch (e, st) {
      debugPrint('❌ [ProjectStorage] Failed to upload file: $e\n$st');
      rethrow;
    }
  }

  /// Delete a file from a project (also deletes from storage)
  static Future<void> deleteFile(String projectId, String fileId) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to delete files.');
    }

    try {
      // Find file to get storage path
      final project = _projectsById[projectId];
      final file = project?.files.firstWhere((f) => f.id == fileId);

      // Delete from database first
      await SupabaseService.client
          .from('project_files')
          .delete()
          .eq('id', fileId);

      // Delete from storage
      if (file != null) {
        try {
          await SupabaseService.client.storage
              .from(bucketName)
              .remove([file.storagePath]);
        } catch (e) {
          debugPrint('⚠️ [ProjectStorage] Failed to delete file from storage: $e');
          // Continue even if storage deletion fails
        }
      }

      // Update cache
      if (project != null) {
        _projectsById[projectId] = project.copyWith(
          files: project.files.where((f) => f.id != fileId).toList(),
        );
        _notifyChanges();
      }

      debugPrint('🗑️ [ProjectStorage] Deleted file: $fileId');
    } catch (e, st) {
      debugPrint('❌ [ProjectStorage] Failed to delete file: $e\n$st');
      rethrow;
    }
  }

  /// Get all files for a project
  static List<ProjectFile> getProjectFiles(String projectId) {
    final project = _projectsById[projectId];
    return project?.files ?? [];
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
      ProjectFile? file;
      for (final project in _projectsById.values) {
        try {
          file = project.files.firstWhere((f) => f.id == fileId);
          break;
        } catch (_) {
          // File not in this project, continue searching
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
      debugPrint('❌ [ProjectStorage] Failed to download/decrypt file: $e\n$st');
      rethrow;
    }
  }

  // ============ STATE MANAGEMENT ============

  /// Reset all state (on logout)
  static Future<void> reset() async {
    _projectsById.clear();
    selectedProjectId = null;
    _notifyChanges();
  }

  /// Load projects for sidebar (only if empty)
  static Future<void> loadProjectsForSidebar() async {
    if (_projectsById.isEmpty) {
      await loadProjects();
    }
  }
}
