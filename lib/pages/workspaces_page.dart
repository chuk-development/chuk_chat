// lib/pages/workspaces_page.dart
import 'dart:async';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/workspace_model.dart';
import 'package:chuk_chat/pages/workspace_detail_page.dart';
import 'package:chuk_chat/services/workspace_storage_service.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:flutter/material.dart';

/// Sort options for workspace list
enum ProjectSortMode { recentlyUpdated, name, mostFiles, mostChats }

class WorkspacesPage extends StatefulWidget {
  final void Function(String workspaceId)? onOpenWorkspace;
  final bool embedded;

  const WorkspacesPage({super.key, this.onOpenWorkspace, this.embedded = false});

  @override
  State<WorkspacesPage> createState() => _WorkspacesPageState();
}

class _WorkspacesPageState extends State<WorkspacesPage> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  List<Workspace> _filteredProjects = [];
  StreamSubscription<void>? _projectUpdatesSub;
  bool _isLoading = true;
  ProjectSortMode _sortMode = ProjectSortMode.recentlyUpdated;

  @override
  void initState() {
    super.initState();
    _loadProjects();
    _searchController.addListener(_onSearchChanged);
    _projectUpdatesSub = WorkspaceStorageService.changes.listen((_) {
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
      await WorkspaceStorageService.loadProjects();
      _filterProjects();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to load projects: $e')));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _filterProjects() {
    if (!mounted) return;
    setState(() {
      var projects = List<Workspace>.from(WorkspaceStorageService.activeProjects);
      if (_searchQuery.isNotEmpty) {
        final query = _searchQuery.toLowerCase();
        projects = projects.where((p) {
          return p.name.toLowerCase().contains(query) ||
              (p.description?.toLowerCase().contains(query) ?? false);
        }).toList();
      }
      // Apply sorting
      switch (_sortMode) {
        case ProjectSortMode.recentlyUpdated:
          projects.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
        case ProjectSortMode.name:
          projects.sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          );
        case ProjectSortMode.mostFiles:
          projects.sort((a, b) => b.fileCount.compareTo(a.fileCount));
        case ProjectSortMode.mostChats:
          projects.sort((a, b) => b.chatCount.compareTo(a.chatCount));
      }
      _filteredProjects = projects;
    });
  }

  Future<void> _createProject() async {
    final result = await showDialog<Map<String, String?>>(
      context: context,
      builder: (context) => const _CreateProjectDialog(),
    );

    if (result != null && mounted) {
      try {
        final workspace = await WorkspaceStorageService.createProject(
          result['name']!,
          description: result['description'],
          customSystemPrompt: result['systemPrompt'],
        );
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Created "${workspace.name}"')));
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to create workspace: $e')),
          );
        }
      }
    }
  }

  Future<void> _deleteProject(Workspace workspace) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Workspace'),
        content: Text(
          'Are you sure you want to delete "${workspace.name}"?\n\n'
          'This will remove the workspace workspace. '
          'Chats and uploaded files will not be deleted.',
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
        await WorkspaceStorageService.deleteProject(workspace.id);
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Workspace deleted')));
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to delete workspace: $e')),
          );
        }
      }
    }
  }

  Future<void> _archiveProject(Workspace workspace) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await WorkspaceStorageService.archiveProject(workspace.id, true);
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(
            content: Text('Archived "${workspace.name}"'),
            action: SnackBarAction(
              label: 'Undo',
              onPressed: () async {
                try {
                  await WorkspaceStorageService.archiveProject(workspace.id, false);
                } catch (e) {
                  messenger.showSnackBar(
                    SnackBar(content: Text('Failed to restore workspace: $e')),
                  );
                }
              },
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('Failed to archive: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final iconFg = theme.resolvedIconColor;
    final isMobile = MediaQuery.of(context).size.width < 800;
    final l = AppLocalizations.of(context)!;

    final body = Column(
      children: [
        // Big serif headline — matches the "Projekte" look from the
        // reference screenshot.
        Padding(
          padding: EdgeInsets.fromLTRB(20, widget.embedded ? 8 : 12, 20, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Text(
                  l.workspaces,
                  style: TextStyle(
                    fontSize: 34,
                    height: 1.05,
                    fontWeight: FontWeight.w600,
                    fontFamily: 'serif',
                    color: iconFg,
                    letterSpacing: -0.5,
                  ),
                ),
              ),
              _SortButton(
                sortMode: _sortMode,
                onChanged: (mode) {
                  setState(() {
                    _sortMode = mode;
                    _filterProjects();
                  });
                },
              ),
              IconButton(
                tooltip: l.newWorkspace,
                onPressed: _createProject,
                icon: Icon(Icons.add, color: iconFg),
              ),
            ],
          ),
        ),

        // Search field (rounded outline, matches reference).
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: SizedBox(
            height: 48,
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: l.searchWorkspacesHint,
                prefixIcon: Icon(Icons.search, color: iconFg, size: 22),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: Icon(Icons.clear, color: iconFg, size: 18),
                        onPressed: () => _searchController.clear(),
                      )
                    : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(28),
                  borderSide: BorderSide(
                    color: iconFg.withValues(alpha: 0.25),
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(28),
                  borderSide: BorderSide(
                    color: iconFg.withValues(alpha: 0.18),
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(28),
                  borderSide: BorderSide(
                    color: iconFg.withValues(alpha: 0.35),
                  ),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                isDense: true,
              ),
              style: const TextStyle(fontSize: 15),
            ),
          ),
        ),

        // Workspace list/grid
        Expanded(
          child: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : _filteredProjects.isEmpty
              ? _buildEmptyState(iconFg)
              : RefreshIndicator(
                  onRefresh: _loadProjects,
                  child: isMobile && !widget.embedded
                      ? _buildMobileList()
                      : _buildDesktopGrid(),
                ),
        ),
      ],
    );

    // In embedded mode, just return the body without Scaffold
    if (widget.embedded) return body;

    // Mobile: thin AppBar with back button only (the serif title lives
    // inside the body to match the reference layout).
    // Desktop: plain Scaffold (sidebar handles navigation).
    if (isMobile) {
      return Scaffold(
        appBar: AppBar(
          backgroundColor: theme.scaffoldBackgroundColor,
          elevation: 0,
          scrolledUnderElevation: 0,
          leading: IconButton(
            icon: Icon(Icons.arrow_back, color: iconFg),
            onPressed: () => Navigator.pop(context),
          ),
        ),
        body: body,
      );
    }
    return Scaffold(body: body);
  }

  Widget _buildEmptyState(Color iconFg) {
    Color displayColorOrFallback(int index, double alpha) {
      final colors = Workspace.kWorkspaceColors;
      if (colors.isEmpty) {
        return iconFg.withValues(alpha: alpha);
      }
      return colors[index % colors.length].withValues(alpha: alpha);
    }

    return Center(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Stacked folder icons with color
              SizedBox(
                height: 80,
                width: 100,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Positioned(
                      left: 0,
                      bottom: 8,
                      child: Icon(
                        Icons.folder_rounded,
                        size: 48,
                        color: displayColorOrFallback(0, 0.2),
                      ),
                    ),
                    Positioned(
                      right: 0,
                      bottom: 8,
                      child: Icon(
                        Icons.folder_rounded,
                        size: 48,
                        color: displayColorOrFallback(3, 0.2),
                      ),
                    ),
                    Icon(
                      Icons.folder_rounded,
                      size: 56,
                      color: displayColorOrFallback(9, 0.3),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Text(
                _searchQuery.isEmpty ? 'No workspaces yet' : 'No workspaces found',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: iconFg.withValues(alpha: 0.7),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _searchQuery.isEmpty
                    ? 'Organize your chats, files, and system prompts\ninto focused workspace workspaces.'
                    : 'Try a different search term.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: iconFg.withValues(alpha: 0.5),
                  height: 1.5,
                ),
              ),
              if (_searchQuery.isEmpty) ...[
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _createProject,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Create your first workspace'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 12,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDesktopGrid() => _buildFlatList(horizontalPadding: 12);

  Widget _buildMobileList() => _buildFlatList(horizontalPadding: 12);

  Widget _buildFlatList({required double horizontalPadding}) {
    return ListView.builder(
      padding: EdgeInsets.fromLTRB(horizontalPadding, 0, horizontalPadding, 24),
      itemCount: _filteredProjects.length,
      itemBuilder: (context, index) {
        return _ProjectRow(
          workspace: _filteredProjects[index],
          onTap: () => _openProjectDetail(_filteredProjects[index]),
          onDelete: () => _deleteProject(_filteredProjects[index]),
          onArchive: () => _archiveProject(_filteredProjects[index]),
        );
      },
    );
  }

  void _openProjectDetail(Workspace workspace) {
    if (widget.onOpenWorkspace != null) {
      widget.onOpenWorkspace!(workspace.id);
    } else {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => WorkspaceDetailPage(workspaceId: workspace.id),
        ),
      );
    }
  }

}

// ---------- Sort Button ----------

class _SortButton extends StatelessWidget {
  final ProjectSortMode sortMode;
  final ValueChanged<ProjectSortMode> onChanged;

  const _SortButton({required this.sortMode, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final iconFg = Theme.of(context).resolvedIconColor;

    return SizedBox(
      height: 42,
      width: 42,
      child: PopupMenuButton<ProjectSortMode>(
        icon: Icon(Icons.sort, color: iconFg, size: 20),
        tooltip: 'Sort projects',
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        onSelected: onChanged,
        itemBuilder: (context) => [
          _sortItem(
            ProjectSortMode.recentlyUpdated,
            'Recently Updated',
            Icons.schedule,
          ),
          _sortItem(ProjectSortMode.name, 'Name', Icons.sort_by_alpha),
          _sortItem(ProjectSortMode.mostFiles, 'Most Files', Icons.folder),
          _sortItem(ProjectSortMode.mostChats, 'Most Chats', Icons.chat_bubble),
        ],
      ),
    );
  }

  PopupMenuItem<ProjectSortMode> _sortItem(
    ProjectSortMode mode,
    String label,
    IconData icon,
  ) {
    final isSelected = sortMode == mode;
    return PopupMenuItem(
      value: mode,
      child: Row(
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 12),
          Text(label),
          if (isSelected) ...[
            const Spacer(),
            const Icon(Icons.check, size: 18),
          ],
        ],
      ),
    );
  }
}

