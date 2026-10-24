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
import 'package:chuk_chat/widgets/icons/huge_icon.dart';
import 'package:chuk_chat/widgets/icons/icon_map.dart';

/// Height of the header band: the chat top bar's 48 row plus its 8/6 of air
/// above and below, so a settings page and the chat sit their headers at the
/// same place on the screen.
const double kFloatingAppBarHeight = 62;

/// Diameter of the round chips: back, and each action. The chat's menu chip.
const double kFloatingAppBarChip = 42;

/// The press area of a chip: 48 px, the smallest reliable touch target. The
/// extra 3 px on each side are slop, not paint.
const double kFloatingAppBarTarget = 48;

/// The slop on each side of a chip.
const double _kChipSlop = (kFloatingAppBarTarget - kFloatingAppBarChip) / 2;

/// Corner radius of the title pill. The chat's title pill.
const double _kTitleRadius = 18;

/// The room a scroll view has to leave above its first item so the floating
/// header does not cover it.
///
/// It belongs *inside* the scroll view: padding put outside would stop the
/// content at the header instead of letting it pass behind.
///
/// The number has to be right from two different places in the tree, and it
/// is read differently in each.
///
/// A Scaffold that extends its body behind the app bar works the figure out
/// itself and puts it in the body's `padding.top`. But only for widgets
/// built *below* the body: a page that hands its own build context to a list
/// three methods away is above it, and sees the bare status bar. Meanwhile
/// the Scaffold also takes the status bar back out of `viewPadding` for the
/// body, so a figure computed from that is short by exactly the status bar
/// down there. Each source is therefore right in one place and wrong in the
/// other — and the wrong one is always the smaller. So take whichever is
/// larger, and both places land on the same number.
/// [extra] is the height of anything the bar carries under itself — a pinned
/// search field, a tab bar. The Scaffold counts it in `padding.top`; the
/// computed figure has to add it too, or the two sources disagree and the
/// page either hides its first row under the field or leaves a second, empty
/// field's worth of space below it.
EdgeInsets floatingHeaderInset(BuildContext context, {double extra = 0}) {
  final MediaQueryData mq = MediaQuery.of(context);
  final double fromScaffold = mq.padding.top;
  final double computed = kFloatingAppBarHeight + extra + mq.viewPadding.top;
  return EdgeInsets.only(
    top: fromScaffold > computed ? fromScaffold : computed,
  );
}

/// The round floating chip: the one icon button of the app's chrome.
///
/// The settings back arrow, the chat header's chips, the inbox bar, the close
/// target over an image or a map, the actions of a full-screen viewer: all of
/// them are this widget. It paints a 42 px opaque circle in
/// [FloatingChromeSurface.fillOf] with a centred 22 px glyph, and it takes a
/// 48 px press. It is never transparent: a bare glyph over a light map or a
/// photo disappears, and that is the bug this widget exists to prevent.
///
/// Variants, all on the same shape:
/// - [accent]: filled with the accent, glyph `accentButtonForeground`. For
///   the one target on a bar that is "on" or ready.
/// - [parked]: the glyph dims, the tap still arrives (the callback says why
///   the feature is not ready).
/// - [busy]: a small spinner replaces the glyph and the tap is off.
/// - `onPressed: null`: disabled, dimmed glyph, no ink.
class FloatingHeaderButton extends StatelessWidget {
  const FloatingHeaderButton({
    super.key,
    this.icon,
    this.hugeIcon,
    required this.onPressed,
    this.tooltip,
    this.color,
    this.accent = false,
    this.parked = false,
    this.busy = false,
    this.semanticsId,
  }) : assert(icon != null || hugeIcon != null, 'Pass icon or hugeIcon.');

  /// A Material glyph, drawn through the app's icon table ([AppIcon]).
  final IconData? icon;

  /// A glyph from the app's own set. Wins over [icon].
  final HugeIconData? hugeIcon;

  final VoidCallback? onPressed;
  final String? tooltip;

  /// Glyph colour override (a destructive action, say). The fill stays.
  final Color? color;

