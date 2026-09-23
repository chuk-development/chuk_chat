// lib/widgets/expressive_settings.dart
//
// The settings look, in one place.
//
// Material 3 Expressive draws a list as separate filled tiles rather than
// one card cut by dividers: the outer corners of a group are large, the
// corners where tiles meet are small, and a press squeezes the tile and
// rounds its corners. That shape carries the grouping on its own, so the
// dividers, the hairline outlines and the small radii all go away.

import 'package:flutter/material.dart';


import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/icons/icon_map.dart';

/// Corner radius at the outer edges of a group.
const double kExpressiveOuterRadius = 26;

/// Corner radius a tile morphs to while it is held.
const double kExpressivePressedRadius = 18;

/// Corner radius where two tiles meet.
const double kExpressiveInnerRadius = 6;

/// Picks the contrast colour of a tone from the scheme.
extension ExpressiveOnColor on ColorScheme {
  /// The colour that stays legible on top of the given fill.
  ///
  /// A tone handed to a tile, a badge or an info card is usually a scheme
  /// colour, so the scheme already knows its partner. Only when the tone
  /// comes from somewhere else does this fall back to a brightness test — and
  /// even then it picks the scheme's own extremes, never pure white or black.
  Color onColorFor(Color background) {
    final List<(Color, Color)> pairs = <(Color, Color)>[
      (primary, onPrimary),
      (primaryContainer, onPrimaryContainer),
      (secondary, onSecondary),
      (secondaryContainer, onSecondaryContainer),
      (tertiary, onTertiary),
      (tertiaryContainer, onTertiaryContainer),
      (error, onError),
      (errorContainer, onErrorContainer),
      (inverseSurface, onInverseSurface),
      (surface, onSurface),
    ];
    for (final (Color fill, Color on) in pairs) {
      if (fill == background) return on;
    }
    final bool darkBackground =
        ThemeData.estimateBrightnessForColor(background) == Brightness.dark;
    final bool onSurfaceIsLight =
        ThemeData.estimateBrightnessForColor(onSurface) == Brightness.light;
    if (darkBackground) return onSurfaceIsLight ? onSurface : surface;
    return onSurfaceIsLight ? surface : onSurface;
  }
}

/// Gap between the tiles of a group.
const double kExpressiveTileGap = 3;

/// A group of settings tiles. The first and last tile round outwards, the
/// ones in between stay tight, so the group reads as one block without a
/// single divider.
class ExpressiveGroup extends StatelessWidget {
  const ExpressiveGroup({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final tiles = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) tiles.add(const SizedBox(height: kExpressiveTileGap));
      tiles.add(
        _ExpressiveTileShape(
          top: i == 0 ? kExpressiveOuterRadius : kExpressiveInnerRadius,
          bottom: i == children.length - 1
              ? kExpressiveOuterRadius
              : kExpressiveInnerRadius,
          child: children[i],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: tiles,
    );
  }
}

/// Hands the radii of its place in the group down to the tile.
class _ExpressiveTileShape extends InheritedWidget {
  const _ExpressiveTileShape({
    required this.top,
    required this.bottom,
    required super.child,
  });

  final double top;
  final double bottom;

  static BorderRadius of(BuildContext context) {
    final shape = context
        .dependOnInheritedWidgetOfExactType<_ExpressiveTileShape>();
    return BorderRadius.vertical(
      top: Radius.circular(shape?.top ?? kExpressiveOuterRadius),
      bottom: Radius.circular(shape?.bottom ?? kExpressiveOuterRadius),
    );
  }

  @override
  bool updateShouldNotify(_ExpressiveTileShape old) =>
      top != old.top || bottom != old.bottom;
}

/// One settings row: a tonal icon, a title, an optional line under it, and
/// whatever belongs on the right.
class ExpressiveRow extends StatefulWidget {
  const ExpressiveRow({
    super.key,
    required this.title,
    this.icon,
    this.leading,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.tone,
  });

  final String title;
  final IconData? icon;

  /// Replaces the icon tile entirely — for an avatar or a logo.
  final Widget? leading;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// Colour of the icon tile. Defaults to the primary container.
  final Color? tone;

  @override
  State<ExpressiveRow> createState() => _ExpressiveRowState();
}

class _ExpressiveRowState extends State<ExpressiveRow> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final m3 = theme.m3;

    return ExpressiveTile(
      onTap: widget.onTap,
      child: Row(
        children: [
          if (widget.leading != null)
            widget.leading!
          else if (widget.icon != null)
            ExpressiveIconTile(icon: widget.icon!, tone: widget.tone),
          if (widget.leading != null || widget.icon != null)
            const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                  ),
                ),
                if (widget.subtitle?.isNotEmpty ?? false) ...[
                  const SizedBox(height: 2),
                  Text(
                    widget.subtitle!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: m3.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (widget.trailing != null) ...[
            const SizedBox(width: 12),
            widget.trailing!,
          ],
        ],
      ),
    );
  }
}

