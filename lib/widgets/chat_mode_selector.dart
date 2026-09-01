// lib/widgets/chat_mode_selector.dart
//
// The composer's primary control: Fast or Thinking, as the same dropdown
// the model selector has always used.
//
// Level 1 (the pill menu) shows only the two modes plus a way one level
// deeper. Level 2 (the model-and-reasoning menu) configures the mode that is
// active: the reasoning level (Off plus the levels the model+provider
// supports), a quick pick from the models the reader has picked, and the way
// out to the full model screen where the whole catalogue lives.

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
    this.reasoningEffort = ChatModeService.reasoningOff,
    this.reasoningLevels = const <String>[ChatModeService.reasoningOff],
    this.onReasoningEffortChanged,
    this.height = 40,
    this.menuAbove = false,
  });

  final ChatMode mode;
  final ValueChanged<ChatMode> onModeChanged;

  /// Called with the model id the reader picked in the second menu. Omit to
  /// hide the quick model rows.
  final ValueChanged<String>? onModelSelected;

  /// Opens the full model screen, where the whole catalogue is browsed and
  /// providers are pinned. The deepest entry of the second menu.
  final VoidCallback? onOpenModelScreen;

  /// The models this reader has picked, in display order.
  final List<ChatModelChoice> pickedModels;

  /// Id of the model in use for the active mode, ticked in the model rows.
  final String? selectedModelId;

  /// Human name of that model, shown on the second-menu opener.
  final String? modelLabel;

  /// The active mode's reasoning level, ticked in the reasoning rows.
  final String reasoningEffort;

  /// The reasoning levels the active mode's model+provider allow, `none`
  /// (off) first. A single-entry list (off only) hides the level choice.
  final List<String> reasoningLevels;

  /// Called with the reasoning level the reader picked for the active mode.
  /// Omit to hide the reasoning rows.
  final ValueChanged<String>? onReasoningEffortChanged;

  /// Whether the pill spells the mode out. The mobile composer sets this
  /// false: the icon carries it, and the words are in the menu.
  final bool showLabel;

  final double height;

  /// Open the menus above the pill whenever they fit there.
  final bool menuAbove;

  /// Longest model list shown in the second menu. Beyond this the list stops
  /// being a menu and becomes a screen — the model page, reachable from the
  /// row underneath.
  static const int kMaxModelsInMenu = 40;

  static IconData iconFor(ChatMode mode) =>
      mode == ChatMode.fast ? Icons.bolt : Icons.psychology_outlined;

  static String labelFor(ChatMode mode) =>
      mode == ChatMode.fast ? 'Fast' : 'Thinking';

  static String descriptionFor(ChatMode mode) => mode == ChatMode.fast
      ? 'Answers right away'
      : 'Thinks first, then answers';

  /// Whether the second menu has anything to show.
  bool get _hasDeeperMenu =>
      onModelSelected != null ||
      onOpenModelScreen != null ||
      onReasoningEffortChanged != null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Color iconFg = theme.resolvedIconColor;

    // The pill always names the mode: each mode carries its own model, so
    // there is no third state that renames it.
    final String pillLabel = labelFor(mode);
    final IconData pillIcon = iconFor(mode);

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
            isSelected: option == mode,
          ),
        if (_hasDeeperMenu)
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

    final picked = choice.mode;
    if (picked != null && picked != mode) onModeChanged(picked);
  }

  // ─── Level 2: reasoning + model, for the active mode ──────────────────

  Future<void> _openModelMenu(BuildContext context) async {
    final iconFg = Theme.of(context).resolvedIconColor;

    final bool showReasoning =
        onReasoningEffortChanged != null && reasoningLevels.length > 1;
    final models = pickedModels.take(kMaxModelsInMenu).toList();
    final bool showModels = onModelSelected != null && models.isNotEmpty;

    final items = <PopupMenuEntry<_DeeperChoice>>[
      // Reasoning is a cascading sub-dropdown that flies out to the right.
      // It must NOT pop the model menu, so it is an opener row, not a
      // _menuRow (whose tap would close this menu).
      if (showReasoning)
        _SubmenuOpener<_DeeperChoice>(
          rowHeight: 40,
          onOpen: _openReasoningMenu,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _rowChild(
              iconFg: iconFg,
              icon: Icons.psychology_alt_outlined,
              label: 'Reasoning',
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    ChatModeService.reasoningLabel(reasoningEffort),
                    style: TextStyle(
                      color: iconFg.withValues(alpha: 0.7),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: iconFg.withValues(alpha: 0.8),
                  ),
                ],
              ),
            ),
          ),
        ),
      if (showReasoning && (showModels || onOpenModelScreen != null))
        const PopupMenuDivider(),
      if (showModels)
        for (final model in models)
          _menuRow<_DeeperChoice>(
            value: _DeeperChoice.model(model.id),
            iconFg: iconFg,
            label: stripLabPrefix(model.name),
            isSelected: model.id == selectedModelId,
          ),
      if (onOpenModelScreen != null)
        _menuRow<_DeeperChoice>(
          value: const _DeeperChoice.openScreen(),
          iconFg: iconFg,
          icon: Icons.add,
          label: 'More models',
          trailing: Icon(
            Icons.chevron_right,
            size: 18,
            color: iconFg.withValues(alpha: 0.8),
          ),
        ),
    ];

    // Nothing to configure and only the way out: skip the near-empty menu
    // and go straight to the model screen.
    if (!showReasoning && !showModels && onOpenModelScreen != null) {
      onOpenModelScreen!.call();
      return;
    }
    if (items.isEmpty) return;

    final picked = await _showAnchoredMenu<_DeeperChoice>(
      context,
      items: items,
    );

    if (picked == null || !context.mounted) return;
    if (picked.openScreen) {
      onOpenModelScreen?.call();
      return;
    }
    final id = picked.modelId;
    if (id != null && id != selectedModelId) onModelSelected?.call(id);
  }

  // ─── Level 3: reasoning, a right-cascading sub-dropdown ───────────────

  /// [rowContext] is the Reasoning row inside the still-open model menu, so
  /// the submenu flies out beside that row and the model menu stays put.
  Future<void> _openReasoningMenu(BuildContext rowContext) async {
    final iconFg = Theme.of(rowContext).resolvedIconColor;
    final picked = await _showAnchoredMenu<String>(
      rowContext,
      // Cascade out to the right of the row, model menu stays open behind it.
      besideAnchor: true,
      items: <PopupMenuEntry<String>>[
        _headerRow<String>(iconFg: iconFg, label: 'Reasoning'),
        for (final level in reasoningLevels)
          _menuRow<String>(
            value: level,
            iconFg: iconFg,
            label: ChatModeService.reasoningLabel(level),
            isSelected: level == reasoningEffort,
          ),
      ],
    );
    if (picked == null) return;
    if (picked != reasoningEffort) onReasoningEffortChanged?.call(picked);
  }

  // ─── Shared menu look ─────────────────────────────────────────────────

  /// A non-interactive section header, dimmer and lighter than a choice.
  PopupMenuItem<T> _headerRow<T>({
    required Color iconFg,
    required String label,
  }) {
    return PopupMenuItem<T>(
      enabled: false,
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          color: iconFg.withValues(alpha: 0.6),
          fontWeight: FontWeight.w700,
          fontSize: 11,
          letterSpacing: 0.6,
        ),
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
      child: _rowChild(
        iconFg: iconFg,
        label: label,
        icon: icon,
        isSelected: isSelected,
        trailing: trailing,
      ),
    );
  }

  /// The inner row of a menu entry, shared by [_menuRow] and the submenu
  /// opener (which cannot be a [PopupMenuItem] because it must not pop).
  Widget _rowChild({
    required Color iconFg,
    required String label,
    IconData? icon,
    bool isSelected = false,
    Widget? trailing,
  }) {
    return Row(
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
    );
  }

  /// Open a menu anchored to this control, styled like the model dropdown.
  /// Nothing here touches the focus: the menu route is opened with
  /// `requestFocus: false`, so the text field keeps whatever it had and the
  /// keyboard stays open or stays closed, exactly as the reader left it.
  Future<T?> _showAnchoredMenu<T>(
    BuildContext context, {
    required List<PopupMenuEntry<T>> items,
    bool? alignRight,
    bool besideAnchor = false,
  }) {
    final theme = Theme.of(context);
    return showAnchoredMenu<T>(
      context,
      items: items,
      color: theme.scaffoldBackgroundColor.withValues(alpha: 0.94),
      borderColor: theme.resolvedIconColor.withValues(alpha: 0.3),
      minWidth: besideAnchor ? 160 : 220,
      preferAbove: menuAbove,
      alignRight: alignRight,
      besideAnchor: besideAnchor,
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

/// A model the reader has picked, as shown in the second menu.
class ChatModelChoice {
  const ChatModelChoice({required this.id, required this.name});

  final String id;
  final String name;
}

/// What a row in the first menu stands for: a mode, or the way one level
/// deeper to the model-and-reasoning menu.
class _MenuChoice {
  const _MenuChoice.mode(ChatMode this.mode) : openModelMenu = false;
  const _MenuChoice.openModelMenu() : mode = null, openModelMenu = true;

  final ChatMode? mode;
  final bool openModelMenu;
}

/// What a row in the second menu stands for: a reasoning level, a model, or
/// the way out to the full model screen.
class _DeeperChoice {
  const _DeeperChoice.model(String this.modelId) : openScreen = false;
  const _DeeperChoice.openScreen() : modelId = null, openScreen = true;

  final String? modelId;
  final bool openScreen;
}

/// A menu row that opens a cascading submenu on tap WITHOUT popping the menu
/// it sits in — a plain [PopupMenuItem] always pops, which would close the
/// model menu the submenu is meant to hang off.
class _SubmenuOpener<T> extends PopupMenuEntry<T> {
  const _SubmenuOpener({
    required this.rowHeight,
    required this.child,
    required this.onOpen,
  });

  final double rowHeight;
  final Widget child;
  final Future<void> Function(BuildContext rowContext) onOpen;

  @override
  double get height => rowHeight;

  @override
  bool represents(T? value) => false;

  @override
  State<_SubmenuOpener<T>> createState() => _SubmenuOpenerState<T>();
}

class _SubmenuOpenerState<T> extends State<_SubmenuOpener<T>> {
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => widget.onOpen(context),
      child: SizedBox(height: widget.rowHeight, child: widget.child),
    );
  }
}
