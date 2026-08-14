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

/// Gap between the anchor and the menu.
const double _kAnchorGap = 6;

/// Smallest margin the menu keeps to the screen edges and the keyboard.
const double _kEdgeMargin = 8;

const Duration _kMenuDuration = Duration(milliseconds: 140);

/// Show [items] as a dropdown anchored to the widget of [anchorContext].
///
/// Returns the chosen value, or null when the menu is dismissed.
Future<T?> showAnchoredMenu<T>(
  BuildContext anchorContext, {
  required List<PopupMenuEntry<T>> items,
  required Color color,
  required Color borderColor,
  double minWidth = 200,
  double borderRadius = 18,
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
  final Rect anchor = topLeft & box.size;

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
    required this.usableTop,
    required this.usableBottom,
    required this.themes,
    // The menu has nothing to do with the keyboard. Taking the focus is
    // what pulled the keyboard down and made the composer jump, so this
    // route does not take it: whatever had the focus keeps it, and the
    // keyboard stays open or closed exactly as the reader left it.
  }) : super(requestFocus: false);

  final Rect anchor;
  final List<PopupMenuEntry<T>> items;
  final Color color;
  final Color borderColor;
  final double minWidth;
  final double borderRadius;
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
        ),
        child: Material(
          color: color,
          // Without a clip the ink of a tapped row is a plain rectangle
          // and its corners stick out of the rounded menu.
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(borderRadius),
            side: BorderSide(color: borderColor, width: 2),
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: minWidth),
            child: IntrinsicWidth(
              child: Semantics(
                role: SemanticsRole.menu,
                scopesRoute: true,
                namesRoute: true,
                explicitChildNodes: true,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: ListBody(children: items),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final CurvedAnimation curve = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      opacity: curve,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.12),
          end: Offset.zero,
        ).animate(curve),
        child: child,
      ),
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
  });

  final Rect anchor;
  final double usableTop;
  final double usableBottom;

  double get _roomBelow => usableBottom - anchor.bottom - _kAnchorGap;
  double get _roomAbove => anchor.top - usableTop - _kAnchorGap;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return BoxConstraints.loose(
      Size(
        constraints.maxWidth - _kEdgeMargin * 2,
        math.max(48, math.max(_roomAbove, _roomBelow)),
      ),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final bool openDown =
        childSize.height <= _roomBelow || _roomBelow >= _roomAbove;
    final double y = openDown
        ? anchor.bottom + _kAnchorGap
        : anchor.top - _kAnchorGap - childSize.height;

    // Aligned to the anchor's left edge, pushed back on screen when the
    // menu is wider than the room to the right of it.
    final double maxX = size.width - _kEdgeMargin - childSize.width;
    return Offset(
      math.max(_kEdgeMargin, math.min(anchor.left, maxX)),
      y.clamp(usableTop, math.max(usableTop, usableBottom - childSize.height)),
    );
  }

  @override
  bool shouldRelayout(_AnchoredMenuLayout old) =>
      anchor != old.anchor ||
      usableTop != old.usableTop ||
      usableBottom != old.usableBottom;
}
