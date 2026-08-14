// lib/platform_specific/chat/handlers/mobile_workspace_handler.dart
import 'package:flutter/material.dart';

import 'package:chuk_chat/pages/workspace_management_page.dart';
import 'package:chuk_chat/services/workspace_storage_service.dart';

/// Handles mobile-specific workspace selection UI and workspace–chat linking.
///
/// All methods are static because they build standalone widgets or show
/// dialogs that receive the required state via parameters and
/// communicate mutations back through callbacks.
class MobileWorkspaceHandler {
  const MobileWorkspaceHandler._();

  // ---------------------------------------------------------------------------
  // Dialog – create new workspace
  // ---------------------------------------------------------------------------

  /// Shows a dialog that lets the user create a new workspace.
  ///
  /// On success the [onOpenWorkspaceManagement] callback is invoked with the
  /// newly created workspace's id so the caller can navigate to the management
  /// page.
  static Future<void> createNewProject({
    required BuildContext context,
    required ValueChanged<String> onShowSnackBar,
    required void Function(String workspaceId) onOpenWorkspaceManagement,
  }) async {
    final nameController = TextEditingController();
    final descController = TextEditingController();

    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Create Workspace'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Workspace Name',
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: descController,
              decoration: const InputDecoration(
                labelText: 'Description (optional)',
              ),
              maxLines: 2,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Create'),
          ),
        ],
      ),
    );

    if (result == true && nameController.text.trim().isNotEmpty) {
      try {
        final workspace = await WorkspaceStorageService.createProject(
          nameController.text.trim(),
          description: descController.text.trim().isEmpty
              ? null
              : descController.text.trim(),
        );
        onShowSnackBar('Workspace "${workspace.name}" created');
        onOpenWorkspaceManagement(workspace.id);
      } catch (e) {
        onShowSnackBar('Failed to create workspace: $e');
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Workspace–chat linking
  // ---------------------------------------------------------------------------

  /// Adds the chat identified by [activeChatId] to the given workspace.
  static Future<void> addChatToProject({
    required String workspaceId,
    required String? activeChatId,
    required ValueChanged<String> onShowSnackBar,
    required VoidCallback onStateChanged,
  }) async {
    if (activeChatId == null) {
      onShowSnackBar('No active chat to add');
      return;
    }
    try {
      await WorkspaceStorageService.addChatToProject(workspaceId, activeChatId);
      onShowSnackBar('Chat added to workspace');
      onStateChanged();
    } catch (e) {
      onShowSnackBar('Failed to add chat: $e');
    }
  }

  /// Removes the chat identified by [activeChatId] from the given workspace.
  static Future<void> removeChatFromProject({
    required String workspaceId,
    required String? activeChatId,
    required ValueChanged<String> onShowSnackBar,
    required VoidCallback onStateChanged,
  }) async {
    if (activeChatId == null) return;
    try {
      await WorkspaceStorageService.removeChatFromProject(
        workspaceId,
        activeChatId,
      );
      onShowSnackBar('Chat removed from workspace');
      onStateChanged();
    } catch (e) {
      onShowSnackBar('Failed to remove chat: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Navigation helper
  // ---------------------------------------------------------------------------

  /// Pushes the [WorkspaceManagementPage] for the given [workspaceId].
  ///
  /// [onStartNewChat] is forwarded to the management page so the user can
  /// start a new chat with the workspace's context.
  static void openProjectManagement({
    required BuildContext context,
    required String workspaceId,
    required void Function(String? workspaceId) onStartNewChat,
  }) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => WorkspaceManagementPage(
          workspaceId: workspaceId,
          onStartNewChat: (selectedWorkspaceId) {
            onStartNewChat(selectedWorkspaceId);
          },
        ),
      ),
    );
  }
}
