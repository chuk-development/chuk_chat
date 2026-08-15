// lib/pages/workspace_detail_page.dart
import 'dart:async';

import 'package:chuk_chat/constants/file_constants.dart';
import 'package:chuk_chat/models/workspace_model.dart';
import 'package:chuk_chat/pages/workspace_mobile_detail_page.dart';
import 'package:chuk_chat/platform_config.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/workspace_message_service.dart';
import 'package:chuk_chat/services/workspace_storage_service.dart';
import 'package:chuk_chat/services/user_preferences_service.dart';
import 'package:chuk_chat/utils/io_helper.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/workspace_file_viewer.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:chuk_chat/constants.dart';

class WorkspaceDetailPage extends StatelessWidget {
  final String workspaceId;
  final Function(String? workspaceId)? onStartNewChat;

  const WorkspaceDetailPage({
    super.key,
    required this.workspaceId,
    this.onStartNewChat,
  });

  bool get _isMobileForm {
    if (kPlatformMobile) return true;
    if (kPlatformDesktop) return false;
    // Auto-detect on platforms where the compile-time flag wasn't set.
    if (kIsWeb) return false;
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => true,
      TargetPlatform.iOS => true,
      _ => false,
    };
  }

  @override
  Widget build(BuildContext context) {
    if (_isMobileForm) {
      return WorkspaceMobileDetailPage(
        workspaceId: workspaceId,
        onStartNewChat: onStartNewChat,
      );
    }
    return _WorkspaceDetailDesktop(
      workspaceId: workspaceId,
      onStartNewChat: onStartNewChat,
    );
  }
}

class _WorkspaceDetailDesktop extends StatefulWidget {
  final String workspaceId;
  final Function(String? workspaceId)? onStartNewChat;

  const _WorkspaceDetailDesktop({
    required this.workspaceId,
    this.onStartNewChat,
  });

  @override
  State<_WorkspaceDetailDesktop> createState() => _WorkspaceDetailPageState();
}

