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

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/utils/color_extensions.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/sidebar/hover_marquee_text.dart';

/// Gap between two cards inside one block. Deliberately tighter than the
/// reference design's 4 px: the cards must still read as separate objects,
/// but a block of three should scan as a single group at a glance.
const double kSbCardGap = 2.5;

/// Horizontal inset of every block from the sidebar edge.
const double kSbBlockInset = 8.0;

/// Corner radius of a sidebar card. Smaller than the settings pages' 26 px
/// because the sidebar is roughly half as wide — the corner has to stay in
/// proportion to the card, not to the screen.
const double kSbCardRadius = 20.0;

/// Height of a navigation card. The reference design uses 72 px on a phone;
/// ours is shorter because the same block has to fit a desktop sidebar too.
const double kSbNavCardHeight = 62.0;

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
    this.onSecondaryTap,
    this.selected = false,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    this.minHeight,
    this.radius = kSbCardRadius,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Right-click, reported in global coordinates so the caller can anchor a
  /// menu to the pointer.
  final void Function(Offset globalPosition)? onSecondaryTap;
  final bool selected;
  final EdgeInsets padding;
  final double? minHeight;
  final double radius;

  @override
  State<SbCard> createState() => _SbCardState();
}

class _SbCardState extends State<SbCard> {
  bool _pressed = false;
  bool _hovered = false;

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
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(widget.radius),
          // The border is always reserved, transparent when unselected, so
          // selecting a card only changes its colour and never its size.
          border: Border.all(
            color: widget.selected
                ? accent.withValues(alpha: 0.55)
                : Colors.transparent,
            width: 1.5,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: widget.onTap,
            onLongPress: widget.onLongPress,
            onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
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
  });

  final List<Widget> children;
  final double inset;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) rows.add(const SizedBox(height: kSbCardGap));
      rows.add(children[i]);
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

/// The rounded square an icon sits in, matching `ExpressiveIconTile` but
/// sized for the narrower sidebar.
class SbIconTile extends StatelessWidget {
  const SbIconTile({
    super.key,
    required this.icon,
    this.tone,
    this.size = 38,
  });

  final IconData icon;
  final Color? tone;
  final double size;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final Color background = tone ?? cs.primaryContainer;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(size * 0.38),
      ),
      child: Icon(
        icon,
        size: size * 0.52,
        color: tone == null
            ? cs.onPrimaryContainer
            : ThemeData.estimateBrightnessForColor(background) ==
                    Brightness.dark
                ? Colors.white
                : Colors.black,
      ),
    );
  }
}

/// One navigation entry: a full-width card with a tonal icon and a bold label.
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
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Row(
        children: [
          SbIconTile(icon: icon, tone: tone),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
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

/// The account card at the top: avatar, name, and the balance under it, with
/// a round action on the right that folds the sidebar away.
class SbProfileCard extends StatelessWidget {
  const SbProfileCard({
    super.key,
    required this.name,
    this.subtitle,
    this.onTap,
    this.onCollapse,
    this.collapseTooltip,
  });

  final String name;

  /// The quiet second line — the plan or the remaining balance.
  final Widget? subtitle;
  final VoidCallback? onTap;

  /// Null hides the round button entirely, for a host that has no way to
  /// collapse the panel.
  final VoidCallback? onCollapse;

  /// Null takes the localized default.
  final String? collapseTooltip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SbCard(
      onTap: onTap,
      padding: const EdgeInsets.fromLTRB(10, 9, 9, 9),
      child: Row(
        children: [
          SbAvatar(name: name),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 1),
                  DefaultTextStyle.merge(
                    style: theme.textTheme.bodySmall!.copyWith(
                      color: theme.m3.onSurfaceVariant,
                    ),
                    child: subtitle!,
                  ),
                ],
              ],
            ),
          ),
          if (onCollapse != null) ...[
            const SizedBox(width: 6),
            SbRoundAction(
              icon: Icons.keyboard_double_arrow_left_rounded,
              tooltip: collapseTooltip ??
                  AppLocalizations.of(context)?.hideSidebar ??
                  'Hide sidebar',
              onTap: onCollapse!,
              diameter: 36,
              iconSize: 20,
              fill: theme.m3.surfaceContainerHighest,
            ),
          ],
        ],
      ),
    );
  }
}

