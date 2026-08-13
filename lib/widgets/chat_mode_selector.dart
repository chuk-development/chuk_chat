// lib/widgets/chat_mode_selector.dart
//
// The composer's primary control: Fast or Thinking, as the same dropdown
// the model selector has always used. One level deeper sits a second
// dropdown of the same kind listing the models the reader has actually
// picked — not the full catalogue, which is what the model screen is for.

import 'package:flutter/material.dart';

import 'package:chuk_chat/services/chat_mode_service.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';

class ChatModeSelector extends StatelessWidget {
  const ChatModeSelector({
    super.key,
    required this.mode,
    required this.onModeChanged,
    this.onModelSelected,
    this.onOpenModelScreen,
    this.selectedModelId,
    this.modelLabel,
    this.pickedModels = const <ChatModelChoice>[],
    this.height = 36,
  });

  final ChatMode mode;
  final ValueChanged<ChatMode> onModeChanged;

  /// Called with the model id the reader picked in the second dropdown.
  /// Omit to hide the model row entirely.
  final ValueChanged<String>? onModelSelected;

  /// Opens the full model screen, where models are added and providers are
  /// pinned. Reachable from the bottom of the second dropdown.
  final VoidCallback? onOpenModelScreen;

  /// The models this reader has picked, in display order. The mode's own
  /// default is always among them and cannot be removed here — taking it
  /// away belongs on the model screen, not in a composer menu.
  final List<ChatModelChoice> pickedModels;

  /// Id of the model in use, ticked in the model dropdown.
  final String? selectedModelId;

  /// Human name of that model, shown next to "Choose model".
  final String? modelLabel;

  final double height;

  /// Longest model list shown in the second dropdown. Beyond this the list
  /// stops being a menu and becomes a screen — that is what the model page
  /// is for, reachable from the row underneath.
  static const int kMaxModelsInMenu = 40;

  static IconData iconFor(ChatMode mode) =>
      mode == ChatMode.fast ? Icons.bolt : Icons.psychology_outlined;

  static String labelFor(ChatMode mode) =>
      mode == ChatMode.fast ? 'Fast' : 'Thinking';

  static String descriptionFor(ChatMode mode) => mode == ChatMode.fast
      ? 'Answers right away'
      : 'Thinks first, then answers';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Color iconFg = theme.resolvedIconColor;

