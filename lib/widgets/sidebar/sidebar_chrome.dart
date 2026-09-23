// Shared chrome for the chat sidebar.
//
// The sidebar is drawn the way the settings pages are drawn: a vertical stack
// of filled, rounded cards collected into blocks, each block under a quiet
// header. Fill colour, press feedback and corner radii all come from the same
// Material You tokens `expressive_settings.dart` uses, so the two surfaces
// cannot drift apart as either one is edited.
//
// Nothing in here knows about chats, storage or navigation — the two platform
// sidebars supply the data and the callbacks. The one thing the chrome does
// resolve for itself is its own labels: every tooltip and hint falls back to
// `AppLocalizations`, so a caller that passes nothing still speaks the user's
// language instead of English.
import 'package:flutter/material.dart';

import 'package:chuk_chat/constants.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/utils/color_extensions.dart';
import 'package:chuk_chat/widgets/floating_chrome_surface.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/sidebar/hover_marquee_text.dart';
import 'package:chuk_chat/widgets/icons/icon_map.dart';
import 'package:chuk_chat/widgets/brand_wordmark.dart';

/// The colour the sidebar panel is painted in — the same step off the page
/// that a floating card takes in the chat.
///
/// Which is why the bars floating over *this* panel step the other way, down
/// to the page background: a bar in the panel's own colour would be
/// invisible, and one in any third colour would be a patch of the wrong
/// shade with a stray line around its rounded edge.
Color sbPanelBackground(BuildContext context) => floatingChromeBase(context);

/// Gap between two cards inside one block. Matches `kExpressiveTileGap`: the
/// cards stay separate objects, and the block still scans as one group.
const double kSbCardGap = 3.0;

/// Horizontal inset of every block from the sidebar edge.
const double kSbBlockInset = 8.0;

/// Corner radius of a lone card, and of the outward corners of a block.
/// Smaller than the settings pages' 26 px because the sidebar is roughly half
/// as wide — the corner stays in proportion to the card, not to the screen.
const double kSbCardRadius = 20.0;

/// The corners where two cards of one block meet. Same idea as
/// `kExpressiveInnerRadius`: a run of cards reads as one block because the
/// joints tighten, not because a frame is drawn around them.
const double kSbCardJointRadius = 6.0;

/// Height of a navigation card. Short enough that the block reads as one
/// run of rows rather than as three separate buttons.
const double kSbNavCardHeight = 42.0;

/// One row of the navigation block, card plus the gap under it. The rhythm
/// the whole left edge is measured in.
const double kSbNavRowStep = kSbNavCardHeight + kSbCardGap;

/// The hamburger's centre line. It is the row above the block — folded, it is
/// the first thing in the same column of icons — so the block is spaced off
/// it rather than off the bottom of the head bar.
const double _kSbMenuCentre = kTopInitialSpacing + kMenuButtonHeight / 2;

/// Where the first navigation card starts.
///
/// Placed so that its icon's centre is exactly one row below the hamburger's:
/// folded, the menu glyph and the icons under it sit on one evenly spaced
/// column, with the same gap between every pair.
const double kSbNavBlockTop =
    _kSbMenuCentre + kSbNavRowStep - kSbNavCardHeight / 2;

/// Top of row [index] of the navigation block — the cards when the panel is
/// open, the rail icons when it is folded.
///
/// Both read the same figure, so the icon a reader is aiming at does not move
/// by a pixel when the panel folds: the label and the card fade, the icon
/// stays put.
double sbNavRowTop(int index) => kSbNavBlockTop + index * kSbNavRowStep;

/// Left edge of the icon inside a navigation card: the block's inset, then
/// the card's own padding. The card's ring is painted in front of its
/// content now, so it takes no room and must not be counted here — the 1.5 px
/// it used to add is exactly how far the icon jumped when the panel folded.
const double kSbNavIconLeft = kSbBlockInset + 8;

/// Side of the tonal square an icon sits in, in a card and in the rail.
const double kSbNavIconTile = 30.0;

/// Top of the icon tile within its row.
const double kSbNavIconTop = (kSbNavCardHeight - kSbNavIconTile) / 2;

/// The vertical line every icon on the left edge stands on: the card icons,
/// the rail icons, and the hamburger above them.
///
/// The hamburger sits in a box of its own size, so it has to be placed from
/// this centre rather than from the panel's edge — measured from the edge the
/// two land a pixel apart, which is visible in a column of three.
const double kSbNavIconCentre = kSbNavIconLeft + kSbNavIconTile / 2;

class SidebarTokens {
  final Color iconFg;
  final Color accent;
  final Color bg;
  final Color surface;
  final Color surfaceHigh;
  final Color hairline;
  final Color muted;
  final bool isDark;
  const SidebarTokens({
    required this.iconFg,
    required this.accent,
    required this.bg,
    required this.surface,
    required this.surfaceHigh,
    required this.hairline,
    required this.muted,
    required this.isDark,
  });

