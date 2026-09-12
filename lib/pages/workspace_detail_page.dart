// lib/pages/workspace_detail_page.dart
import 'package:chuk_chat/models/workspace_model.dart';
import 'package:chuk_chat/pages/workspace_mobile_detail_page.dart';
import 'package:chuk_chat/platform_config.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/workspace_message_service.dart';
import 'package:chuk_chat/services/workspace_storage_service.dart';
import 'package:chuk_chat/services/user_preferences_service.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/workspace/workspace_actions_mixin.dart';
import 'package:chuk_chat/widgets/workspace/workspace_common_widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:chuk_chat/widgets/floating_app_bar.dart';

import 'package:chuk_chat/widgets/app_notification.dart';
import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/widgets/icons/icon_map.dart';

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
    with
        SingleTickerProviderStateMixin,
        WorkspaceActionsMixin<_WorkspaceDetailDesktop> {
  late TabController _tabController;
  Workspace? _project;
  List<StoredChat> _projectChats = [];
  bool _isLoading = true;

  // Settings editing state
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _systemPromptController = TextEditingController();
  bool _hasSettingsChanges = false;

  // Context budget
  String? _selectedModelId;

  @override
  String get workspaceId => widget.workspaceId;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadProject();
    _loadModelId();
    listenToWorkspaceChanges(_loadProject);
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
    cancelWorkspaceChangesSubscription();
    _nameController.dispose();
    _descriptionController.dispose();
    _systemPromptController.dispose();
    super.dispose();
  }

  Future<void> _loadProject() async {
    setState(() => _isLoading = true);
    await loadWorkspaceAndChats(
      onLoaded: (workspace, chats) {
        _project = workspace;
        _projectChats = chats;
        // Only update text controllers if not actively editing
        if (!_hasSettingsChanges) {
          _nameController.text = workspace.name;
          _descriptionController.text = workspace.description ?? '';
          _systemPromptController.text = workspace.customSystemPrompt ?? '';
        }
        _isLoading = false;
      },
      onFailed: () => _isLoading = false,
    );
  }

  Future<void> _saveSettings() async {
    if (_project == null) return;
    final name = _nameController.text.trim();
    if (name.isEmpty) {
        AppNotifications.show(context, 'Workspace name cannot be empty');
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
        setState(() => _hasSettingsChanges = false);AppNotifications.show(context, 'Settings saved');
      }
    } catch (e) {
      if (mounted) {
        AppNotifications.show(context, 'Failed to save: $e');
      }
    }
  }

  Future<void> _addChat() {
    return addChatToWorkspace(
      existingChatIds: _project?.chatIds ?? const <String>[],
      pickChat: (availableChats) => showDialog<StoredChat>(
        context: context,
        builder: (context) => _ChatSelectorDialog(chats: availableChats),
      ),
    );
  }

  /// Confirms an upload that would blow the model's file token budget.
  Future<bool> _confirmContextBudget(int estimatedNewTokens) async {
    final project = _project;
    if (project == null) return false;
    final remaining = WorkspaceMessageService.remainingFileTokenBudget(
      project,
      _selectedModelId,
    );
    if (remaining >= estimatedNewTokens) return true;
    if (!mounted) return false;

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
    return proceed == true;
  }

  @override
  Widget build(BuildContext context) {
    final iconFg = Theme.of(context).resolvedIconColor;

    if (_isLoading) {
      return Scaffold(
        // The page runs underneath the floating header.
        extendBodyBehindAppBar: true,
        appBar: FloatingAppBar(
          title: const Text('Loading...'),
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_project == null) {
      return Scaffold(
        // The page runs underneath the floating header.
        extendBodyBehindAppBar: true,
        appBar: FloatingAppBar(
          title: const Text('Workspace Not Found'),
        ),
        body: const Center(child: Text('Workspace not found')),
      );
    }

    final displayColor = _project!.displayColor;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      // The page runs underneath the floating header.
      extendBodyBehindAppBar: true,
      appBar: FloatingAppBar(
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
              child: AppIcon(_project!.displayIcon, color: displayColor, size: 16),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(_project!.name, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
        leading: IconButton(
          icon: AppIcon(Icons.arrow_back, color: iconFg),
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
                  const AppIcon(Icons.description_outlined, size: 18),
                  const SizedBox(width: 6),
                  const Text('Files'),
                  if (_project!.fileCount > 0)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: WorkspaceCountBadge(
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
                  const AppIcon(Icons.chat_bubble_outline, size: 18),
                  const SizedBox(width: 6),
                  const Text('Chats'),
                  if (_project!.chatCount > 0)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: WorkspaceCountBadge(
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
                  AppIcon(Icons.settings_outlined, size: 18),
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
              icon: const AppIcon(Icons.add_comment),
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
              onPressed: isUploadingFile
                  ? null
                  : () => uploadFileToWorkspace(
                      confirmOversizedUpload: _confirmContextBudget,
                    ),
              icon: const AppIcon(Icons.upload_file),
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
        if (isUploadingFile)
          WorkspaceUploadProgressCard(
            fileName: uploadFileName,
            status: uploadStatus,
            progress: uploadProgress,
            displayColor: displayColor,
          ),

        // File list
        Expanded(
          child: _project!.files.isEmpty
              ? const WorkspaceEmptyState(
                  icon: Icons.folder_open,
                  title: 'No files yet',
                  subtitle:
                      'Upload PDFs, documents, or code files\nto reference in your chats',
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                  ).add(floatingHeaderInset(context)),
                  itemCount: _project!.files.length,
                  itemBuilder: (context, index) {
                    final file = _project!.files[index];
                    final fileRatio = WorkspaceMessageService.fileContextRatio(
                      file,
                      _selectedModelId,
                    );
                    return WorkspaceFileTile(
                      file: file,
                      workspaceId: widget.workspaceId,
                      displayColor: displayColor,
                      isDark: isDark,
                      onView: (menuContext) =>
                          viewWorkspaceFile(menuContext, file),
                      onDelete: () => deleteWorkspaceFile(file),
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
                            AppIcon(
                              Icons.check_circle,
                              size: 13,
                              color: Colors.green[600],
                            ),
                          ],
                        ],
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
                AppIcon(
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
    return WorkspaceChatsTab(
      chats: _projectChats,
      displayColor: _project!.displayColor,
      onAddChat: _addChat,
      onRemoveChat: removeChatFromWorkspace,
      showChatDate: true,
      removeIconSize: 20,
    );
  }

  // ============ SETTINGS TAB ============

  Widget _buildSettingsTab() {
    final theme = Theme.of(context);
    final iconFg = theme.resolvedIconColor;
    final displayColor = _project!.displayColor;
    final isDark = theme.brightness == Brightness.dark;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16).add(floatingHeaderInset(context)),
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
                        child: AppIcon(
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
                      AppIcon(Icons.tune, color: displayColor, size: 20),
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
                icon: const AppIcon(Icons.save, size: 18),
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
                            if (!mounted) return;AppNotifications.show(context, 'Failed to delete workspace: $e');
                          }
                        }
                      },
                      icon: const AppIcon(Icons.delete_outline, size: 18),
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
              AppIcon(Icons.memory_outlined, size: 14, color: barColor),
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
                    prefixIcon: const AppIcon(Icons.search, size: 20),
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
