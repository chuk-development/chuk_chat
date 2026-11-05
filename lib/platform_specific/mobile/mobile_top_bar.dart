/// The phone's top chrome in the Agents build: one row and one strip, the
/// same in the Chats and the Agents half, so a switch between the halves
/// moves nothing on screen.
///
/// ```
/// [ menu ] [ Home | Chats | Agenten ] [ + ]   row, 48 px
/// [ prev ‹  face  Title  › next ]   ChatTitleStrip, 58 px (swipe here)
/// ```
///
/// There is no drawer and no bottom navigation (owner, 2026-11-05). The
/// menu chip opens a sheet with Settings, Media and the other pages; the
/// strip names the chat in view and is where the thumb swipes to the next
/// one (it drives [SwipeChatPager]). There is no list and no dropdown. The bar lies over the chat: the page colour
/// holds it down behind the chips and fades out under the strip, so the
/// transcript scrolls under it and shows through below the strip.
library;

import 'package:flutter/material.dart';

import 'package:chuk_chat/platform_specific/mobile/chat_title_strip.dart';
import 'package:chuk_chat/widgets/floating_app_bar.dart';
import 'package:chuk_chat/widgets/icons/icon_map.dart';

/// Space above the row inside the safe area.
const double kMobileTopBarRowTop = 8;

/// Height of the row (the press reach of the 42 px chips).
const double kMobileTopBarRow = 48;

/// Gap between the row and the strip.
const double kMobileTopBarGap = 6;

/// Space under the strip before the chat may start.
const double kMobileTopBarBottom = 8;

/// The height of the whole bar under the safe area: what a chat below it
/// passes as its `topInset` (plus `MediaQuery.viewPaddingOf(context).top`).
const double kMobileTopBarHeight =
    kMobileTopBarRowTop +
    kMobileTopBarRow +
    kMobileTopBarGap +
    kChatTitleStripHeight +
    kMobileTopBarBottom;

/// The height of the bar without a strip (Home).
const double kMobileTopBarRowOnlyHeight =
    kMobileTopBarRowTop + kMobileTopBarRow + kMobileTopBarBottom;

/// The bar: menu chip, the [centre] (the mode switch), the add button, and
/// under them the [strip].
class MobileTopBar extends StatelessWidget {
  const MobileTopBar({
    super.key,
    required this.onMenu,
    required this.centre,
    required this.onAdd,
    this.strip,
    this.menuTooltip = 'Menu',
    this.addTooltip = 'New chat',
    this.addIcon = Icons.edit_square,
  });

  final VoidCallback onMenu;

  /// The Chats | Agenten switch. Null leaves the middle empty.
  final Widget? centre;

  /// The primary action of the half: a new chat, or a new agent. Null hides
  /// the button but keeps its room, so the switch stays centred.
  final VoidCallback? onAdd;

  /// The [ChatTitleStrip] of the half. Null (Home) leaves the row alone.
  final Widget? strip;

  final String menuTooltip;
  final String addTooltip;
  final IconData addIcon;

  @override
  Widget build(BuildContext context) {
    final Color page = Theme.of(context).scaffoldBackgroundColor;
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
          padding: const EdgeInsets.only(
            top: kMobileTopBarRowTop,
            bottom: kMobileTopBarBottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: SizedBox(
                  height: kMobileTopBarRow,
                  child: Row(
                    children: <Widget>[
                      FloatingHeaderButton(
                        icon: Icons.menu,
                        onPressed: onMenu,
                        tooltip: menuTooltip,
                        semanticsId: 'mobile_menu_button',
                      ),
                      Expanded(
                        child: Center(child: centre ?? const SizedBox()),
                      ),
                      // FloatingHeaderButton, not AccentIconButton: the
                      // header chip paints 42 px but takes a 48 px press.
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
              ),
              if (strip case final Widget strip) ...<Widget>[
                const SizedBox(height: kMobileTopBarGap),
                strip,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// One row of the menu sheet.
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

/// The sheet behind the menu chip. Closes itself, then runs the row's
/// action, so a page it opens never sits under the sheet.
Future<void> showMobileMenuSheet(
  BuildContext context, {
  required List<MobileMenuItem> items,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    // Grows with its rows, up to the safe area; scrolls past that.
    isScrollControlled: true,
    builder: (BuildContext sheetContext) {
      final ColorScheme scheme = Theme.of(sheetContext).colorScheme;
      return SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (final MobileMenuItem item in items)
                ListTile(
                  minTileHeight: 56,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  leading: AppIcon(
                    item.icon,
                    color: item.destructive ? scheme.error : null,
                  ),
                  title: Text(
                    item.label,
                    style: item.destructive
                        ? TextStyle(color: scheme.error)
                        : null,
                  ),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    item.onTap();
                  },
                ),
            ],
          ),
        ),
      );
    },
  );
}
