// lib/widgets/menu_tile_group.dart
//
// The one menu surface of the app. Every dropdown and every long-press
// action sheet is drawn with it, so they all read the same.
//
// Material 3 Expressive draws a menu the way it draws a settings group: one
// filled tile per row, large corners at the ends of a run, small corners
// where two tiles meet, and a thin gap instead of a divider. There is no
// frame around the whole menu — the tiles carry the grouping on their own.

import 'package:flutter/material.dart';

import 'package:chuk_chat/ui/expressive/icon_map.dart';

/// Corner radius at the outer edges of a run.
const double kMenuOuterRadius = 26;

/// Corner radius where two tiles meet.
const double kMenuInnerRadius = 6;

/// Gap between the tiles of a run.
const double kMenuTileGap = 3;

/// Gap between two runs — what a divider turns into.
const double kMenuGroupGap = 10;

/// A run of menu rows as separate filled tiles.
///
/// [groups] holds the runs: the rows inside one run are tight together and
/// only the first and the last corner of the run round outwards; between two
/// runs sits [kMenuGroupGap] instead of a divider line.
class MenuTileGroup extends StatelessWidget {
  const MenuTileGroup({
    super.key,
    required this.groups,
    required this.color,
    this.outerRadius = kMenuOuterRadius,
  });

  /// One run of rows.
  MenuTileGroup.single({
    Key? key,
    required List<Widget> children,
    required Color color,
    double outerRadius = kMenuOuterRadius,
  }) : this(
         key: key,
         groups: <List<Widget>>[children],
         color: color,
         outerRadius: outerRadius,
       );

  final List<List<Widget>> groups;

  /// Fill of a tile. The gaps stay open, so whatever is behind the menu
  /// shows through them.
  final Color color;

  final double outerRadius;

  @override
  Widget build(BuildContext context) {
    final List<Widget> out = <Widget>[];
    for (final List<Widget> run in groups) {
      if (run.isEmpty) continue;
      if (out.isNotEmpty) out.add(const SizedBox(height: kMenuGroupGap));
      for (int i = 0; i < run.length; i++) {
        if (i > 0) out.add(const SizedBox(height: kMenuTileGap));
        out.add(
          Material(
            color: color,
            // Without a clip the ink of a tapped row is a plain rectangle
            // and its corners stick out of the tile.
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(
                top: Radius.circular(i == 0 ? outerRadius : kMenuInnerRadius),
                bottom: Radius.circular(
                  i == run.length - 1 ? outerRadius : kMenuInnerRadius,
                ),
              ),
            ),
            child: run[i],
          ),
        );
      }
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: out,
    );
  }
}

/// One row of a menu: an icon, a label, an optional line under it and
/// whatever belongs on the right.
///
/// The tile around it comes from [MenuTileGroup], so this only draws the
/// content and the tap target. Every menu in the app uses it, which is why
/// no screen needs its own `ListTile` with a hand-rolled shape any more.
class MenuActionRow extends StatelessWidget {
  const MenuActionRow({
    super.key,
    required this.label,
    this.icon,
    this.leading,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.tone,
    this.selected = false,
    this.enabled = true,
    this.maxLines,
  });

  final String label;
  final IconData? icon;

  /// Replaces the icon — for an avatar or a badge.
  final Widget? leading;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// Colour of the icon and the label. Defaults to the scheme's `onSurface`;
  /// pass `scheme.error` for a destructive row.
  final Color? tone;

  /// Draws the check on the right, for a row that is a choice.
  final bool selected;

  /// A parked row: it still reads, it just does not answer.
  final bool enabled;

  /// Cuts a long label after so many lines. Null lets it wrap freely.
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    final Color fg = (tone ?? scheme.onSurface).withValues(
      alpha: enabled ? 1 : 0.38,
    );
    return InkWell(
      onTap: enabled ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: <Widget>[
            if (leading != null)
              leading!
            else if (icon != null)
              AppIcon(icon!, size: 20, color: fg),
            if (leading != null || icon != null) const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    label,
                    maxLines: maxLines,
                    overflow: maxLines == null ? null : TextOverflow.ellipsis,
                    style: text.bodyLarge?.copyWith(
                      color: fg,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      style: text.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant.withValues(
                          alpha: enabled ? 1 : 0.5,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (trailing != null) ...<Widget>[
              const SizedBox(width: 12),
              trailing!,
            ] else if (selected) ...<Widget>[
              const SizedBox(width: 12),
              AppIcon(Icons.check, size: 18, color: scheme.primary),
            ],
          ],
        ),
      ),
    );
  }
}

/// A menu as a bottom sheet: the house sheet chrome, then the same tiles a
/// dropdown is made of. What a long press opens on a phone and what a click
/// opens on a pointer are then the same menu in two places.
Future<T?> showMenuSheet<T>(
  BuildContext context, {
  required List<List<Widget>> groups,
  Widget? header,
  Color? color,
}) {
  final ColorScheme scheme = Theme.of(context).colorScheme;
  return showModalBottomSheet<T>(
    context: context,
    // A long list scrolls inside the sheet instead of pushing it to the top
    // of the screen.
    constraints: BoxConstraints(
      maxHeight: MediaQuery.of(context).size.height * 0.8,
    ),
    backgroundColor: scheme.surfaceContainerLow,
    showDragHandle: false,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(36)),
    ),
    isScrollControlled: true,
    builder: (BuildContext sheetContext) => SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: scheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 14),
            if (header != null) ...<Widget>[header, const SizedBox(height: 10)],
            Flexible(
              child: SingleChildScrollView(
                child: MenuTileGroup(
                  groups: groups,
                  color: color ?? scheme.surfaceContainerHigh,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// The control a menu hangs off: the current value, an arrow, and the tap
/// that opens the menu. It replaces `DropdownButton` — the house menu needs
/// a plain anchor, not a control that brings its own popup.
///
/// [onTap] gets the anchor's own context, because that is what
/// `showAnchoredMenu` measures the menu against.
class MenuAnchorButton extends StatelessWidget {
  const MenuAnchorButton({
    super.key,
    required this.label,
    required this.onTap,
    this.leading,
    this.labelStyle,
    this.expand = false,
  });

  final String label;
  final ValueChanged<BuildContext> onTap;

  /// Sits before the label — a swatch, a dot row, an icon.
  final Widget? leading;

  /// Merged over the house style, for a preview in the chosen font.
  final TextStyle? labelStyle;

  /// Fills the width, the way `isExpanded` did.
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Widget text = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: (theme.textTheme.titleMedium ?? const TextStyle())
          .copyWith(color: theme.colorScheme.onSurface)
          .merge(labelStyle),
    );
    // What this sits in is usually a plain Container, so the ink needs a
    // Material of its own or the splash lands behind the fill.
    return Material(
      type: MaterialType.transparency,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: Builder(
        builder: (BuildContext anchorContext) => InkWell(
          onTap: () => onTap(anchorContext),
          borderRadius: BorderRadius.circular(18),
          child: SizedBox(
            height: 48,
            child: Row(
              mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
              children: <Widget>[
                if (leading != null) ...<Widget>[
                  leading!,
                  const SizedBox(width: 12),
                ],
                if (expand) Expanded(child: text) else Flexible(child: text),
                const SizedBox(width: 4),
                AppIcon(
                  Icons.arrow_drop_down,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
