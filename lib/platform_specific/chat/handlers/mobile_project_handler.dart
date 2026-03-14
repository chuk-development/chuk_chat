// lib/platform_specific/chat/handlers/mobile_project_handler.dart
import 'package:flutter/material.dart';

import 'package:chuk_chat/pages/project_management_page.dart';
import 'package:chuk_chat/services/project_message_service.dart';
import 'package:chuk_chat/services/project_storage_service.dart';

/// Handles mobile-specific project selection UI and project–chat linking.
///
/// All methods are static because they build standalone widgets or show
/// dialogs/sheets that receive the required state via parameters and
/// communicate mutations back through callbacks.
class MobileProjectHandler {
  const MobileProjectHandler._();

  // ---------------------------------------------------------------------------
  // Bottom sheet – project selection
  // ---------------------------------------------------------------------------

  /// Shows a modal bottom sheet listing available projects.
  ///
  /// [selectedProjectId] – the currently selected project (nullable).
  /// [activeChatId] – the chat that is currently open (nullable).
  /// [onProjectSelected] – called when the user taps a project (or "No Project").
  /// [onShowSnackBar] – helper for displaying transient messages.
  /// [onStateChanged] – called when any mutation requires a rebuild.
  static void showProjectSelectionSheet({
    required BuildContext context,
    required String? selectedProjectId,
    required String? activeChatId,
    required ValueChanged<String?> onProjectSelected,
    required ValueChanged<String> onShowSnackBar,
    required VoidCallback onStateChanged,
    required void Function(String projectId) onOpenProjectManagement,
  }) {
    final theme = Theme.of(context);
    final projects = ProjectStorageService.activeProjects;

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
                // No project option
                buildProjectOption(
                  sheetContext: sheetContext,
                  theme: theme,
                  projectId: null,
                  name: 'No Project',
                  icon: Icons.close,
                  selectedProjectId: selectedProjectId,
                  activeChatId: activeChatId,
                  onProjectSelected: onProjectSelected,
                  onShowSnackBar: onShowSnackBar,
                  onStateChanged: onStateChanged,
                  onOpenProjectManagement: onOpenProjectManagement,
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
                              onOpenProjectManagement: onOpenProjectManagement,
                            );
                          },
                          icon: const Icon(Icons.add),
                          label: const Text('Create Project'),
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
                                  onOpenProjectManagement:
                                      onOpenProjectManagement,
                                );
                              },
                              icon: const Icon(Icons.add),
                              label: const Text('Create New Project'),
                            ),
                          );
                        }
                        final project = projects[index];
                        return buildProjectOption(
                          sheetContext: sheetContext,
                          theme: theme,
                          projectId: project.id,
                          name: project.name,
                          icon: Icons.folder,
                          subtitle:
                              ProjectMessageService.getProjectContextSummary(
                                project,
                              ),
                          selectedProjectId: selectedProjectId,
                          activeChatId: activeChatId,
                          onProjectSelected: onProjectSelected,
                          onShowSnackBar: onShowSnackBar,
                          onStateChanged: onStateChanged,
                          onOpenProjectManagement: onOpenProjectManagement,
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
  // Dialog – create new project
  // ---------------------------------------------------------------------------

  /// Shows a dialog that lets the user create a new project.
  ///
  /// On success the [onOpenProjectManagement] callback is invoked with the
  /// newly created project's id so the caller can navigate to the management
  /// page.
  static Future<void> createNewProject({
    required BuildContext context,
    required ValueChanged<String> onShowSnackBar,
    required void Function(String projectId) onOpenProjectManagement,
  }) async {
    final nameController = TextEditingController();
    final descController = TextEditingController();

    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Create Project'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Project Name',
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
        final project = await ProjectStorageService.createProject(
          nameController.text.trim(),
          description: descController.text.trim().isEmpty
              ? null
              : descController.text.trim(),
        );
        onShowSnackBar('Project "${project.name}" created');
        onOpenProjectManagement(project.id);
      } catch (e) {
        onShowSnackBar('Failed to create project: $e');
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Widget builder – single project option in the selection sheet
  // ---------------------------------------------------------------------------

  /// Builds a [ListTile] for a single project inside the selection sheet.
  ///
  /// When [projectId] is `null` this renders the "No Project" option.
  static Widget buildProjectOption({
    required BuildContext sheetContext,
    required ThemeData theme,
    required String? projectId,
    required String name,
    required IconData icon,
    String? subtitle,
    required String? selectedProjectId,
    required String? activeChatId,
    required ValueChanged<String?> onProjectSelected,
    required ValueChanged<String> onShowSnackBar,
    required VoidCallback onStateChanged,
    required void Function(String projectId) onOpenProjectManagement,
  }) {
    final isSelected = selectedProjectId == projectId;
    final project = projectId != null
        ? ProjectStorageService.getProject(projectId)
        : null;
    final bool chatInProject =
        project != null &&
        activeChatId != null &&
        project.chatIds.contains(activeChatId);

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
          if (projectId != null) ...[
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
                    ? 'Remove chat from project'
                    : 'Add chat to project',
                onPressed: () async {
                  Navigator.of(sheetContext).pop();
                  if (chatInProject) {
                    await removeChatFromProject(
                      projectId: projectId,
                      activeChatId: activeChatId,
                      onShowSnackBar: onShowSnackBar,
                      onStateChanged: onStateChanged,
                    );
                  } else {
                    await addChatToProject(
                      projectId: projectId,
                      activeChatId: activeChatId,
                      onShowSnackBar: onShowSnackBar,
                      onStateChanged: onStateChanged,
                    );
                  }
                },
              ),
            ],
            // Manage project button
            IconButton(
              icon: Icon(
                Icons.settings,
                size: 20,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
              tooltip: 'Manage project',
              onPressed: () {
                Navigator.of(sheetContext).pop();
                onOpenProjectManagement(projectId);
              },
            ),
          ],
        ],
      ),
      onTap: () {
        Navigator.of(sheetContext).pop();
        onProjectSelected(projectId);
        if (projectId != null) {
          onShowSnackBar('Project selected: $name');
        } else {
          onShowSnackBar('Project cleared');
        }
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Widget builder – selected project badge (used above the message list)
  // ---------------------------------------------------------------------------

  /// Builds a compact badge showing the currently selected project name with a
  /// close button to deselect it.
  static Widget buildSelectedProjectBadge({
    required ThemeData theme,
    required String selectedProjectId,
    required VoidCallback onClearProject,
  }) {
    final project = ProjectStorageService.getProject(selectedProjectId);
    if (project == null) return const SizedBox.shrink();

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
            project.name,
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
  // Widget builder – compact project indicator (for the input area)
  // ---------------------------------------------------------------------------

  /// Builds a row showing the project name, context summary, and a close
  /// button. Intended for the area just above the text input field.
  static Widget buildProjectIndicator({
    required ThemeData theme,
    required String selectedProjectId,
    required VoidCallback onClearProject,
    required ValueChanged<String> onShowSnackBar,
  }) {
    final project = ProjectStorageService.getProject(selectedProjectId);
    if (project == null) return const SizedBox.shrink();

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
                  project.name,
                  style: TextStyle(
                    fontSize: 13,
                    color: theme.colorScheme.onSurface,
                    fontWeight: FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  ProjectMessageService.getProjectContextSummary(project),
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
              onShowSnackBar('Project cleared');
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
  // Project–chat linking
  // ---------------------------------------------------------------------------

  /// Adds the chat identified by [activeChatId] to the given project.
  static Future<void> addChatToProject({
    required String projectId,
    required String? activeChatId,
    required ValueChanged<String> onShowSnackBar,
    required VoidCallback onStateChanged,
  }) async {
    if (activeChatId == null) {
      onShowSnackBar('No active chat to add');
      return;
    }
    try {
      await ProjectStorageService.addChatToProject(projectId, activeChatId);
      onShowSnackBar('Chat added to project');
      onStateChanged();
    } catch (e) {
      onShowSnackBar('Failed to add chat: $e');
    }
  }

  /// Removes the chat identified by [activeChatId] from the given project.
  static Future<void> removeChatFromProject({
    required String projectId,
    required String? activeChatId,
    required ValueChanged<String> onShowSnackBar,
    required VoidCallback onStateChanged,
  }) async {
    if (activeChatId == null) return;
    try {
      await ProjectStorageService.removeChatFromProject(
        projectId,
        activeChatId,
      );
      onShowSnackBar('Chat removed from project');
      onStateChanged();
    } catch (e) {
      onShowSnackBar('Failed to remove chat: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Navigation helper
  // ---------------------------------------------------------------------------

  /// Pushes the [ProjectManagementPage] for the given [projectId].
  ///
  /// [onStartNewChat] is forwarded to the management page so the user can
  /// start a new chat with the project's context.
  static void openProjectManagement({
    required BuildContext context,
    required String projectId,
    required void Function(String? projectId) onStartNewChat,
  }) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ProjectManagementPage(
          projectId: projectId,
          onStartNewChat: (selectedProjectId) {
            onStartNewChat(selectedProjectId);
          },
        ),
      ),
    );
  }
}
