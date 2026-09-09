// lib/widgets/workspace/workspace_actions_mixin.dart
//
// Shared workspace file/chat/instruction actions.
//
// The workspace detail page, the workspace management page, the workspace
// files page and the desktop workspace panel all drive the same
// WorkspaceStorageService operations (upload a file, delete a file, save the
// custom system prompt, add/remove a chat). This mixin holds that logic once.
// Everything that genuinely differs between the callers — the chat picker
// presentation, the context-budget confirmation, the dialog strings — is a
// parameter.

import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'package:chuk_chat/constants/file_constants.dart';
import 'package:chuk_chat/models/workspace_model.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/workspace_storage_service.dart';
import 'package:chuk_chat/utils/io_helper.dart';
import 'package:chuk_chat/widgets/workspace_file_viewer.dart';

/// Shared workspace actions for a [State] that manages a single workspace.
///
/// Implementors provide [workspaceId]; the mixin owns the upload progress
/// state and the workspace-change subscription.
mixin WorkspaceActionsMixin<T extends StatefulWidget> on State<T> {
  /// Id of the workspace this state operates on.
  String get workspaceId;

  // ---------------------------------------------------------------------
  // Upload progress state (read by the callers' build methods)
  // ---------------------------------------------------------------------

  bool isUploadingFile = false;
  String? uploadFileName;

  /// `'uploading'`, `'converting'` or `''`.
  String uploadStatus = '';
  double uploadProgress = 0.0;

  // ---------------------------------------------------------------------
  // Workspace change subscription
  // ---------------------------------------------------------------------

  StreamSubscription<void>? _workspaceChangesSub;

  /// Calls [onChange] whenever the workspace store reports a change.
  void listenToWorkspaceChanges(VoidCallback onChange) {
    // Re-listening without this leaks the old subscription, and then every
    // change fires onChange twice.
    _workspaceChangesSub?.cancel();
    _workspaceChangesSub = WorkspaceStorageService.changes.listen((_) {
      if (mounted) onChange();
    });
  }

  /// Stops the subscription started by [listenToWorkspaceChanges].
  void cancelWorkspaceChangesSubscription() {
    _workspaceChangesSub?.cancel();
    _workspaceChangesSub = null;
  }

  // ---------------------------------------------------------------------
  // Loading
  // ---------------------------------------------------------------------

  /// Loads the workspace plus its chats and hands both to [onLoaded] inside a
  /// `setState`. On failure it runs [onFailed] inside a `setState`, shows a
  /// snack bar and pops the route.
  Future<void> loadWorkspaceAndChats({
    required void Function(Workspace workspace, List<StoredChat> chats)
    onLoaded,
    required VoidCallback onFailed,
  }) async {
    try {
      final workspace = WorkspaceStorageService.getWorkspace(workspaceId);
      if (workspace == null) {
        throw StateError('Workspace not found');
      }
      final chats = await WorkspaceStorageService.getProjectChats(workspaceId);
      if (mounted) {
        setState(() => onLoaded(workspace, chats));
      }
    } catch (e) {
      if (mounted) {
        setState(onFailed);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to load workspace: $e')));
        Navigator.pop(context);
      }
    }
  }

  // ---------------------------------------------------------------------
  // Files
  // ---------------------------------------------------------------------

  /// Picks a file and uploads it into the workspace, driving the
  /// [isUploadingFile] / [uploadFileName] / [uploadStatus] / [uploadProgress]
  /// fields along the way.
  ///
  /// [warnWhenPathUnavailable] shows a "not supported on this platform" snack
  /// bar when the picked file has no path (web). [confirmOversizedUpload] is
  /// asked before uploading; return `false` to abort.
  Future<void> pickAndUploadWorkspaceFile({
    bool warnWhenPathUnavailable = false,
    Future<bool> Function(int estimatedTokens)? confirmOversizedUpload,
  }) async {
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: FileConstants.allowedExtensions,
      );

      if (file == null) return;

      if (file.path == null) {
        if (warnWhenPathUnavailable && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('File upload is not supported on this platform.'),
            ),
          );
        }
        return;
      }

      final filePath = file.path!;
      final fileName = file.name;
      final fileType = fileName.split('.').last;

      // The native picker can outlive the page that opened it.
      if (!mounted) return;
      setState(() {
        isUploadingFile = true;
        uploadFileName = fileName;
        uploadStatus = 'uploading';
        uploadProgress = 0.0;
      });

      final fileBytes = await File(filePath).readAsBytes();

      if (!mounted) return;

      if (confirmOversizedUpload != null) {
        final estimatedNewTokens = (fileBytes.length / 4).ceil();
        final proceed = await confirmOversizedUpload(estimatedNewTokens);
        if (!proceed || !mounted) return;
      }

      await WorkspaceStorageService.uploadFile(
        workspaceId,
        fileName,
        fileBytes,
        fileType,
        filePath: filePath,
        generateMarkdown: true,
        onUploadProgress: (progress) {
          if (mounted) setState(() => uploadProgress = progress);
        },
        onConversionStart: () {
          if (mounted) setState(() => uploadStatus = 'converting');
        },
      );

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Uploaded: $fileName')));
      }
    } catch (e) {
      if (mounted) {
        final errorMessage = e is StateError ? e.message : e.toString();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(errorMessage),
            backgroundColor: Colors.red[700],
            duration: const Duration(seconds: 5),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          isUploadingFile = false;
          uploadFileName = null;
          uploadStatus = '';
          uploadProgress = 0.0;
        });
      }
    }
  }

  /// Asks for confirmation and deletes [file] from the workspace.
  ///
  /// The labels default to the English strings used by the desktop surfaces;
  /// localized callers pass their own.
  Future<void> deleteWorkspaceFile(
    WorkspaceFile file, {
    String? title,
    String? body,
    String? cancelLabel,
    String? deleteLabel,
    String Function(String error)? failedMessage,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title ?? 'Delete File'),
        content: Text(body ?? 'Delete "${file.fileName}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(cancelLabel ?? 'Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text(deleteLabel ?? 'Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await WorkspaceStorageService.deleteFile(workspaceId, file.id);
    } catch (e) {
      if (mounted) {
        final message =
            failedMessage?.call(e.toString()) ?? 'Delete failed: $e';
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
    }
  }

  /// Opens the file viewer after the current frame, using [viewerContext].
  void viewWorkspaceFile(BuildContext viewerContext, WorkspaceFile file) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      WorkspaceFileViewer.show(viewerContext, file, workspaceId);
    });
  }

  // ---------------------------------------------------------------------
  // Instructions
  // ---------------------------------------------------------------------

  /// Saves the workspace's custom system prompt. Returns `true` when the save
  /// succeeded and this state is still mounted.
  Future<bool> saveWorkspaceInstructions(
    String instructions, {
    String? successMessage,
  }) async {
    try {
      await WorkspaceStorageService.updateProject(
        workspaceId,
        customSystemPrompt: instructions.trim(),
      );
      if (!mounted) return false;
      if (successMessage != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(successMessage)));
      }
      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to save: $e')));
      }
      return false;
    }
  }

  // ---------------------------------------------------------------------
  // Chats
  // ---------------------------------------------------------------------

  /// Lets the user pick one of the chats that are not in the workspace yet and
  /// adds it. [pickChat] owns the presentation (dialog or bottom sheet).
  Future<void> addChatToWorkspace({
    required Iterable<String> existingChatIds,
    required Future<StoredChat?> Function(List<StoredChat> available) pickChat,
  }) async {
    final existing = existingChatIds.toSet();
    final availableChats = ChatStorageService.savedChats
        .where((chat) => !existing.contains(chat.id))
        .toList();

    if (availableChats.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No chats available to add')),
      );
      return;
    }

    final selected = await pickChat(availableChats);
    if (selected == null || !mounted) return;

    try {
      await WorkspaceStorageService.addChatToProject(workspaceId, selected.id);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Chat added to workspace')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to add chat: $e')));
    }
  }

  /// Removes [chatId] from the workspace.
  Future<void> removeChatFromWorkspace(String chatId) async {
    try {
      await WorkspaceStorageService.removeChatFromProject(workspaceId, chatId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Chat removed from workspace')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to remove chat: $e')));
    }
  }
}
