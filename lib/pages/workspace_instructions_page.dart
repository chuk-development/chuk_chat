// lib/pages/workspace_instructions_page.dart
//
// Mobile editor for a workspace's custom system prompt
// ("Benutzerdefinierte Anweisungen"). Styled to match the Material You
// aesthetic of settings_page / system_prompt_page.

import 'package:flutter/material.dart';
import 'package:chuk_chat/widgets/settings_list_view.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/workspace_model.dart';
import 'package:chuk_chat/services/workspace_storage_service.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';

class WorkspaceInstructionsPage extends StatefulWidget {
  final String workspaceId;

  const WorkspaceInstructionsPage({super.key, required this.workspaceId});

  @override
  State<WorkspaceInstructionsPage> createState() =>
      _WorkspaceInstructionsPageState();
}

class _WorkspaceInstructionsPageState extends State<WorkspaceInstructionsPage> {
  final TextEditingController _controller = TextEditingController();
  Workspace? _workspace;
  String _original = '';
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final ws = WorkspaceStorageService.getWorkspace(widget.workspaceId);
    _workspace = ws;
    _original = ws?.customSystemPrompt ?? '';
    _controller.text = _original;
    _controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onChanged() => setState(() {});

  bool get _hasChanges => _controller.text.trim() != _original.trim();

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await WorkspaceStorageService.updateProject(
        widget.workspaceId,
        customSystemPrompt: _controller.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _original = _controller.text.trim();
        _saving = false;
      });
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      final l = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.projectSaveFailed(e.toString()))),
      );
    }
  }

  Future<bool> _confirmDiscard() async {
    if (!_hasChanges) return true;
    final l = AppLocalizations.of(context)!;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.projectDiscardChangesTitle),
        content: Text(l.projectDiscardChangesBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l.projectKeepEditing),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l.projectDiscardAction),
          ),
        ],
      ),
    );
    return result == true;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final m3 = theme.m3;
    final l = AppLocalizations.of(context)!;

    if (_workspace == null) {
      return Scaffold(
        appBar: AppBar(title: Text(l.projectInstructions)),
        body: Center(child: Text(l.projectWorkspaceNotFound)),
      );
    }

    return PopScope(
      canPop: !_hasChanges,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final shouldPop = await _confirmDiscard();
        if (!shouldPop || !mounted) return;
        Navigator.of(this.context).pop();
      },
      child: Scaffold(
        backgroundColor: cs.surface,
        appBar: AppBar(
          title: Text(l.projectInstructions),
          backgroundColor: cs.surface,
          elevation: 0,
          scrolledUnderElevation: 0,
        ),
        body: SettingsListView(
          padding: const EdgeInsets.all(16),
          children: [
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 12,
              ),
              decoration: BoxDecoration(
                color: m3.surfaceContainerLow,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline, size: 18, color: m3.onSurfaceVariant),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      l.projectInstructionsSubtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: m3.onSurfaceVariant,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              minLines: 10,
              maxLines: 24,
              style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurface),
              decoration: InputDecoration(
                hintText: l.systemPromptExample,
                hintStyle: theme.textTheme.bodyMedium?.copyWith(
                  color: m3.onSurfaceVariant,
                ),
                filled: true,
                fillColor: m3.surfaceContainer,
                contentPadding: const EdgeInsets.all(16),
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                '${_controller.text.length} ${l.characters}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: m3.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton.icon(
                icon: _saving
                    ? SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(
                          valueColor: AlwaysStoppedAnimation<Color>(
                            cs.onPrimary,
                          ),
                          strokeWidth: 2,
                        ),
                      )
                    : const Icon(Icons.check, size: 20),
                label: Text(_saving ? l.saving : l.saveChanges),
                onPressed: _saving || !_hasChanges ? null : _save,
                style: FilledButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(999),
                  ),
                  textStyle: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
