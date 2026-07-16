import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/skill.dart';
import 'package:chuk_chat/services/skills/skill_registry.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';

/// Attaches skills to the next message, the way Claude and Kimi's composers do.
///
/// A picked skill is force-activated on the session with no model round-trip:
/// its body is in the very first system prompt of the turn rather than arriving
/// a pass later. That is the whole point — the model never has to decide to
/// load it, so it cannot decline to.
///
/// Picking is *loading*, and loading persists: the skill stays active for the
/// rest of the conversation, exactly like one the model loaded itself. Both
/// paths go through `ToolCallHandler._activateSkill`, so nothing downstream can
/// tell them apart.
class SkillPickerButton extends StatelessWidget {
  const SkillPickerButton({
    super.key,
    required this.selected,
    required this.onChanged,
    required this.iconColor,
    this.accent,
  });

  /// Names of the currently attached skills.
  final List<String> selected;
  final ValueChanged<List<String>> onChanged;
  final Color iconColor;
  final Color? accent;

  Future<void> _open(BuildContext context) async {
    final l = AppLocalizations.of(context)!;
    final skills = SkillRegistry.all;

    if (skills.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.skillPickerEmpty)));
      return;
    }

    final picked = await showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) =>
          _SkillPickerSheet(skills: skills, selected: selected),
    );
    if (picked != null) onChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    final isActive = selected.isNotEmpty;
    final activeColor = accent ?? Theme.of(context).colorScheme.primary;

    return Tooltip(
      message: AppLocalizations.of(context)!.skillPickerTitle,
      child: InkWell(
        onTap: () => _open(context),
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(
            Icons.auto_awesome_outlined,
            size: 20,
            color: isActive ? activeColor : iconColor,
          ),
        ),
      ),
    );
  }
}

/// The chips shown inside the composer for attached skills.
///
/// Rendered above the text field and right-padded clear of the floating
/// send button, mirroring the queued-message banner that already lives there.
class SkillChipsRow extends StatelessWidget {
  const SkillChipsRow({
    super.key,
    required this.selected,
    required this.onRemove,
    required this.iconColor,
    this.rightPadding = 0,
  });

  final List<String> selected;
  final ValueChanged<String> onRemove;
  final Color iconColor;
  final double rightPadding;

  @override
  Widget build(BuildContext context) {
    if (selected.isEmpty) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;

    return Padding(
      padding: EdgeInsets.only(bottom: 6, right: rightPadding),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final name in selected)
            _SkillChip(
              name: name,
              onRemove: () => onRemove(name),
              color: cs.primary,
              iconColor: iconColor,
            ),
        ],
      ),
    );
  }
}

class _SkillChip extends StatelessWidget {
  const _SkillChip({
    required this.name,
    required this.onRemove,
    required this.color,
    required this.iconColor,
  });

  final String name;
  final VoidCallback onRemove;
  final Color color;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.only(left: 8, right: 4, top: 3, bottom: 3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.5), width: 1.2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.auto_awesome_outlined, size: 12, color: color),
          const SizedBox(width: 5),
          Text(
            name,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
          const SizedBox(width: 2),
          // IconButton, not a bare GestureDetector: this needs to be focusable
          // and to announce itself to a screen reader.
          IconButton(
            onPressed: onRemove,
            tooltip: AppLocalizations.of(context)!.skillRemove,
            iconSize: 14,
            padding: const EdgeInsets.all(3),
            constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.close, color: iconColor.withValues(alpha: 0.7)),
          ),
        ],
      ),
    );
  }
}

class _SkillPickerSheet extends StatefulWidget {
  const _SkillPickerSheet({required this.skills, required this.selected});

  final List<Skill> skills;
  final List<String> selected;

  @override
  State<_SkillPickerSheet> createState() => _SkillPickerSheetState();
}

class _SkillPickerSheetState extends State<_SkillPickerSheet> {
  late final Set<String> _selected = {...widget.selected};

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final m3 = theme.m3;

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    l.skillPickerTitle,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, _selected.toList()),
                  child: Text(l.save),
                ),
              ],
            ),
          ),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: widget.skills.length,
              itemBuilder: (context, index) {
                final skill = widget.skills[index];
                return CheckboxListTile(
                  value: _selected.contains(skill.name),
                  onChanged: (checked) => setState(() {
                    if (checked == true) {
                      _selected.add(skill.name);
                    } else {
                      _selected.remove(skill.name);
                    }
                  }),
                  title: Text(skill.name),
                  subtitle: Text(
                    skill.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: m3.onSurfaceVariant),
                  ),
                  secondary: Icon(
                    skill.isBuiltin
                        ? Icons.lock_outline
                        : Icons.auto_awesome_outlined,
                    size: 18,
                    color: m3.onSurfaceVariant,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