  factory SidebarTokens.of(BuildContext context) {
    final theme = Theme.of(context);
    final iconFg = theme.resolvedIconColor;
    return SidebarTokens(
      iconFg: iconFg,
      accent: theme.colorScheme.primary,
      bg: theme.cardColor.darken(0.03),
      surface: theme.m3.surfaceContainer,
      surfaceHigh: theme.m3.surfaceContainerHigh,
      hairline: theme.dividerColor.withValues(alpha: 0.5),
      muted: theme.m3.onSurfaceVariant,
      isDark: theme.brightness == Brightness.dark,
    );
  }
}

/// The filled, rounded card every sidebar row sits in.
///
/// Mirrors `ExpressiveTile`: same fill, same press squeeze. It differs in two
/// ways the sidebar needs — a card can be *selected* (the open chat), and it
/// can reveal extra controls on hover, which a settings page never does.
class SbCard extends StatefulWidget {
  const SbCard({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.onLongPressAt,
    this.onSecondaryTap,
    this.selected = false,
    this.outlined = false,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    this.minHeight,
    this.radius,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Long press, reported in global coordinates so the caller can open a menu
  /// where the finger was rather than at the card's corner.
  final void Function(Offset globalPosition)? onLongPressAt;

  /// Right-click, reported in global coordinates so the caller can anchor a
  /// menu to the pointer.
  final void Function(Offset globalPosition)? onSecondaryTap;
  final bool selected;

  /// Draws the accent ring without the accent fill — for the search field,
  /// which has to look like an input, not like the chat you are in.
  final bool outlined;
  final EdgeInsets padding;
  final double? minHeight;

  /// Overrides the shape the enclosing [SbBlock] would give this card.
  final double? radius;

  @override
  State<SbCard> createState() => _SbCardState();
}

class _SbCardState extends State<SbCard> {
  bool _pressed = false;
  bool _hovered = false;

  /// Where the finger went down. A long press is always preceded by a tap
  /// down on the same card, and InkWell's long-press callback carries no
  /// position of its own.
  Offset? _lastDown;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m3 = theme.m3;
    final Color accent = theme.colorScheme.primary;
    final bool enabled = widget.onTap != null;

    final Color fill = widget.selected
        ? Color.alphaBlend(accent.withValues(alpha: 0.20), m3.surfaceContainer)
        : (_pressed || _hovered
            ? m3.surfaceContainerHigh
            : m3.surfaceContainer);

    final BorderRadius shape = widget.radius != null
        ? BorderRadius.circular(widget.radius!)
        : SbCardShape.of(context) ?? BorderRadius.circular(kSbCardRadius);

    Widget card = AnimatedScale(
      scale: _pressed ? 0.985 : 1,
      duration: const Duration(milliseconds: 130),
      curve: Curves.easeOutCubic,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 130),
        curve: Curves.easeOutCubic,
        constraints: widget.minHeight == null
            ? null
            : BoxConstraints(minHeight: widget.minHeight!),
        decoration: BoxDecoration(color: fill, borderRadius: shape),
        // The ring goes in front of the content, not behind it: a border in
        // the background decoration is painted under the clip, which eats
        // half its width on the tight corners of a block joint and leaves
        // the stroke looking uneven from corner to corner.
        // A selected chat is the accent fill alone — a ring around it as
        // well made the row read as a control instead of as the chat the
        // user is in.
        foregroundDecoration: widget.outlined
            ? BoxDecoration(
                borderRadius: shape,
                border: Border.all(
                  color: accent.withValues(alpha: 0.55),
                  width: 1.5,
                ),
              )
            : null,
        clipBehavior: Clip.antiAlias,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: widget.onTap,
            onLongPress: widget.onLongPress == null &&
                    widget.onLongPressAt == null
                ? null
                : () {
                    widget.onLongPress?.call();
                    final at = _lastDown;
                    if (at != null) widget.onLongPressAt?.call(at);
                  },
            onTapDown: enabled
                ? (details) {
                    _lastDown = details.globalPosition;
                    setState(() => _pressed = true);
                  }
                : null,
            onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
            onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
            child: Padding(
              padding: widget.padding,
              child: SbCardHoverScope(hovered: _hovered, child: widget.child),
            ),
          ),
        ),
      ),
    );

    if (widget.onSecondaryTap != null) {
      card = GestureDetector(
        onSecondaryTapDown: (details) =>
            widget.onSecondaryTap!(details.globalPosition),
        child: card,
      );
    }

    return RepaintBoundary(
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: card,
      ),
    );
  }
}

/// Publishes the hover state of the enclosing [SbCard] to its content.
class SbCardHoverScope extends InheritedWidget {
  const SbCardHoverScope({
    super.key,
    required this.hovered,
    required super.child,
  });

  final bool hovered;

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SbCardHoverScope>()?.hovered ??
      false;

  @override
  bool updateShouldNotify(SbCardHoverScope old) => hovered != old.hovered;
}

