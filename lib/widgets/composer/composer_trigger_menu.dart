// lib/widgets/composer/composer_trigger_menu.dart
//
// The `/` and `@` menu, drawn above the composer field while a trigger is
// open (lib/services/composer/composer_trigger.dart). Keyboard-first on the
// desktop, taps on the phone: a tap picks, a tap on a group opens it.
import 'package:flutter/material.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/composer/composer_trigger.dart';
import 'package:chuk_chat/widgets/icons/icon_map.dart';

/// The localised name of a menu group.
String triggerGroupLabel(AppLocalizations l, TriggerGroup g) => switch (g) {
  TriggerGroup.skills => l.composerMenuSkills,
  TriggerGroup.modes => l.composerMenuModes,
  TriggerGroup.commands => l.composerMenuCommands,
  TriggerGroup.files => l.composerMenuFiles,
  TriggerGroup.agents => l.composerMenuAgents,
  TriggerGroup.workspaces => l.composerMenuWorkspaces,
  TriggerGroup.chats => l.composerMenuChats,
};

class ComposerTriggerMenu extends StatefulWidget {
  const ComposerTriggerMenu({
    super.key,
    required this.controller,
    this.trailingInset = 0,
  });

  final ComposerTriggerController controller;

  /// Space kept free on the right (the desktop's floating send button).
  final double trailingInset;

  static const double rowHeight = 40;
  static const int maxVisibleRows = 6;

  @override
  State<ComposerTriggerMenu> createState() => _ComposerTriggerMenuState();
}

class _ComposerTriggerMenuState extends State<ComposerTriggerMenu> {
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_follow);
  }

  @override
  void didUpdateWidget(ComposerTriggerMenu old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_follow);
      widget.controller.addListener(_follow);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_follow);
    _scroll.dispose();
    super.dispose();
  }

  /// Keeps the highlighted row in view.
  void _follow() {
    if (!_scroll.hasClients) return;
    final double top = widget.controller.highlight * ComposerTriggerMenu.rowHeight;
    final double bottom = top + ComposerTriggerMenu.rowHeight;
    final double viewTop = _scroll.offset;
    final double viewBottom = viewTop + _scroll.position.viewportDimension;
    if (top < viewTop) {
      _scroll.jumpTo(top);
    } else if (bottom > viewBottom) {
      _scroll.jumpTo(bottom - _scroll.position.viewportDimension);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (BuildContext context, _) {
        final ComposerTriggerController c = widget.controller;
        if (!c.isOpen) return const SizedBox.shrink();
        final ThemeData theme = Theme.of(context);
        final ColorScheme scheme = theme.colorScheme;
        final AppLocalizations l =
            AppLocalizations.of(context) ??
            AppLocalizations(const Locale('en'));
        final List<TriggerItem> items = c.visible;
        final TriggerItem? group = c.group;
        final int rows = items.isEmpty
            ? 1
            : items.length.clamp(1, ComposerTriggerMenu.maxVisibleRows);
        return Padding(
          padding: EdgeInsets.only(bottom: 6, right: widget.trailingInset),
          child: Container(
            key: const ValueKey<String>('composer-trigger-menu'),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(kRadiusLg),
            ),
            clipBehavior: Clip.antiAlias,
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                  child: Text(
                    group == null
                        ? l.composerMenuHint
                        : triggerGroupLabel(l, group.group),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                SizedBox(
                  height: rows * ComposerTriggerMenu.rowHeight,
                  child: items.isEmpty
                      ? Center(
                          child: Text(
                            l.composerMenuNoMatch,
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                        )
                      : ListView.builder(
                          controller: _scroll,
                          padding: EdgeInsets.zero,
                          itemExtent: ComposerTriggerMenu.rowHeight,
                          itemCount: items.length,
                          itemBuilder: (BuildContext context, int i) =>
                              _TriggerRow(
                                item: items[i],
                                label: items[i].isGroup
                                    ? triggerGroupLabel(l, items[i].group)
                                    : items[i].label,
                                detail: items[i].isGroup
                                    ? '${items[i].children?.length ?? 0}'
                                    : items[i].detail,
                                highlighted: i == c.highlight,
                                onTap: () => c.pick(items[i]),
                                onHover: () => c.setHighlight(i),
                              ),
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _TriggerRow extends StatelessWidget {
  const _TriggerRow({
    required this.item,
    required this.label,
    required this.detail,
    required this.highlighted,
    required this.onTap,
    required this.onHover,
  });

  final TriggerItem item;
  final String label;
  final String? detail;
  final bool highlighted;
  final VoidCallback onTap;
  final VoidCallback onHover;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: highlighted,
      label: label,
      child: MouseRegion(
        onEnter: (_) => onHover(),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            key: ValueKey<String>('composer-trigger-row-${item.id}'),
            margin: const EdgeInsets.symmetric(horizontal: 4),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: highlighted
                  ? scheme.surfaceContainerHighest
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(kRadiusMd),
            ),
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 20,
                  child: Center(
                    child: AppIcon(
                      item.icon,
                      size: 16,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                ),
                if (detail case final String d when d.isNotEmpty) ...<Widget>[
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      d,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ] else
                  const Spacer(),
                if (item.isGroup)
                  AppIcon(
                    Icons.chevron_right,
                    size: 16,
                    color: scheme.onSurfaceVariant,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
