// lib/pages/project_detail_page.dart
import 'dart:async';

import 'package:chuk_chat/models/project_model.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/project_storage_service.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:flutter/material.dart';

class ProjectDetailPage extends StatefulWidget {
  final String projectId;

  const ProjectDetailPage({super.key, required this.projectId});

  @override
  State<ProjectDetailPage> createState() => _ProjectDetailPageState();
}

class _ProjectDetailPageState extends State<ProjectDetailPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  Project? _project;
  List<StoredChat> _projectChats = [];
  StreamSubscription<void>? _projectUpdatesSub;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadProject();
    _projectUpdatesSub = ProjectStorageService.changes.listen((_) {
      if (!mounted) return;
      _loadProject();
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _projectUpdatesSub?.cancel();
    super.dispose();
  }

  Future<void> _loadProject() async {
    setState(() => _isLoading = true);
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

  Future<void> _updateProject({
    String? name,
    String? description,
    String? systemPrompt,
  }) async {
    try {
      await ProjectStorageService.updateProject(
        widget.projectId,
        name: name,
        description: description,
        customSystemPrompt: systemPrompt,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Project updated')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update project: $e')),
        );
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
        await ProjectStorageService.addChatToProject(
          widget.projectId,
          selected.id,
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Chat added to project')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to add chat: $e')),
          );
        }
      }
    }
  }

  Future<void> _removeChat(String chatId) async {
    try {
      await ProjectStorageService.removeChatFromProject(widget.projectId, chatId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Chat removed from project')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to remove chat: $e')),
        );
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
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Chats', icon: Icon(Icons.chat)),
            Tab(text: 'Files', icon: Icon(Icons.attach_file)),
            Tab(text: 'Settings', icon: Icon(Icons.settings)),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildChatsTab(),
          _buildFilesTab(),
          _buildSettingsTab(),
        ],
      ),
    );
  }

  Widget _buildChatsTab() {
    final iconFg = Theme.of(context).resolvedIconColor;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: ElevatedButton.icon(
            onPressed: _addChat,
            icon: const Icon(Icons.add),
            label: const Text('Add Chat to Project'),
          ),
        ),
        Expanded(
          child: _projectChats.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.chat,
                          size: 64, color: iconFg.withOpacity(0.3)),
                      const SizedBox(height: 16),
                      Text(
                        'No chats in this project',
                        style: TextStyle(color: iconFg.withOpacity(0.5)),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: _projectChats.length,
                  itemBuilder: (context, index) {
                    final chat = _projectChats[index];
                    return ListTile(
                      leading: Icon(Icons.chat, color: iconFg),
                      title: Text(
                        chat.customName ?? chat.previewText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${chat.messages.length} messages • ${chat.createdAt.toString().split(' ')[0]}',
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.close, color: Colors.red),
                        onPressed: () => _removeChat(chat.id),
                        tooltip: 'Remove from project',
                      ),
                      onTap: () {
                        // TODO: Open chat in chat UI with project context
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Chat UI integration coming soon'),
                          ),
                        );
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildFilesTab() {
    final iconFg = Theme.of(context).resolvedIconColor;

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.attach_file, size: 64, color: iconFg.withOpacity(0.3)),
          const SizedBox(height: 16),
          Text(
            'File upload coming soon',
            style: TextStyle(color: iconFg.withOpacity(0.5)),
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Project Name',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          TextFormField(
            initialValue: _project!.name,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: 'Project name',
            ),
            onFieldSubmitted: (value) {
              if (value.trim().isNotEmpty) {
                _updateProject(name: value.trim());
              }
            },
          ),
          const SizedBox(height: 24),
          const Text(
            'Description',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          TextFormField(
            initialValue: _project!.description ?? '',
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: 'Project description',
            ),
            maxLines: 3,
            onFieldSubmitted: (value) {
              _updateProject(description: value.trim());
            },
          ),
          const SizedBox(height: 24),
          const Text(
            'Custom System Prompt',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          TextFormField(
            initialValue: _project!.customSystemPrompt ?? '',
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: 'Special instructions for AI in this project',
            ),
            maxLines: 5,
            onFieldSubmitted: (value) {
              _updateProject(systemPrompt: value.trim());
            },
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: () async {
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
            },
            icon: const Icon(Icons.delete, color: Colors.red),
            label: const Text('Delete Project'),
            style: ElevatedButton.styleFrom(foregroundColor: Colors.red),
          ),
        ],
      ),
    );
  }
}

class _ChatSelectorDialog extends StatelessWidget {
  final List<StoredChat> chats;

  const _ChatSelectorDialog({required this.chats});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Select Chat'),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: chats.length,
          itemBuilder: (context, index) {
            final chat = chats[index];
            return ListTile(
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
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
