// Shared chrome primitives for the Final-mix sidebar.
// Reads colors from the active app theme — no palette duplication.
// Uses rounded icon variants for a softer, less standard look.
import 'package:flutter/material.dart';
import 'package:chuk_chat/utils/color_extensions.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';

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
    final accent = theme.colorScheme.primary;
    final bg = theme.cardColor.darken(0.03);
    return SidebarTokens(
      iconFg: iconFg,
      accent: accent,
      bg: bg,
      surface: bg.lighten(theme.brightness == Brightness.dark ? 0.04 : 0.02),
      surfaceHigh:
          bg.lighten(theme.brightness == Brightness.dark ? 0.08 : 0.05),
      hairline: theme.dividerColor.withValues(alpha: 0.5),
      muted: iconFg.withValues(alpha: 0.6),
      isDark: theme.brightness == Brightness.dark,
    );
  }
}

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
    this.label = 'chuk chat',
    this.showLogo = false,
    this.fontSize = 17,
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
              child: Text('C',
                  style: TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 13,
                      color: t.isDark ? Colors.black : Colors.white)),
            ),
            const SizedBox(width: 10),
          ],
          Text(label,
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: fontWeight,
                letterSpacing: -0.4,
                color: t.iconFg,
              )),
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
  const SbSearchTrigger({super.key, required this.onTap, this.label = 'Search'});

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
              Icon(Icons.search_rounded, size: 15, color: t.muted),
              const SizedBox(width: 6),
              Text(label,
                  style: TextStyle(
                      fontSize: 12,
                      color: t.muted,
                      fontWeight: FontWeight.w500)),
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
              Icon(icon, size: 15, color: on),
              const SizedBox(width: 6),
              Text(label,
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: on)),
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
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          child: Row(
            children: [
              Icon(icon, size: 19, color: iconColor),
              const SizedBox(width: 14),
              Text(label,
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: primary ? FontWeight.w700 : FontWeight.w500,
                    color: textColor,
                  )),
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
                    child: Icon(icon, size: iconSize, color: iconColor),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    label,
                    overflow: TextOverflow.clip,
                    softWrap: false,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight:
                          primary ? FontWeight.w700 : FontWeight.w500,
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
          Text(label.toUpperCase(),
              style: TextStyle(
                fontSize: 13,
                letterSpacing: 1.2,
                fontWeight: FontWeight.w800,
                color: c,
              )),
          if (count != null) ...[
            const Spacer(),
            Text('$count',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: c.withValues(alpha: 0.7),
                )),
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
                  Text('Pinned',
                      style: TextStyle(
                          fontSize: 12,
                          letterSpacing: 0.1,
                          fontWeight: FontWeight.w600,
                          color: t.muted)),
                  const Spacer(),
                  Text('$count',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: t.muted.withValues(alpha: 0.65))),
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

/// Relative time helper (e.g. "now", "5m", "3h", "2d", "1w").
String sbRelativeTime(DateTime? t) {
  if (t == null) return '';
  final diff = DateTime.now().difference(t);
  if (diff.inSeconds < 60) return 'now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m';
  if (diff.inHours < 24) return '${diff.inHours}h';
  if (diff.inDays < 7) return '${diff.inDays}d';
  if (diff.inDays < 31) return '${diff.inDays ~/ 7}w';
  if (diff.inDays < 365) return '${diff.inDays ~/ 30}mo';
  return '${diff.inDays ~/ 365}y';
}

/// Demo-style flat chat row. Pin icon + title + unread dot + time + optional
/// trailing menu (e.g. PopupMenuButton). Honors selected/locked/streaming.
///
/// When [trailingOnHover] is true, the [trailing] widget is hidden by default
/// and faded in on mouse hover — the time text shifts under to keep the row
/// height stable. On mobile (no hover) the trailing simply stays hidden;
/// long-press / secondary tap is used to open the actions menu instead.
class SbChatTile extends StatefulWidget {
  final String title;
  final DateTime? createdAt;
  final bool selected;
  final bool pinned;
  final bool locked;
  final bool streaming;
  final bool dimmed;
  final VoidCallback? onTap;
  final void Function(Offset globalPosition)? onSecondaryTap;
  final VoidCallback? onLongPress;
  final Widget? trailing;
  final bool trailingOnHover;
  final bool compact;
  /// When true, skip the outer 6 px horizontal wrapper. Used when the tile is
  /// hosted inside a container that supplies its own indent (e.g. the pinned
  /// bento) so the title sits at the same x as tiles in the open list.
  final bool noOuterPad;
  const SbChatTile({
    super.key,
    required this.title,
    this.createdAt,
    this.selected = false,
    this.pinned = false,
    this.locked = false,
    this.streaming = false,
    this.dimmed = false,
    this.onTap,
    this.onSecondaryTap,
    this.onLongPress,
    this.trailing,
    this.trailingOnHover = false,
    this.compact = false,
    this.noOuterPad = false,
  });

