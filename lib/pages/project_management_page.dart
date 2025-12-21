// lib/pages/project_management_page.dart
import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:chuk_chat/constants/file_constants.dart';
import 'package:chuk_chat/models/project_model.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/project_storage_service.dart';
import 'package:chuk_chat/services/project_message_service.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/project_file_viewer.dart';

/// Mobile-friendly project management page
/// Allows managing files, instructions, chats, and starting new chats with project context
class ProjectManagementPage extends StatefulWidget {
  final String projectId;
  final Function(String? projectId)? onStartNewChat;

  const ProjectManagementPage({
    super.key,
    required this.projectId,
    this.onStartNewChat,
  });

  @override
  State<ProjectManagementPage> createState() => _ProjectManagementPageState();
}

class _ProjectManagementPageState extends State<ProjectManagementPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  Project? _project;
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
    _projectSub = ProjectStorageService.changes.listen((_) {
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
      final project = ProjectStorageService.getProject(widget.projectId);
      if (project == null) {
        throw StateError('Project not found');
      }
      final chats = await ProjectStorageService.getProjectChats(widget.projectId);
      if (mounted) {
        setState(() {
          _project = project;
          _projectChats = chats;
          _instructionsController.text = project.customSystemPrompt ?? '';
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load project: $e')),
        );
        Navigator.pop(context);
      }
    }
  }

  Future<void> _saveInstructions() async {
    if (_project == null) return;
    try {
      await ProjectStorageService.updateProject(
        widget.projectId,
        customSystemPrompt: _instructionsController.text.trim(),
      );
      if (mounted) {
        setState(() => _isEditingInstructions = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Instructions saved')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save: $e')),
        );
      }
    }
  }

  Future<void> _pickAndUploadFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
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

      await ProjectStorageService.uploadFile(
        widget.projectId,
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Uploaded: $fileName')),
        );
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

  Future<void> _deleteFile(ProjectFile file) async {
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
        await ProjectStorageService.deleteFile(widget.projectId, file.id);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Delete failed: $e')),
          );
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
        await ProjectStorageService.addChatToProject(
          widget.projectId,
          selected.id,
        );
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Chat added to project')),
        );
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to add chat: $e')),
        );
      }
    }
  }

  Future<void> _removeChat(String chatId) async {
    try {
      await ProjectStorageService.removeChatFromProject(widget.projectId, chatId);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Chat removed from project')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to remove chat: $e')),
      );
    }
  }

  void _startNewChatWithProject() {
    if (widget.onStartNewChat != null) {
      widget.onStartNewChat!(widget.projectId);
      Navigator.pop(context);
    } else {
      // Return project ID for parent to handle
      Navigator.pop(context, widget.projectId);
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
        appBar: AppBar(title: const Text('Project Not Found')),
        body: const Center(child: Text('Project not found')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(_project!.name),
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: iconFg),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.edit, color: iconFg),
            onPressed: _showEditProjectDialog,
            tooltip: 'Edit project',
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Files', icon: Icon(Icons.folder)),
            Tab(text: 'Chats', icon: Icon(Icons.chat)),
            Tab(text: 'Settings', icon: Icon(Icons.settings)),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildFilesTab(),
          _buildChatsTab(),
          _buildSettingsTab(),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _startNewChatWithProject,
        icon: const Icon(Icons.add_comment),
        label: const Text('New Chat'),
        tooltip: 'Start new chat with this project',
      ),
    );
  }

  Widget _buildFilesTab() {
    final theme = Theme.of(context);
    final iconFg = theme.resolvedIconColor;
    final accentColor = theme.colorScheme.primary;

    return Column(
      children: [
        // Upload button
        Padding(
          padding: const EdgeInsets.all(16),
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _isUploadingFile ? null : _pickAndUploadFile,
              icon: const Icon(Icons.upload_file),
              label: const Text('Upload File'),
            ),
          ),
        ),

        // Upload progress
        if (_isUploadingFile)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.insert_drive_file, color: accentColor),
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
                          ? 'Uploading...'
                          : 'Converting to markdown...',
                      style: TextStyle(
                        fontSize: 12,
                        color: iconFg.withValues(alpha: 0.7),
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (_uploadStatus == 'uploading')
                      LinearProgressIndicator(value: _uploadProgress)
                    else
                      const LinearProgressIndicator(),
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
                        size: 64,
                        color: iconFg.withValues(alpha: 0.3),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'No files in this project',
                        style: TextStyle(
                          color: iconFg.withValues(alpha: 0.5),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Upload PDFs, documents, or code files\nto reference in your chats',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
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
                    return _buildFileCard(file);
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildFileCard(ProjectFile file) {
    final theme = Theme.of(context);
    final iconFg = theme.resolvedIconColor;
    final accentColor = theme.colorScheme.primary;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(file.fileIcon, color: accentColor),
        title: Text(
          file.fileName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Row(
          children: [
            Text(file.fileSizeFormatted),
            if (file.hasMarkdownSummary) ...[
              const SizedBox(width: 8),
              Icon(Icons.check_circle, size: 14, color: Colors.green),
              const SizedBox(width: 4),
              Text(
                'Processed',
                style: TextStyle(fontSize: 12, color: Colors.green),
              ),
            ],
          ],
        ),
        trailing: PopupMenuButton(
          itemBuilder: (context) => [
            PopupMenuItem(
              child: const Row(
                children: [
                  Icon(Icons.visibility),
                  SizedBox(width: 8),
                  Text('View'),
                ],
              ),
              onTap: () {
                Future.delayed(Duration.zero, () {
                  ProjectFileViewer.show(context, file, widget.projectId);
                });
              },
            ),
            PopupMenuItem(
              child: Row(
                children: [
                  Icon(Icons.delete, color: Colors.red),
                  const SizedBox(width: 8),
                  Text('Delete', style: TextStyle(color: Colors.red)),
                ],
              ),
              onTap: () => Future.delayed(Duration.zero, () => _deleteFile(file)),
            ),
          ],
        ),
        onTap: () => ProjectFileViewer.show(context, file, widget.projectId),
      ),
    );
  }

  Widget _buildChatsTab() {
    final iconFg = Theme.of(context).resolvedIconColor;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _addChat,
              icon: const Icon(Icons.add),
              label: const Text('Add Existing Chat'),
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
                        size: 64,
                        color: iconFg.withValues(alpha: 0.3),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'No chats in this project',
                        style: TextStyle(
                          color: iconFg.withValues(alpha: 0.5),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Add existing chats or start a new one\nwith the button below',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
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
                      child: ListTile(
                        leading: Icon(Icons.chat, color: iconFg),
                        title: Text(
                          chat.customName ?? chat.previewText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${chat.messages.length} messages',
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.remove_circle_outline),
                          color: Colors.red,
                          onPressed: () => _removeChat(chat.id),
                          tooltip: 'Remove from project',
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

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Project summary card
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Project Summary',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _buildSummaryRow(
                    Icons.description,
                    ProjectMessageService.getProjectContextSummary(_project!),
                  ),
                  if (_project!.description?.isNotEmpty == true) ...[
                    const SizedBox(height: 8),
                    Text(
                      _project!.description!,
                      style: TextStyle(
                        color: iconFg.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Instructions section
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Custom Instructions',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (!_isEditingInstructions)
                        IconButton(
                          icon: const Icon(Icons.edit),
                          onPressed: () => setState(() => _isEditingInstructions = true),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Add instructions to customize AI responses for this project',
                    style: TextStyle(
                      fontSize: 12,
                      color: iconFg.withValues(alpha: 0.6),
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (_isEditingInstructions) ...[
                    TextField(
                      controller: _instructionsController,
                      maxLines: 6,
                      decoration: const InputDecoration(
                        hintText: 'Enter custom instructions for the AI...',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () {
                            _instructionsController.text = _project?.customSystemPrompt ?? '';
                            setState(() => _isEditingInstructions = false);
                          },
                          child: const Text('Cancel'),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: _saveInstructions,
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
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: iconFg.withValues(alpha: 0.1)),
                      ),
                      child: Text(
                        _project!.customSystemPrompt!,
                        style: TextStyle(color: iconFg),
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
            color: Colors.red.withValues(alpha: 0.05),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Danger Zone',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: Colors.red,
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _showDeleteProjectDialog,
                      icon: const Icon(Icons.delete, color: Colors.red),
                      label: const Text('Delete Project'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red,
                        side: const BorderSide(color: Colors.red),
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

  Widget _buildSummaryRow(IconData icon, String text) {
    final iconFg = Theme.of(context).resolvedIconColor;
    return Row(
      children: [
        Icon(icon, size: 16, color: iconFg.withValues(alpha: 0.6)),
        const SizedBox(width: 8),
        Text(text),
      ],
    );
  }

  Future<void> _showEditProjectDialog() async {
    final nameController = TextEditingController(text: _project!.name);
    final descController = TextEditingController(text: _project!.description ?? '');

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit Project'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
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
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (result == true && mounted) {
      try {
        await ProjectStorageService.updateProject(
          widget.projectId,
          name: nameController.text.trim(),
          description: descController.text.trim(),
        );
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Project updated')),
        );
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update: $e')),
        );
      }
    }
  }

  Future<void> _showDeleteProjectDialog() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Project'),
        content: const Text(
          'Are you sure? This will not delete chats or files, just the project workspace.',
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
      await ProjectStorageService.deleteProject(widget.projectId);
      if (mounted) Navigator.pop(context);
    }
  }
}

/// Bottom sheet for selecting a chat to add to project
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