    return Semantics(
      button: true,
      label: 'Mode: ${labelFor(mode)}',
      child: InkWell(
        onTap: () => _openModeMenu(context),
        borderRadius: BorderRadius.circular(height / 2),
        child: Container(
          height: height,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(height / 2),
            border: Border.all(
              color: iconFg.withValues(alpha: 0.3),
              width: 1.8,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(iconFor(mode), size: 17, color: iconFg),
              const SizedBox(width: 5),
              Text(
                labelFor(mode),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: iconFg,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 2),
              Icon(
                Icons.keyboard_arrow_down,
                size: 16,
                color: iconFg.withValues(alpha: 0.7),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── Level 1: the mode ────────────────────────────────────────────────

  Future<void> _openModeMenu(BuildContext context) async {
    final iconFg = Theme.of(context).resolvedIconColor;

    final choice = await _showAnchoredMenu<_MenuChoice>(
      context,
      items: <PopupMenuEntry<_MenuChoice>>[
        for (final option in ChatMode.values)
          _menuRow<_MenuChoice>(
            value: _MenuChoice.mode(option),
            iconFg: iconFg,
            icon: iconFor(option),
            label: labelFor(option),
            isSelected: option == mode,
          ),
        if (onModelSelected != null || onOpenModelScreen != null) ...[
          const PopupMenuDivider(),
          _menuRow<_MenuChoice>(
            value: const _MenuChoice.openModelMenu(),
            iconFg: iconFg,
            icon: Icons.tune,
            label: modelLabel == null
                ? 'Choose model'
                : stripLabPrefix(modelLabel!),
            trailing: Icon(
              Icons.chevron_right,
              size: 18,
              color: iconFg.withValues(alpha: 0.8),
            ),
          ),
        ],
      ],
    );

    if (choice == null || !context.mounted) return;

    if (choice.openModelMenu) {
      await _openModelMenu(context);
      return;
    }

    final picked = choice.mode;
    if (picked != null && picked != mode) onModeChanged(picked);
  }

  // ─── Level 2: the model ───────────────────────────────────────────────

  Future<void> _openModelMenu(BuildContext context) async {
    final iconFg = Theme.of(context).resolvedIconColor;

    if (pickedModels.isEmpty) {
      onOpenModelScreen?.call();
      return;
    }

    final picked = await _showAnchoredMenu<_ModelChoice>(
      context,
      items: <PopupMenuEntry<_ModelChoice>>[
        for (final model in pickedModels.take(kMaxModelsInMenu))
          _menuRow<_ModelChoice>(
            value: _ModelChoice.model(model.id),
            iconFg: iconFg,
            label: stripLabPrefix(model.name),
            isSelected: model.id == selectedModelId,
          ),
        if (onOpenModelScreen != null) ...[
          const PopupMenuDivider(),
          _menuRow<_ModelChoice>(
            value: const _ModelChoice.openScreen(),
            iconFg: iconFg,
            icon: Icons.add,
            label: 'More models',
            trailing: Icon(
              Icons.chevron_right,
              size: 18,
              color: iconFg.withValues(alpha: 0.8),
            ),
          ),
        ],
      ],
    );

    if (picked == null) return;
    if (picked.openScreen) {
      onOpenModelScreen?.call();
      return;
    }
    final id = picked.modelId;
    if (id != null && id != selectedModelId) onModelSelected?.call(id);
  }

  // ─── Shared menu look ─────────────────────────────────────────────────

  /// One row, matching the model dropdown: 40 high, 16 of side padding,
  /// bold label, a tick on the right when it is the current choice.
  PopupMenuItem<T> _menuRow<T>({
    required T value,
    required Color iconFg,
    required String label,
    IconData? icon,
    bool isSelected = false,
    Widget? trailing,
  }) {
    return PopupMenuItem<T>(
      value: value,
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 18, color: iconFg),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Text(
              label,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: isSelected ? iconFg : iconFg.withValues(alpha: 0.8),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 12),
          if (isSelected) Icon(Icons.check, color: iconFg, size: 18),
          ?trailing,
        ],
      ),
    );
  }

  /// Open a menu anchored to this control, styled like the model dropdown.
  Future<T?> _showAnchoredMenu<T>(
    BuildContext context, {
    required List<PopupMenuEntry<T>> items,
  }) async {
    final theme = Theme.of(context);
    final box = context.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return null;

    final Offset topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
    final Offset bottomRight = box.localToGlobal(
      box.size.bottomRight(Offset.zero),
      ancestor: overlay,
    );

    return showMenu<T>(
      context: context,
      position: RelativeRect.fromLTRB(
        topLeft.dx,
        topLeft.dy,
        overlay.size.width - bottomRight.dx,
        overlay.size.height - topLeft.dy,
      ),
      color: theme.scaffoldBackgroundColor.withValues(alpha: 0.94),
      constraints: const BoxConstraints(minWidth: 220),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(
          color: theme.resolvedIconColor.withValues(alpha: 0.3),
          width: 2,
        ),
      ),
      items: items,
    );
  }

  /// `DeepSeek: DeepSeek V4 Flash` → `DeepSeek V4 Flash`, the way the model
  /// dropdown has always shown it.
  static String stripLabPrefix(String name) {
    final index = name.indexOf(': ');
    if (index <= 0 || index + 2 >= name.length) return name;
    return name.substring(index + 2);
  }
}

/// A model the reader has picked, as shown in the second dropdown.
class ChatModelChoice {
  const ChatModelChoice({required this.id, required this.name});

  final String id;
  final String name;
}

/// What a row in the second menu stands for: a model, or the way to the
/// model screen.
class _ModelChoice {
  const _ModelChoice.model(String this.modelId) : openScreen = false;
  const _ModelChoice.openScreen() : modelId = null, openScreen = true;

  final String? modelId;
  final bool openScreen;
}

/// What a row in the first menu stands for: a mode, or the model list.
class _MenuChoice {
  const _MenuChoice.mode(ChatMode this.mode) : openModelMenu = false;
  const _MenuChoice.openModelMenu() : mode = null, openModelMenu = true;

  final ChatMode? mode;
  final bool openModelMenu;
}
