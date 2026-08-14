// lib/pages/workspace_mobile_detail_page.dart
//
// Mobile-first project ("workspace") detail view. Replaces the tabbed
// Files/Chats/Settings layout with a card-grid overview:
//
//   [ Project title ]   [ Privacy chip ]
//   [ Projektwissen card ] [ Benutzerdefinierte Anweisungen card ]
//   Neueste Chats
//   ▸ chat 1
//   ▸ chat 2
//   …
//   ( Neuer Chat FAB )
//
// Desktop continues to use the existing [WorkspaceDetailPage] tabbed view.

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/workspace_model.dart';
import 'package:chuk_chat/pages/workspace_files_page.dart';
import 'package:chuk_chat/pages/workspace_instructions_page.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/workspace_storage_service.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/constants.dart';

class WorkspaceMobileDetailPage extends StatefulWidget {
  final String workspaceId;
  final Function(String? workspaceId)? onStartNewChat;

  const WorkspaceMobileDetailPage({
    super.key,
    required this.workspaceId,
    this.onStartNewChat,
  });

  @override
  State<WorkspaceMobileDetailPage> createState() =>
      _WorkspaceMobileDetailPageState();
}

class _WorkspaceMobileDetailPageState extends State<WorkspaceMobileDetailPage> {
  Workspace? _workspace;
  List<StoredChat> _chats = const [];
  StreamSubscription<void>? _sub;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
    _sub = WorkspaceStorageService.changes.listen((_) {
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final ws = WorkspaceStorageService.getWorkspace(widget.workspaceId);
      if (ws == null) {
        if (mounted) {
          setState(() => _loading = false);
          Navigator.of(context).pop();
        }
        return;
      }
      final chats = await WorkspaceStorageService.getProjectChats(
        widget.workspaceId,
      );
      if (!mounted) return;
      setState(() {
        _workspace = ws;
        _chats = chats;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      final l = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.projectLoadFailed(e.toString()))));
    }
  }

  void _openFiles() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WorkspaceFilesPage(workspaceId: widget.workspaceId),
      ),
    );
  }

  void _openInstructions() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            WorkspaceInstructionsPage(workspaceId: widget.workspaceId),
      ),
    );
  }

  Future<void> _confirmDelete() async {
    final l = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.projectDeleteProject),
        content: Text(l.projectDeleteProjectBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text(l.delete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await WorkspaceStorageService.deleteProject(widget.workspaceId);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l.projectDeleteFailed(e.toString()))));
      }
    }
  }

  Future<void> _editNameDescription() async {
    final ws = _workspace;
    if (ws == null) return;
    final l = AppLocalizations.of(context)!;
    final nameCtrl = TextEditingController(text: ws.name);
    final descCtrl = TextEditingController(text: ws.description ?? '');

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
            ),
            title: Text(l.projectEditProjectTitle),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  autofocus: true,
                  onChanged: (_) => setDialogState(() {}),
                  decoration: InputDecoration(
                    labelText: l.projectName,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: descCtrl,
                  maxLines: 3,
                  decoration: InputDecoration(
                    labelText: l.projectDescriptionLabel,
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(l.cancel),
              ),
              FilledButton(
                onPressed: nameCtrl.text.trim().isEmpty
                    ? null
                    : () => Navigator.pop(ctx, true),
                child: Text(l.save),
              ),
            ],
          ),
        );
      },
    );

    if (saved == true && mounted) {
      try {
        await WorkspaceStorageService.updateProject(
          widget.workspaceId,
          name: nameCtrl.text.trim(),
          description: descCtrl.text.trim(),
        );
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(l.projectSaveFailed(e.toString()))));
        }
      }
    }
    nameCtrl.dispose();
    descCtrl.dispose();
  }

  // ─── Build ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final m3 = theme.m3;
    final l = AppLocalizations.of(context)!;

    if (_loading) {
      return Scaffold(
        backgroundColor: cs.surface,
        appBar: AppBar(backgroundColor: cs.surface, elevation: 0),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final ws = _workspace;
    if (ws == null) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(child: Text(l.projectWorkspaceNotFound)),
      );
    }

    final promptPreview = (ws.customSystemPrompt ?? '').trim();

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        backgroundColor: cs.surface,
        elevation: 0,
        scrolledUnderElevation: 0,
        actions: [
          // Fix D: previously the only way to edit the workspace on mobile
          // was hidden under the 3-dot menu, and instructions had no entry
          // at all — users reported they couldn't edit workspaces on
          // mobile. Surface "Edit Project" (name + description) as a
          // visible AppBar icon alongside the existing menu, and add an
          // explicit "Edit instructions" item to the menu so all three
          // fields the desktop Settings tab edits (name, description,
          // instructions) are reachable from the AppBar.
          IconButton(
            tooltip: l.projectEditProject,
            icon: const Icon(Icons.edit_outlined),
            onPressed: _editNameDescription,
          ),
          IconButton(
            icon: const Icon(Icons.more_vert),
            onPressed: () async {
              final theme = Theme.of(context);
              final choice = await showModalBottomSheet<String>(
                context: context,
                backgroundColor: theme.colorScheme.surface,
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                ),
                builder: (ctx) => SafeArea(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(height: 8),
                      ListTile(
                        leading: const Icon(Icons.edit_outlined),
                        title: Text(l.projectEditProject),
                        onTap: () => Navigator.pop(ctx, 'edit'),
                      ),
                      ListTile(
                        leading: const Icon(Icons.notes_outlined),
                        title: Text(l.projectInstructions),
                        onTap: () => Navigator.pop(ctx, 'instructions'),
                      ),
                      ListTile(
                        leading: const Icon(
                          Icons.delete_outline,
                          color: Colors.red,
                        ),
                        title: Text(
                          l.projectDeleteProject,
                          style: const TextStyle(color: Colors.red),
                        ),
                        onTap: () => Navigator.pop(ctx, 'delete'),
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              );
              if (!mounted) return;
              if (choice == 'edit') _editNameDescription();
              if (choice == 'instructions') _openInstructions();
              if (choice == 'delete') _confirmDelete();
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
        children: [
          // ── Title ───────────────────────────────────────────────
          Text(
            ws.name,
            style: theme.textTheme.displaySmall?.copyWith(
              fontWeight: FontWeight.w700,
              height: 1.1,
              letterSpacing: -0.5,
            ),
          ),
          if ((ws.description ?? '').isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              ws.description!,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: m3.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 16),

          // ── Privacy chip ───────────────────────────────────────
          _PrivacyChip(
            isPublic: ws.isPublic,
            theme: theme,
          ),
          const SizedBox(height: 20),

          // ── Card grid: Projektwissen + Benutzerdefinierte Anweisungen
          Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _InfoCard(
                  title: l.projectKnowledge,
                  footer: Text(
                    l.projectFileCount(ws.fileCount),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: m3.onSurfaceVariant,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  onTap: _openFiles,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _InfoCard(
                  title: l.projectInstructions,
                  bodyText: promptPreview.isEmpty
                      ? l.projectInstructionsEmpty
                      : promptPreview,
                  bodyIsPlaceholder: promptPreview.isEmpty,
                  onTap: _openInstructions,
                ),
              ),
            ],
          ),
          const SizedBox(height: 28),

          // ── Recent chats ───────────────────────────────────────
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 8),
            child: Text(
              l.projectLatestChats,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: m3.onSurfaceVariant,
              ),
            ),
          ),
          if (_chats.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
              child: Text(
                l.projectNoChatsHint,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: m3.onSurfaceVariant,
                ),
              ),
            )
          else
            ..._chats.map(
              (c) => _ChatRow(chat: c, theme: theme),
            ),
        ],
      ),

      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          widget.onStartNewChat?.call(widget.workspaceId);
          Navigator.of(context).pop();
        },
        backgroundColor: cs.primary,
        foregroundColor: cs.onPrimary,
        icon: const Icon(Icons.add_comment_outlined),
        label: Text(l.projectNewChat),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(999),
        ),
      ),
    );
  }
}

