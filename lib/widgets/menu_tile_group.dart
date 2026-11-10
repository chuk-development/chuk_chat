// lib/widgets/menu_tile_group.dart
//
// The one menu surface of the app. Every dropdown and every long-press
// action sheet is drawn with it, so they all read the same.
//
// Material 3 Expressive vertical menu (m3.material.io/components/menus):
// each group of rows is ONE rounded container in `surfaceContainerLow`
// with a small shadow. Groups are split by a small gap instead of a divider
// line; the spec allows one or two gaps per menu. Rows inside a group have
// no gaps. The chosen row of a choice menu is an inset pill in
// `tertiaryContainer`.

import 'package:flutter/material.dart';

import 'package:chuk_chat/constants.dart' show kCompactModeBreakpoint;
import 'package:chuk_chat/widgets/icons/icon_map.dart';

/// Corner radius of a group container: the spec's large corner family,
/// taken one step up so a 48 px row's ink and the selected pill sit well
/// inside it.
const double kMenuOuterRadius = 20;

/// Corner of the selected pill and of the row ink inside a group:
/// [kMenuOuterRadius] minus [kMenuRowInset].
const double kMenuInnerRadius = 16;

/// Inset of a row's ink and selected pill from the container edge.
const double kMenuRowInset = 4;

/// Gap between two groups. Material 3 Expressive groups a menu with gaps,
/// not divider lines, and does not change the gap size.
const double kMenuGroupGap = 4;

/// Kept for callers that still read it; rows of one group no longer have a
/// gap between them.
const double kMenuTileGap = 0;

/// The Material 3 Expressive vertical menu surface.
///
/// [groups] holds the groups: each one is one rounded container with the
/// rows stacked inside it, and [kMenuGroupGap] sits between two groups where
/// a divider line used to be. Pass [color] `surfaceContainerLow` for the
/// spec's standard menu, `tertiaryContainer` for the vibrant one.
class MenuTileGroup extends StatelessWidget {
  const MenuTileGroup({
    super.key,
    required this.groups,
    required this.color,
    this.outerRadius = kMenuOuterRadius,
  });

  /// One run of rows that belong together.
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

  /// Each list is one connected run; the gap between runs replaces a divider.
  final List<List<Widget>> groups;

  /// Tile fill. It has to be a step above whatever is behind the menu, or the
  /// gaps disappear and the run reads as one block again.
  final Color color;

  final double outerRadius;

  @override
  Widget build(BuildContext context) {
    final List<Widget> out = <Widget>[];
    for (final List<Widget> run in groups) {
      if (run.isEmpty) continue;
      if (out.isNotEmpty) out.add(const SizedBox(height: kMenuGroupGap));
      out.add(
        Material(
          color: color,
          // Level 2: a small neutral shadow lifts the menu off the page. Never
          // a coloured one.
          elevation: 2,
          shadowColor: Colors.black,
          surfaceTintColor: Colors.transparent,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(outerRadius),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: kMenuRowInset),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: run,
            ),
          ),
        ),
      );
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
    this.shortcut,
  });

  final String label;

  /// The keyboard shortcut for this row ("Ctrl+N"), printed on the right in
  /// the quiet colour. Only the desktop menus pass one.
  final String? shortcut;
  final IconData? icon;

  /// Replaces the icon — for an avatar or a badge.
  final Widget? leading;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// Colour of the icon and the label. Defaults to the scheme's `onSurface`;
  /// pass `scheme.error` for a destructive row.
  final Color? tone;

  /// The chosen row of a choice menu. Material 3 Expressive marks it with
  /// shape and vibrant colour: the whole tile fills with
  /// `tertiaryContainer`, the text and glyphs turn `onTertiaryContainer` and
  /// a check leads the label (m3.material.io/components/menus, selection).
  final bool selected;

  /// A parked row: it still reads, it just does not answer.
  final bool enabled;

  /// Cuts a long label after so many lines. Null lets it wrap freely.
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    final Color fg =
        (selected ? scheme.onTertiaryContainer : (tone ?? scheme.onSurface))
            .withValues(alpha: enabled ? 1 : 0.38);
    // A selected row leads with the check; its own icon steps aside. A row
    // with a custom leading (an avatar, a lab logo) keeps it and shows the
    // check after the label instead, so the logo column stays aligned.
    final bool leadCheck = selected && leading == null;
    final Widget row = InkWell(
      onTap: enabled ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Row(
          children: <Widget>[
            if (leading != null)
              leading!
            else if (leadCheck)
              AppIcon(Icons.check, size: 20, color: fg)
            else if (icon != null)
              AppIcon(icon!, size: 20, color: fg),
            if (leading != null || icon != null || leadCheck)
              const SizedBox(width: 14),
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
                      // Emphasized type for the chosen row.
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      style: text.bodySmall?.copyWith(
                        color:
                            (selected
                                    ? scheme.onTertiaryContainer
                                    : scheme.onSurfaceVariant)
                                .withValues(alpha: enabled ? 1 : 0.5),
                      ),
                    ),
                ],
              ),
            ),
            if (trailing != null) ...<Widget>[
              const SizedBox(width: 12),
              trailing!,
            ] else if (selected && !leadCheck) ...<Widget>[
              const SizedBox(width: 12),
              AppIcon(Icons.check, size: 20, color: fg),
            ],
            if (shortcut != null) ...<Widget>[
              const SizedBox(width: 16),
              Text(
                shortcut!,
                style: text.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
    // Every row's ink, and the selected pill, sit inset in the group
    // container with a smaller corner, as in the spec's vertical menu.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: kMenuRowInset),
      child: Material(
        type: selected ? MaterialType.canvas : MaterialType.transparency,
        color: selected ? scheme.tertiaryContainer : null,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kMenuInnerRadius),
        ),
        child: row,
      ),
    );
  }
}

/// A menu as a bottom sheet: the house sheet chrome, then the same tiles a
/// dropdown is made of. What a long press opens on a phone and what a click
/// opens on a pointer are then the same menu in two places.
///
/// On a wide window a bottom sheet runs edge to edge under the sidebar and the
/// chat alike, so there the same content opens as a centred card instead,
/// the width of a phone sheet.
Future<T?> showMenuSheet<T>(
  BuildContext context, {
  required List<List<Widget>> groups,
  Widget? header,
  Color? color,
}) {
  final ColorScheme scheme = Theme.of(context).colorScheme;
  final Size screen = MediaQuery.of(context).size;
  Widget body({required bool handle}) => Column(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      if (handle) ...<Widget>[
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
      ],
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
  );

  if (screen.width >= kCompactModeBreakpoint) {
    return showDialog<T>(
      context: context,
      // The navigator the bottom sheet uses, so a tile that pops through
      // its own context closes the same route at both widths.
      useRootNavigator: false,
      builder: (BuildContext dialogContext) => Dialog(
        backgroundColor: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        insetPadding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 520,
            maxHeight: screen.height * 0.7,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
            child: body(handle: false),
          ),
        ),
      ),
    );
  }

  return showModalBottomSheet<T>(
    context: context,
    // A long list scrolls inside the sheet instead of pushing it to the top
    // of the screen.
    constraints: BoxConstraints(maxHeight: screen.height * 0.8),
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
        child: body(handle: true),
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
