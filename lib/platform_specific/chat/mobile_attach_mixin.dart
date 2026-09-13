// lib/platform_specific/chat/mobile_attach_mixin.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'package:chuk_chat/platform_config.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/platform_specific/chat/chat_scroll_mixin.dart';
import 'package:chuk_chat/platform_specific/chat/composer_menu.dart';
import 'package:chuk_chat/platform_specific/chat/composer_menu_choices.dart';
import 'package:chuk_chat/platform_specific/chat/handlers/file_attachment_handler.dart';
import 'package:chuk_chat/platform_specific/chat/handlers/mobile_workspace_handler.dart';
import 'package:chuk_chat/platform_specific/chat/model_provider_resolution_mixin.dart';
import 'package:chuk_chat/services/workspace_storage_service.dart';
import 'package:chuk_chat/ui/expressive/icon_map.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';

/// What the plus button offers, and the workspace the chat works in.
///
/// The two anchored menus behind the composer's plus button — attach a photo,
/// a file, or pick a workspace — plus the workspace chip beside the mode pill
/// and the upload-status bridge the file handler reports through.
///
/// Members are public so the host State and its build method can reach them.
mixin MobileAttachMixin<T extends StatefulWidget>
    on State<T>, ModelProviderResolutionMixin<T>, ChatScrollMixin<T> {
  // --- host-provided -------------------------------------------------------

  /// The handler that actually picks, uploads and tracks files.
  FileAttachmentHandler get fileHandler;

  /// The host's snack bar.
  void showChatSnackBar(String message);

  /// Start a fresh chat bound to [workspaceId] (null clears the workspace).
  /// Owned by the host because it clears the whole message list with it.
  void startNewChatWithProject(String? workspaceId);

  // --- state ---------------------------------------------------------------

  /// The workspace the next send carries as context, or null for none.
  String? selectedWorkspaceId;

  // --- the attach menu -----------------------------------------------------

  /// The attachment menu, anchored to the plus button in the same style as
  /// the mode menu. It used to be a sheet sliding up from the bottom edge,
  /// which looked like a different app every time it appeared.
  Future<void> handleAddAttachmentTap(BuildContext anchorContext) async {
    if (!mounted) return;
    final bool supportsImages = modelSupportsImageInput;
    final Color iconFg = Theme.of(context).resolvedIconColor;
    final l10n = AppLocalizations.of(context)!;

    final choice = await showAnchoredComposerMenu<AttachChoice>(
      anchorContext: anchorContext,
      items: <PopupMenuEntry<AttachChoice>>[
        composerMenuRow(
          value: AttachChoice.camera,
          iconFg: iconFg,
          icon: Icons.photo_camera_outlined,
          label: l10n.camera,
          isEnabled: supportsImages,
        ),
        composerMenuRow(
          value: AttachChoice.photos,
          iconFg: iconFg,
          icon: Icons.photo_library_outlined,
          label: l10n.photos,
          isEnabled: supportsImages,
        ),
        composerMenuRow(
          value: AttachChoice.files,
          iconFg: iconFg,
          icon: Icons.attach_file,
          label: l10n.files,
        ),
        if (kFeatureWorkspaces)
          composerMenuRow(
            value: AttachChoice.workspace,
            iconFg: iconFg,
            icon: Icons.folder_outlined,
            label: selectedWorkspaceId == null
                ? 'Workspace'
                : 'Change workspace',
          ),
      ],
    );

    if (!mounted || choice == null) return;

    switch (choice) {
      case AttachChoice.camera:
        if (!supportsImages) return;
        unawaited(
          fileHandler.pickImageFromSource(
            ImageSource.camera,
            supportsImages: supportsImages,
          ),
        );
      case AttachChoice.photos:
        if (!supportsImages) return;
        unawaited(
          fileHandler.pickImagesFromGallery(supportsImages: supportsImages),
        );
      case AttachChoice.files:
        unawaited(fileHandler.uploadFiles(supportsImages: supportsImages));
      case AttachChoice.workspace:
        if (!anchorContext.mounted) return;
        await openWorkspaceMenu(anchorContext);
    }
  }

  // --- the workspace menu --------------------------------------------------

  /// The workspace in use, shown beside the mode pill — not floating over
  /// the middle of the chat, where it covered the conversation. Tapping it
  /// opens the same workspace menu the plus button does.
  Widget buildWorkspaceChip(Color iconFg) {
    final workspace = WorkspaceStorageService.getWorkspace(
      selectedWorkspaceId!,
    );
    if (workspace == null) return const SizedBox.shrink();

    return Builder(
      builder: (anchorContext) => InkWell(
        onTap: () => openWorkspaceMenu(anchorContext),
        borderRadius: BorderRadius.circular(19),
        child: Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(19),
            border: Border.all(
              color: iconFg.withValues(alpha: 0.3),
              width: 1.8,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppIcon(
                Icons.folder_outlined,
                size: 17,
                color: workspace.displayColor,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  workspace.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: iconFg,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The workspace picker: the same anchored menu one level deeper, not a
  /// sheet from the bottom of the screen.
  Future<void> openWorkspaceMenu(BuildContext anchorContext) async {
    final Color iconFg = Theme.of(anchorContext).resolvedIconColor;
    final workspaces = WorkspaceStorageService.activeProjects;

    final choice = await showAnchoredComposerMenu<WorkspaceChoice>(
      anchorContext: anchorContext,
      items: <PopupMenuEntry<WorkspaceChoice>>[
        composerMenuRow(
          value: const WorkspaceChoice.pick(null),
          iconFg: iconFg,
          icon: Icons.close,
          label: 'No workspace',
          isSelected: selectedWorkspaceId == null,
        ),
        for (final workspace in workspaces)
          composerMenuRow(
            value: WorkspaceChoice.pick(workspace.id),
            iconFg: iconFg,
            icon: Icons.folder_outlined,
            label: workspace.name,
            isSelected: workspace.id == selectedWorkspaceId,
          ),
        composerMenuRow(
          value: const WorkspaceChoice.create(),
          iconFg: iconFg,
          icon: Icons.add,
          label: 'New workspace',
        ),
      ],
    );

    if (!mounted || choice == null) return;

    if (choice.create) {
      await MobileWorkspaceHandler.createNewProject(
        context: context,
        onShowSnackBar: showChatSnackBar,
        onOpenWorkspaceManagement: openProjectManagement,
      );
      return;
    }

    final String? id = choice.workspaceId;
    setState(() => selectedWorkspaceId = id);
    showChatSnackBar(
      id == null
          ? 'Workspace cleared'
          : 'Workspace selected: '
                '${WorkspaceStorageService.getWorkspace(id)?.name ?? id}',
    );
  }

  void openProjectManagement(String workspaceId) {
    MobileWorkspaceHandler.openProjectManagement(
      context: context,
      workspaceId: workspaceId,
      onStartNewChat: startNewChatWithProject,
    );
  }

  /// Public entry point for starting a new chat with a workspace context.
  void startNewChatWithWorkspace(String workspaceId) =>
      startNewChatWithProject(workspaceId);

  // --- upload status -------------------------------------------------------

  void handleFileUploadUpdate(
    String fileId,
    String? markdownContent,
    bool isUploading,
    String? snackBarMessage, {
    List<String>? pageImages,
  }) {
    if (!mounted) return;
    fileHandler.handleUploadStatusUpdate(
      fileId,
      markdownContent,
      isUploading,
      pageImages: pageImages,
    );
    if (snackBarMessage != null) {
      showChatSnackBar(snackBarMessage);
    }
    scrollChatToBottom();
  }
}
