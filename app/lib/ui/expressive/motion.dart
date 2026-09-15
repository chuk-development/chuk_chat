/// Material 3 Expressive motion: the springs, the press-and-morph surface and
/// the buttons built on it.
///
/// One rule drives the whole language: a tappable surface SPRINGS (scale) and
/// MORPHS (shape) while it is held, and it comes back on a spring, not on a
/// curve. [MorphTap] is that surface; every expressive button in the app wraps
/// it, so a press feels the same everywhere.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:chuk_chat/ui/expressive/icon_map.dart';

import 'package:chuk_chat/ui/expressive/huge_icon.dart';
import 'package:flutter/physics.dart';

/// The bouncy spatial spring used for press and selection feedback.
/// The curve for widgets that cannot take a spring.
///
/// [AnimatedContainer], [AnimatedOpacity] and friends interpolate along a
/// [Curve]; they have no place to put a [SpringSimulation]. Left without a
/// `curve:` they run on [Curves.linear], which reads as mechanical next to the
/// spring everything else uses. This is M3's emphasized-decelerate shape: it
/// leaves fast and settles slowly, which is the half of a spring the eye
/// actually reads.
const Cubic kExpressiveDecelerate = Cubic(0.05, 0.7, 0.1, 1.0);

/// The matching duration. Long enough to be seen, short enough not to be
/// waited for.
const Duration kExpressiveShort = Duration(milliseconds: 180);

const SpringDescription kSpatialSpring = SpringDescription(
  mass: 1,
  stiffness: 420,
  damping: 22,
);

/// A snappier spring for small effects (icons, indicators).
const SpringDescription kEffectSpring = SpringDescription(
  mass: 1,
  stiffness: 600,
  damping: 26,
);

/// A surface that springs and morphs on press. Wrap ANY tappable element.
class MorphTap extends StatefulWidget {
  const MorphTap({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.color,
    this.pressedColor,
    this.shape = const StadiumBorder(),
    this.pressedShape,
    this.pressedOutline,
    this.pressedOutlineWidth = 1.5,
    this.padding = EdgeInsets.zero,
    this.pressedScale = 0.93,
    this.instant = false,
    this.hitPadding = EdgeInsets.zero,
  }) : assert(
         hitPadding == EdgeInsets.zero || instant,
         'hitPadding is the area the Listener covers; only instant taps use it',
       );

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Color? color;

  /// The colour the surface fades toward while held. Null keeps [color].
  final Color? pressedColor;
  final ShapeBorder shape;

  /// The shape the surface morphs toward while held. Defaults to a blockier
  /// version of [shape].
  final ShapeBorder? pressedShape;

  /// An outline drawn in the current shape while the surface is held. A
  /// surface with no fill of its own needs it: without it a press on such a
  /// surface shows nothing but a scale, and the user cannot see which shape
  /// the target is about to take. It fades in with the press and out with it.
  final Color? pressedOutline;
  final double pressedOutlineWidth;
  final EdgeInsetsGeometry padding;
  final double pressedScale;

  /// Commit the tap on pointer DOWN instead of on a recognised tap.
  ///
  /// An [InkWell] hands its tap to the gesture arena, and the arena gives the
  /// gesture to the scroll view the moment the finger travels a few pixels.
  /// On a segment inside a scrolling page that reads as a control that does
  /// nothing: the press shows, the selection never happens. A control whose
  /// whole job is to switch — the navigation pill, the filter pill — cannot
  /// afford that, so it takes the press itself, from a [Listener], and no
  /// arena can take it back. There is no ink splash in this mode; the spring
  /// and the fill that lands at once are the feedback.
  ///
  /// One physical press calls [onTap] exactly once, whether it ends as a tap,
  /// a drag or a cancel. The screen-reader tap is a semantics action, not a
  /// pointer, so it does not go through the [Listener] and cannot double up.
  final bool instant;

  /// Transparent room around the surface that still takes the press. Only an
  /// [instant] tap has it, because only there does the whole box hit-test.
  /// It lets a capsule paint smaller than the target a finger has to hit.
  final EdgeInsets hitPadding;

  @override
  State<MorphTap> createState() => _MorphTapState();
}