/// A stack of cards that belong together — the navigation block, or the chats
/// of one time group. The block is what carries the grouping; there are no
/// dividers and no outer frame.
class SbBlock extends StatelessWidget {
  const SbBlock({
    super.key,
    required this.children,
    this.inset = kSbBlockInset,
    this.joinTop = false,
  });

  final List<Widget> children;
  final double inset;

  /// The block continues the card above it — the sidebar's head bar — so its
  /// first card tightens its top corners instead of rounding them.
  final bool joinTop;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) rows.add(const SizedBox(height: kSbCardGap));
      rows.add(
        SbCardShape(
          radius: sbBlockRadiusFor(
            index: i,
            length: children.length,
            joinTop: joinTop,
          ),
          child: children[i],
        ),
      );
    }
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: inset),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: rows,
      ),
    );
  }
}

/// The corners of the card at [index] in a block of [length] cards: outward
/// corners stay round, the joints between neighbours tighten.
BorderRadius sbBlockRadiusFor({
  required int index,
  required int length,
  bool joinTop = false,
}) {
  const outer = Radius.circular(kSbCardRadius);
  const joint = Radius.circular(kSbCardJointRadius);
  // The block continues something above it, so its first card meets that
  // the way two cards of one block meet: tight corners, not round ones.
  if (joinTop && index == 0) {
    return BorderRadius.only(
      topLeft: joint,
      topRight: joint,
      bottomLeft: length <= 1 ? outer : joint,
      bottomRight: length <= 1 ? outer : joint,
    );
  }
  if (length <= 1) return BorderRadius.circular(kSbCardRadius);
  if (index == 0) {
    return const BorderRadius.only(
      topLeft: outer,
      topRight: outer,
      bottomLeft: joint,
      bottomRight: joint,
    );
  }
  if (index == length - 1) {
    return const BorderRadius.only(
      topLeft: joint,
      topRight: joint,
      bottomLeft: outer,
      bottomRight: outer,
    );
  }
  return const BorderRadius.all(joint);
}

/// Carries the shape a card should take from its block down to the card.
///
/// The card cannot work it out for itself — only the block knows whether this
/// one is first, last, or in the middle.
class SbCardShape extends InheritedWidget {
  const SbCardShape({super.key, required this.radius, required super.child});

  final BorderRadius radius;

  static BorderRadius? of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<SbCardShape>()
      ?.radius;

  @override
  bool updateShouldNotify(SbCardShape old) => radius != old.radius;
}

/// The glyph of a navigation entry: the bare icon in the accent colour, in a
/// box of [kSbNavIconTile] so the card and the folded rail place it
/// identically.
///
/// No plate behind it. A filled square around every icon turned a short list
/// of destinations into a row of buttons; the colour alone marks them.
class SbNavIcon extends StatelessWidget {
  const SbNavIcon({
    super.key,
    required this.icon,
    this.tone,
    this.size = kSbNavIconTile,
  });

  final IconData icon;

  /// Null takes the theme's accent.
  final Color? tone;

  /// Side of the box the glyph is centred in.
  final double size;

  @override
  Widget build(BuildContext context) {
    final Color color = tone ?? Theme.of(context).colorScheme.primary;
    return SizedBox(
      width: size,
      height: size,
      child: Center(child: AppIcon(icon, size: size * 0.8, color: color)),
    );
  }
}

/// One navigation entry: a full-width card with a coloured icon and a bold
/// label.
class SbNavCard extends StatelessWidget {
  const SbNavCard({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.tone,
    this.trailing,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? tone;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SbCard(
      onTap: onTap,
      minHeight: kSbNavCardHeight,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      child: Row(
        children: [
          SbNavIcon(icon: icon, tone: tone),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurface,
              ),
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
        ],
      ),
    );
  }
}

/// A round icon button on the card fill — the shape the head bar and the
/// account line use for their actions.
class SbRoundAction extends StatelessWidget {
  const SbRoundAction({
    super.key,
    required this.icon,
    required this.onTap,
    required this.tooltip,
    this.diameter = 44,
    this.iconSize = 22,
    this.fill,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;
  final double diameter;
  final double iconSize;

  /// Null uses the same container fill the cards use; a colour here makes the
  /// button the loud one of the pair (new chat).
  final Color? fill;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Color background = fill ?? theme.m3.surfaceContainer;
    final Color foreground = fill == null
        ? theme.colorScheme.onSurface
        : ThemeData.estimateBrightnessForColor(background) == Brightness.dark
            ? Colors.white
            : Colors.black;
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: diameter,
        height: diameter,
        child: Material(
          color: background,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: AppIcon(icon, size: iconSize, color: foreground),
          ),
        ),
      ),
    );
  }
}

/// The header above a block: a quiet label, the number of items in the group,
/// and a chevron that folds the block away.
class SbGroupHeader extends StatelessWidget {
  const SbGroupHeader({
    super.key,
    required this.label,
    required this.collapsed,
    this.count,
    this.onToggle,
  });

