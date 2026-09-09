// lib/widgets/workspace/workspace_common_widgets.dart
//
// Presentation pieces shared by the workspace surfaces (detail page,
// management page, files page, desktop panel).

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/models/workspace_model.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/workspace_file_viewer.dart';

/// Small pill with a count, used in the workspace tab bars.
class WorkspaceCountBadge extends StatelessWidget {
  final int count;
  final Color color;

  const WorkspaceCountBadge({
    super.key,
    required this.count,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        '$count',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

/// Centered "nothing here yet" placeholder used by the files and chats tabs.
class WorkspaceEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const WorkspaceEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final iconFg = Theme.of(context).resolvedIconColor;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 56, color: iconFg.withValues(alpha: 0.2)),
          const SizedBox(height: 16),
          Text(
            title,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: iconFg.withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              color: iconFg.withValues(alpha: 0.4),
            ),
          ),
        ],
      ),
    );
  }
}

/// Card that shows the running file upload (progress bar + status text).
class WorkspaceUploadProgressCard extends StatelessWidget {
  final String? fileName;
  final String status;
  final double progress;
  final Color displayColor;

  const WorkspaceUploadProgressCard({
    super.key,
    required this.fileName,
    required this.status,
    required this.progress,
    required this.displayColor,
  });

  @override
  Widget build(BuildContext context) {
    final iconFg = Theme.of(context).resolvedIconColor;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.insert_drive_file, color: displayColor),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      fileName ?? 'File',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                status == 'uploading'
                    ? 'Encrypting and uploading...'
                    : 'Converting to markdown...',
                style: TextStyle(
                  fontSize: 12,
                  color: iconFg.withValues(alpha: 0.7),
                ),
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: status == 'uploading'
                    ? LinearProgressIndicator(
                        value: progress,
                        valueColor: AlwaysStoppedAnimation<Color>(displayColor),
                      )
                    : LinearProgressIndicator(
                        valueColor: AlwaysStoppedAnimation<Color>(displayColor),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One row in a workspace file list: icon, name, caller-supplied subtitle and
/// a View/Delete menu.
class WorkspaceFileTile extends StatelessWidget {
  final WorkspaceFile file;
  final String workspaceId;
  final Color displayColor;
  final bool isDark;

  /// Subtitle row content, e.g. size plus a context-usage chip.
  final Widget subtitle;

  /// Called with the popup menu item's context when "View" is tapped.
  final void Function(BuildContext menuContext) onView;

  /// Called (after a zero-duration delay, so the menu can close) on "Delete".
  final VoidCallback onDelete;

  const WorkspaceFileTile({
    super.key,
    required this.file,
    required this.workspaceId,
    required this.displayColor,
    required this.isDark,
    required this.subtitle,
    required this.onView,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: displayColor.withValues(alpha: isDark ? 0.15 : 0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(file.fileIcon, color: displayColor, size: 20),
        ),
        title: Text(
          file.fileName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14),
        ),
        subtitle: subtitle,
        trailing: PopupMenuButton(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          itemBuilder: (menuContext) => [
            PopupMenuItem(
              child: const Row(
                children: [
                  Icon(Icons.visibility, size: 18),
                  SizedBox(width: 10),
                  Text('View'),
                ],
              ),
              onTap: () => onView(menuContext),
            ),
            PopupMenuItem(
              child: Row(
                children: [
                  Icon(Icons.delete_outline, color: Colors.red, size: 18),
                  const SizedBox(width: 10),
                  const Text('Delete', style: TextStyle(color: Colors.red)),
                ],
              ),
              onTap: () => unawaited(Future.delayed(Duration.zero, onDelete)),
            ),
          ],
        ),
        onTap: () => WorkspaceFileViewer.show(context, file, workspaceId),
      ),
    );
  }
}

/// The "Chats" tab shared by the workspace detail and management pages.
class WorkspaceChatsTab extends StatelessWidget {
  final List<StoredChat> chats;
  final Color displayColor;
  final VoidCallback onAddChat;
  final void Function(String chatId) onRemoveChat;

  /// Appends the creation date to the "N messages" subtitle.
  final bool showChatDate;

  /// Size of the remove icon; `null` keeps the [IconButton] default.
  final double? removeIconSize;

  const WorkspaceChatsTab({
    super.key,
    required this.chats,
    required this.displayColor,
    required this.onAddChat,
    required this.onRemoveChat,
    this.showChatDate = false,
    this.removeIconSize,
  });

  @override
  Widget build(BuildContext context) {
    final iconFg = Theme.of(context).resolvedIconColor;

    return Column(
      children: [
        // Add chat button
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: onAddChat,
              icon: const Icon(Icons.add),
              label: const Text('Add Existing Chat'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: kBorderRadiusPill,
                ),
                side: BorderSide(color: displayColor.withValues(alpha: 0.5)),
              ),
            ),
          ),
        ),

        Expanded(
          child: chats.isEmpty
              ? const WorkspaceEmptyState(
                  icon: Icons.chat_bubble_outline,
                  title: 'No chats in this workspace',
                  subtitle:
                      'Add existing chats or start a new one\nwith the button below',
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: chats.length,
                  itemBuilder: (context, index) {
                    final chat = chats[index];
                    final date = chat.createdAt.toString().split(' ')[0];
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: ListTile(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        leading: Icon(Icons.chat, color: iconFg),
                        title: Text(
                          chat.customName ?? chat.previewText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          showChatDate
                              ? '${chat.messages.length} messages -- $date'
                              : '${chat.messages.length} messages',
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: IconButton(
                          icon: Icon(
                            Icons.remove_circle_outline,
                            color: Colors.red.withValues(alpha: 0.7),
                            size: removeIconSize,
                          ),
                          onPressed: () => onRemoveChat(chat.id),
                          tooltip: 'Remove from workspace',
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
