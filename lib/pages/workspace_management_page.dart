// lib/pages/workspace_management_page.dart
import 'dart:async';

import 'package:chuk_chat/utils/io_helper.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:chuk_chat/constants/file_constants.dart';
import 'package:chuk_chat/models/workspace_model.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/workspace_storage_service.dart';
import 'package:chuk_chat/services/workspace_message_service.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/workspace_file_viewer.dart';

/// Mobile-friendly workspace management page
/// Allows managing files, instructions, chats, and starting new chats with workspace context
class WorkspaceManagementPage extends StatefulWidget {
  final String workspaceId;
  final Function(String? workspaceId)? onStartNewChat;

  const WorkspaceManagementPage({
    super.key,
    required this.workspaceId,
    this.onStartNewChat,
  });

  @override
  State<WorkspaceManagementPage> createState() => _WorkspaceManagementPageState();
}

class _WorkspaceManagementPageState extends State<WorkspaceManagementPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  Workspace? _project;
  List<StoredChat> _projectChats = [];
  StreamSubscription<void>? _projectSub;
  bool _isLoading = true;

  // Upload state
  bool _isUploadingFile = false;
  String? _uploadFileName;
  String _uploadStatus = '';
  double _uploadProgress = 0.0;

  // Instructions editing
  bool _isEditingInstructions = false;
  final TextEditingController _instructionsController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadProject();
    _projectSub = WorkspaceStorageService.changes.listen((_) {
      if (mounted) _loadProject();
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _projectSub?.cancel();
    _instructionsController.dispose();
    super.dispose();
  }

  Future<void> _loadProject() async {
    try {
      final workspace = WorkspaceStorageService.getWorkspace(widget.workspaceId);
      if (workspace == null) {
        throw StateError('Workspace not found');
      }
      final chats = await WorkspaceStorageService.getProjectChats(
        widget.workspaceId,
      );
      if (mounted) {
        setState(() {
          _project = workspace;
          _projectChats = chats;
          _instructionsController.text = workspace.customSystemPrompt ?? '';
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to load workspace: $e')));
        Navigator.pop(context);
      }
    }
  }

  Future<void> _saveInstructions() async {
    if (_project == null) return;
    try {
      await WorkspaceStorageService.updateProject(
        widget.workspaceId,
        customSystemPrompt: _instructionsController.text.trim(),
      );
      if (mounted) {
        setState(() => _isEditingInstructions = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Instructions saved')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to save: $e')));
      }
    }
  }

  Future<void> _pickAndUploadFile() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: FileConstants.allowedExtensions,
        allowMultiple: false,
      );

      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      if (file.path == null) return;

      final filePath = file.path!;
      final fileName = file.name;
      final fileType = fileName.split('.').last;

      setState(() {
        _isUploadingFile = true;
        _uploadFileName = fileName;
        _uploadStatus = 'uploading';
        _uploadProgress = 0.0;
      });

      final fileBytes = await File(filePath).readAsBytes();

      await WorkspaceStorageService.uploadFile(
        widget.workspaceId,
        fileName,
        fileBytes,
        fileType,
        filePath: filePath,
        generateMarkdown: true,
        onUploadProgress: (progress) {
          if (mounted) setState(() => _uploadProgress = progress);
        },
        onConversionStart: () {
          if (mounted) setState(() => _uploadStatus = 'converting');
        },
      );

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Uploaded: $fileName')));
      }
    } catch (e) {
      if (mounted) {
        String errorMessage;
        if (e is StateError) {
          errorMessage = e.message;
        } else {
          errorMessage = e.toString();
        }
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
          _isUploadingFile = false;
          _uploadFileName = null;
          _uploadStatus = '';
          _uploadProgress = 0.0;
        });
      }
    }
  }

  Future<void> _deleteFile(WorkspaceFile file) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete File'),
        content: Text('Delete "${file.fileName}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await WorkspaceStorageService.deleteFile(widget.workspaceId, file.id);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Delete failed: $e')));
        }
      }
    }
  }

  Future<void> _addChat() async {
    final allChats = ChatStorageService.savedChats;
    final availableChats = allChats
        .where((chat) => !(_project?.chatIds.contains(chat.id) ?? false))
        .toList();

    if (availableChats.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No chats available to add')),
      );
      return;
    }

    final selected = await showModalBottomSheet<StoredChat>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => _ChatSelectorSheet(chats: availableChats),
    );

    if (selected != null && mounted) {
      try {
        await WorkspaceStorageService.addChatToProject(
          widget.workspaceId,
          selected.id,
        );
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
  }

  Future<void> _removeChat(String chatId) async {
    try {
      await WorkspaceStorageService.removeChatFromProject(
        widget.workspaceId,
        chatId,
      );
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

  void _startNewChatWithProject() {
    if (widget.onStartNewChat != null) {
      widget.onStartNewChat!(widget.workspaceId);
      Navigator.pop(context);
    } else {
      // Return workspace ID for parent to handle
      Navigator.pop(context, widget.workspaceId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final iconFg = theme.resolvedIconColor;

    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Loading...')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_project == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Workspace Not Found')),
        body: const Center(child: Text('Workspace not found')),
      );
    }

    final displayColor = _project!.displayColor;
    final onProjectColor =
        ThemeData.estimateBrightnessForColor(displayColor) == Brightness.dark
        ? Colors.white
        : Colors.black;
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: displayColor.withValues(alpha: isDark ? 0.2 : 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(_project!.displayIcon, color: displayColor, size: 16),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(_project!.name, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: iconFg),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.edit, color: iconFg),
            onPressed: _showEditProjectDialog,
            tooltip: 'Edit workspace',
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: displayColor,
          labelColor: displayColor,
          tabs: [
            Tab(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.folder_outlined, size: 18),
                  const SizedBox(width: 6),
                  const Text('Files'),
                  if (_project!.fileCount > 0)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: _CountBadge(
                        count: _project!.fileCount,
                        color: displayColor,
                      ),
                    ),
                ],
              ),
            ),
            Tab(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.chat_bubble_outline, size: 18),
                  const SizedBox(width: 6),
                  const Text('Chats'),
                  if (_project!.chatCount > 0)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: _CountBadge(
                        count: _project!.chatCount,
                        color: displayColor,
                      ),
                    ),
                ],
              ),
            ),
            const Tab(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.settings_outlined, size: 18),
                  SizedBox(width: 6),
                  Text('Settings'),
                ],
              ),
            ),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [_buildFilesTab(), _buildChatsTab(), _buildSettingsTab()],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _startNewChatWithProject,
        icon: const Icon(Icons.add_comment),
        label: const Text('New Chat'),
        backgroundColor: displayColor,
        foregroundColor: onProjectColor,
        tooltip: 'Start new chat with this workspace',
      ),
    );
  }

  Widget _buildFilesTab() {
    final theme = Theme.of(context);
    final iconFg = theme.resolvedIconColor;
    final displayColor = _project!.displayColor;
    final isDark = theme.brightness == Brightness.dark;

    return Column(
      children: [
        // Upload button
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _isUploadingFile ? null : _pickAndUploadFile,
              icon: const Icon(Icons.upload_file),
              label: const Text('Upload File'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                side: BorderSide(color: displayColor.withValues(alpha: 0.5)),
              ),
            ),
          ),
        ),

        // Upload progress
        if (_isUploadingFile)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Card(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
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
                            _uploadFileName ?? 'File',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _uploadStatus == 'uploading'
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
                      child: _uploadStatus == 'uploading'
                          ? LinearProgressIndicator(
                              value: _uploadProgress,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                displayColor,
                              ),
                            )
                          : LinearProgressIndicator(
                              valueColor: AlwaysStoppedAnimation<Color>(
                                displayColor,
                              ),
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),

        // File list
        Expanded(
          child: _project!.files.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.folder_open,
                        size: 56,
                        color: iconFg.withValues(alpha: 0.2),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'No files in this workspace',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: iconFg.withValues(alpha: 0.5),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Upload PDFs, documents, or code files\nto reference in your chats',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13,
                          color: iconFg.withValues(alpha: 0.4),
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: _project!.files.length,
                  itemBuilder: (context, index) {
                    final file = _project!.files[index];
                    return _buildFileCard(file, displayColor, isDark);
                  },
                ),
        ),

        // Total size footer
        if (_project!.files.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.lock_outlined,
                  size: 12,
                  color: iconFg.withValues(alpha: 0.35),
                ),
                const SizedBox(width: 4),
                Text(
                  '${_project!.files.length} files'
                  ' -- ${_project!.totalFileSizeFormatted}'
                  ' -- End-to-end encrypted',
                  style: TextStyle(
                    fontSize: 11,
                    color: iconFg.withValues(alpha: 0.35),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildFileCard(WorkspaceFile file, Color displayColor, bool isDark) {
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
        subtitle: Row(
          children: [
            Text(file.fileSizeFormatted, style: const TextStyle(fontSize: 12)),
            if (file.hasMarkdownSummary) ...[
              const SizedBox(width: 8),
              Icon(Icons.check_circle, size: 14, color: Colors.green[600]),
              const SizedBox(width: 3),
              Text(
                'Processed',
                style: TextStyle(fontSize: 11, color: Colors.green[600]),
              ),
            ],
          ],
        ),
        trailing: PopupMenuButton(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          itemBuilder: (context) => [
            PopupMenuItem(
              child: const Row(
                children: [
                  Icon(Icons.visibility, size: 18),
                  SizedBox(width: 10),
                  Text('View'),
                ],
              ),
              onTap: () {
                final currentContext = context;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted) return;
                  WorkspaceFileViewer.show(
                    currentContext,
                    file,
                    widget.workspaceId,
                  );
                });
              },
            ),
            PopupMenuItem(
              child: Row(
                children: [
                  Icon(Icons.delete_outline, color: Colors.red, size: 18),
                  const SizedBox(width: 10),
                  const Text('Delete', style: TextStyle(color: Colors.red)),
                ],
              ),
              onTap: () =>
                  Future.delayed(Duration.zero, () => _deleteFile(file)),
            ),
          ],
        ),
        onTap: () => WorkspaceFileViewer.show(context, file, widget.workspaceId),
      ),
    );
  }

  Widget _buildChatsTab() {
    final iconFg = Theme.of(context).resolvedIconColor;
    final displayColor = _project!.displayColor;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _addChat,
              icon: const Icon(Icons.add),
              label: const Text('Add Existing Chat'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                side: BorderSide(color: displayColor.withValues(alpha: 0.5)),
              ),
            ),
          ),
        ),
        Expanded(
          child: _projectChats.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.chat_bubble_outline,
                        size: 56,
                        color: iconFg.withValues(alpha: 0.2),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'No chats in this workspace',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: iconFg.withValues(alpha: 0.5),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Add existing chats or start a new one\nwith the button below',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13,
                          color: iconFg.withValues(alpha: 0.4),
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: _projectChats.length,
                  itemBuilder: (context, index) {
                    final chat = _projectChats[index];
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
                          '${chat.messages.length} messages',
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.remove_circle_outline),
                          color: Colors.red.withValues(alpha: 0.7),
                          onPressed: () => _removeChat(chat.id),
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

  Widget _buildSettingsTab() {
    final theme = Theme.of(context);
    final iconFg = theme.resolvedIconColor;
    final displayColor = _project!.displayColor;
    final onProjectColor =
        ThemeData.estimateBrightnessForColor(displayColor) == Brightness.dark
        ? Colors.white
        : Colors.black;
    final isDark = theme.brightness == Brightness.dark;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Workspace summary card
          Card(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: displayColor.withValues(
                            alpha: isDark ? 0.2 : 0.12,
                          ),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          _project!.displayIcon,
                          color: displayColor,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Workspace Summary',
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              WorkspaceMessageService.getProjectContextSummary(
                                _project!,
                              ),
                              style: TextStyle(
                                fontSize: 12,
                                color: iconFg.withValues(alpha: 0.6),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (_project!.description?.isNotEmpty == true) ...[
                    const SizedBox(height: 12),
                    Text(
                      _project!.description!,
                      style: TextStyle(color: iconFg.withValues(alpha: 0.7)),
                    ),
                  ],
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Instructions section
          Card(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.tune, color: displayColor, size: 18),
                          const SizedBox(width: 8),
                          Text(
                            'Custom Instructions',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      if (!_isEditingInstructions)
                        IconButton(
                          icon: const Icon(Icons.edit, size: 18),
                          onPressed: () =>
                              setState(() => _isEditingInstructions = true),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Instructions sent to the AI at the start of every chat',
                    style: TextStyle(
                      fontSize: 12,
                      color: iconFg.withValues(alpha: 0.5),
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (_isEditingInstructions) ...[
                    TextField(
                      controller: _instructionsController,
                      maxLines: 6,
                      decoration: InputDecoration(
                        hintText: 'Enter custom instructions for the AI...',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () {
                            _instructionsController.text =
                                _project?.customSystemPrompt ?? '';
                            setState(() => _isEditingInstructions = false);
                          },
                          child: const Text('Cancel'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: _saveInstructions,
                          style: FilledButton.styleFrom(
                            backgroundColor: displayColor,
                            foregroundColor: onProjectColor,
                          ),
                          child: const Text('Save'),
                        ),
                      ],
                    ),
                  ] else if (_project!.hasCustomPrompt)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: iconFg.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: iconFg.withValues(alpha: 0.1),
                        ),
                      ),
                      child: Text(
                        _project!.customSystemPrompt!,
                        style: TextStyle(color: iconFg, fontSize: 13),
                      ),
                    )
                  else
                    Text(
                      'No custom instructions set',
                      style: TextStyle(
                        fontStyle: FontStyle.italic,
                        color: iconFg.withValues(alpha: 0.5),
                      ),
                    ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 24),

          // Danger zone
          Card(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: Colors.red.withValues(alpha: 0.2)),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Danger Zone',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: Colors.red[400],
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _showDeleteProjectDialog,
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('Delete Workspace'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red,
                        side: const BorderSide(color: Colors.red),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showEditProjectDialog() async {
    final nameController = TextEditingController(text: _project!.name);
    final descController = TextEditingController(
      text: _project!.description ?? '',
    );

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit Workspace'),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: InputDecoration(
                labelText: 'Workspace Name',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: descController,
              decoration: InputDecoration(
                labelText: 'Description (optional)',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              maxLines: 2,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (result == true && mounted) {
      try {
        await WorkspaceStorageService.updateProject(
          widget.workspaceId,
          name: nameController.text.trim(),
          description: descController.text.trim(),
        );
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Workspace updated')));
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to update: $e')));
      }
    }
  }

  Future<void> _showDeleteProjectDialog() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Workspace'),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        content: const Text(
          'Are you sure? This will remove the workspace workspace. '
          'Chats and files will not be deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      _projectSub?.cancel(); // Stop listener before delete to prevent race
      await WorkspaceStorageService.deleteProject(widget.workspaceId);
      if (mounted) Navigator.pop(context);
    }
  }
}

// ---------- Count Badge ----------

class _CountBadge extends StatelessWidget {
  final int count;
  final Color color;

  const _CountBadge({required this.count, required this.color});

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

/// Bottom sheet for selecting a chat to add to workspace
class _ChatSelectorSheet extends StatelessWidget {
  final List<StoredChat> chats;

  const _ChatSelectorSheet({required this.chats});

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.5,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) {
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey[400],
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Select Chat to Add',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                controller: scrollController,
                itemCount: chats.length,
                itemBuilder: (context, index) {
                  final chat = chats[index];
                  return ListTile(
                    leading: const Icon(Icons.chat),
                    title: Text(
                      chat.customName ?? chat.previewText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${chat.messages.length} messages',
                      style: const TextStyle(fontSize: 12),
                    ),
                    onTap: () => Navigator.pop(context, chat),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}