// ─── Privacy chip ──────────────────────────────────────────────────────────

class _PrivacyChip extends StatelessWidget {
  final bool isPublic;
  final ThemeData theme;

  const _PrivacyChip({required this.isPublic, required this.theme});

  @override
  Widget build(BuildContext context) {
    final m3 = theme.m3;
    final l = AppLocalizations.of(context)!;
    final icon = isPublic ? Icons.public : Icons.lock_outline;
    final label = isPublic ? l.projectPublic : l.projectPrivate;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: m3.surfaceContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: IntrinsicWidth(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: m3.onSurfaceVariant),
            const SizedBox(width: 6),
            Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: m3.onSurfaceVariant,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Info card (Projektwissen / Benutzerdefinierte Anweisungen) ───────────

class _InfoCard extends StatelessWidget {
  final String title;
  final String? bodyText;
  final bool bodyIsPlaceholder;
  final Widget? footer;
  final VoidCallback onTap;

  const _InfoCard({
    required this.title,
    this.bodyText,
    this.bodyIsPlaceholder = false,
    this.footer,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m3 = theme.m3;
    return Material(
      color: m3.surfaceContainer,
      borderRadius: BorderRadius.circular(24),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: kBorderRadiusRow,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 140),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 12),
                if (bodyText != null)
                  Expanded(
                    child: Text(
                      bodyText!,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: bodyIsPlaceholder
                            ? m3.onSurfaceVariant.withValues(alpha: 0.7)
                            : m3.onSurfaceVariant,
                        height: 1.35,
                      ),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  )
                else
                  const Spacer(),
                ?footer,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _formatDate(DateTime date, BuildContext context) {
  return MaterialLocalizations.of(context).formatMediumDate(date);
}

// ─── Recent chat row ──────────────────────────────────────────────────────

class _ChatRow extends StatelessWidget {
  final StoredChat chat;
  final ThemeData theme;

  const _ChatRow({required this.chat, required this.theme});

  @override
  Widget build(BuildContext context) {
    final m3 = theme.m3;
    final title = chat.customName ?? chat.previewText;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            _formatDate(chat.createdAt.toLocal(), context),
            style: theme.textTheme.bodySmall?.copyWith(
              color: m3.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
