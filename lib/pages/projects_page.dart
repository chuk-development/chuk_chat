// lib/pages/projects_page.dart
import 'dart:async';

import 'package:chuk_chat/models/project_model.dart';
import 'package:chuk_chat/pages/project_detail_page.dart';
import 'package:chuk_chat/services/project_storage_service.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:flutter/material.dart';

class ProjectsPage extends StatefulWidget {
  const ProjectsPage({super.key});

  @override
  State<ProjectsPage> createState() => _ProjectsPageState();
}

class _ProjectsPageState extends State<ProjectsPage> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  List<Project> _filteredProjects = [];
  StreamSubscription<void>? _projectUpdatesSub;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadProjects();
    _searchController.addListener(_onSearchChanged);
    _projectUpdatesSub = ProjectStorageService.changes.listen((_) {
      if (!mounted) return;
      _filterProjects();
    });
  }

  @override
  void dispose() {
    _projectUpdatesSub?.cancel();
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    setState(() {
      _searchQuery = _searchController.text;
      _filterProjects();
    });
  }

  Future<void> _loadProjects() async {
    setState(() => _isLoading = true);
    try {
      await ProjectStorageService.loadProjects();
      _filterProjects();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load projects: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _filterProjects() {
    if (!mounted) return;
    setState(() {
      final projects = ProjectStorageService.activeProjects;
      if (_searchQuery.isEmpty) {
        _filteredProjects = projects;
      } else {
        final query = _searchQuery.toLowerCase();
        _filteredProjects = projects.where((p) {
          return p.name.toLowerCase().contains(query) ||
              (p.description?.toLowerCase().contains(query) ?? false);
        }).toList();
      }
    });
  }

  Future<void> _createProject() async {
    final result = await showDialog<Map<String, String?>>(
      context: context,
      builder: (context) => const _CreateProjectDialog(),
    );

    if (result != null && mounted) {
      try {
        await ProjectStorageService.createProject(
          result['name']!,
          description: result['description'],
          customSystemPrompt: result['systemPrompt'],
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Project created')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to create project: $e')),
          );
        }
      }
    }
  }

  Future<void> _deleteProject(Project project) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Project'),
        content: Text(
          'Are you sure you want to delete "${project.name}"?\n\nThis will not delete the chats or files, just the project workspace.',
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
      try {
        await ProjectStorageService.deleteProject(project.id);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Project deleted')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to delete project: $e')),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final iconFg = Theme.of(context).resolvedIconColor;
    final isMobile = MediaQuery.of(context).size.width < 800;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Projects'),
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: iconFg),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.add, color: iconFg),
            onPressed: _createProject,
            tooltip: 'Create Project',
          ),
        ],
      ),
      body: Column(
        children: [
          // Search bar
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search projects...',
                prefixIcon: Icon(Icons.search, color: iconFg),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: Icon(Icons.clear, color: iconFg),
                        onPressed: () => _searchController.clear(),
                      )
                    : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ),

          // Project list
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _filteredProjects.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.folder_open,
                                size: 64, color: iconFg.withOpacity(0.3)),
                            const SizedBox(height: 16),
                            Text(
                              _searchQuery.isEmpty
                                  ? 'No projects yet'
                                  : 'No projects found',
                              style: TextStyle(color: iconFg.withOpacity(0.5)),
                            ),
                            if (_searchQuery.isEmpty) ...[
                              const SizedBox(height: 8),
                              TextButton.icon(
                                onPressed: _createProject,
                                icon: const Icon(Icons.add),
                                label: const Text('Create your first project'),
                              ),
                            ],
                          ],
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: _loadProjects,
                        child: isMobile
                            ? _buildMobileList()
                            : _buildDesktopGrid(),
                      ),
          ),
        ],
      ),
      floatingActionButton: isMobile
          ? FloatingActionButton(
              onPressed: _createProject,
              child: const Icon(Icons.add),
            )
          : null,
    );
  }

  Widget _buildDesktopGrid() {
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 400,
        mainAxisSpacing: 16,
        crossAxisSpacing: 16,
        childAspectRatio: 1.5,
      ),
      itemCount: _filteredProjects.length,
      itemBuilder: (context, index) {
        return _ProjectCard(
          project: _filteredProjects[index],
          onTap: () => _openProjectDetail(_filteredProjects[index]),
          onDelete: () => _deleteProject(_filteredProjects[index]),
        );
      },
    );
  }

  Widget _buildMobileList() {
    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: _filteredProjects.length,
      itemBuilder: (context, index) {
        return _ProjectCard(
          project: _filteredProjects[index],
          onTap: () => _openProjectDetail(_filteredProjects[index]),
          onDelete: () => _deleteProject(_filteredProjects[index]),
        );
      },
    );
  }

  void _openProjectDetail(Project project) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ProjectDetailPage(projectId: project.id),
      ),
    );
  }
}

