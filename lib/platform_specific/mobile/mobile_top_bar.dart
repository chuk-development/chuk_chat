/// The phone's top chrome in the Agents build: the same two rows in the
/// Chats and the Sidekicks half, so a switch between the halves moves
/// nothing on screen.
///
/// ```
/// [ menu ]   [ Home | Chats | Sidekicks ]   [ + ]    row, 48 px
/// ( face  Title ••• )                      [ ... ]   pill row, 56 px
/// ```
///
/// Owner, 2026-11-13: the switch stays on top in every place, also over a
/// conversation; it is not in the sidebar. The menu chip opens the sidebar:
/// the list of chats or Sidekicks, each with its last line and its unread
/// mark. A dot on the chip says that something in that list is unread. The
/// pill names the chat in view and is where the thumb swipes to the next
/// one (it drives [SwipeChatPager]). The "..." chip holds what to do with
/// this chat. Home has no pill row. The bar lies over the chat: the page
/// colour holds it down behind the chips and fades out under them.
library;

import 'package:flutter/material.dart';

import 'package:chuk_chat/platform_specific/mobile/chat_title_strip.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';
import 'package:chuk_chat/widgets/floating_app_bar.dart';
import 'package:chuk_chat/widgets/icons/icon_map.dart';

/// Space above the row inside the safe area.
const double kMobileTopBarRowTop = 8;

/// Height of the row (the press reach of the 42 px chips).
const double kMobileTopBarRow = 48;

/// Gap between the row and the pill row.
const double kMobileTopBarGap = 6;

/// Space under the bar before the chat may start.
const double kMobileTopBarBottom = 8;

/// The height of the whole bar under the safe area: what a chat below it
/// passes as its `topInset` (plus `MediaQuery.viewPaddingOf(context).top`).
const double kMobileTopBarHeight =
    kMobileTopBarRowTop +
    kMobileTopBarRow +
    kMobileTopBarGap +
    kChatTitleStripHeight +
    kMobileTopBarBottom;

/// The height of the bar without a pill row (Home).
const double kMobileTopBarRowOnlyHeight =
    kMobileTopBarRowTop + kMobileTopBarRow + kMobileTopBarBottom;

/// The bar: the menu chip, the [centre] (the mode switch) and the add
/// button; under them the [strip] and the "..." chip.
class MobileTopBar extends StatelessWidget {
  const MobileTopBar({
    super.key,
    required this.onMenu,
    required this.centre,
    required this.onAdd,
    this.strip,
    this.onMore,
    this.menuBadge = false,
    this.menuTooltip = 'Menu',
    this.moreTooltip = 'More',
    this.addTooltip = 'New chat',
    this.addIcon = Icons.edit_square,
  });

  /// Opens the sidebar.
  final VoidCallback onMenu;

  /// Draws a dot on the menu chip: something in the sidebar is unread.
  final bool menuBadge;

  /// The switch Home | Chats | Sidekicks. Null leaves the middle empty.
  final Widget? centre;

  /// The primary action of the half: a new chat, or a new Sidekick. Null
  /// hides the button but keeps its room, so the switch stays centred.
  final VoidCallback? onAdd;

  /// What to do with the chat in view: the chip at the end of the pill row.
  /// Null hides it.
  final VoidCallback? onMore;

  /// The [ChatTitleStrip] of the half. Null (Home) leaves the row alone.
  final Widget? strip;

