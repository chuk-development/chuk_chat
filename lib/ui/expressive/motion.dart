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

import 'package:cowork/ui/expressive/icon_map.dart';

import 'package:cowork/ui/expressive/huge_icon.dart';
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
    this.padding = EdgeInsets.zero,
    this.pressedScale = 0.93,
  });

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
  final EdgeInsetsGeometry padding;
  final double pressedScale;

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
        return Transform.scale(
          scale: scale,
          child: PhysicalShape(
            clipper: ShapeBorderClipper(shape: shape),
            color: fill,
            elevation: 0,
            shadowColor: Colors.transparent,
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                customBorder: shape,
                onTap: widget.onTap,
                onLongPress: widget.onLongPress,
                onHighlightChanged: _press,
                child: Padding(padding: widget.padding, child: widget.child),
              ),
            ),
          ),
        );
      },
    );
  }
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
    Widget button = MorphTap(
      onTap: onTap,
      pressedScale: parked ? 0.98 : 0.93,
      color: enabled ? fill : fill.withValues(alpha: 0.5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(size * 0.34),
      ),
      pressedShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(size * 0.20),
      ),
      padding: EdgeInsets.all((size - 22) / 2),
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