class _ProjectCard extends StatelessWidget {
  final Project project;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _ProjectCard({
    required this.project,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final iconFg = Theme.of(context).resolvedIconColor;
    final accentColor = Theme.of(context).colorScheme.primary;

    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                children: [
                  Icon(Icons.folder_open, color: accentColor),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      project.name,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  PopupMenuButton<String>(
                    icon: Icon(Icons.more_vert, color: iconFg),
                    onSelected: (value) {
                      if (value == 'delete') onDelete();
                    },
                    itemBuilder: (context) => [
                      const PopupMenuItem(
                        value: 'delete',
                        child: Row(
                          children: [
                            Icon(Icons.delete, color: Colors.red),
                            SizedBox(width: 8),
                            Text('Delete', style: TextStyle(color: Colors.red)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 8),

              // Description
              if (project.description != null &&
                  project.description!.isNotEmpty)
                Expanded(
                  child: Text(
                    project.description!,
                    style: TextStyle(color: iconFg.withOpacity(0.7)),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                )
              else
                const Spacer(),

              const SizedBox(height: 8),

              // Stats
              Wrap(
                spacing: 12,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.chat, size: 16, color: iconFg.withOpacity(0.6)),
                      const SizedBox(width: 4),
                      Text(
                        '${project.chatCount}',
                        style: TextStyle(color: iconFg.withOpacity(0.6)),
                      ),
                    ],
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.attach_file,
                          size: 16, color: iconFg.withOpacity(0.6)),
                      const SizedBox(width: 4),
                      Text(
                        '${project.fileCount}',
                        style: TextStyle(color: iconFg.withOpacity(0.6)),
                      ),
                    ],
                  ),
                  if (project.hasCustomPrompt)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.settings,
                            size: 16, color: accentColor),
                        const SizedBox(width: 4),
                        Text(
                          'Custom',
                          style: TextStyle(color: accentColor),
                        ),
                      ],
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CreateProjectDialog extends StatefulWidget {
  const _CreateProjectDialog();

  @override
  State<_CreateProjectDialog> createState() => _CreateProjectDialogState();
}

class _CreateProjectDialogState extends State<_CreateProjectDialog> {
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _systemPromptController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _systemPromptController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Create Project'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Project Name',
                hintText: 'e.g., AI Research Assistant',
              ),
              autofocus: true,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _descriptionController,
              decoration: const InputDecoration(
                labelText: 'Description (optional)',
                hintText: 'Briefly describe this project',
              ),
              maxLines: 2,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _systemPromptController,
              decoration: const InputDecoration(
                labelText: 'Custom System Prompt (optional)',
                hintText: 'Special instructions for AI in this project',
              ),
              maxLines: 3,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () {
            final name = _nameController.text.trim();
            if (name.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Project name is required')),
              );
              return;
            }
            Navigator.pop(context, {
              'name': name,
              'description': _descriptionController.text.trim().isNotEmpty
                  ? _descriptionController.text.trim()
                  : null,
              'systemPrompt': _systemPromptController.text.trim().isNotEmpty
                  ? _systemPromptController.text.trim()
                  : null,
            });
          },
          child: const Text('Create'),
        ),
      ],
    );
  }
}