  final String menuTooltip;
  final String moreTooltip;
  final String addTooltip;
  final IconData addIcon;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color page = Theme.of(context).scaffoldBackgroundColor;
    final Widget? strip = this.strip;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[page, page, page.withValues(alpha: 0)],
          stops: const <double>[0, 0.82, 1],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            10,
            kMobileTopBarRowTop,
            10,
            kMobileTopBarBottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SizedBox(
                height: kMobileTopBarRow,
                child: Row(
                  children: <Widget>[
                    Stack(
                      clipBehavior: Clip.none,
                      children: <Widget>[
                        FloatingHeaderButton(
                          icon: Icons.menu,
                          onPressed: onMenu,
                          tooltip: menuTooltip,
                          semanticsId: 'mobile_menu_button',
                        ),
                        if (menuBadge)
                          Positioned(
                            top: 5,
                            right: 5,
                            child: IgnorePointer(
                              child: Container(
                                key: const ValueKey<String>(
                                  'mobile_menu_badge',
                                ),
                                width: 11,
                                height: 11,
                                decoration: BoxDecoration(
                                  color: scheme.primary,
                                  shape: BoxShape.circle,
                                  border: Border.all(color: page, width: 2),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    Expanded(child: Center(child: centre ?? const SizedBox())),
                    // FloatingHeaderButton, not AccentIconButton: the header
                    // chip paints 42 px but takes a 48 px press.
                    SizedBox(
                      width: 48,
                      height: 48,
                      child: onAdd == null
                          ? null
                          : FloatingHeaderButton(
                              icon: addIcon,
                              accent: true,
                              onPressed: onAdd,
                              tooltip: addTooltip,
                              semanticsId: 'mobile_add_button',
                            ),
                    ),
                  ],
                ),
              ),
              if (strip != null) ...<Widget>[
                const SizedBox(height: kMobileTopBarGap),
                SizedBox(
                  height: kChatTitleStripHeight,
                  child: Row(
                    children: <Widget>[
                      // 3 px: the pill's edge under the painted edge of the
                      // menu chip (a 42 px chip in a 48 px press).
                      const SizedBox(width: 3),
                      Expanded(child: strip),
                      if (onMore != null) ...<Widget>[
                        const SizedBox(width: 4),
                        FloatingHeaderButton(
                          icon: Icons.more_horiz_rounded,
                          onPressed: onMore,
                          tooltip: moreTooltip,
                          semanticsId: 'mobile_more_button',
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// One entry of the menu sheet.
@immutable
class MobileMenuItem {
  const MobileMenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool destructive;
}

/// Gap between the tiles of the shortcut row.
const double _kShortcutGap = 4;

/// Height of a shortcut tile.
const double _kShortcutHeight = 84;

/// The sheet behind the menu chip, in the Material 3 Expressive shape.
///
/// ```
///        ──                    drag handle
/// [ Settings ][ Media ][ ... ]   shortcuts: where to go in the app
///  Title of the chat in view     section header
/// ┌ Rename                  ┐    items: what to do with this chat,
/// │ Copy full chat          │    one group of filled tiles
/// └ Delete                  ┘
/// ```
///
/// [shortcuts] are the app's other pages, as a connected row of large tonal
/// tiles: one tap, big targets, the way the official button group joins its
/// members (outer corners large, inner corners small). [items] act on the
/// chat or agent in view; [sectionTitle] names it. The sheet closes itself
/// first and then runs the action, so a page it opens never sits under it.
Future<void> showMobileMenuSheet(
  BuildContext context, {
  required List<MobileMenuItem> shortcuts,
  List<MobileMenuItem> items = const <MobileMenuItem>[],
  String? sectionTitle,
}) {
  final ColorScheme scheme = Theme.of(context).colorScheme;
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    // Grows with its rows, up to the safe area; scrolls past that.
    isScrollControlled: true,
    backgroundColor: scheme.surfaceContainerLow,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (BuildContext sheetContext) {
      void run(MobileMenuItem item) {
        Navigator.of(sheetContext).pop();
        item.onTap();
      }

      return SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const _SheetHandle(),
              if (shortcuts.isNotEmpty)
                _ShortcutRow(items: shortcuts, onTap: run),
              if (items.isNotEmpty) ...<Widget>[
                if (sectionTitle != null && sectionTitle.isNotEmpty)
                  _SectionTitle(sectionTitle)
                else
                  const SizedBox(height: 12),
                ExpressiveGroup(
                  children: <Widget>[
                    for (final MobileMenuItem item in items)
                      _MenuRow(item: item, onTap: () => run(item)),
                  ],
                ),
              ],
            ],
          ),
        ),
      );
    },
  );
}

/// The official drag handle: 32 x 4, `onSurfaceVariant` at 40 %, 22 px
/// of room above and below it.
class _SheetHandle extends StatelessWidget {
  const _SheetHandle();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: Container(
          width: 32,
          height: 4,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.onSurfaceVariant
                .withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }
}

/// The name of the chat or agent the rows below act on.
class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 20, 6, 8),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w700,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// One action row: a small tonal icon, the label.
class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.item, required this.onTap});

  final MobileMenuItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Color fg = item.destructive ? scheme.error : scheme.onSurface;
    return ExpressiveTile(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: <Widget>[
          ExpressiveIconTile(
            icon: item.icon,
            size: 36,
            tone: item.destructive ? scheme.errorContainer : null,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              item.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: fg,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The app's pages as one connected row of tonal tiles.
class _ShortcutRow extends StatelessWidget {
  const _ShortcutRow({required this.items, required this.onTap});

  final List<MobileMenuItem> items;
  final ValueChanged<MobileMenuItem> onTap;

  @override
  Widget build(BuildContext context) {
    // Four fit a 360 dp phone with readable labels; more wrap to a second
    // row of the same tiles.
    const int perRow = 4;
    final List<List<MobileMenuItem>> rows = <List<MobileMenuItem>>[
      for (int i = 0; i < items.length; i += perRow)
        items.sublist(i, (i + perRow).clamp(0, items.length)),
    ];
    return Column(
      children: <Widget>[
        for (int r = 0; r < rows.length; r++) ...<Widget>[
          if (r > 0) const SizedBox(height: _kShortcutGap),
          Row(
            children: <Widget>[
              for (int i = 0; i < rows[r].length; i++) ...<Widget>[
                if (i > 0) const SizedBox(width: _kShortcutGap),
                Expanded(
                  child: _ShortcutTile(
                    item: rows[r][i],
                    onTap: () => onTap(rows[r][i]),
                    radius: _cornersFor(
                      row: r,
                      rows: rows.length,
                      index: i,
                      count: rows[r].length,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ],
    );
  }

  /// Large corners on the outside of the whole block, small ones where two
  /// tiles meet.
  static BorderRadius _cornersFor({
    required int row,
    required int rows,
    required int index,
    required int count,
  }) {
    const Radius outer = Radius.circular(24);
    const Radius inner = Radius.circular(8);
    final bool top = row == 0;
    final bool bottom = row == rows - 1;
    final bool left = index == 0;
    final bool right = index == count - 1;
    return BorderRadius.only(
      topLeft: top && left ? outer : inner,
      topRight: top && right ? outer : inner,
      bottomLeft: bottom && left ? outer : inner,
      bottomRight: bottom && right ? outer : inner,
    );
  }
}

/// One shortcut: icon over label in `secondaryContainer`. A press rounds
/// every corner (the M3E shape morph) on the fast spatial spring's timing.
class _ShortcutTile extends StatefulWidget {
  const _ShortcutTile({
    required this.item,
    required this.onTap,
    required this.radius,
  });

  final MobileMenuItem item;
  final VoidCallback onTap;
  final BorderRadius radius;

  @override
  State<_ShortcutTile> createState() => _ShortcutTileState();
}

class _ShortcutTileState extends State<_ShortcutTile> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Color fill = scheme.secondaryContainer;
    final Color fg = scheme.onSecondaryContainer;
    return Semantics(
      button: true,
      label: widget.item.label,
      excludeSemantics: true,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
        height: _kShortcutHeight,
        decoration: BoxDecoration(
          color: fill,
          borderRadius: _pressed
              ? BorderRadius.circular(_kShortcutHeight / 2)
              : widget.radius,
        ),
        clipBehavior: Clip.antiAlias,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: widget.onTap,
            onTapDown: (_) => _setPressed(true),
            onTapUp: (_) => _setPressed(false),
            onTapCancel: () => _setPressed(false),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  AppIcon(widget.item.icon, size: 24, color: fg),
                  const SizedBox(height: 8),
                  Text(
                    widget.item.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: fg,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
