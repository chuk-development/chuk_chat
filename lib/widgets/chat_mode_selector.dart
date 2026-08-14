// lib/widgets/chat_mode_selector.dart
//
// The composer's primary control: Fast or Thinking, as the same dropdown
// the model selector has always used. One level deeper sits a second
// dropdown of the same kind listing the models the reader has actually
// picked — not the full catalogue, which is what the model screen is for.

import 'package:flutter/material.dart';

import 'package:chuk_chat/services/chat_mode_service.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/anchored_menu.dart';

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
    this.showLabel = true,
    this.reasoning = true,
    this.onReasoningChanged,
    this.height = 40,
    this.menuAbove = false,
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

  /// Whether the model may reason in the current mode. Independent of the
  /// mode itself: a fast answer can still think briefly, and the deep mode
  /// can be told to skip it.
  final bool reasoning;

  /// Called when the reader flips the reasoning switch.
  final ValueChanged<bool>? onReasoningChanged;

  /// Whether the pill spells the mode out. The mobile composer sets this
  /// false: the icon carries it, and the words are in the menu where there
  /// is room for them.
  final bool showLabel;

  final double height;

  /// Open the menus above the pill whenever they fit there. The desktop
  /// composer sets it: its window is tall, so a menu is free to drop down
  /// over the composer it was opened from, which reads as the wrong thing
  /// moving.
  final bool menuAbove;

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

  /// Whether a model was picked by hand. Fast and Thinking each run their
  /// own pinned model, so picking one from the list is a third state, not
  /// a mode: the pill then names the model, and no mode is ticked.
  bool get usesPickedModel {
    final String? id = selectedModelId;
    return id != null && id.isNotEmpty && id != ChatModeService.defaultModelId;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Color iconFg = theme.resolvedIconColor;

    final String pillLabel = usesPickedModel
        ? stripLabPrefix(modelLabel ?? selectedModelId!)
        : labelFor(mode);
    final IconData pillIcon = usesPickedModel ? Icons.tune : iconFor(mode);

    return Semantics(
      button: true,
      label: 'Mode: $pillLabel',
      child: InkWell(
        onTap: () => _openModeMenu(context),
        borderRadius: BorderRadius.circular(height / 2),
        child: Container(
          height: height,
          padding: EdgeInsets.symmetric(horizontal: showLabel ? 12 : 14),
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
              Icon(pillIcon, size: 19, color: iconFg),
              if (showLabel) ...[
                const SizedBox(width: 5),
                Text(
                  pillLabel,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: iconFg,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
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
            isSelected: !usesPickedModel && option == mode,
          ),
        if (onReasoningChanged != null) _reasoningRow<_MenuChoice>(iconFg: iconFg),
        if (onModelSelected != null || onOpenModelScreen != null)
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
    );

    if (choice == null || !context.mounted) return;

    if (choice.openModelMenu) {
      await _openModelMenu(context);
      return;
    }

    // Also reported when the mode is unchanged: coming back from a
    // hand-picked model to Fast or Thinking is a change of what runs, even
    // when the mode name stays the same.
    final picked = choice.mode;
    if (picked != null && (picked != mode || usesPickedModel)) {
      onModeChanged(picked);
    }
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
        if (onOpenModelScreen != null)
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

  /// The thinking switch. It is a setting, not a choice, so tapping it
  /// flips the switch in place instead of closing the menu — closing on
  /// every flip was what made the row feel broken. `enabled: false` only
  /// takes the row's own tap away; the switch and its ink are the child's.
  PopupMenuItem<T> _reasoningRow<T>({required Color iconFg}) {
    // Lives as long as the open menu does: the row keeps showing what the
    // reader just did, whoever owns the setting underneath.
    bool on = reasoning;
    bool flash = false;
    return PopupMenuItem<T>(
      enabled: false,
      height: 40,
      padding: EdgeInsets.zero,
      child: StatefulBuilder(
        builder: (context, setLocalState) {
          return InkWell(
            onTap: () {
              setLocalState(() {
                on = !on;
                flash = true;
              });
              onReasoningChanged?.call(on);
              // Picking a model flashes the row on its way out. This row
              // stays, so it flashes on its own — the same short answer to
              // the same tap.
              Future<void>.delayed(const Duration(milliseconds: 220), () {
                if (context.mounted) setLocalState(() => flash = false);
              });
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOut,
              color: flash ? iconFg.withValues(alpha: 0.16) : null,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Icon(
                    on ? Icons.psychology_alt : Icons.psychology_alt_outlined,
                    size: 18,
                    color: iconFg,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      // Not "Thinking": that is the name of a mode one row
                      // above, and two rows with one name is a riddle.
                      'Reasoning',
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: on ? iconFg : iconFg.withValues(alpha: 0.8),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // A tick, like every other row that is on. The switch was
                  // taller than a row and behaved like nothing else here.
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 160),
                    transitionBuilder: (child, animation) => ScaleTransition(
                      scale: animation,
                      child: FadeTransition(opacity: animation, child: child),
                    ),
                    child: on
                        ? Icon(Icons.check, color: iconFg, size: 18)
                        : const SizedBox(width: 18, height: 18),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

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
  /// Nothing here touches the focus: the menu route is opened with
  /// `requestFocus: false`, so the text field keeps whatever it had and the
  /// keyboard stays open or stays closed, exactly as the reader left it.
  Future<T?> _showAnchoredMenu<T>(
    BuildContext context, {
    required List<PopupMenuEntry<T>> items,
  }) {
    final theme = Theme.of(context);
    return showAnchoredMenu<T>(
      context,
      items: items,
      color: theme.scaffoldBackgroundColor.withValues(alpha: 0.94),
      borderColor: theme.resolvedIconColor.withValues(alpha: 0.3),
      minWidth: 220,
      preferAbove: menuAbove,
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

/// A readable name for a model id the catalogue does not know, so the menu
/// never shows a raw slug: `deepseek/deepseek-v4-pro` → `DeepSeek V4 Pro`.
String prettyModelId(String id) {
  final tail = id.contains('/') ? id.split('/').last : id;
  final words = tail
      .replaceAll(RegExp(r'[-_:]+'), ' ')
      .split(' ')
      .where((word) => word.isNotEmpty)
      .map((word) {
        // Version-ish parts stay as they are: v4, 4b, 20b, 3.5.
        if (RegExp(r'^[0-9]').hasMatch(word) ||
            RegExp(r'^v[0-9]', caseSensitive: false).hasMatch(word)) {
          return word.toLowerCase();
        }
        // Short words that are acronyms in model names, not words.
        const acronyms = {'gpt', 'oss', 'ai', 'llm', 'moe', 'vl', 'r'};
        if (acronyms.contains(word.toLowerCase())) return word.toUpperCase();
        return word[0].toUpperCase() + word.substring(1);
      });
  final name = words.join(' ');
  return name.isEmpty ? id : name;
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
/// The thinking switch is not here — it flips in place and never closes
/// the menu, so it returns nothing.
class _MenuChoice {
  const _MenuChoice.mode(ChatMode this.mode) : openModelMenu = false;
  const _MenuChoice.openModelMenu() : mode = null, openModelMenu = true;

  final ChatMode? mode;
  final bool openModelMenu;
}
