// lib/widgets/anchored_menu.dart
//
// A dropdown anchored to the button that opened it. It rises from below,
// it takes no focus, and it never lands behind the keyboard.
//
// `showMenu` cannot do this. It always grows downwards from the anchor and
// measures against the whole screen — the keyboard is `viewInsets`, not
// `padding`, and the popup layout ignores it — so a menu opened from the
// composer ends up under the keyboard. Owning the route also means the
// menu's real height decides where it goes, with nothing estimated.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:chuk_chat/widgets/menu_tile_group.dart';

/// Gap between the anchor and the menu.
const double _kAnchorGap = 6;

/// Smallest margin the menu keeps to the screen edges and the keyboard.
const double _kEdgeMargin = 8;

/// Below this, "open above" is not worth forcing — the menu would be a
/// two-row scroller squeezed against the top edge.
const double _kMinRoomAbove = 120;

const Duration _kMenuDuration = Duration(milliseconds: 140);

/// Show [items] as a dropdown anchored to the widget of [anchorContext].
///
/// Returns the chosen value, or null when the menu is dismissed.
Future<T?> showAnchoredMenu<T>(
  BuildContext anchorContext, {
  required List<Widget> items,
  required Color color,
  required Color borderColor,
  double minWidth = 200,
  double borderRadius = 18,
  bool preferAbove = false,
  // null → pick the side from the anchor's screen position (a control on the
  // right opens leftwards). true → align the menu's right edge to the anchor
  // (open leftwards). false → align left edges (open rightwards, for a
  // right-cascading submenu).
  bool? alignRight,
  // Global position of the press. Given, the menu opens there instead of at
  // the anchor widget.
  Offset? anchorPoint,
  // A cascading submenu: open beside the anchor (to its right, or to its left
  // when the right would run off screen) with the top edges aligned, the way
  // a native submenu flies out of its parent row.
  bool besideAnchor = false,
  // Draw the frame around the whole menu. An action menu is a run of loose
  // tiles and wants none; a picker — the model and mode menus — is a list
  // being read against the chat behind it, and there the frame is what says
  // where the list ends.
  bool outlined = false,
}) {
  final RenderBox? box = anchorContext.findRenderObject() as RenderBox?;
  final NavigatorState navigator = Navigator.of(anchorContext);
  final RenderBox? overlay =
      Overlay.of(anchorContext).context.findRenderObject() as RenderBox?;
  if (box == null || !box.hasSize || overlay == null) {
    return Future<T?>.value();
  }

  // Both media queries matter. A Scaffold that resizes for the keyboard
  // removes the inset from everything below it, so the anchor no longer
  // knows the keyboard is there; the overlay, which sits above it, still
  // does. Take whichever inset is real.
  final MediaQueryData media = MediaQuery.of(anchorContext);
  final MediaQueryData overlayMedia = MediaQuery.of(navigator.context);

  final Offset topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
  final Offset overlayTopLeft = overlay.localToGlobal(Offset.zero);
  // A press anchors the menu where the finger was, not to the whole row: a
  // long press on a list tile should open under the thumb, not at the tile's
  // corner or at the bottom of the screen.
  final Rect anchor = anchorPoint == null
      ? topLeft & box.size
      : Rect.fromLTWH(
          anchorPoint.dx - overlayTopLeft.dx,
          anchorPoint.dy - overlayTopLeft.dy,
          0,
          0,
        );

  final double bottomInset = <double>[
    media.viewInsets.bottom,
    media.padding.bottom,
    overlayMedia.viewInsets.bottom,
    overlayMedia.padding.bottom,
  ].reduce(math.max);

  return navigator.push(
    _AnchoredMenuRoute<T>(
      anchor: anchor,
      items: items,
      color: color,
      borderColor: borderColor,
      minWidth: minWidth,
      borderRadius: borderRadius,
      preferAbove: preferAbove,
      alignRight: alignRight,
      besideAnchor: besideAnchor,
      outlined: outlined,
      usableTop:
          math.max(media.padding.top, overlayMedia.padding.top) + _kEdgeMargin,
      usableBottom: overlay.size.height - bottomInset - _kEdgeMargin,
      themes: InheritedTheme.capture(
        from: anchorContext,
        to: navigator.context,
      ),
    ),
  );
}

class _AnchoredMenuRoute<T> extends PopupRoute<T> {
  _AnchoredMenuRoute({
    required this.anchor,
    required this.items,
    required this.color,
    required this.borderColor,
    required this.minWidth,
    required this.borderRadius,
    required this.preferAbove,
    required this.alignRight,
    required this.besideAnchor,
    required this.outlined,
    required this.usableTop,
    required this.usableBottom,
    required this.themes,
    // The menu has nothing to do with the keyboard. Taking the focus is
    // what pulled the keyboard down and made the composer jump, so this
    // route does not take it: whatever had the focus keeps it, and the
    // keyboard stays open or closed exactly as the reader left it.
  }) : super(requestFocus: false);

  final Rect anchor;
  final List<Widget> items;
  final Color color;
  final Color borderColor;
  final double minWidth;
  final double borderRadius;
  final bool preferAbove;
  final bool? alignRight;
  final bool besideAnchor;
  final bool outlined;
  final double usableTop;
  final double usableBottom;
  final CapturedThemes themes;

  @override
  Duration get transitionDuration => _kMenuDuration;

