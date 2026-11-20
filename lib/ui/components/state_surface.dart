// lib/ui/components/state_surface.dart
//
// The one interactive surface of a list item: its fill, its shape and its
// state layer (hover, focus, press, selection).
//
// Before this, each list drew its own: the sidebar card changed its fill on
// hover, the settings tile rounded every corner on a press, a menu row put a
// rectangular ink on a rounded pill. The same item then showed one shape on
// hover and another when pressed or selected. Here every state paints inside
// the same shape, so they cannot drift apart again.

import 'package:flutter/material.dart';

import 'package:chuk_chat/constants.dart';

/// The outer corner of a group of list items (a sidebar block, a settings
/// group): the first and the last item of a group round outwards with it.
const double kListItemRadius = kRadiusXl;

/// The corner where two items of one group meet.
const double kListItemJointRadius = 6;

/// The gap between two items of one group.
const double kListItemGap = 3;

/// The corners of the item at [index] in a group of [length] items: the
/// outer corners of the group are [outer], the joints between items are
/// [joint]. [joinTop] makes the first item continue a surface above it
/// (a tight top edge instead of a round one).
BorderRadius listItemRadius({
  required int index,
  required int length,
  bool joinTop = false,
  double outer = kListItemRadius,
  double joint = kListItemJointRadius,
}) {
  final Radius o = Radius.circular(outer);
  final Radius j = Radius.circular(joint);
  final bool first = index == 0;
  final bool last = index == length - 1;
  final Radius top = first && !joinTop ? o : j;
  final Radius bottom = last ? o : j;
  return BorderRadius.only(
    topLeft: top,
    topRight: top,
    bottomLeft: bottom,
    bottomRight: bottom,
  );
}

/// The state layer every list item uses: the theme's `onSurface` at the
/// Material 3 opacities (hover 8 %, focus and press 10 %).
///
/// [hoverLayer] false leaves the hover out, for a surface that shows hover
/// as its own fill ([StateSurface.hoverColor]).
WidgetStateProperty<Color?> listItemStateLayer(
  ThemeData theme, {
  bool hoverLayer = true,
}) {
  final Color on = theme.colorScheme.onSurface;
  return WidgetStateProperty.resolveWith<Color?>((Set<WidgetState> states) {
    if (states.contains(WidgetState.pressed)) {
      return on.withValues(alpha: 0.10);
    }
    if (states.contains(WidgetState.focused)) {
      return on.withValues(alpha: 0.10);
    }
    if (hoverLayer && states.contains(WidgetState.hovered)) {
      return on.withValues(alpha: 0.08);
    }
    return null;
  });
}

/// One interactive list item: a fill, one shape, and a state layer.
///
/// Rest, hover, focus, press and selection all paint inside
/// [borderRadius]. The shape never changes with the state. Use it for
/// every row a user can hover, press or select: sidebar items, settings
/// rows, menu items, picker rows and pane rows.
class StateSurface extends StatefulWidget {
  const StateSurface({
    super.key,
    required this.child,
    required this.borderRadius,
    this.color,
    this.selected = false,
    this.selectedColor,
    this.hoverColor,
    this.onTap,
    this.onLongPress,
    this.onLongPressAt,
    this.onSecondaryTapAt,
    this.onHover,
    this.padding = EdgeInsets.zero,
    this.squeeze = false,
    this.enabled = true,
    this.focusNode,
    this.autofocus = false,
    this.minHeight,
  });

  final Widget child;

  /// The one shape of the item in every state.
  final BorderRadius borderRadius;

  /// The fill at rest. Null is transparent.
  final Color? color;

  /// Draws [selectedColor] in place of [color].
  final bool selected;

  /// The fill of a selected item. Null keeps [color].
  final Color? selectedColor;

  /// The fill of a hovered item that is not selected, in place of the hover
  /// layer. For a row whose content needs to know the exact hover colour
  /// (a sidebar card covers its time with the hover fill). Null draws the
  /// hover layer over [color].
  final Color? hoverColor;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// A long press, with the global position of the finger, so a menu can
  /// open where it went down.
  final void Function(Offset globalPosition)? onLongPressAt;

  /// A right click, with the global position of the pointer.
  final void Function(Offset globalPosition)? onSecondaryTapAt;

  /// The pointer enters (true) or leaves (false) the item.
  final ValueChanged<bool>? onHover;

  final EdgeInsetsGeometry padding;

  /// Shrinks the item a little while it is pressed. The shape stays.
  final bool squeeze;

  /// False dims nothing, but takes no input.
  final bool enabled;

  final FocusNode? focusNode;
  final bool autofocus;
  final double? minHeight;

  @override
  State<StateSurface> createState() => _StateSurfaceState();
}

class _StateSurfaceState extends State<StateSurface> {
  bool _pressed = false;
  bool _hovered = false;
  Offset? _lastDown;

  void _setHovered(bool value) {
    widget.onHover?.call(value);
    if (widget.hoverColor == null || _hovered == value) return;
    setState(() => _hovered = value);
  }

  void _setPressed(bool value) {
    if (_pressed == value || !widget.squeeze) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool enabled = widget.enabled;
    final Color fill =
        (widget.selected ? widget.selectedColor : null) ??
        (_hovered && enabled ? widget.hoverColor : null) ??
        widget.color ??
        Colors.transparent;
    final ShapeBorder shape = RoundedRectangleBorder(
      borderRadius: widget.borderRadius,
    );
    final VoidCallback? onLongPress =
        widget.onLongPress == null && widget.onLongPressAt == null
        ? null
        : () {
            widget.onLongPress?.call();
            final Offset? at = _lastDown;
            if (at != null) widget.onLongPressAt?.call(at);
          };
    final void Function(Offset)? secondary = widget.onSecondaryTapAt;
    Widget content = Padding(padding: widget.padding, child: widget.child);
    if (widget.minHeight case final double h) {
      content = ConstrainedBox(
        constraints: BoxConstraints(minHeight: h),
        child: content,
      );
    }
    // No handler: the item only shows its shape and fill. It takes no
    // hits, so a parent that owns the tap (a popup menu item) still gets it.
    final bool interactive =
        widget.onTap != null ||
        onLongPress != null ||
        secondary != null ||
        widget.onHover != null;
    if (!interactive) {
      return DecoratedBox(
        decoration: ShapeDecoration(color: fill, shape: shape),
        child: content,
      );
    }
    Widget surface = Material(
      color: fill,
      shape: shape,
      clipBehavior: Clip.antiAlias,
      animationDuration: const Duration(milliseconds: 130),
      child: InkWell(
        customBorder: shape,
        overlayColor: listItemStateLayer(
          theme,
          hoverLayer: widget.hoverColor == null,
        ),
        focusNode: widget.focusNode,
        autofocus: widget.autofocus,
        onTap: enabled ? widget.onTap : null,
        onLongPress: enabled ? onLongPress : null,
        onSecondaryTapDown: enabled && secondary != null
            ? (TapDownDetails d) => secondary(d.globalPosition)
            : null,
        onTapDown: enabled
            ? (TapDownDetails d) {
                _lastDown = d.globalPosition;
                _setPressed(true);
              }
            : null,
        onTapUp: enabled ? (_) => _setPressed(false) : null,
        onTapCancel: enabled ? () => _setPressed(false) : null,
        onHover: _setHovered,
        child: content,
      ),
    );
    if (widget.squeeze) {
      surface = AnimatedScale(
        scale: _pressed ? 0.985 : 1,
        duration: const Duration(milliseconds: 130),
        curve: Curves.easeOutCubic,
        child: surface,
      );
    }
    return surface;
  }
}