// ---------- Workspace Row ----------
//
// Flat list row that mirrors the reference design: workspace name as a
// large heading and a single muted "Edited <date>" subtitle. Long-press
// (or hover-then-tap on the trailing more icon) opens archive/delete.
class _ProjectRow extends StatelessWidget {
  final Workspace workspace;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback onArchive;

  const _ProjectRow({
    required this.workspace,
    required this.onTap,
    required this.onDelete,
    required this.onArchive,
  });

  Future<void> _showRowMenu(BuildContext context, Offset globalPos) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final l = AppLocalizations.of(context)!;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPos.dx,
        globalPos.dy,
        overlay.size.width - globalPos.dx,
        overlay.size.height - globalPos.dy,
      ),
      items: [
        PopupMenuItem(
          value: 'archive',
          child: Row(
            children: [
              const Icon(Icons.archive_outlined, size: 18),
              const SizedBox(width: 10),
              Text(l.archive),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'delete',
          child: Row(
            children: [
              const Icon(Icons.delete_outline, color: Colors.red, size: 18),
              const SizedBox(width: 10),
              Text(l.delete, style: const TextStyle(color: Colors.red)),
            ],
          ),
        ),
      ],
    );
    if (selected == 'archive') onArchive();
    if (selected == 'delete') onDelete();
  }

  String _editedLabel(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final dateText =
        MaterialLocalizations.of(context).formatShortDate(workspace.updatedAt);
    return l.editedAt(dateText);
  }

  @override
  Widget build(BuildContext context) {
    final iconFg = Theme.of(context).resolvedIconColor;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPressStart: (d) => _showRowMenu(context, d.globalPosition),
      onSecondaryTapDown: (d) => _showRowMenu(context, d.globalPosition),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                workspace.name,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  height: 1.2,
                  color: iconFg,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              Text(
                _editedLabel(context),
                style: TextStyle(
                  fontSize: 13,
                  color: iconFg.withValues(alpha: 0.55),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------- Create Workspace Dialog ----------

class _CreateProjectDialog extends StatefulWidget {
  const _CreateProjectDialog();

  @override
  State<_CreateProjectDialog> createState() => _CreateProjectDialogState();
}

class _CreateProjectDialogState extends State<_CreateProjectDialog> {
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _systemPromptController = TextEditingController();
  bool _showAdvanced = false;
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _systemPromptController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;

    Navigator.pop(context, {
      'name': _nameController.text.trim(),
      'description': _descriptionController.text.trim().isNotEmpty
          ? _descriptionController.text.trim()
          : null,
      'systemPrompt': _systemPromptController.text.trim().isNotEmpty
          ? _systemPromptController.text.trim()
          : null,
    });
  }

  @override
  Widget build(BuildContext context) {
    final iconFg = Theme.of(context).resolvedIconColor;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final screenWidth = MediaQuery.of(context).size.width;
    final isWide = screenWidth > 600;

    // Preview color/icon based on current name
    final previewName = _nameController.text.trim();
    final colors = Workspace.kWorkspaceColors;
    final icons = Workspace.kWorkspaceIcons;
    final previewColor = colors.isEmpty
        ? Theme.of(context).colorScheme.primary
        : colors[previewName.isEmpty
              ? 0
              : previewName.hashCode.abs() % colors.length];
    final previewIcon = icons.isEmpty
        ? Icons.folder
        : icons[previewName.isEmpty
              ? 0
              : (previewName.hashCode.abs() ~/ 7) % icons.length];

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: isWide ? 480 : screenWidth * 0.9),
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Header with preview
                Container(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
                  decoration: BoxDecoration(
                    color: previewColor.withValues(alpha: isDark ? 0.1 : 0.06),
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(20),
                    ),
                  ),
                  child: Column(
                    children: [
                      // Workspace icon preview
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: previewColor.withValues(
                            alpha: isDark ? 0.25 : 0.15,
                          ),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Icon(previewIcon, color: previewColor, size: 28),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'New Workspace',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                          color: iconFg,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Organize chats, files, and prompts',
                        style: TextStyle(
                          fontSize: 13,
                          color: iconFg.withValues(alpha: 0.5),
                        ),
                      ),
                    ],
                  ),
                ),

                // Form fields
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Name field
                      TextFormField(
                        controller: _nameController,
                        decoration: InputDecoration(
                          labelText: 'Workspace Name',
                          hintText: 'e.g., AI Research, Website Redesign',
                          prefixIcon: const Icon(Icons.folder_outlined),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        autofocus: true,
                        textInputAction: TextInputAction.next,
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return 'Workspace name is required';
                          }
                          return null;
                        },
                        onChanged: (_) => setState(() {}),
                      ),
                      const SizedBox(height: 16),

                      // Description field
                      TextFormField(
                        controller: _descriptionController,
                        decoration: InputDecoration(
                          labelText: 'Description (optional)',
                          hintText: 'What is this workspace about?',
                          prefixIcon: const Icon(Icons.notes_outlined),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        maxLines: 2,
                        textInputAction: TextInputAction.next,
                      ),

                      // Advanced options toggle
                      const SizedBox(height: 12),
                      InkWell(
                        onTap: () =>
                            setState(() => _showAdvanced = !_showAdvanced),
                        borderRadius: BorderRadius.circular(8),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Row(
                            children: [
                              Icon(
                                _showAdvanced
                                    ? Icons.expand_less
                                    : Icons.expand_more,
                                size: 20,
                                color: iconFg.withValues(alpha: 0.6),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'System Prompt',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: iconFg.withValues(alpha: 0.6),
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              if (!_showAdvanced &&
                                  _systemPromptController.text
                                      .trim()
                                      .isNotEmpty) ...[
                                const SizedBox(width: 8),
                                Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: previewColor,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),

                      // System prompt (expandable)
                      AnimatedCrossFade(
                        firstChild: const SizedBox.shrink(),
                        secondChild: Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: TextFormField(
                            controller: _systemPromptController,
                            decoration: InputDecoration(
                              labelText: 'Custom System Prompt',
                              hintText:
                                  'Special instructions for AI in this workspace...',
                              alignLabelWithHint: true,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            maxLines: 4,
                          ),
                        ),
                        crossFadeState: _showAdvanced
                            ? CrossFadeState.showSecond
                            : CrossFadeState.showFirst,
                        duration: const Duration(milliseconds: 200),
                      ),
                    ],
                  ),
                ),

                // Actions
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 12),
                      FilledButton(
                        onPressed: _submit,
                        style: FilledButton.styleFrom(
                          backgroundColor: previewColor,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 12,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: const Text('Create Workspace'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