class _MorphTapState extends State<MorphTap>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController.unbounded(
    vsync: this,
    value: 0,
  );

  ShapeBorder get _pressed =>
      widget.pressedShape ??
      (widget.shape is RoundedRectangleBorder
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: (widget.shape as RoundedRectangleBorder).side,
            )
          : RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)));

  /// Reduced motion: the press still happens, it just does not travel.
  bool _reducedMotion = false;

  /// The pointer that owns the press in [MorphTap.instant] mode. A second
  /// finger landing on the same segment is not a second selection.
  int? _pointer;

  void _instantDown(PointerDownEvent event) {
    if (_pointer != null) {
      return;
    }
    _pointer = event.pointer;
    _press(true);
    // The selection is committed here, before any arena can claim the
    // gesture. Nothing later in this pointer's life calls it again.
    widget.onTap?.call();
  }

  void _instantRelease(PointerEvent event) {
    if (_pointer != event.pointer) {
      return;
    }
    _pointer = null;
    _press(false);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reducedMotion = MediaQuery.disableAnimationsOf(context);
    if (_reducedMotion && _c.isAnimating) {
      _c.stop();
      _c.value = _c.value >= 0.5 ? 1 : 0;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _press(bool down) {
    if (_reducedMotion) {
      _c.value = down ? 1 : 0;
      return;
    }
    if (down) {
      _c.animateTo(
        1,
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOut,
      );
    } else {
      _c.animateWith(SpringSimulation(kSpatialSpring, _c.value, 0, 0));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (BuildContext context, Widget? _) {
        final double t = _c.value.clamp(0.0, 1.0);
        final ShapeBorder shape = ShapeBorder.lerp(widget.shape, _pressed, t)!;
        final double scale = 1 - (1 - widget.pressedScale) * t;
        final Color resting = widget.color ?? Colors.transparent;
        final Color fill = widget.pressedColor == null
            ? resting
            : Color.lerp(resting, widget.pressedColor, t)!;
        Widget surface = PhysicalShape(
          clipper: ShapeBorderClipper(shape: shape),
          color: fill,
          elevation: 0,
          shadowColor: Colors.transparent,
          child: widget.instant
              // No ink well: its tap is exactly what this mode replaces, and
              // an arena that cannot claim the gesture cannot splash either.
              ? Padding(padding: widget.padding, child: widget.child)
              : Material(
                  type: MaterialType.transparency,
                  child: InkWell(
                    customBorder: shape,
                    onTap: widget.onTap,
                    onLongPress: widget.onLongPress,
                    onHighlightChanged: _press,
                    child: Padding(
                      padding: widget.padding,
                      child: widget.child,
                    ),
                  ),
                ),
        );
        final Color? outline = widget.pressedOutline;
        if (outline != null && t > 0) {
          surface = CustomPaint(
            foregroundPainter: _PressOutlinePainter(
              shape: shape,
              color: outline.withValues(alpha: outline.a * t),
              width: widget.pressedOutlineWidth,
            ),
            child: surface,
          );
        }
        if (widget.instant) {
          surface = Semantics(
            button: true,
            onTap: widget.onTap,
            onLongPress: widget.onLongPress,
            child: Listener(
              // Opaque so the transparent hit padding takes the press too.
              behavior: HitTestBehavior.opaque,
              onPointerDown: _instantDown,
              onPointerUp: _instantRelease,
              onPointerCancel: _instantRelease,
              child: Padding(padding: widget.hitPadding, child: surface),
            ),
          );
        }
        return Transform.scale(scale: scale, child: surface);
      },
    );
  }
}

/// Draws [MorphTap.pressedOutline] along the shape the surface currently has.
///
/// The stroke straddles the path, so the path is taken from a rect deflated by
/// half the stroke: the outline then sits inside the surface and keeps the
/// capsule exactly as wide as the capsule a selection fills.
class _PressOutlinePainter extends CustomPainter {
  const _PressOutlinePainter({
    required this.shape,
    required this.color,
    required this.width,
  });

  final ShapeBorder shape;
  final Color color;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect rect = (Offset.zero & size).deflate(width / 2);
    if (rect.isEmpty) {
      return;
    }
    canvas.drawPath(
      shape.getOuterPath(rect),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_PressOutlinePainter old) =>
      old.color != color || old.width != width || old.shape != shape;
}

/// A fully rounded button that springs and morphs on press.
class ExpressiveButton extends StatelessWidget {
  const ExpressiveButton({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
    this.color,
    this.onColor,
    this.tonal = false,
  });

  final IconData? icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;
  final Color? onColor;
  final bool tonal;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color bg =
        color ?? (tonal ? scheme.secondaryContainer : scheme.primary);
    final Color fg =
        onColor ?? (tonal ? scheme.onSecondaryContainer : scheme.onPrimary);
    return MorphTap(
      onTap: onTap,
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 16),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            AppIcon(icon, color: fg, size: 20),
            const SizedBox(width: 10),
          ],
          Text(
            label,
            style: TextStyle(
              color: fg,
              fontWeight: FontWeight.w700,
              fontSize: 15,
            ),
          ),
        ],
      ),
    );
  }
}