  @override
  State<SbChatTile> createState() => _SbChatTileState();
}

class _SbChatTileState extends State<SbChatTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final t = SidebarTokens.of(context);
    final Color titleColor = widget.locked
        ? t.iconFg.withValues(alpha: 0.35)
        : widget.dimmed
            ? t.iconFg.withValues(alpha: 0.38)
            : (widget.selected ? t.accent : t.iconFg);
    final Color timeColor = t.iconFg.withValues(alpha: 0.55);

    // Trailing actions (pin/more) hover OVER the row's right edge rather
    // than reserving a slot, so the title stretches as far right as
    // possible. The time text on the right always shows; on hover, the
    // actions overlay it (and a small chunk of trailing title).
    final bool hoverOverlay =
        widget.trailingOnHover && widget.trailing != null;
    final bool hoverActive = hoverOverlay && _hovered;

    final row = Row(
      children: [
        if (widget.locked)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Icon(Icons.lock_rounded,
                size: 14, color: t.iconFg.withValues(alpha: 0.4)),
          ),
        Expanded(
          child: Text(
            widget.title,
            maxLines: 1,
            overflow: TextOverflow.clip,
            softWrap: false,
            style: TextStyle(
              fontSize: widget.compact ? 13.5 : 15,
              fontWeight: FontWeight.w500,
              color: titleColor,
              fontStyle: widget.locked ? FontStyle.italic : null,
            ),
          ),
        ),
        if (widget.streaming) ...[
          const SizedBox(width: 6),
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: t.accent,
              boxShadow: [
                BoxShadow(
                  color: t.accent.withValues(alpha: 0.5),
                  blurRadius: 4,
                  spreadRadius: 1,
                ),
              ],
            ),
          ),
        ],
        if (widget.createdAt != null) ...[
          const SizedBox(width: 8),
          Text(
            sbRelativeTime(widget.createdAt),
            style: TextStyle(fontSize: 11.5, color: timeColor),
          ),
        ],
        if (widget.trailing != null && !hoverOverlay) ...[
          const SizedBox(width: 4),
          widget.trailing!,
        ],
      ],
    );

    // Body padding's left value lines the chat title up with the left edge
    // of the nav icons above: outer wrapper 6 + body 14 = 20, same as the
    // hamburger / rail icon glyph left edge (left:8 + (48-24)/2 = 20).
    final EdgeInsets pad = widget.compact
        ? const EdgeInsets.fromLTRB(8, 4, 4, 4)
        : const EdgeInsets.fromLTRB(14, 5, 8, 5);

    final Color rowBg = widget.selected
        ? Color.alphaBlend(t.accent.withValues(alpha: 0.12), t.bg)
        : (_hovered
            ? Color.alphaBlend(t.iconFg.withValues(alpha: 0.05), t.bg)
            : t.bg);

    Widget body = AnimatedContainer(
      duration: const Duration(milliseconds: 110),
      padding: pad,
      decoration: BoxDecoration(
        color: widget.selected
            ? t.accent.withValues(alpha: 0.12)
            : (_hovered ? t.iconFg.withValues(alpha: 0.05) : null),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Stack(
        children: [
          row,
          // Hover-only action overlay: floats over the right edge of the
          // row, painting its own background to mask whatever title text
          // or time tag is behind it. The title's `Expanded(Text)` keeps
          // its full width so it only clips when the title is actually
          // too long, not because of reserved trailing space.
          if (hoverActive)
            Positioned(
              top: 0,
              right: 0,
              bottom: 0,
              child: Container(
                color: rowBg,
                padding: const EdgeInsets.only(left: 4),
                alignment: Alignment.center,
                child: widget.trailing!,
              ),
            ),
        ],
      ),
    );

    body = InkWell(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      borderRadius: BorderRadius.circular(8),
      child: body,
    );

    if (widget.onSecondaryTap != null) {
      body = GestureDetector(
        onSecondaryTapDown: (details) =>
            widget.onSecondaryTap!(details.globalPosition),
        child: body,
      );
    }

    body = MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: body,
    );

    if (!widget.compact && !widget.noOuterPad) {
      body = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: body,
      );
    }

    return RepaintBoundary(child: body);
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
    this.height = 32,
  });

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
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
