// lib/widgets/per_model_system_prompt_sheet.dart
import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/per_model_system_prompt_service.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';

/// Bottom sheet for editing a per-model system prompt and merge mode.
///
/// Returns `true` when the user saved or deleted the config so the caller can
/// refresh its state, `false`/`null` on cancel.
Future<bool?> showPerModelSystemPromptSheet({
  required BuildContext context,
  required String modelId,
  required String modelName,
  ModelPromptConfig? initial,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(ctx).viewInsets.bottom,
      ),
      child: _PerModelSystemPromptEditor(
        modelId: modelId,
        modelName: modelName,
        initial: initial,
      ),
    ),
  );
}

class _PerModelSystemPromptEditor extends StatefulWidget {
  const _PerModelSystemPromptEditor({
    required this.modelId,
    required this.modelName,
    required this.initial,
  });

  final String modelId;
  final String modelName;
  final ModelPromptConfig? initial;

  @override
  State<_PerModelSystemPromptEditor> createState() =>
      _PerModelSystemPromptEditorState();
}

class _PerModelSystemPromptEditorState
    extends State<_PerModelSystemPromptEditor> {
  late final TextEditingController _ctrl;
  late ModelPromptMode _mode;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initial?.prompt ?? '');
    _mode = widget.initial?.mode ?? ModelPromptMode.append;
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    // Capture localized failure message and the messenger BEFORE the await
    // so we don't reach for `context` after an async gap.
    final failureMessage =
        AppLocalizations.of(context)!.perModelPromptSaveFailed;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final text = _ctrl.text;
    final config = ModelPromptConfig(prompt: text, mode: _mode);
    final ok =
        await PerModelSystemPromptService.save(widget.modelId, config);
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) {
      navigator.pop(true);
    } else {
      messenger.showSnackBar(SnackBar(content: Text(failureMessage)));
    }
  }

  Future<void> _delete() async {
    if (_saving) return;
    setState(() => _saving = true);
    final l = AppLocalizations.of(context)!;
    final failureMessage = l.perModelPromptDeleteFailed;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final ok = await PerModelSystemPromptService.delete(widget.modelId);
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) {
      navigator.pop(true);
    } else {
      messenger.showSnackBar(SnackBar(content: Text(failureMessage)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final m3 = theme.m3;
    final hasInitial = widget.initial != null;

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l.perModelPromptTitle,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              widget.modelName,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: m3.onSurfaceVariant,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 12),
            Text(
              l.perModelPromptHint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: m3.onSurfaceVariant,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 16),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.4,
              ),
              child: TextField(
                controller: _ctrl,
                maxLines: null,
                minLines: 5,
                expands: false,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  hintText: l.perModelPromptPlaceholder,
                  filled: true,
                  fillColor: m3.surfaceContainer,
                  contentPadding: const EdgeInsets.all(14),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              l.perModelPromptModeLabel,
              style: theme.textTheme.labelLarge,
            ),
            const SizedBox(height: 8),
            _ModeChips(
              mode: _mode,
              onChanged: (m) => setState(() => _mode = m),
            ),
            const SizedBox(height: 8),
            Text(
              _modeDescription(l, _mode),
              style: theme.textTheme.bodySmall?.copyWith(
                color: m3.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                if (hasInitial)
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _saving ? null : _delete,
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: Text(l.perModelPromptRemove),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    ),
                  ),
                if (hasInitial) const SizedBox(width: 12),
                Expanded(
                  child: TextButton(
                    onPressed: _saving
                        ? null
                        : () => Navigator.of(context).pop(false),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                    child: Text(l.cancel),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: _saving ? null : _save,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                    child: Text(_saving ? l.saving : l.save),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _modeDescription(AppLocalizations l, ModelPromptMode mode) {
    switch (mode) {
      case ModelPromptMode.off:
        return l.perModelPromptModeOffHint;
      case ModelPromptMode.replace:
        return l.perModelPromptModeReplaceHint;
      case ModelPromptMode.append:
        return l.perModelPromptModeAppendHint;
      case ModelPromptMode.prepend:
        return l.perModelPromptModePrependHint;
    }
  }
}

class _ModeChips extends StatelessWidget {
  const _ModeChips({required this.mode, required this.onChanged});

  final ModelPromptMode mode;
  final ValueChanged<ModelPromptMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final entries = <(ModelPromptMode, String)>[
      (ModelPromptMode.off, l.perModelPromptModeOff),
      (ModelPromptMode.append, l.perModelPromptModeAppend),
      (ModelPromptMode.prepend, l.perModelPromptModePrepend),
      (ModelPromptMode.replace, l.perModelPromptModeReplace),
    ];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: entries.map((e) {
        final selected = mode == e.$1;
        return ChoiceChip(
          label: Text(e.$2),
          selected: selected,
          onSelected: (_) => onChanged(e.$1),
        );
      }).toList(),
    );
  }
}
