/// The reference messenger's chat-open animation, driven by a progress value
/// instead of by a route.
///
/// The reference (`~/git/messenager/lib/screens/chats_page.dart`,
/// `ConversationTile.build`) wraps every conversation row in an `OpenContainer`
/// from the `animations` package: a Material container transform, so the chat
/// grows out of the row it was tapped on and shrinks back into it. Its
/// settings there are 300 ms, [ContainerTransitionType.fade], a closed shape of
/// radius 30, no elevation, a transparent closed colour and the surface colour
/// open.
///
/// Agents cannot use `OpenContainer` itself, because `openBuilder` builds the
/// open child as a ROUTE. The phone thread here is not a route: it hosts
/// `AgentsThreadView`, which owns the relay socket, so it must stay mounted
/// whether or not a chat is open (see `messenger_shell.dart`). This widget is
/// therefore the geometry of `_OpenContainerRoute.buildPage` — the same rect
/// tween, the same `Curves.fastOutSlowIn` (flipped on the way back), the same
/// fifths for the colour and the opacity, the same `FittedBox(fitWidth,
/// topLeft)` on both children, the same `black54` scrim — over one shell-owned
/// progress value. Same animation, one thread view.
library;

import 'package:flutter/material.dart';

/// One tapped roster row, as the container transform needs it: where the row
/// is on the screen, and a copy of it to fade out inside the growing rect.
@immutable
class ContainerTransformSource {
  const ContainerTransformSource({required this.rect, required this.child});

  /// The row's rounded rect, in the coordinates of the shell's phone body.
  final Rect rect;

  /// A copy of the row, drawn inside the growing container while the real row
  /// is hidden in the list underneath. Built without its outer padding, so it
  /// fills [rect] exactly.
  final Widget child;
}

/// The container transform: [closed] grows into [open] over [progress].
class MobileContainerTransform extends StatelessWidget {
  const MobileContainerTransform({
    super.key,
    required this.progress,
    required this.reverse,
    required this.openSize,
    required this.open,
    required this.openColor,
    this.closed,
  });

  /// The reference's `transitionDuration`.
  static const Duration duration = Duration(milliseconds: 300);

  /// The reference's `closedShape` radius.
  static const double closedRadius = 30;

  /// Linear travel, 0 (closed, sitting on the row) to 1 (open, full screen).
  /// Linear on purpose: the rect and the shape read a curved value, the colour
  /// and the opacity read this one, exactly as the package does.
  final double progress;

  /// True while [progress] is falling. The curve is flipped then, and the
  /// colour and the opacity cross the FOURTH fifth instead of the second —
  /// the package's `_FlippableTweenSequence`.
  final bool reverse;

  /// The open state: the whole phone body.
  final Size openSize;

  final Widget open;
  final Color openColor;

  /// The row the travel starts from. Null before any row has been tapped (a
  /// restored selection, a notification): the transform then degenerates into
  /// a plain fade over the full screen, which is the honest answer when there
  /// is no row to grow out of.
  final ContainerTransformSource? closed;

  @override
  Widget build(BuildContext context) {
    final double t = progress.clamp(0.0, 1.0);
    final Rect openRect = Offset.zero & openSize;
    final Rect closedRect = closed?.rect ?? openRect;

    // `Curves.fastOutSlowIn`, flipped on the way back: the package's
    // `CurvedAnimation(curve: fastOutSlowIn, reverseCurve: fastOutSlowIn.flipped)`.
    final double c = reverse
        ? Curves.fastOutSlowIn.flipped.transform(t)
        : Curves.fastOutSlowIn.transform(t);

    final Rect rect = Rect.lerp(closedRect, openRect, c)!;
    final double radius = closedRadius * (1 - c);

    // The fade type's colour and open-opacity sequences: a fifth of nothing,
    // a fifth of crossing, then done. Flipped means the crossing fifth moves
    // to 3/5..4/5, which is the same fifth of wall-clock time coming back.
    final double fadeStart = reverse ? 3 / 5 : 1 / 5;
    final double f = ((t - fadeStart) * 5).clamp(0.0, 1.0);
    final Color color = Color.lerp(Colors.transparent, openColor, f)!;

    // The scrim: fading in over the first fifth of the curve, fading out
    // straight down the curve (`_scrimFadeInTween` / `_scrimFadeOutTween`).
    final Color scrim = Color.lerp(
      Colors.transparent,
      Colors.black54,
      reverse ? c : (c * 5).clamp(0.0, 1.0),
    )!;

    return SizedBox.expand(
      child: ColoredBox(
        color: scrim,
        child: Align(
          alignment: Alignment.topLeft,
          child: Transform.translate(
            offset: Offset(rect.left, rect.top),
            child: SizedBox(
              width: rect.width,
              height: rect.height,
              child: Material(
                // Nothing to clip once the container is the screen, and an
                // antialiased full-screen clip on every resting frame is not
                // free.
                clipBehavior: t >= 1 ? Clip.none : Clip.antiAlias,
                animationDuration: Duration.zero,
                color: color,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(radius),
                ),
                child: Stack(
                  fit: StackFit.passthrough,
                  children: <Widget>[
                    // The row, fading out under the open child. The reference's
                    // fade type keeps it at full opacity and lets the colour
                    // and the open child cover it.
                    FittedBox(
                      fit: BoxFit.fitWidth,
                      alignment: Alignment.topLeft,
                      child: SizedBox(
                        width: closedRect.width,
                        height: closedRect.height,
                        // Gone once the travel is over: at rest this would be
                        // a full-width copy of a row nobody can see.
                        child: t >= 1 || closed == null
                            ? null
                            : IgnorePointer(child: closed!.child),
                      ),
                    ),
                    // The thread, fading in. Laid out at the open size the
                    // whole way, so it never reflows mid-travel.
                    FittedBox(
                      fit: BoxFit.fitWidth,
                      alignment: Alignment.topLeft,
                      child: SizedBox(
                        width: openRect.width,
                        height: openRect.height,
                        // Never a hard zero: an opacity of zero skips the
                        // paint, so the thread's first raster would land in the
                        // middle of the travel and eat most of it. A thousandth
                        // is invisible and keeps the raster on the parked frame.
                        child: Opacity(
                          opacity: f == 0 ? 0.001 : f,
                          child: open,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