  @override
  bool get barrierDismissible => true;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => 'Dismiss';

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, _) {
    return themes.wrap(
      CustomSingleChildLayout(
        delegate: _AnchoredMenuLayout(
          anchor: anchor,
          usableTop: usableTop,
          usableBottom: usableBottom,
          preferAbove: preferAbove,
          alignRight: alignRight,
          besideAnchor: besideAnchor,
        ),
        // No box around the menu: every row is its own filled tile, and a
        // divider becomes the gap that starts the next run. See
        // [MenuTileGroup].
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: minWidth),
          child: IntrinsicWidth(
            child: Semantics(
              role: SemanticsRole.menu,
              scopesRoute: true,
              namesRoute: true,
              explicitChildNodes: true,
              child: ScrollConfiguration(
                // No scrollbar over the menu — it looked messy on desktop.
                behavior:
                    ScrollConfiguration.of(context).copyWith(scrollbars: false),
                child: SingleChildScrollView(
                  child: _frame(
                    MenuTileGroup(
                      groups: _splitOnDividers(items),
                      color: color,
                      outerRadius: borderRadius,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The frame, when the caller asked for one. The tiles keep their own
  /// shape inside it; the border only closes the list off from the chat
  /// behind it. Its radius clears the tiles by the padding, so the corners
  /// run parallel instead of cutting across them.
  Widget _frame(Widget child) {
    if (!outlined) return child;
    const double pad = 3;
    return Container(
      padding: const EdgeInsets.all(pad),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(borderRadius + pad),
        border: Border.all(color: borderColor, width: 2),
      ),
      // A list that runs to the frame's edge must be cut by the frame's
      // corners. Without this the last row is sliced off square and the
      // panel reads as a rendering fault rather than as a scroller.
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // Fade only. The menu used to rise into place, and the distance it rose
    // was a fraction of its own height — a short menu barely moved, a long
    // one flew in. It now appears where it will stay.
    return FadeTransition(
      opacity: CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      ),
      child: child,
    );
  }
}

/// Puts the menu above the anchor when it does not fit below it. The child
/// is measured first, so nothing here is guessed.
class _AnchoredMenuLayout extends SingleChildLayoutDelegate {
  const _AnchoredMenuLayout({
    required this.anchor,
    required this.usableTop,
    required this.usableBottom,
    this.preferAbove = false,
    this.alignRight,
    this.besideAnchor = false,
  });

  final Rect anchor;
  final double usableTop;
  final double usableBottom;

  /// Which edge the menu aligns to; null means pick from the anchor position.
  final bool? alignRight;

  /// A cascade: sit beside the anchor (right, or left if right runs off) with
  /// the top edges aligned, instead of above/below it.
  final bool besideAnchor;

  /// Open above the anchor whenever the menu fits there, even when there is
  /// more room below. The desktop composer sits at the bottom of a tall
  /// window: a menu that drops down covers the box it belongs to.
  final bool preferAbove;

  double get _roomBelow => usableBottom - anchor.bottom - _kAnchorGap;
  double get _roomAbove => anchor.top - usableTop - _kAnchorGap;

  /// Honour [preferAbove] only while there is room worth using up there.
  /// A menu forced into 30 pixels is worse than one that drops down.
  bool get _forceAbove => preferAbove && _roomAbove >= _kMinRoomAbove;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return BoxConstraints.loose(
      Size(
        constraints.maxWidth - _kEdgeMargin * 2,
        _forceAbove
            ? _roomAbove
            : math.max(48, math.max(_roomAbove, _roomBelow)),
      ),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final double maxXAll =
        math.max(_kEdgeMargin, size.width - _kEdgeMargin - childSize.width);
    // Cascade: sit to the right of the anchor, or flip to the left when the
    // right side would run off screen. Top edges aligned.
    if (besideAnchor) {
      final double toRight = anchor.right + _kAnchorGap;
      final double toLeft = anchor.left - _kAnchorGap - childSize.width;
      final double x =
          (toRight + childSize.width <= size.width - _kEdgeMargin || toLeft < _kEdgeMargin)
              ? toRight
              : toLeft;
      return Offset(
        x.clamp(_kEdgeMargin, maxXAll),
        anchor.top.clamp(
          usableTop,
          math.max(usableTop, usableBottom - childSize.height),
        ),
      );
    }

    final bool openDown = !_forceAbove &&
        (childSize.height <= _roomBelow || _roomBelow >= _roomAbove);
    final double y = openDown
        ? anchor.bottom + _kAnchorGap
        : anchor.top - _kAnchorGap - childSize.height;

    // Anchor the menu to the near edge of the control: a control on the
    // right side of the screen opens leftwards (right edges aligned) so the
    // menu never runs off toward the centre; one on the left opens rightwards
    // as before. Then clamp so it always stays on screen.
    final double maxX = math.max(_kEdgeMargin, size.width - _kEdgeMargin - childSize.width);
    final bool ar = alignRight ?? (anchor.right > size.width * 0.6);
    final double x = ar
        ? anchor.right - childSize.width
        : anchor.left;
    return Offset(
      x.clamp(_kEdgeMargin, maxX),
      y.clamp(usableTop, math.max(usableTop, usableBottom - childSize.height)),
    );
  }

  @override
  bool shouldRelayout(_AnchoredMenuLayout old) =>
      anchor != old.anchor ||
      usableTop != old.usableTop ||
      usableBottom != old.usableBottom ||
      preferAbove != old.preferAbove ||
      alignRight != old.alignRight ||
      besideAnchor != old.besideAnchor;
}

/// Splits a flat item list into runs at every divider, so a divider becomes
/// a gap between two groups of tiles instead of a drawn line.
List<List<Widget>> _splitOnDividers(List<Widget> items) {
  final groups = <List<Widget>>[<Widget>[]];
  for (final item in items) {
    if (item is Divider || item is PopupMenuDivider) {
      if (groups.last.isNotEmpty) groups.add(<Widget>[]);
      continue;
    }
    groups.last.add(item);
  }
  return groups.where((run) => run.isNotEmpty).toList(growable: false);
}
