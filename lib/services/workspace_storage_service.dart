// AGENTS STUB. Upstream: chuk_chat/lib/services/workspace_storage_service.dart @ d31526a229fdde27c82adf3661d5d3a149db8340.
// Reason: hosted-only — workspaces (projects) are a chuk_chat feature backed by
// Supabase. Agents's sidebar lists agents (coworkers), not projects, so the
// store is permanently empty and every mutation is a no-op.
// Keep the public API signature-compatible with upstream so the imported chat UI compiles unchanged. Do not "improve" this file.

import 'dart:async';

import 'package:chuk_chat/models/workspace_model.dart';

class WorkspaceStorageService {
  /// Always null: no workspace can be selected because none exist.
  static String? selectedWorkspaceId;

  static final StreamController<void> _changesController =
      StreamController<void>.broadcast();

  static Stream<void> get changes => _changesController.stream;

  static List<Workspace> get projects => const <Workspace>[];

  static List<Workspace> get activeProjects => const <Workspace>[];

  static List<Workspace> get archivedProjects => const <Workspace>[];

  static Future<void> loadFromCache() async {}

  static Future<void> loadProjects() async {}

  static Future<Workspace> createProject(
    String name, {
    String? description,
    String? customSystemPrompt,
  }) async {
    throw UnsupportedError('Agents has no workspaces.');
  }

  static Workspace? getWorkspace(String workspaceId) => null;

  static Workspace? getWorkspaceForChat(String chatId) => null;

  static Future<void> linkChatToWorkspace(
    String workspaceId,
    String chatId,
  ) async {}

  static Future<void> addChatToProject(
    String workspaceId,
    String chatId,
  ) async {}

  static Future<void> removeChatFromProject(
    String workspaceId,
    String chatId,
  ) async {}

  static Future<void> reset() async {}
}