  final String label;
  final bool collapsed;
  final int? count;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Color fg = theme.m3.onSurfaceVariant;
    // The header is the lid of its block: open, it is the top card and the
    // chats join underneath it; shut, it is a closed card on its own. A bare
    // floating label instead leaves a hole in the list where the group was.
    return Padding(
      padding: const EdgeInsets.fromLTRB(kSbBlockInset, 10, kSbBlockInset, 0),
      child: SbCardShape(
        radius: collapsed
            ? BorderRadius.circular(kSbCardRadius)
            : const BorderRadius.only(
                topLeft: Radius.circular(kSbCardRadius),
                topRight: Radius.circular(kSbCardRadius),
                bottomLeft: Radius.circular(kSbCardJointRadius),
                bottomRight: Radius.circular(kSbCardJointRadius),
              ),
        child: Semantics(
          button: true,
          expanded: !collapsed,
          child: SbCard(
            onTap: onToggle,
            minHeight: 38,
            // The right inset puts the 20 px chevron on the same axis as the
            // 18 px three-dot glyph of a chat row: that one sits in a 48 px
            // box behind a 4 px inset, so its centre is 28 px from the edge.
            padding: const EdgeInsets.fromLTRB(14, 6, 18, 6),
            child: Row(
              children: [
                // The label takes the free space, so the count and the
                // chevron both end at the right edge on every row. With a
                // Spacer beside a Flexible label the two split that space
                // and the chevron drifts with the label's length.
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: fg,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (count != null) ...[
                  Text(
                    '$count',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: fg.withValues(alpha: 0.7),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                AnimatedRotation(
                  // Shut points down (there is more to open), open points up.
                  turns: collapsed ? 0 : 0.5,
                  duration: const Duration(milliseconds: 150),
                  curve: Curves.easeOutCubic,
                  child: AppIcon(Icons.expand_more_rounded, size: 20, color: fg),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The pill-shaped search field of the bottom bar.
class SbSearchField extends StatefulWidget {
  const SbSearchField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onClear,
    this.hintText,
    this.transparent = false,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onClear;

  /// Null takes the localized default.
  final String? hintText;

  /// Draws no fill of its own, for a field that sits where a card already
  /// supplies the surface.
  final bool transparent;

  @override
  State<SbSearchField> createState() => _SbSearchFieldState();
}

class _SbSearchFieldState extends State<SbSearchField> {
  /// Whether the clear button belongs on screen. Tracked here, from the
  /// controller, because the field must not depend on the host happening to
  /// rebuild it on every keystroke — a host that debounces its own work
  /// would otherwise leave the button behind.
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _hasText = widget.controller.text.isNotEmpty;
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void didUpdateWidget(covariant SbSearchField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
      _hasText = widget.controller.text.isNotEmpty;
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    final bool hasText = widget.controller.text.isNotEmpty;
    if (hasText == _hasText) return;
    setState(() => _hasText = hasText);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Color muted = theme.m3.onSurfaceVariant;
    return Container(
      height: widget.transparent ? kSbNavCardHeight : 44,
      decoration: BoxDecoration(
        color: widget.transparent
            ? Colors.transparent
            : theme.m3.surfaceContainer,
        borderRadius: widget.transparent
            ? (SbCardShape.of(context) ??
                BorderRadius.circular(kSbCardRadius))
            : BorderRadius.circular(999),
      ),
      child: TextField(
        controller: widget.controller,
        focusNode: widget.focusNode,
        style: TextStyle(color: theme.colorScheme.onSurface, fontSize: 14),
        cursorColor: theme.colorScheme.primary,
        // Centred in the pill rather than padded down from the top — the
        // padded version sits high whenever the pill is taller than the line.
        textAlignVertical: TextAlignVertical.center,
        decoration: InputDecoration(
          hintText: widget.hintText ??
              AppLocalizations.of(context)?.searchChatsHint ??
              'Search chats',
          hintStyle: TextStyle(color: muted, fontSize: 14),
          prefixIcon: AppIcon(Icons.search_rounded, size: 19, color: muted),
          prefixIconConstraints:
              const BoxConstraints(minWidth: 40, minHeight: 44),
          // The app theme fills every field and rounds it to kRadiusField.
          // Left on, that fill is painted OVER the pill below it, which
          // is why the bar kept looking square however round the box was.
          filled: false,
          isDense: true,
          contentPadding: EdgeInsets.zero,
          // Every state, not just the resting one: `border` alone leaves the
          // theme's focused outline in place, and the field then grows a
          // coloured ring the cards around it do not have.
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          disabledBorder: InputBorder.none,
          errorBorder: InputBorder.none,
          focusedErrorBorder: InputBorder.none,
          // The clear button only exists while there is something to clear,
          // so an untouched field stays a clean pill.
          suffixIcon: !_hasText
              ? null
              : InkResponse(
                  radius: 16,
                  onTap: widget.onClear,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: AppIcon(Icons.close_rounded, size: 17, color: muted),
                  ),
                ),
          suffixIconConstraints:
              const BoxConstraints(minWidth: 32, minHeight: 32),
        ),
      ),
    );
  }
}

/// The bottom bar of the phone sidebar: who is signed in, what is left on the
/// account, and the way into the settings — one quiet, translucent card.
///
/// It reads as chrome under the list rather than as one more row of it, which
/// is why the fill is weaker than a card's and the settings glyph lives
/// inside the same shape instead of beside it.
class SbAccountLine extends StatelessWidget {
  const SbAccountLine({
    super.key,
    required this.name,
    this.balance,
    this.onTap,
    this.onSettings,
    this.settingsTooltip,
    this.onNewChat,
    this.newChatTooltip,
  });

  final String name;

  /// The remaining balance, drawn on the right.
  final Widget? balance;
  final VoidCallback? onTap;
  final VoidCallback? onSettings;
  final String? settingsTooltip;

  /// The one accent action of the panel. Null leaves it out.
  final VoidCallback? onNewChat;
  final String? newChatTooltip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The list runs straight past it on every side, so the row reads as
    // something held above the panel rather than as a band closing it off.
    return SbFloatingBar(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ),
              if (balance != null) ...[
                const SizedBox(width: 10),
                // The credit is its own reading: a filled chip, one step
                // lighter than the bar it sits in, separates the number from
                // the name beside it. A ring would add a third outline to a
                // row that already has none.
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: theme.m3.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: balance!,
                ),
              ],
              if (onSettings != null)
                IconButton(
                  onPressed: onSettings,
                  icon: const AppIcon(Icons.settings_rounded, size: 20),
                  color: theme.m3.onSurfaceVariant,
                  tooltip: settingsTooltip ??
                      AppLocalizations.of(context)?.settings ??
                      'Settings',
                  constraints:
                      const BoxConstraints.tightFor(width: 40, height: 40),
                  padding: EdgeInsets.zero,
                  splashRadius: 22,
                ),
              if (onNewChat != null) ...[
                const SizedBox(width: 2),
                SbRoundAction(
                  icon: Icons.edit_square,
                  tooltip: newChatTooltip ??
                      AppLocalizations.of(context)?.newChat ??
                      'New chat',
                  onTap: onNewChat!,
                  fill: theme.colorScheme.primary,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// One chat in a group block: the title, the date under it, and the actions
/// on the right.
class SbChatTile extends StatelessWidget {
  const SbChatTile({
    super.key,
    required this.title,
    this.dateLine,
    this.selected = false,
    this.locked = false,
    this.streaming = false,
    this.onTap,
    this.onLongPress,
    this.onLongPressAt,
    this.onSecondaryTap,
    this.trailing,
    this.hoverTrailing,
  });

  final String title;
  final String? dateLine;
  final bool selected;
  final bool locked;
  final bool streaming;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Long press with the position of the finger, for a menu that opens there.
  final void Function(Offset globalPosition)? onLongPressAt;
  final void Function(Offset globalPosition)? onSecondaryTap;

  /// Always visible — the three-dot menu.
  final Widget? trailing;

  /// Revealed only while the pointer is over the card, for a control that
  /// would be noise on a list of forty rows (the pin toggle).
  final Widget? hoverTrailing;

  @override
  Widget build(BuildContext context) {
    return SbCard(
      selected: selected,
      onTap: onTap,
      onLongPress: onLongPress,
      onLongPressAt: onLongPressAt,
      onSecondaryTap: onSecondaryTap,
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
      child: _SbChatTileBody(
        title: title,
        dateLine: dateLine,
        selected: selected,
        locked: locked,
        streaming: streaming,
        trailing: trailing,
        hoverTrailing: hoverTrailing,
      ),
    );
  }
}

/// Split out so it can read the card's hover state, which the card publishes
/// through an inherited widget wrapped around its own child.
class _SbChatTileBody extends StatelessWidget {
  const _SbChatTileBody({
    required this.title,
    required this.dateLine,
    required this.selected,
    required this.locked,
    required this.streaming,
    required this.trailing,
    required this.hoverTrailing,
  });

  final String title;
  final String? dateLine;
  final bool selected;
  final bool locked;
  final bool streaming;
  final Widget? trailing;
  final Widget? hoverTrailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bool hovered = SbCardHoverScope.of(context);
    final Color titleColor = locked
        ? theme.colorScheme.onSurface.withValues(alpha: 0.45)
        : (selected ? theme.colorScheme.primary : theme.colorScheme.onSurface);

    return Row(
      children: [
        if (locked)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: AppIcon(
              Icons.lock_rounded,
              size: 14,
              color: theme.m3.onSurfaceVariant,
            ),
          ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              HoverMarqueeText(
                title,
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: titleColor,
                  fontStyle: locked ? FontStyle.italic : null,
                ),
              ),
              if (dateLine != null && dateLine!.isNotEmpty) ...[
                const SizedBox(height: 1),
                Text(
                  dateLine!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.m3.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (streaming) ...[
          const SizedBox(width: 6),
          Container(
            width: 7,
            height: 7,
            // A flat dot. No halo: the design has no glow anywhere.
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: theme.colorScheme.primary,
            ),
          ),
        ],
        // The hover control keeps its slot at all times and only changes
        // opacity. Adding the widget on hover would resize the row and make
        // the title jump under the pointer.
        if (hoverTrailing != null)
          AnimatedOpacity(
            opacity: hovered ? 1 : 0,
            duration: const Duration(milliseconds: 120),
            // A faded-out control must be gone for everyone, not just for
            // the pointer: without these a keyboard user tabs onto an
            // invisible button and a screen reader reads it out.
            child: ExcludeFocus(
              excluding: !hovered,
              child: ExcludeSemantics(
                excluding: !hovered,
                child:
                    IgnorePointer(ignoring: !hovered, child: hoverTrailing!),
              ),
            ),
          ),
        ?trailing,
      ],
    );
  }
}

/// A time group: the header label and the chats that fall into it.
class SbChatGroup<T> {
  const SbChatGroup(this.label, this.items);
  final String label;
  final List<T> items;
}

/// Buckets chats into Today / This week / This month / one group per older
/// month. Pure and generic, so the grouping can be tested without a theme, a
/// store or a `StoredChat`.
///
/// [monthLabel] renders the header of an older bucket; callers hand in
/// `MaterialLocalizations.formatMonthYear` so the month name follows the
/// user's locale.
List<SbChatGroup<T>> sbGroupByTime<T>(
  List<T> items,
  DateTime Function(T item) dateOf, {
  required String Function(DateTime date) monthLabel,
  String todayLabel = 'Today',
  String weekLabel = 'This week',
  String thisMonthLabel = 'This month',
  DateTime? now,
}) {
  final DateTime reference = now ?? DateTime.now();
  final DateTime startOfToday =
      DateTime(reference.year, reference.month, reference.day);
  final DateTime startOfWeek = startOfToday.subtract(const Duration(days: 6));
  final DateTime startOfMonth = DateTime(reference.year, reference.month);

  final List<T> today = <T>[];
  final List<T> week = <T>[];
  final List<T> month = <T>[];
  // Insertion-ordered, and the source list is already newest first, so the
  // older months come out newest first as well.
  final Map<String, List<T>> older = <String, List<T>>{};

  for (final T item in items) {
    final DateTime date = dateOf(item);
    if (!date.isBefore(startOfToday)) {
      today.add(item);
    } else if (!date.isBefore(startOfWeek)) {
      week.add(item);
    } else if (!date.isBefore(startOfMonth)) {
      month.add(item);
    } else {
      older.putIfAbsent(monthLabel(date), () => <T>[]).add(item);
    }
  }

  return <SbChatGroup<T>>[
    if (today.isNotEmpty) SbChatGroup<T>(todayLabel, today),
    if (week.isNotEmpty) SbChatGroup<T>(weekLabel, week),
    if (month.isNotEmpty) SbChatGroup<T>(thisMonthLabel, month),
    for (final entry in older.entries) SbChatGroup<T>(entry.key, entry.value),
  ];
}

/// The muted line under a chat title: the time for anything from today, the
/// date for everything else. Formatted through [MaterialLocalizations], so it
/// follows the user's locale and 12/24-hour setting.
String sbChatDateLine(BuildContext context, DateTime? date) {
  if (date == null) return '';
  final MaterialLocalizations localizations = MaterialLocalizations.of(context);
  final DateTime now = DateTime.now();
  final bool isToday =
      date.year == now.year && date.month == now.month && date.day == now.day;
  if (isToday) {
    return localizations.formatTimeOfDay(
      TimeOfDay.fromDateTime(date),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );
  }
  return localizations.formatMediumDate(date);
}

/// The strip that says the list is stale because the device is offline, with
/// a retry.
class SbOfflineNotice extends StatelessWidget {
  const SbOfflineNotice({
    super.key,
    required this.label,
    required this.onRetry,
    this.retryTooltip,
  });

  final String label;
  final VoidCallback onRetry;

  /// Null takes the localized default.
  final String? retryTooltip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(kSbBlockInset, 6, kSbBlockInset, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
        decoration: BoxDecoration(
          color: theme.m3.warningContainer,
          borderRadius: BorderRadius.circular(kSbCardRadius),
        ),
        child: Row(
          children: [
            AppIcon(
              Icons.cloud_off_rounded,
              size: 16,
              color: theme.m3.onWarningContainer,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.m3.onWarningContainer,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            IconButton(
              icon: AppIcon(
                Icons.refresh_rounded,
                size: 18,
                color: theme.m3.onWarningContainer,
              ),
              // This retries the connection, not an app update: the banner
              // is about being offline.
              tooltip: retryTooltip ??
                  AppLocalizations.of(context)?.retryConnection ??
                  'Try again',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 28, height: 28),
              onPressed: onRetry,
            ),
          ],
        ),
      ),
    );
  }
}

/// A card that floats over the scrolling list — the app name at the top of
/// the phone sidebar, the account row at the bottom.
///
/// No outline, no shadow, and the panel's own colour as the fill. Nothing is
/// meant to be visible here except the text: the bar exists only so the
/// chats scrolling underneath disappear behind it instead of running into
/// the app name. Anything that draws an edge — a border, a shadow, a fill
/// of a different colour — turns it back into a box.
class SbFloatingBar extends StatelessWidget {
  const SbFloatingBar({super.key, required this.child, this.borderRadius});

  final Widget child;

  /// Per-corner shape. A bar that the block below it joins tightens the
  /// corners on that side, the way two cards of one block do.
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    return FloatingChromeSurface(
      radius: kSbCardRadius,
      borderRadius: borderRadius,
      baseColor: Theme.of(context).scaffoldBackgroundColor,
      // Solid: the chat list passes right under these bars, and a chat title
      // ghosting through the account row reads as a rendering fault.
      fillAlpha: 1,
      child: Material(type: MaterialType.transparency, child: child),
    );
  }
}

// ---------------------------------------------------------------------------
// The rail chrome the agent roster is built from.
//
// Upstream's own sidebar moved to the card grammar above (SbCard / SbBlock /
// SbNavCard). The roster and the desktop shell still draw the older rail —
// a brand row, hover pills, a section label, the pinned bento — so those
// widgets stay here rather than being deleted with the sidebar that stopped
// using them. Nothing above depends on them.
// ---------------------------------------------------------------------------

/// Brand row: optional logo square + text. Trailing widget on the right.
class SbBrand extends StatelessWidget {
  final Widget? trailing;
  final EdgeInsets padding;
  final String label;
  final bool showLogo;
  final double fontSize;
  final FontWeight fontWeight;
  const SbBrand({
    super.key,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(16, 16, 10, 12),
    this.label = 'Chuk Chat',
    this.showLogo = false,
    this.fontSize = 20,
    this.fontWeight = FontWeight.w700,
  });

  @override
  Widget build(BuildContext context) {
    final t = SidebarTokens.of(context);
    return Padding(
      padding: padding,
      child: Row(
        children: [
          if (showLogo) ...[
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: t.accent,
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,
              child: Text(
                'C',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 13,
                  color: t.isDark ? Colors.black : Colors.white,
                ),
              ),
            ),
            const SizedBox(width: 10),
          ],
          // Brand label renders as the frozen SVG wordmark; any other
          // label (none in production today) falls back to plain text.
          if (label == 'Chuk Chat')
            BrandWordmark(color: t.iconFg, height: fontSize * 0.75)
          else
            Text(
              label,
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: fontWeight,
                color: t.iconFg,
              ),
            ),
          const Spacer(),
          ?trailing,
        ],
      ),
    );
  }
}

/// Subtle search trigger — rounded icon button with "Search" label.
/// Opens whatever search experience the caller wires up (focus inline search,
/// open command palette, etc.).
class SbSearchTrigger extends StatelessWidget {
  final VoidCallback onTap;
  final String label;
  const SbSearchTrigger({
    super.key,
    required this.onTap,
    this.label = 'Search',
  });

  @override
  Widget build(BuildContext context) {
    final t = SidebarTokens.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: t.hairline),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppIcon(Icons.search_rounded, size: 15, color: t.muted),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  color: t.muted,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Compact accent pill — used for mobile top-right "New chat".
class SbNewChatPill extends StatelessWidget {
  final VoidCallback onTap;
  final String label;
  final IconData icon;
  const SbNewChatPill({
    super.key,
    required this.onTap,
    this.label = 'New',
    this.icon = Icons.edit_rounded,
  });

  @override
  Widget build(BuildContext context) {
    final t = SidebarTokens.of(context);
    final on = t.isDark ? Colors.black : Colors.white;
    return Material(
      color: t.accent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppIcon(icon, size: 15, color: on),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: on,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Sidebar nav row (icon + label, stacked vertically). Primary highlights accent.
class SbNavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool primary;
  const SbNavItem({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.primary = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = SidebarTokens.of(context);
    final iconColor = primary ? t.accent : t.iconFg.withValues(alpha: 0.85);
    final textColor = primary ? t.iconFg : t.iconFg.withValues(alpha: 0.92);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: kBorderRadiusRow,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          child: Row(
            children: [
              AppIcon(icon, size: 19, color: iconColor),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: primary ? FontWeight.w700 : FontWeight.w500,
                    color: textColor,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Rail-aligned nav row. 48 px tall, icon centred inside a 48x48 square at
/// the same x as the floating mini-rail IconButtons — so opening/closing
/// the sidebar doesn't shift any icon. Label sits to the right of the icon.
class SbRailRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool primary;

  /// Inner padding inside the rounded hover pill. Combined with the 6 px
  /// outer wrapper this yields an effective left offset of 8 — same as
  /// `kFixedLeftPadding`, so the icon glyph centres line up with the
  /// hamburger overlay above.
  final double leftPadding;
  final double rowHeight;
  final double iconBoxWidth;
  final double iconSize;
  const SbRailRow({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.primary = false,
    this.leftPadding = 2.0,
    this.rowHeight = 40.0,
    this.iconBoxWidth = 48.0,
    this.iconSize = 24.0,
  });

  @override
  Widget build(BuildContext context) {
    final t = SidebarTokens.of(context);
    final iconColor = primary ? t.accent : t.iconFg.withValues(alpha: 0.85);
    final textColor = primary ? t.iconFg : t.iconFg.withValues(alpha: 0.92);
    final BorderRadius radius = BorderRadius.circular(10);
    // Pill width is controlled by the parent (callers wrap a group of
    // rail rows in `IntrinsicWidth + Column(stretch)` so every row in
    // the group matches the widest label). Row uses mainAxisSize.min so
    // its natural width can be measured by IntrinsicWidth.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: SizedBox(
        height: rowHeight,
        child: Material(
          color: Colors.transparent,
          borderRadius: radius,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            borderRadius: radius,
            child: Padding(
              padding: EdgeInsets.only(left: leftPadding, right: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: iconBoxWidth,
                    height: rowHeight,
                    child: AppIcon(icon, size: iconSize, color: iconColor),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    label,
                    overflow: TextOverflow.clip,
                    softWrap: false,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: primary ? FontWeight.w700 : FontWeight.w500,
                      color: textColor,
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

/// Mixed-case section label with optional count. Claude.ai style.
class SbSectionLabel extends StatelessWidget {
  final String label;
  final int? count;
  final EdgeInsets padding;
  final Color? color;
  const SbSectionLabel({
    super.key,
    required this.label,
    this.count,
    this.padding = const EdgeInsets.fromLTRB(16, 12, 16, 4),
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final t = SidebarTokens.of(context);
    // Just the label in the user's accent colour — no leading dot, no
    // underline. The accent itself supplies the visual emphasis.
    final Color c = color ?? t.accent;
    return Padding(
      padding: padding,
      child: Row(
        children: [
          // Not upper case any more: small capitals read smaller than they
          // measure, and this label has to be findable at a glance.
          Text(
            label,
            // A line height above 1 keeps the descenders inside the box
            // whatever the font: without it the y and the p are clipped.
            style: TextStyle(
              fontSize: 16,
              height: 1.35,
              letterSpacing: -0.2,
              fontWeight: FontWeight.w900,
              color: c,
            ),
          ),
          if (count != null) ...[
            const Spacer(),
            Text(
              '$count',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: c.withValues(alpha: 0.7),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Accent-tinted "Pinned" bento card. Caller supplies the row widgets.
class SbPinnedBento extends StatelessWidget {
  final int count;
  final List<Widget> children;
  final EdgeInsets margin;
  const SbPinnedBento({
    super.key,
    required this.count,
    required this.children,
    this.margin = const EdgeInsets.symmetric(horizontal: 6),
  });

  @override
  Widget build(BuildContext context) {
    final t = SidebarTokens.of(context);
    // Neutral outlined card — a subtle hairline border (no accent fill, no
    // accent border) wraps the pinned section so it's visually grouped
    // without screaming colour.
    return Padding(
      padding: margin,
      child: Container(
        padding: const EdgeInsets.fromLTRB(0, 6, 0, 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: t.hairline),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 2, 14, 4),
              child: Row(
                children: [
                  Text(
                    'Pinned',
                    style: TextStyle(
                      fontSize: 12,
                      letterSpacing: 0.1,
                      fontWeight: FontWeight.w600,
                      color: t.muted,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '$count',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: t.muted.withValues(alpha: 0.65),
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: children,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Sliver delegate that renders an SbSectionLabel as a pinned header. The
/// header stays glued to the top of the viewport until the next pinned
/// header pushes it out — a classic "current section" indicator while
/// scrolling through Today / This week / Older buckets.
class SbStickyLabelDelegate extends SliverPersistentHeaderDelegate {
  final String label;
  final Color background;
  final Color? color;
  final double height;
  const SbStickyLabelDelegate({
    required this.label,
    required this.background,
    this.color,
    this.height = 40,
  });

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return Container(
      color: background,
      child: SbSectionLabel(
        label: label,
        color: color,
        padding: const EdgeInsets.fromLTRB(20, 8, 16, 8),
      ),
    );
  }

  @override
  double get maxExtent => height;
  @override
  double get minExtent => height;

  @override
  bool shouldRebuild(covariant SbStickyLabelDelegate oldDelegate) {
    return oldDelegate.label != label ||
        oldDelegate.background != background ||
        oldDelegate.color != color ||
        oldDelegate.height != height;
  }
}

/// Hairline divider matching app palette.
class SbHairline extends StatelessWidget {
  final EdgeInsets margin;
  const SbHairline({super.key, this.margin = EdgeInsets.zero});
  @override
  Widget build(BuildContext context) {
    final t = SidebarTokens.of(context);
    return Padding(
      padding: margin,
      child: Container(height: 1, color: t.hairline),
    );
  }
}
