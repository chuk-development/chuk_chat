// lib/widgets/floating_app_bar.dart
//
// The top of every settings-style page.
//
// A Material AppBar is a solid band across the top: a fill, a title inside it
// and a back arrow at its left edge. The rest of the app stopped drawing
// bands a while ago — the sidebar's two bars and the chat's top bar are
// floating cards over a page that runs on underneath them. This is the same
// idea for a page that has an app bar: nothing behind the header but the
// page, and the two things that belong to it — back, and where you are — are
// each a floating chip.

import 'package:flutter/material.dart';

import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/floating_chrome_surface.dart';
import 'package:chuk_chat/widgets/icons/icon_map.dart';

/// Height of the header band: the chat top bar's 48 row plus its 8/6 of air
/// above and below, so a settings page and the chat sit their headers at the
/// same place on the screen.
const double kFloatingAppBarHeight = 62;

/// Diameter of the round chips: back, and each action. The chat's menu chip.
const double kFloatingAppBarChip = 42;

/// Corner radius of the title pill. The chat's title pill.
const double _kTitleRadius = 18;

/// A round floating chip for the header — the back arrow, and whatever a
/// page puts on the right.
class FloatingHeaderButton extends StatelessWidget {
  const FloatingHeaderButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.color,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Widget chip = FloatingChromeSurface(
      shape: BoxShape.circle,
      child: Material(
        type: MaterialType.transparency,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: SizedBox(
            width: kFloatingAppBarChip,
            height: kFloatingAppBarChip,
            child: Center(
              child: AppIcon(
                icon,
                size: 22,
                color: color ?? theme.resolvedIconColor,
              ),
            ),
          ),
        ),
      ),
    );
    return tooltip == null ? chip : Tooltip(message: tooltip!, child: chip);
  }
}

/// The header of a settings-style page: a floating back chip, a floating
/// title pill, and nothing behind either of them.
class FloatingAppBar extends StatelessWidget implements PreferredSizeWidget {
  const FloatingAppBar({
    super.key,
    required this.title,
    this.actions,
    this.leading,
    this.automaticallyImplyLeading = true,
    this.bottom,
  });

  /// Usually a [Text]. It is put inside the floating pill.
  final Widget title;

  /// The right-hand side. Wrap anything tappable in [FloatingHeaderButton] so
  /// it floats like the rest.
  final List<Widget>? actions;

  /// Replaces the back chip.
  final Widget? leading;
  final bool automaticallyImplyLeading;

  /// A tab bar or search field under the header, as on a normal AppBar.
  final PreferredSizeWidget? bottom;

  @override
  Size get preferredSize => Size.fromHeight(
    kFloatingAppBarHeight + (bottom?.preferredSize.height ?? 0),
  );

  /// The title, in the one size every page uses.
  ///
  /// A page that passes a plain [Text] gets rebuilt with the shared style,
  /// its own `style:` dropped. Pages had each picked their own size, and a
  /// title two points larger on one page makes the back chip beside it look
  /// like a different size too — the chip is unchanged, the eye compares it
  /// to the text. Anything that is not a [Text] only inherits the style, so
  /// a caller that really needs its own layout still can.
  Widget _styledTitle(BuildContext context, ThemeData theme) {
    final TextStyle style = TextStyle(
      color: theme.resolvedIconColor.withValues(alpha: 0.92),
      fontSize: 15,
      fontWeight: FontWeight.w800,
    );
    final Widget self = title;
    if (self is Text && self.data != null) {
      return Text(
        self.data!,
        style: style,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        semanticsLabel: self.semanticsLabel,
      );
    }
    return DefaultTextStyle.merge(
      style: style,
      overflow: TextOverflow.ellipsis,
      maxLines: 1,
      child: self,
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool canPop = Navigator.of(context).canPop();
    final Widget? back =
        leading ??
        (automaticallyImplyLeading && canPop
            ? FloatingHeaderButton(
                icon: Icons.arrow_back_rounded,
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                onPressed: () => Navigator.of(context).maybePop(),
              )
            : null);

    return AppBar(
      // Nothing of the bar itself is drawn: no fill, no shadow, and no
      // tinted "scrolled under" state. What shows behind the chips is the
      // page.
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      toolbarHeight: kFloatingAppBarHeight,
      automaticallyImplyLeading: false,
      titleSpacing: back == null ? 10 : 8,
      leadingWidth: kFloatingAppBarChip + 10,
      leading: back == null
          ? null
          : Padding(
              padding: const EdgeInsets.only(left: 10),
              child: Center(child: back),
            ),
      title: Align(
        alignment: Alignment.centerLeft,
        child: FloatingChromeSurface(
          radius: _kTitleRadius,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          // The chat's title pill, to the pixel: same radius, padding, size
          // and weight. A settings page and the chat must not read as two
          // different apps.
          child: _styledTitle(context, theme),
        ),
      ),
      actions: actions == null
          ? null
          : <Widget>[
              for (final Widget action in actions!) ...[
                Center(child: action),
                const SizedBox(width: 8),
              ],
              const SizedBox(width: 4),
            ],
      bottom: bottom,
    );
  }
}