/// The expressive icon target: a soft squircle that squashes a touch more
/// square while held. Used for every round chip in the floating chrome.
///
/// [onTap] null renders the target disabled — dimmed glyph, no ink, no spring.
/// [parked] renders the same dimmed look but keeps the tap, so a feature that
/// does not exist yet can hold its place and say so when it is pressed. That is
/// how the voice-call button in the chat header is shown.
class ExpressiveIconButton extends StatelessWidget {
  const ExpressiveIconButton({
    super.key,
    this.icon,
    this.hugeIcon,
    required this.onTap,
    this.color,
    this.onColor,
    this.size = 48,
    this.width,
    this.tooltip,
    this.semanticsId,
    this.parked = false,
  });

  /// A Material glyph. Kept for the screens that have not been moved over yet;
  /// new code passes [hugeIcon].
  final IconData? icon;

  /// The app's own set (docs/DESIGN.md). Wins when both are given.
  final HugeIconData? hugeIcon;

  /// Null disables the button.
  final VoidCallback? onTap;
  final Color? color;
  final Color? onColor;
  final double size;

  /// The painted width. Null keeps the square target; a wider value makes the
  /// oval the home bar uses, and the oval then carries fully round ends so it
  /// reads as a shorter sibling of the pill beside it.
  final double? width;

  final String? tooltip;
  final String? semanticsId;

  /// A target for a feature that is not available yet: it looks disabled and it
  /// still calls [onTap], which is expected to explain why.
  final bool parked;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool enabled = onTap != null && !parked;
    final Color fill = color ?? scheme.surfaceContainerHighest;
    final Color glyph = onColor ?? scheme.onSurfaceVariant;
    final double boxWidth = width ?? size;
    final bool oval = boxWidth != size;
    Widget button = MorphTap(
      onTap: onTap,
      pressedScale: parked ? 0.98 : 0.93,
      color: enabled ? fill : fill.withValues(alpha: 0.5),
      // An oval stays an oval while the finger is down, the way the connected
      // group does; only the square target squares off further.
      shape: oval
          ? const StadiumBorder()
          : RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(size * 0.34),
            ),
      pressedShape: oval
          ? const StadiumBorder()
          : RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(size * 0.20),
            ),
      padding: EdgeInsets.symmetric(
        horizontal: (boxWidth - 22) / 2,
        vertical: (size - 22) / 2,
      ),
      child: hugeIcon != null
          ? HugeIcon(
              hugeIcon!,
              size: 22,
              color: enabled ? glyph : glyph.withValues(alpha: 0.38),
            )
          : AppIcon(
              icon,
              size: 22,
              color: enabled ? glyph : glyph.withValues(alpha: 0.38),
            ),
    );
    if (tooltip != null) {
      button = Tooltip(message: tooltip!, child: button);
    }
    return Semantics(
      identifier: semanticsId,
      button: true,
      enabled: enabled,
      label: tooltip,
      child: button,
    );
  }
}

/// The expressive spinner: a cookie blob that turns while its scallop depth
/// pulses. Replaces a plain [CircularProgressIndicator] on expressive surfaces.
class ExpressiveLoader extends StatefulWidget {
  const ExpressiveLoader({super.key, this.size = 48, this.color});

  final double size;
  final Color? color;

  @override
  State<ExpressiveLoader> createState() => _ExpressiveLoaderState();
}

class _ExpressiveLoaderState extends State<ExpressiveLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Color color = widget.color ?? Theme.of(context).colorScheme.primary;
    return AnimatedBuilder(
      animation: _c,
      builder: (BuildContext context, Widget? _) => SizedBox(
        width: widget.size,
        height: widget.size,
        child: CustomPaint(
          painter: _BlobPainter(t: _c.value, color: color),
        ),
      ),
    );
  }
}

class _BlobPainter extends CustomPainter {
  _BlobPainter({required this.t, required this.color});

  final double t;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset centre = size.center(Offset.zero);
    final double base = size.shortestSide / 2;
    final double pulse = 0.10 + 0.06 * (0.5 + 0.5 * math.sin(t * 2 * math.pi));
    final double rot = t * 2 * math.pi;
    final Path path = Path();
    const int steps = 120;
    for (int i = 0; i <= steps; i++) {
      final double a = (i / steps) * 2 * math.pi + rot;
      final double r =
          base * (1 - pulse) + base * pulse * math.cos(6 * (a - rot));
      final Offset p = Offset(
        centre.dx + r * math.cos(a),
        centre.dy + r * math.sin(a),
      );
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    path.close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_BlobPainter old) => old.t != t || old.color != color;
}