class _WorkspaceDetailPageState extends State<_WorkspaceDetailDesktop>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  Workspace? _project;
  List<StoredChat> _projectChats = [];
  StreamSubscription<void>? _projectUpdatesSub;
  bool _isLoading = true;

  // Upload state
  bool _isUploadingFile = false;
  String? _uploadFileName;
  String _uploadStatus = '';
  double _uploadProgress = 0.0;

  // Settings editing state
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _systemPromptController = TextEditingController();
  bool _hasSettingsChanges = false;

  // Context budget
  String? _selectedModelId;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadProject();
    _loadModelId();
    _projectUpdatesSub = WorkspaceStorageService.changes.listen((_) {
      if (!mounted) return;
      _loadProject();
    });
  }

  Future<void> _loadModelId() async {
    final modelId = await UserPreferencesService.loadSelectedModel();
    if (mounted) {
      setState(() => _selectedModelId = modelId);
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _projectUpdatesSub?.cancel();
    _nameController.dispose();
    _descriptionController.dispose();
    _systemPromptController.dispose();
    super.dispose();
  }

  Future<void> _loadProject() async {
    setState(() => _isLoading = true);
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
          // Only update text controllers if not actively editing
          if (!_hasSettingsChanges) {
            _nameController.text = workspace.name;
            _descriptionController.text = workspace.description ?? '';
            _systemPromptController.text = workspace.customSystemPrompt ?? '';
          }
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

  Future<void> _saveSettings() async {
    if (_project == null) return;
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Workspace name cannot be empty')),
      );
      return;
    }

    try {
      await WorkspaceStorageService.updateProject(
        widget.workspaceId,
        name: name,
        description: _descriptionController.text.trim(),
        customSystemPrompt: _systemPromptController.text.trim(),
      );
      if (mounted) {
        setState(() => _hasSettingsChanges = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Settings saved')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to save: $e')));
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

    final selected = await showDialog<StoredChat>(
      context: context,
      builder: (context) => _ChatSelectorDialog(chats: availableChats),
    );

    if (selected != null && mounted) {
      try {
        await WorkspaceStorageService.addChatToProject(
          widget.workspaceId,
          selected.id,
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Chat added to workspace')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Failed to add chat: $e')));
        }
      }
    }
  }

  Future<void> _removeChat(String chatId) async {
    try {
      await WorkspaceStorageService.removeChatFromProject(
        widget.workspaceId,
        chatId,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Chat removed from workspace')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to remove chat: $e')));
      }
    }
  }

  Future<void> _pickAndUploadFile() async {
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: FileConstants.allowedExtensions,
      );

      if (file == null) return;

      if (file.path == null) {
        if (mounted) {
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

      setState(() {
        _isUploadingFile = true;
        _uploadFileName = fileName;
        _uploadStatus = 'uploading';
        _uploadProgress = 0.0;
      });

      final fileBytes = await File(filePath).readAsBytes();

      if (!mounted || _project == null) return;

      // Check context budget before uploading
      final estimatedNewTokens = (fileBytes.length / 4).ceil();
      final remaining = WorkspaceMessageService.remainingFileTokenBudget(
        _project!,
        _selectedModelId,
      );
      if (remaining < estimatedNewTokens) {
        if (mounted) {
          final proceed = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Context Budget Warning'),
              content: Text(
                'This file (~${_formatTokenCount(estimatedNewTokens)} tokens) '
                'would exceed the context budget for your current model. '
                'The AI may not be able to use all workspace files.\n\n'
                'Upload anyway?',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Upload Anyway'),
                ),
              ],
            ),
          );
          if (proceed != true) return;
        }
      }

      if (!mounted || _project == null) return;

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

  @override
  Widget build(BuildContext context) {
    final iconFg = Theme.of(context).resolvedIconColor;

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
    final isDark = Theme.of(context).brightness == Brightness.dark;

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
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: displayColor,
          labelColor: displayColor,
          tabs: [
            Tab(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.description_outlined, size: 18),
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
      floatingActionButton: widget.onStartNewChat != null
          ? FloatingActionButton.extended(
              onPressed: () {
                widget.onStartNewChat!(widget.workspaceId);
                Navigator.pop(context);
              },
              icon: const Icon(Icons.add_comment),
              label: const Text('New Chat'),
              backgroundColor: displayColor,
              foregroundColor: Colors.white,
            )
          : null,
    );
  }

  // ============ FILES TAB ============

  Widget _buildFilesTab() {
    final iconFg = Theme.of(context).resolvedIconColor;
    final displayColor = _project!.displayColor;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Context budget calculations
    final contextRatio = WorkspaceMessageService.contextUsageRatio(
      _project!,
      _selectedModelId,
    );
    final contextWindow = WorkspaceMessageService.getModelContextWindow(
      _selectedModelId,
    );
    final totalFileTokens = WorkspaceMessageService.estimateTotalFileTokens(
      _project!,
    );
    final remaining = WorkspaceMessageService.remainingFileTokenBudget(
      _project!,
      _selectedModelId,
    );
    final isOverBudget = remaining < 0;

    return Column(
      children: [
        // Context usage bar (shown when files exist or model known)
        if (_project!.files.isNotEmpty && contextRatio != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: _ContextUsageBar(
              ratio: contextRatio,
              totalTokens: totalFileTokens,
              contextWindow: contextWindow ?? 0,
              displayColor: displayColor,
              isOverBudget: isOverBudget,
            ),
          ),

        // Upload button
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _isUploadingFile ? null : _pickAndUploadFile,
              icon: const Icon(Icons.upload_file),
              label: Text(isOverBudget ? 'Context budget full' : 'Upload File'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: kBorderRadiusPill,
                ),
                side: BorderSide(
                  color: isOverBudget
                      ? Colors.orange.withValues(alpha: 0.5)
                      : displayColor.withValues(alpha: 0.5),
                ),
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
                        'No files yet',
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
                    final fileRatio = WorkspaceMessageService.fileContextRatio(
                      file,
                      _selectedModelId,
                    );
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: ListTile(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        leading: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: displayColor.withValues(
                              alpha: isDark ? 0.15 : 0.1,
                            ),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            file.fileIcon,
                            color: displayColor,
                            size: 20,
                          ),
                        ),
                        title: Text(
                          file.fileName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 14),
                        ),
                        subtitle: Row(
                          children: [
                            Text(
                              file.fileSizeFormatted,
                              style: const TextStyle(fontSize: 12),
                            ),
                            const SizedBox(width: 8),
                            // Context usage chip
                            if (fileRatio != null)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 5,
                                  vertical: 1,
                                ),
                                decoration: BoxDecoration(
                                  color: _contextChipColor(
                                    fileRatio,
                                  ).withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  '${(fileRatio * 100).toStringAsFixed(1)}%',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: _contextChipColor(fileRatio),
                                  ),
                                ),
                              )
                            else
                              Text(
                                file.estimatedTokensFormatted,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: iconFg.withValues(alpha: 0.5),
                                ),
                              ),
                            if (file.hasMarkdownSummary) ...[
                              const SizedBox(width: 6),
                              Icon(
                                Icons.check_circle,
                                size: 13,
                                color: Colors.green[600],
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
                                WidgetsBinding.instance.addPostFrameCallback((
                                  _,
                                ) {
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
                                  Icon(
                                    Icons.delete_outline,
                                    color: Colors.red,
                                    size: 18,
                                  ),
                                  const SizedBox(width: 10),
                                  const Text(
                                    'Delete',
                                    style: TextStyle(color: Colors.red),
                                  ),
                                ],
                              ),
                              onTap: () => Future.delayed(
                                Duration.zero,
                                () => _deleteFile(file),
                              ),
                            ),
                          ],
                        ),
                        onTap: () => WorkspaceFileViewer.show(
                          context,
                          file,
                          widget.workspaceId,
                        ),
                      ),
                    );
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
                  Icons.storage_outlined,
                  size: 14,
                  color: iconFg.withValues(alpha: 0.4),
                ),
                const SizedBox(width: 6),
                Text(
                  '${_project!.files.length} file${_project!.files.length == 1 ? '' : 's'}'
                  ' -- ${_project!.totalFileSizeFormatted} total'
                  ' -- All encrypted',
                  style: TextStyle(
                    fontSize: 12,
                    color: iconFg.withValues(alpha: 0.4),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  static String _formatTokenCount(int tokens) {
    if (tokens < 1000) return '$tokens';
    if (tokens < 10000) return '${(tokens / 1000).toStringAsFixed(1)}k';
    return '${(tokens / 1000).round()}k';
  }

  Color _contextChipColor(double ratio) {
    if (ratio > 0.20) return Colors.red;
    if (ratio > 0.10) return Colors.orange;
    return Colors.green;
  }

  // ============ CHATS TAB ============

  Widget _buildChatsTab() {
    final iconFg = Theme.of(context).resolvedIconColor;
    final displayColor = _project!.displayColor;

    return Column(
      children: [
        // Add chat button
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
                  borderRadius: kBorderRadiusPill,
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
                          '${chat.messages.length} messages'
                          ' -- ${chat.createdAt.toString().split(' ')[0]}',
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: IconButton(
                          icon: Icon(
                            Icons.remove_circle_outline,
                            color: Colors.red.withValues(alpha: 0.7),
                            size: 20,
                          ),
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

  // ============ SETTINGS TAB ============

  Widget _buildSettingsTab() {
    final theme = Theme.of(context);
    final iconFg = theme.resolvedIconColor;
    final displayColor = _project!.displayColor;
    final isDark = theme.brightness == Brightness.dark;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Workspace identity card
          Card(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Workspace avatar + stats header
                  Row(
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: displayColor.withValues(
                            alpha: isDark ? 0.2 : 0.12,
                          ),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Icon(
                          _project!.displayIcon,
                          color: displayColor,
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${_project!.chatCount} chats, ${_project!.fileCount} files',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                                color: iconFg,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Updated ${_project!.updatedAgo}',
                              style: TextStyle(
                                fontSize: 12,
                                color: iconFg.withValues(alpha: 0.5),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),

                  // Name
                  Text(
                    'Workspace Name',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      color: iconFg.withValues(alpha: 0.7),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _nameController,
                    decoration: InputDecoration(
                      hintText: 'Workspace name',
                    ),
                    onChanged: (_) =>
                        setState(() => _hasSettingsChanges = true),
                  ),
                  const SizedBox(height: 16),

                  // Description
                  Text(
                    'Description',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      color: iconFg.withValues(alpha: 0.7),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _descriptionController,
                    decoration: InputDecoration(
                      hintText: 'What is this workspace about?',
                    ),
                    maxLines: 3,
                    onChanged: (_) =>
                        setState(() => _hasSettingsChanges = true),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // System prompt card
          Card(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.tune, color: displayColor, size: 20),
                      const SizedBox(width: 8),
                      Text(
                        'Custom System Prompt',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                          color: iconFg,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'These instructions are sent to the AI at the start of '
                    'every chat in this workspace.',
                    style: TextStyle(
                      fontSize: 12,
                      color: iconFg.withValues(alpha: 0.5),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _systemPromptController,
                    decoration: InputDecoration(
                      hintText:
                          'e.g., You are a senior developer helping with a '
                          'Flutter workspace. Use Dart best practices...',
                      hintMaxLines: 3,
                    ),
                    maxLines: 6,
                    onChanged: (_) =>
                        setState(() => _hasSettingsChanges = true),
                  ),
                ],
              ),
            ),
          ),

          // Save button (only shown when changes exist)
          if (_hasSettingsChanges) ...[
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _saveSettings,
                icon: const Icon(Icons.save, size: 18),
                label: const Text('Save Changes'),
                style: FilledButton.styleFrom(
                  backgroundColor: displayColor,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: kBorderRadiusPill,
                  ),
                ),
              ),
            ),
          ],

          const SizedBox(height: 24),

          // Danger zone
          Card(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: Colors.red.withValues(alpha: 0.2)),
            ),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Danger Zone',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                      color: Colors.red[400],
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'These actions cannot be undone.',
                    style: TextStyle(
                      fontSize: 12,
                      color: iconFg.withValues(alpha: 0.5),
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        final confirmed = await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: const Text('Delete Workspace'),
                            content: const Text(
                              'Are you sure? This will remove the workspace '
                              'workspace. Chats and files will not be deleted.',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context, false),
                                child: const Text('Cancel'),
                              ),
                              TextButton(
                                onPressed: () => Navigator.pop(context, true),
                                style: TextButton.styleFrom(
                                  foregroundColor: Colors.red,
                                ),
                                child: const Text('Delete'),
                              ),
                            ],
                          ),
                        );
                        if (confirmed == true && mounted) {
                          try {
                            await WorkspaceStorageService.deleteProject(
                              widget.workspaceId,
                            );
                            if (mounted) Navigator.pop(context);
                          } catch (e) {
                            if (!mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Failed to delete workspace: $e'),
                              ),
                            );
                          }
                        }
                      },
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('Delete Workspace'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red,
                        side: const BorderSide(color: Colors.red),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: kBorderRadiusPill,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

// ---------- Context Usage Bar ----------

class _ContextUsageBar extends StatelessWidget {
  final double ratio;
  final int totalTokens;
  final int contextWindow;
  final Color displayColor;
  final bool isOverBudget;

  const _ContextUsageBar({
    required this.ratio,
    required this.totalTokens,
    required this.contextWindow,
    required this.displayColor,
    required this.isOverBudget,
  });

  @override
  Widget build(BuildContext context) {
    final iconFg = Theme.of(context).resolvedIconColor;
    // We use 75% of context as the file budget
    final budgetRatio = (ratio / 0.75).clamp(0.0, 1.0);
    final pct = (ratio * 100).toStringAsFixed(1);

    final barColor = isOverBudget
        ? Colors.red
        : ratio > 0.50
        ? Colors.orange
        : displayColor;

    String tokenLabel;
    if (totalTokens < 1000) {
      tokenLabel = '$totalTokens';
    } else if (totalTokens < 10000) {
      tokenLabel = '${(totalTokens / 1000).toStringAsFixed(1)}k';
    } else {
      tokenLabel = '${(totalTokens / 1000).round()}k';
    }

    String windowLabel;
    if (contextWindow < 1000) {
      windowLabel = '$contextWindow';
    } else {
      windowLabel = '${(contextWindow / 1000).round()}k';
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: iconFg.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isOverBudget
              ? Colors.red.withValues(alpha: 0.3)
              : iconFg.withValues(alpha: 0.08),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.memory_outlined, size: 14, color: barColor),
              const SizedBox(width: 6),
              Text(
                'Context Usage',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: iconFg.withValues(alpha: 0.7),
                ),
              ),
              const Spacer(),
              Text(
                '$tokenLabel / $windowLabel tokens ($pct%)',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: barColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: budgetRatio,
              minHeight: 6,
              backgroundColor: iconFg.withValues(alpha: 0.08),
              valueColor: AlwaysStoppedAnimation<Color>(barColor),
            ),
          ),
          if (isOverBudget) ...[
            const SizedBox(height: 6),
            Text(
              'Files exceed 75% context budget. Some may be excluded from AI context.',
              style: TextStyle(fontSize: 11, color: Colors.red[400]),
            ),
          ],
        ],
      ),
    );
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

// ---------- Chat Selector Dialog ----------

class _ChatSelectorDialog extends StatefulWidget {
  final List<StoredChat> chats;

  const _ChatSelectorDialog({required this.chats});

  @override
  State<_ChatSelectorDialog> createState() => _ChatSelectorDialogState();
}

class _ChatSelectorDialogState extends State<_ChatSelectorDialog> {
  final _searchController = TextEditingController();
  late List<StoredChat> _filtered;

  @override
  void initState() {
    super.initState();
    _filtered = widget.chats;
    _searchController.addListener(_filter);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _filter() {
    final query = _searchController.text.toLowerCase();
    setState(() {
      if (query.isEmpty) {
        _filtered = widget.chats;
      } else {
        _filtered = widget.chats.where((chat) {
          final name = (chat.customName ?? chat.previewText).toLowerCase();
          return name.contains(query);
        }).toList();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Select Chat'),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.chats.length > 5)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: 'Search chats...',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                ),
              ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _filtered.length,
                itemBuilder: (context, index) {
                  final chat = _filtered[index];
                  return ListTile(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
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
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
