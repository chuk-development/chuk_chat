// lib/platform_specific/chat/handlers/mobile_workspace_handler.dart
import 'package:flutter/material.dart';

import 'package:chuk_chat/pages/workspace_management_page.dart';
import 'package:chuk_chat/services/workspace_message_service.dart';
import 'package:chuk_chat/services/workspace_storage_service.dart';

/// Handles mobile-specific workspace selection UI and workspace–chat linking.
///
/// All methods are static because they build standalone widgets or show
/// dialogs/sheets that receive the required state via parameters and
/// communicate mutations back through callbacks.
class MobileWorkspaceHandler {
  const MobileWorkspaceHandler._();

  // ---------------------------------------------------------------------------
  // Bottom sheet – workspace selection
  // ---------------------------------------------------------------------------

  /// Shows a modal bottom sheet listing available projects.
  ///
  /// [selectedWorkspaceId] – the currently selected workspace (nullable).
  /// [activeChatId] – the chat that is currently open (nullable).
  /// [onWorkspaceSelected] – called when the user taps a workspace (or "No Workspace").
  /// [onShowSnackBar] – helper for displaying transient messages.
  /// [onStateChanged] – called when any mutation requires a rebuild.
  static void showProjectSelectionSheet({
    required BuildContext context,
    required String? selectedWorkspaceId,
    required String? activeChatId,
    required ValueChanged<String?> onWorkspaceSelected,
    required ValueChanged<String> onShowSnackBar,
    required VoidCallback onStateChanged,
    required void Function(String workspaceId) onOpenWorkspaceManagement,
  }) {
    final theme = Theme.of(context);
    final projects = WorkspaceStorageService.activeProjects;

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: theme.colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      isScrollControlled: true,
      builder: (sheetContext) {
        final Color indicatorColor = theme.dividerColor.withValues(alpha: 0.3);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: indicatorColor,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'Projects',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                // No workspace option
                buildProjectOption(
                  sheetContext: sheetContext,
                  theme: theme,
                  workspaceId: null,
                  name: 'No Workspace',
                  icon: Icons.close,
                  selectedWorkspaceId: selectedWorkspaceId,
                  activeChatId: activeChatId,
                  onWorkspaceSelected: onWorkspaceSelected,
                  onShowSnackBar: onShowSnackBar,
                  onStateChanged: onStateChanged,
                  onOpenWorkspaceManagement: onOpenWorkspaceManagement,
                ),
                if (projects.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Column(
                      children: [
                        Icon(
                          Icons.folder_open,
                          size: 48,
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.3,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'No projects yet',
                          style: TextStyle(
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.6,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        ElevatedButton.icon(
                          onPressed: () {
                            Navigator.pop(sheetContext);
                            createNewProject(
                              context: context,
                              onShowSnackBar: onShowSnackBar,
                              onOpenWorkspaceManagement: onOpenWorkspaceManagement,
                            );
                          },
                          icon: const Icon(Icons.add),
                          label: const Text('Create Workspace'),
                        ),
                      ],
                    ),
                  )
                else
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.of(context).size.height * 0.4,
                    ),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: projects.length + 1,
                      itemBuilder: (listContext, index) {
                        if (index == projects.length) {
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: OutlinedButton.icon(
                              onPressed: () {
                                Navigator.pop(sheetContext);
                                createNewProject(
                                  context: context,
                                  onShowSnackBar: onShowSnackBar,
                                  onOpenWorkspaceManagement:
                                      onOpenWorkspaceManagement,
                                );
                              },
                              icon: const Icon(Icons.add),
                              label: const Text('Create New Workspace'),
                            ),
                          );
                        }
                        final workspace = projects[index];
                        return buildProjectOption(
                          sheetContext: sheetContext,
                          theme: theme,
                          workspaceId: workspace.id,
                          name: workspace.name,
                          icon: Icons.folder,
                          subtitle:
                              WorkspaceMessageService.getProjectContextSummary(
                                workspace,
                              ),
                          selectedWorkspaceId: selectedWorkspaceId,
                          activeChatId: activeChatId,
                          onWorkspaceSelected: onWorkspaceSelected,
                          onShowSnackBar: onShowSnackBar,
                          onStateChanged: onStateChanged,
                          onOpenWorkspaceManagement: onOpenWorkspaceManagement,
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

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
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: descController,
              decoration: const InputDecoration(
                labelText: 'Description (optional)',
                border: OutlineInputBorder(),
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
  // Widget builder – single workspace option in the selection sheet
  // ---------------------------------------------------------------------------

  /// Builds a [ListTile] for a single workspace inside the selection sheet.
  ///
  /// When [workspaceId] is `null` this renders the "No Workspace" option.
  static Widget buildProjectOption({
    required BuildContext sheetContext,
    required ThemeData theme,
    required String? workspaceId,
    required String name,
    required IconData icon,
    String? subtitle,
    required String? selectedWorkspaceId,
    required String? activeChatId,
    required ValueChanged<String?> onWorkspaceSelected,
    required ValueChanged<String> onShowSnackBar,
    required VoidCallback onStateChanged,
    required void Function(String workspaceId) onOpenWorkspaceManagement,
  }) {
    final isSelected = selectedWorkspaceId == workspaceId;
    final workspace = workspaceId != null
        ? WorkspaceStorageService.getWorkspace(workspaceId)
        : null;
    final bool chatInProject =
        workspace != null &&
        activeChatId != null &&
        workspace.chatIds.contains(activeChatId);

    return ListTile(
      leading: Icon(icon, color: isSelected ? theme.colorScheme.primary : null),
      title: Text(
        name,
        style: TextStyle(
          fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
          color: isSelected ? theme.colorScheme.primary : null,
        ),
      ),
      subtitle: subtitle != null ? Text(subtitle) : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isSelected) Icon(Icons.check, color: theme.colorScheme.primary),
          if (workspaceId != null) ...[
            // Link / unlink chat button
            if (activeChatId != null) ...[
              const SizedBox(width: 4),
              IconButton(
                icon: Icon(
                  chatInProject ? Icons.link_off : Icons.link,
                  size: 20,
                  color: chatInProject
                      ? Colors.orange
                      : theme.colorScheme.primary.withValues(alpha: 0.7),
                ),
                tooltip: chatInProject
                    ? 'Remove chat from workspace'
                    : 'Add chat to workspace',
                onPressed: () async {
                  Navigator.of(sheetContext).pop();
                  if (chatInProject) {
                    await removeChatFromProject(
                      workspaceId: workspaceId,
                      activeChatId: activeChatId,
                      onShowSnackBar: onShowSnackBar,
                      onStateChanged: onStateChanged,
                    );
                  } else {
                    await addChatToProject(
                      workspaceId: workspaceId,
                      activeChatId: activeChatId,
                      onShowSnackBar: onShowSnackBar,
                      onStateChanged: onStateChanged,
                    );
                  }
                },
              ),
            ],
            // Manage workspace button
            IconButton(
              icon: Icon(
                Icons.settings,
                size: 20,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
              tooltip: 'Manage workspace',
              onPressed: () {
                Navigator.of(sheetContext).pop();
                onOpenWorkspaceManagement(workspaceId);
              },
            ),
          ],
        ],
      ),
      onTap: () {
        Navigator.of(sheetContext).pop();
        onWorkspaceSelected(workspaceId);
        if (workspaceId != null) {
          onShowSnackBar('Workspace selected: $name');
        } else {
          onShowSnackBar('Workspace cleared');
        }
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Widget builder – selected workspace badge (used above the message list)
  // ---------------------------------------------------------------------------

  /// Builds a compact badge showing the currently selected workspace name with a
  /// close button to deselect it.
  static Widget buildSelectedProjectBadge({
    required ThemeData theme,
    required String selectedWorkspaceId,
    required VoidCallback onClearProject,
  }) {
    final workspace = WorkspaceStorageService.getWorkspace(selectedWorkspaceId);
    if (workspace == null) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.folder,
            size: 16,
            color: theme.colorScheme.onPrimaryContainer,
          ),
          const SizedBox(width: 6),
          Text(
            workspace.name,
            style: TextStyle(
              fontSize: 12,
              color: theme.colorScheme.onPrimaryContainer,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: onClearProject,
            child: Icon(
              Icons.close,
              size: 14,
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Widget builder – compact workspace indicator (for the input area)
  // ---------------------------------------------------------------------------

  /// Builds a row showing the workspace name, context summary, and a close
  /// button. Intended for the area just above the text input field.
  static Widget buildProjectIndicator({
    required ThemeData theme,
    required String selectedWorkspaceId,
    required VoidCallback onClearProject,
    required ValueChanged<String> onShowSnackBar,
  }) {
    final workspace = WorkspaceStorageService.getWorkspace(selectedWorkspaceId);
    if (workspace == null) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.folder, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  workspace.name,
                  style: TextStyle(
                    fontSize: 13,
                    color: theme.colorScheme.onSurface,
                    fontWeight: FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  WorkspaceMessageService.getProjectContextSummary(workspace),
                  style: TextStyle(
                    fontSize: 11,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
          GestureDetector(
            onTap: () {
              onClearProject();
              onShowSnackBar('Workspace cleared');
            },
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(
                Icons.close,
                size: 18,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ),
        ],
      ),
    );
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
