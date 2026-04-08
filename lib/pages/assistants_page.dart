// lib/pages/assistants_page.dart
import 'dart:async';

import 'package:chuk_chat/models/assistant_model.dart';
import 'package:chuk_chat/pages/assistant_editor_page.dart';
import 'package:chuk_chat/services/assistant_storage_service.dart';
import 'package:chuk_chat/services/image_storage_service.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Sort options for assistant list
enum AssistantSortMode { recentlyUpdated, name, mostChats }

class AssistantsPage extends StatefulWidget {
  final void Function(String assistantId)? onOpenAssistant;
  final bool embedded;

  const AssistantsPage({
    super.key,
    this.onOpenAssistant,
    this.embedded = false,
  });

  @override
  State<AssistantsPage> createState() => _AssistantsPageState();
}

class _AssistantsPageState extends State<AssistantsPage> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  List<Assistant> _filteredAssistants = [];
  StreamSubscription<void>? _assistantUpdatesSub;
  bool _isLoading = true;
  bool _isLoadingPublic = false;
  bool _showPublic = false;
  AssistantSortMode _sortMode = AssistantSortMode.recentlyUpdated;

  @override
  void initState() {
    super.initState();
    _loadAssistants();
    _searchController.addListener(_onSearchChanged);
    _assistantUpdatesSub = AssistantStorageService.changes.listen((_) {
      if (!mounted) return;
      _filterAssistants();
    });
  }

  @override
  void dispose() {
    _assistantUpdatesSub?.cancel();
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    setState(() {
      _searchQuery = _searchController.text;
      _filterAssistants();
    });
  }

  Future<void> _loadAssistants() async {
    setState(() => _isLoading = true);
    try {
      await AssistantStorageService.loadAssistants();
      _filterAssistants();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load assistants: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _filterAssistants() {
    if (!mounted) return;
    setState(() {
      var assistants = _showPublic
          ? List<Assistant>.from(AssistantStorageService.publicAssistants)
          : List<Assistant>.from(AssistantStorageService.activeAssistants);
      if (_searchQuery.isNotEmpty) {
        final query = _searchQuery.toLowerCase();
        assistants = assistants.where((a) {
          return a.name.toLowerCase().contains(query) ||
              (a.description?.toLowerCase().contains(query) ?? false) ||
              a.systemPrompt.toLowerCase().contains(query);
        }).toList();
      }
      // Apply sorting
      switch (_sortMode) {
        case AssistantSortMode.recentlyUpdated:
          assistants.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
        case AssistantSortMode.name:
          assistants.sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          );
        case AssistantSortMode.mostChats:
          assistants.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      }
      _filteredAssistants = assistants;
    });
  }

  Future<void> _loadPublicAssistants() async {
    if (_isLoadingPublic) return;
    setState(() => _isLoadingPublic = true);
    try {
      await AssistantStorageService.loadPublicAssistants();
      _filterAssistants();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load public assistants: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoadingPublic = false);
    }
  }

  void _switchTab(bool showPublic) {
    setState(() {
      _showPublic = showPublic;
      _searchController.clear();
      _searchQuery = '';
    });
    if (showPublic) {
      _loadPublicAssistants();
    } else {
      _filterAssistants();
    }
  }

  Future<void> _createAssistant() async {
    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(builder: (context) => const AssistantEditorPage()),
    );

    if (result != null && mounted) {
      try {
        var assistant = await AssistantStorageService.createAssistant(
          name: result['name'] as String,
          systemPrompt: result['systemPrompt'] as String,
          description: result['description'] as String?,
          memoryEnabled: result['memoryEnabled'] as bool? ?? true,
          modelId: result['modelId'] as String?,
          avatarColor: result['avatarColor'] as String?,
          avatarIcon: result['avatarIcon'] as String?,
        );

        // Upload avatar image if one was picked
        final imageBytes = result['pickedImageBytes'] as Uint8List?;
        if (imageBytes != null) {
          assistant = await AssistantStorageService.uploadAvatar(
            assistant.id,
            imageBytes,
          );
        }

        // Make public if requested
        final isPublic = result['isPublic'] as bool? ?? false;
        if (isPublic) {
          await AssistantStorageService.makePublic(assistant.id);
        }

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Created "${assistant.name}"')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to create assistant: $e')),
          );
        }
      }
    }
  }

  Future<void> _editAssistant(Assistant assistant) async {
    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (context) => AssistantEditorPage(assistant: assistant),
      ),
    );

    if (result != null && mounted) {
      try {
        await AssistantStorageService.updateAssistant(
          assistant.id,
          name: result['name'] as String?,
          systemPrompt: result['systemPrompt'] as String?,
          description: result['description'] as String?,
          memoryEnabled: result['memoryEnabled'] as bool?,
          modelId: result['modelId'] as String?,
          avatarColor: result['avatarColor'] as String?,
          avatarIcon: result['avatarIcon'] as String?,
        );

        // Handle avatar image changes
        final imageBytes = result['pickedImageBytes'] as Uint8List?;
        final removeImage = result['removeImage'] as bool? ?? false;
        if (imageBytes != null) {
          await AssistantStorageService.uploadAvatar(
            assistant.id,
            imageBytes,
          );
        } else if (removeImage) {
          await AssistantStorageService.deleteAvatar(assistant.id);
        }

        // Handle public/private toggle
        final isPublic = result['isPublic'] as bool? ?? false;
        if (isPublic != assistant.isPublic) {
          if (isPublic) {
            await AssistantStorageService.makePublic(assistant.id);
          } else {
            await AssistantStorageService.makePrivate(assistant.id);
          }
        }

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Updated "${assistant.name}"')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to update assistant: $e')),
          );
        }
      }
    }
  }

  Future<void> _deleteAssistant(Assistant assistant) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Assistant'),
        content: Text(
          'Are you sure you want to delete "${assistant.name}"?\n\n'
          'This will remove the assistant configuration. '
          'Chats with this assistant will become regular chats.',
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
        await AssistantStorageService.deleteAssistant(assistant.id);
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Assistant deleted')));
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to delete assistant: $e')),
          );
        }
      }
    }
  }

  Future<void> _archiveAssistant(Assistant assistant) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await AssistantStorageService.archiveAssistant(assistant.id, true);
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(
            content: Text('Archived "${assistant.name}"'),
            action: SnackBarAction(
              label: 'Undo',
              onPressed: () async {
                try {
                  await AssistantStorageService.archiveAssistant(
                    assistant.id,
                    false,
                  );
                } catch (e) {
                  messenger.showSnackBar(
                    SnackBar(content: Text('Failed to restore assistant: $e')),
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

  Future<void> _startChatWithAssistant(Assistant assistant) async {
    if (widget.onOpenAssistant != null) {
      widget.onOpenAssistant!(assistant.id);
    } else {
      if (kDebugMode) {
        debugPrint(
          '⚠️ [Assistants] onOpenAssistant callback not provided — '
          'cannot start chat with ${assistant.id}',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final iconFg = Theme.of(context).resolvedIconColor;
    final isMobile = MediaQuery.of(context).size.width < 800;

    final isLoading = _showPublic ? _isLoadingPublic : _isLoading;

    final body = Column(
      children: [
        // Tab selector: My Assistants / Public
        Padding(
          padding: EdgeInsets.fromLTRB(16, widget.embedded ? 12 : 16, 16, 8),
          child: SizedBox(
            width: double.infinity,
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                  value: false,
                  label: Text('My Assistants'),
                  icon: Icon(Icons.person_outline, size: 18),
                ),
                ButtonSegment(
                  value: true,
                  label: Text('Public'),
                  icon: Icon(Icons.public, size: 18),
                ),
              ],
              selected: {_showPublic},
              onSelectionChanged: (sel) => _switchTab(sel.first),
              style: ButtonStyle(
                visualDensity: VisualDensity.compact,
                textStyle: WidgetStatePropertyAll(
                  const TextStyle(fontSize: 13),
                ),
              ),
            ),
          ),
        ),

        // Header row: search + sort + create
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(
            children: [
              // Search field
              Expanded(
                child: SizedBox(
                  height: 42,
                  child: TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      hintText: _showPublic
                          ? 'Search public assistants...'
                          : 'Search assistants...',
                      prefixIcon: Icon(Icons.search, color: iconFg, size: 20),
                      suffixIcon: _searchQuery.isNotEmpty
                          ? IconButton(
                              icon: Icon(Icons.clear, color: iconFg, size: 18),
                              onPressed: () => _searchController.clear(),
                            )
                          : null,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(
                          color: iconFg.withValues(alpha: 0.2),
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(
                          color: iconFg.withValues(alpha: 0.15),
                        ),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                      ),
                      isDense: true,
                    ),
                    style: const TextStyle(fontSize: 14),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Sort button
              _SortButton(
                sortMode: _sortMode,
                onChanged: (mode) {
                  setState(() {
                    _sortMode = mode;
                    _filterAssistants();
                  });
                },
              ),
              // Create button (only on My Assistants tab)
              if (!_showPublic) ...[
                const SizedBox(width: 8),
                SizedBox(
                  height: 42,
                  child: FilledButton.icon(
                    onPressed: _createAssistant,
                    icon: const Icon(Icons.add, size: 18),
                    label: isMobile || widget.embedded
                        ? const SizedBox.shrink()
                        : const Text('New Assistant'),
                    style: FilledButton.styleFrom(
                      padding: isMobile || widget.embedded
                          ? const EdgeInsets.symmetric(horizontal: 12)
                          : const EdgeInsets.symmetric(horizontal: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),

        // Stats bar
        if (!isLoading && _filteredAssistants.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Text(
                  '${_filteredAssistants.length} assistant${_filteredAssistants.length == 1 ? '' : 's'}',
                  style: TextStyle(
                    fontSize: 12,
                    color: iconFg.withValues(alpha: 0.5),
                  ),
                ),
                const Spacer(),
                Text(
                  _sortModeLabel(_sortMode),
                  style: TextStyle(
                    fontSize: 12,
                    color: iconFg.withValues(alpha: 0.4),
                  ),
                ),
              ],
            ),
          ),

        const SizedBox(height: 8),

        // Assistant list/grid
        Expanded(
          child: isLoading
              ? const Center(child: CircularProgressIndicator())
              : _filteredAssistants.isEmpty
              ? _buildEmptyState(iconFg)
              : RefreshIndicator(
                  onRefresh: _showPublic
                      ? _loadPublicAssistants
                      : _loadAssistants,
                  child: (isMobile || widget.embedded)
                      ? _buildMobileList()
                      : _buildDesktopGrid(),
                ),
        ),
      ],
    );

    // In embedded mode (desktop panel), just return the body
    if (widget.embedded) return body;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Assistants'),
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: iconFg),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: body,
    );
  }

  Widget _buildEmptyState(Color iconFg) {
    return Center(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Stacked bot icons
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
                        Icons.smart_toy_outlined,
                        size: 48,
                        color: iconFg.withValues(alpha: 0.2),
                      ),
                    ),
                    Positioned(
                      right: 0,
                      bottom: 8,
                      child: Icon(
                        Icons.psychology_outlined,
                        size: 48,
                        color: iconFg.withValues(alpha: 0.2),
                      ),
                    ),
                    Icon(
                      Icons.auto_awesome_outlined,
                      size: 56,
                      color: iconFg.withValues(alpha: 0.3),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Text(
                _searchQuery.isNotEmpty
                    ? 'No assistants found'
                    : _showPublic
                        ? 'No public assistants yet'
                        : 'No assistants yet',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: iconFg.withValues(alpha: 0.7),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _searchQuery.isNotEmpty
                    ? 'Try a different search term.'
                    : _showPublic
                        ? 'Public assistants shared by other users\nwill appear here.'
                        : 'Create custom AI assistants with unique personalities,\nsystem prompts, and isolated memory settings.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: iconFg.withValues(alpha: 0.5),
                  height: 1.5,
                ),
              ),
              if (_searchQuery.isEmpty && !_showPublic) ...[
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _createAssistant,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Create your first assistant'),
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

  Widget _buildDesktopGrid() {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 400,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 1.3,
      ),
      itemCount: _filteredAssistants.length,
      itemBuilder: (context, index) {
        final a = _filteredAssistants[index];
        return _AssistantCard(
          assistant: a,
          isReadOnly: _showPublic,
          onTap: () => _startChatWithAssistant(a),
          onEdit: _showPublic ? null : () => _editAssistant(a),
          onDelete: _showPublic ? null : () => _deleteAssistant(a),
          onArchive: _showPublic ? null : () => _archiveAssistant(a),
        );
      },
    );
  }

  Widget _buildMobileList() {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      itemCount: _filteredAssistants.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final a = _filteredAssistants[index];
        return _AssistantCard(
          assistant: a,
          isReadOnly: _showPublic,
          onTap: () => _startChatWithAssistant(a),
          onEdit: _showPublic ? null : () => _editAssistant(a),
          onDelete: _showPublic ? null : () => _deleteAssistant(a),
          onArchive: _showPublic ? null : () => _archiveAssistant(a),
        );
      },
    );
  }

  String _sortModeLabel(AssistantSortMode mode) {
    switch (mode) {
      case AssistantSortMode.recentlyUpdated:
        return 'Recently updated';
      case AssistantSortMode.name:
        return 'By name';
      case AssistantSortMode.mostChats:
        return 'Most chats';
    }
  }
}

// ---------- Sort Button ----------

class _SortButton extends StatelessWidget {
  final AssistantSortMode sortMode;
  final ValueChanged<AssistantSortMode> onChanged;

  const _SortButton({required this.sortMode, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final iconFg = Theme.of(context).resolvedIconColor;

    return SizedBox(
      height: 42,
      width: 42,
      child: PopupMenuButton<AssistantSortMode>(
        icon: Icon(Icons.sort, color: iconFg, size: 20),
        tooltip: 'Sort assistants',
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        onSelected: onChanged,
        itemBuilder: (context) => [
          _sortItem(
            AssistantSortMode.recentlyUpdated,
            'Recently Updated',
            Icons.schedule,
          ),
          _sortItem(AssistantSortMode.name, 'Name', Icons.sort_by_alpha),
          _sortItem(
            AssistantSortMode.mostChats,
            'Most Chats',
            Icons.chat_bubble,
          ),
        ],
      ),
    );
  }

  PopupMenuItem<AssistantSortMode> _sortItem(
    AssistantSortMode mode,
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

// ---------- Assistant Card ----------

class _AssistantCard extends StatelessWidget {
  final Assistant assistant;
  final VoidCallback onTap;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final VoidCallback? onArchive;
  final bool isReadOnly;

  const _AssistantCard({
    required this.assistant,
    required this.onTap,
    this.onEdit,
    this.onDelete,
    this.onArchive,
    this.isReadOnly = false,
  });

  @override
  Widget build(BuildContext context) {
    final iconFg = Theme.of(context).resolvedIconColor;
    final assistantColor = assistant.displayColor;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: iconFg.withValues(alpha: 0.1)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Colored accent header
            Container(
              height: 6,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    assistantColor,
                    assistantColor.withValues(alpha: 0.6),
                  ],
                ),
              ),
            ),

            // Content
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Title row with avatar and menu
                    Row(
                      children: [
                        // Assistant avatar
                        _AssistantAvatar(
                          assistant: assistant,
                          size: 40,
                          iconSize: 22,
                          borderRadius: 10,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                assistant.name,
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  height: 1.2,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                isReadOnly && assistant.ownerDisplayName != null
                                    ? 'by ${assistant.ownerDisplayName}'
                                    : assistant.updatedAgo,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: iconFg.withValues(alpha: 0.45),
                                ),
                              ),
                            ],
                          ),
                        ),
                        // Menu (hidden for public/read-only cards)
                        if (!isReadOnly)
                          PopupMenuButton<String>(
                            icon: Icon(
                              Icons.more_horiz,
                              color: iconFg.withValues(alpha: 0.5),
                              size: 20,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 28,
                              minHeight: 28,
                            ),
                            onSelected: (value) {
                              if (value == 'edit') onEdit?.call();
                              if (value == 'delete') onDelete?.call();
                              if (value == 'archive') onArchive?.call();
                            },
                            itemBuilder: (context) => [
                              const PopupMenuItem(
                                value: 'edit',
                                child: Row(
                                  children: [
                                    Icon(Icons.edit_outlined, size: 18),
                                    SizedBox(width: 10),
                                    Text('Edit'),
                                  ],
                                ),
                              ),
                              const PopupMenuItem(
                                value: 'archive',
                                child: Row(
                                  children: [
                                    Icon(Icons.archive_outlined, size: 18),
                                    SizedBox(width: 10),
                                    Text('Archive'),
                                  ],
                                ),
                              ),
                              PopupMenuItem(
                                value: 'delete',
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
                              ),
                            ],
                          ),
                      ],
                    ),

                    const SizedBox(height: 8),

                    // Description
                    if (assistant.hasDescription)
                      Expanded(
                        child: Text(
                          assistant.description!,
                          style: TextStyle(
                            fontSize: 13,
                            color: iconFg.withValues(alpha: 0.6),
                            height: 1.4,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      )
                    else
                      Expanded(
                        child: Text(
                          assistant.systemPrompt,
                          style: TextStyle(
                            fontSize: 12,
                            color: iconFg.withValues(alpha: 0.5),
                            height: 1.4,
                            fontStyle: FontStyle.italic,
                          ),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),

                    // Bottom stats row
                    Row(
                      children: [
                        _StatChip(
                          icon: assistant.memoryEnabled
                              ? Icons.memory_outlined
                              : Icons.memory_outlined,
                          label: assistant.memoryEnabled
                              ? 'Memory on'
                              : 'Memory off',
                          color: assistant.memoryEnabled
                              ? Colors.green
                              : Colors.orange,
                        ),
                        if (assistant.isPublic) ...[
                          const SizedBox(width: 12),
                          _StatChip(
                            icon: Icons.public,
                            label: 'Public',
                            color: Colors.blue,
                          ),
                        ],
                        if (assistant.modelId != null) ...[
                          const SizedBox(width: 12),
                          _StatChip(
                            icon: Icons.model_training_outlined,
                            label: assistant.modelId!,
                            color: iconFg,
                          ),
                        ],
                        const Spacer(),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Reusable avatar widget that shows uploaded image or fallback icon.
/// Uses StatefulWidget to cache the download future across rebuilds.
class _AssistantAvatar extends StatefulWidget {
  final Assistant assistant;
  final double size;
  final double iconSize;
  final double borderRadius;

  const _AssistantAvatar({
    required this.assistant,
    required this.size,
    required this.iconSize,
    required this.borderRadius,
  });

  @override
  State<_AssistantAvatar> createState() => _AssistantAvatarState();
}

class _AssistantAvatarState extends State<_AssistantAvatar> {
  Future<Uint8List>? _imageFuture;

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  @override
  void didUpdateWidget(_AssistantAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.assistant.avatarImagePath !=
        widget.assistant.avatarImagePath) {
      _loadImage();
    }
  }

  void _loadImage() {
    if (widget.assistant.hasCustomImage) {
      _imageFuture = ImageStorageService.downloadAndDecryptImage(
        widget.assistant.avatarImagePath!,
      );
    } else {
      _imageFuture = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.assistant.displayColor;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (_imageFuture != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(widget.borderRadius),
        child: FutureBuilder<Uint8List>(
          future: _imageFuture,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return _buildFallbackIcon(color, isDark);
            }
            if (snapshot.hasData) {
              return Image.memory(
                snapshot.data!,
                width: widget.size,
                height: widget.size,
                fit: BoxFit.cover,
              );
            }
            return Container(
              width: widget.size,
              height: widget.size,
              decoration: BoxDecoration(
                color: color.withValues(alpha: isDark ? 0.2 : 0.12),
                borderRadius: BorderRadius.circular(widget.borderRadius),
              ),
              child: Center(
                child: SizedBox(
                  width: widget.iconSize * 0.7,
                  height: widget.iconSize * 0.7,
                  child: const CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          },
        ),
      );
    }

    return _buildFallbackIcon(color, isDark);
  }

  Widget _buildFallbackIcon(Color color, bool isDark) {
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.2 : 0.12),
        borderRadius: BorderRadius.circular(widget.borderRadius),
      ),
      child: Icon(
        widget.assistant.displayIcon,
        color: color,
        size: widget.iconSize,
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _StatChip({
    required this.icon,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color.withValues(alpha: 0.7)),
        const SizedBox(width: 3),
        Text(
          label,
          style: TextStyle(fontSize: 12, color: color.withValues(alpha: 0.7)),
        ),
      ],
    );
  }
}