  final bool accent;
  final bool parked;
  final bool busy;
  final String? semanticsId;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color fill = accent
        ? theme.colorScheme.primary
        : FloatingChromeSurface.fillOf(context);
    final Color base =
        color ??
        (accent ? theme.accentButtonForeground(fill) : theme.resolvedIconColor);
    final bool enabled = onPressed != null && !busy;
    final Color glyph = (parked || onPressed == null)
        ? base.withValues(alpha: 0.45)
        : base;
    final Widget content = busy
        ? SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(strokeWidth: 2, color: base),
          )
        : hugeIcon != null
        ? HugeIcon(hugeIcon!, size: 22, color: glyph)
        : AppIcon(icon, size: 22, color: glyph);
    // The chip paints 42 px, the chat's chip; the press covers 48 px, the
    // smallest target a finger hits reliably. The ink stays on the chip.
    final Widget chip = Material(
      type: MaterialType.transparency,
      child: InkResponse(
        onTap: enabled ? onPressed : null,
        containedInkWell: false,
        highlightShape: BoxShape.circle,
        radius: kFloatingAppBarChip / 2,
        child: SizedBox.square(
          dimension: kFloatingAppBarTarget,
          child: Center(
            // Ink, not a plain box: the chip's fill is painted on the
            // Material, so the press ink lands on top of it.
            child: Ink(
              width: kFloatingAppBarChip,
              height: kFloatingAppBarChip,
              decoration: BoxDecoration(color: fill, shape: BoxShape.circle),
              child: Center(child: content),
            ),
          ),
        ),
      ),
    );
    final Widget withTip = tooltip == null
        ? chip
        : Tooltip(message: tooltip!, child: chip);
    return Semantics(
      identifier: semanticsId,
      button: true,
      enabled: enabled,
      child: withTip,
    );
  }
}

/// The header of a settings-style page: a floating back chip, a floating
/// title pill, and nothing behind either of them.
class FloatingAppBar extends StatelessWidget implements PreferredSizeWidget {
  const FloatingAppBar({
    super.key,
    this.title,
    this.actions,
    this.leading,
    this.automaticallyImplyLeading = true,
    this.bottom,
    this.scrim = true,
  });

  /// Usually a [Text]. It is put inside the floating pill. Null draws no
  /// pill: a page whose body carries its own big heading.
  final Widget? title;

  /// The right-hand side. Wrap anything tappable in [FloatingHeaderButton] so
  /// it floats like the rest.
  final List<Widget>? actions;

  /// Replaces the back chip.
  final Widget? leading;
  final bool automaticallyImplyLeading;

  /// A tab bar or search field under the header, as on a normal AppBar.
  final PreferredSizeWidget? bottom;

  /// Whether the page-colour fade sits behind the chips. Off for pages whose
  /// content runs to the top edge on purpose, such as a full-screen map.
  final bool scrim;

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
  Widget _styledTitle(BuildContext context, ThemeData theme, Widget self) {
    final TextStyle style = TextStyle(
      color: theme.resolvedIconColor.withValues(alpha: 0.92),
      fontSize: 15,
      fontWeight: FontWeight.w800,
    );
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

    final Color pageColor = theme.scaffoldBackgroundColor;

    return AppBar(
      // The bar draws no box, but it does hold the page down behind it: a
      // scrim that is the page colour at the status bar and nothing at all
      // by the bottom edge. Without it a list scrolling up runs its own
      // headings straight across the title pill, which reads as a fault.
      flexibleSpace: !scrim
          ? null
          : IgnorePointer(
        // SizedBox.expand, because a childless DecoratedBox takes the
        // smallest size the (loose) constraints allow — that is zero, and
        // the scrim then paints nothing at all.
        child: SizedBox.expand(
          child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                pageColor,
                pageColor,
                pageColor.withValues(alpha: 0),
              ],
              stops: const [0.0, 0.72, 1.0],
            ),
          ),
          ),
        ),
      ),
      // Nothing of the bar itself is drawn: no fill, no shadow, and no
      // tinted "scrolled under" state. What shows behind the chips is the
      // page.
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      toolbarHeight: kFloatingAppBarHeight,
      automaticallyImplyLeading: false,
      // The chips keep their painted place: the 48 px press area takes its
      // slop out of the margins around them.
      titleSpacing: back == null ? 10 : 8 - _kChipSlop,
      leadingWidth: kFloatingAppBarTarget + 10 - _kChipSlop,
      leading: back == null
          ? null
          : Padding(
              padding: const EdgeInsets.only(left: 10 - _kChipSlop),
              child: Center(child: back),
            ),
      title: title == null
          ? null
          : Align(
              alignment: Alignment.centerLeft,
              child: FloatingChromeSurface(
                radius: _kTitleRadius,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 11,
                ),
                // The chat's title pill, to the pixel: same radius, padding, size
                // and weight. A settings page and the chat must not read as two
                // different apps.
                child: _styledTitle(context, theme, title!),
              ),
            ),
      actions: actions == null
          ? null
          : <Widget>[
              for (final Widget action in actions!) ...[
                Center(child: action),
                const SizedBox(width: 8 - 2 * _kChipSlop),
              ],
              const SizedBox(width: 4 + _kChipSlop),
            ],
      bottom: bottom,
    );
  }
}