/// Round avatar carrying the first letter of the display name.
class SbAvatar extends StatelessWidget {
  const SbAvatar({super.key, required this.name, this.diameter = 40});

  final String name;
  final double diameter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final String trimmed = name.trim();
    final String initial =
        trimmed.isEmpty ? '?' : trimmed.characters.first.toUpperCase();
    return Container(
      width: diameter,
      height: diameter,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        shape: BoxShape.circle,
      ),
      child: Text(
        initial,
        style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w800,
          color: theme.colorScheme.onPrimaryContainer,
        ),
      ),
    );
  }
}

/// A round icon button on the card fill — the shape the bottom bar and the
/// profile card use for their actions.
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
            child: Icon(icon, size: iconSize, color: foreground),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(kSbBlockInset, 14, kSbBlockInset, 6),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: fg,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (count != null) ...[
                  const SizedBox(width: 8),
                  Text(
                    '$count',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: fg.withValues(alpha: 0.7),
                    ),
                  ),
                ],
                const Spacer(),
                AnimatedRotation(
                  turns: collapsed ? -0.25 : 0,
                  duration: const Duration(milliseconds: 150),
                  curve: Curves.easeOutCubic,
                  child: Icon(Icons.expand_more_rounded, size: 20, color: fg),
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
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onClear;

  /// Null takes the localized default.
  final String? hintText;

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
      height: 44,
      decoration: BoxDecoration(
        color: theme.m3.surfaceContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: TextField(
        controller: widget.controller,
        focusNode: widget.focusNode,
        style: TextStyle(color: theme.colorScheme.onSurface, fontSize: 14),
        cursorColor: theme.colorScheme.primary,
        decoration: InputDecoration(
          hintText: widget.hintText ??
              AppLocalizations.of(context)?.searchChatsHint ??
              'Search chats',
          hintStyle: TextStyle(color: muted, fontSize: 14),
          prefixIcon: Icon(Icons.search_rounded, size: 19, color: muted),
          prefixIconConstraints:
              const BoxConstraints(minWidth: 40, minHeight: 44),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 13),
          border: InputBorder.none,
          // The clear button only exists while there is something to clear,
          // so an untouched field stays a clean pill.
          suffixIcon: !_hasText
              ? null
              : InkResponse(
                  radius: 16,
                  onTap: widget.onClear,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: Icon(Icons.close_rounded, size: 17, color: muted),
                  ),
                ),
          suffixIconConstraints:
              const BoxConstraints(minWidth: 32, minHeight: 32),
        ),
      ),
    );
  }
}

/// The bar at the foot of the sidebar: the search pill, then the two round
/// actions.
class SbBottomBar extends StatelessWidget {
  const SbBottomBar({
    super.key,
    required this.search,
    required this.onSettings,
    required this.onNewChat,
    this.settingsTooltip,
    this.newChatTooltip,
    this.padding =
        const EdgeInsets.fromLTRB(kSbBlockInset, 6, kSbBlockInset, 10),
  });

  final Widget search;
  final VoidCallback onSettings;
  final VoidCallback onNewChat;

  /// Null on either takes the localized default.
  final String? settingsTooltip;
  final String? newChatTooltip;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Expanded(child: search),
          const SizedBox(width: 6),
          SbRoundAction(
            icon: Icons.settings_rounded,
            tooltip: settingsTooltip ??
                AppLocalizations.of(context)?.settings ??
                'Settings',
            onTap: onSettings,
          ),
          const SizedBox(width: 6),
          SbRoundAction(
            icon: Icons.edit_square,
            tooltip: newChatTooltip ??
                AppLocalizations.of(context)?.newChat ??
                'New chat',
            onTap: onNewChat,
            fill: theme.colorScheme.primary,
          ),
        ],
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
      onSecondaryTap: onSecondaryTap,
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
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
            child: Icon(
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
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: theme.colorScheme.primary,
              boxShadow: [
                BoxShadow(
                  color: theme.colorScheme.primary.withValues(alpha: 0.5),
                  blurRadius: 4,
                  spreadRadius: 1,
                ),
              ],
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
            Icon(
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
              icon: Icon(
                Icons.refresh_rounded,
                size: 18,
                color: theme.m3.onWarningContainer,
              ),
              tooltip: retryTooltip ??
                  AppLocalizations.of(context)?.checkForUpdates ??
                  'Check for updates',
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