/// The filled tile every row in a group sits in. Anything can go inside —
/// a settings row, an account header, a connector — and it will carry the
/// group's shape, its colour and its press feedback.
class ExpressiveTile extends StatelessWidget {
  const ExpressiveTile({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final m3 = Theme.of(context).m3;
    final BorderRadius resting = _ExpressiveTileShape.of(context);

    // The squeeze: pressing shrinks the tile a little and squares its corners
    // off, then a spring carries it back. It is the same [MorphTap] every
    // chat control is built on, so a settings row answers a finger exactly
    // the way the rest of the app does — no ripple is needed on top of it.
    return MorphTap(
      onTap: onTap,
      color: m3.surfaceContainer,
      pressedColor: m3.surfaceContainerHigh,
      pressedScale: 0.985,
      shape: RoundedRectangleBorder(borderRadius: resting),
      pressedShape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(
          Radius.circular(kExpressivePressedRadius),
        ),
      ),
      padding: padding,
      child: child,
    );
  }
}

/// A settings row that carries a switch. The whole tile is the target — the
/// switch itself is only the state, so a tap anywhere flips it.
class ExpressiveSwitchRow extends StatelessWidget {
  const ExpressiveSwitchRow({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.icon,
    this.subtitle,
    this.tone,
  });

  final String title;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final IconData? icon;
  final String? subtitle;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final bool enabled = onChanged != null;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: ExpressiveRow(
        icon: icon,
        title: title,
        subtitle: subtitle,
        tone: tone,
        onTap: enabled ? () => onChanged!(!value) : null,
        trailing: IgnorePointer(
          child: Switch.adaptive(value: value, onChanged: onChanged),
        ),
      ),
    );
  }
}

/// A block that is not a row: a slider, a preview, an editor. It carries the
/// group's shape, so it can sit inside an [ExpressiveGroup] or stand alone.
class ExpressiveCard extends StatelessWidget {
  const ExpressiveCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
  });

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final m3 = Theme.of(context).m3;
    return Container(
      decoration: BoxDecoration(
        color: m3.surfaceContainer,
        borderRadius: _ExpressiveTileShape.of(context),
      ),
      clipBehavior: Clip.antiAlias,
      padding: padding,
      child: child,
    );
  }
}

/// The quiet paragraph under a group: what the setting means, or why it is
/// off. Lower than the tiles it explains, so it never competes with them.
class ExpressiveInfoCard extends StatelessWidget {
  const ExpressiveInfoCard({
    super.key,
    required this.text,
    this.icon = Icons.info_outline,
    this.tone,
  });

  final String text;
  final IconData icon;

  /// Background. Defaults to the low container.
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m3 = theme.m3;
    final Color background = tone ?? m3.surfaceContainerLow;
    final Color foreground = tone == null
        ? m3.onSurfaceVariant
        : theme.colorScheme.onColorFor(background);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(kExpressiveOuterRadius),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppIcon(icon, size: 18, color: foreground),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: foreground,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A filled field that holds a dropdown, a text field or a picker, so that
/// the controls inside a card carry the same shape as the cards themselves.
class ExpressiveField extends StatelessWidget {
  const ExpressiveField({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
  });

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final m3 = Theme.of(context).m3;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: m3.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
      ),
      child: child,
    );
  }
}

/// The rounded tile an icon sits in.
class ExpressiveIconTile extends StatelessWidget {
  const ExpressiveIconTile({
    super.key,
    required this.icon,
    this.tone,
    this.size = 42,
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
      child: AppIcon(
        icon,
        // The icon's own box, before [HugeIcon]'s optical inset trims it to
        // about 0.86 of that. That lands a 42 px tile on a 25 px drawing —
        // the 24-in-40 proportion a filled tile wants. The old 0.5 was set
        // when the icon ignored it and filled the whole tile anyway.
        size: size * 0.7,
        color: tone == null ? cs.onPrimaryContainer : cs.onColorFor(background),
      ),
    );
  }
}

/// The label above a group. Large and heavy, the way Expressive titles are
/// — no more all-caps whisper.
class ExpressiveSectionHeader extends StatelessWidget {
  const ExpressiveSectionHeader(
    this.label, {
    super.key,
    this.trailing,
    this.color,
  });

  final String label;

  /// An action that belongs to the section, e.g. "Fullscreen" over a field.
  final Widget? trailing;

  /// Overrides the label colour — for a section that warns, not informs.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = Text(
      label,
      style: theme.textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w700,
        color: color ?? theme.colorScheme.primary,
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 26, 6, 10),
      child: trailing == null
          ? title
          : Row(
              children: [
                Expanded(child: title),
                const SizedBox(width: 8),
                trailing!,
              ],
            ),
    );
  }
}

/// A trailing pill: a short state word on the right of a row.
class ExpressiveBadge extends StatelessWidget {
  const ExpressiveBadge(this.label, {super.key, this.tone, this.icon});

  final String label;
  final Color? tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Color background = tone ?? theme.m3.surfaceContainerHighest;
    final Color foreground = tone == null
        ? theme.colorScheme.onSurface
        : theme.colorScheme.onColorFor(background);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            AppIcon(icon, size: 15, color: foreground),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: foreground,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The big page title Expressive puts above a settings list.
class ExpressiveTitle extends StatelessWidget {
  const ExpressiveTitle(this.title, {super.key, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
            ),
          ),
          if (subtitle?.isNotEmpty ?? false) ...[
            const SizedBox(height: 6),
            Text(
              subtitle!,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.m3.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
