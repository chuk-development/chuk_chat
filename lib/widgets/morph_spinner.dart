import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Material 3 Expressive "loading indicator" (the shape-morph spinner).
///
/// A continuously rotating blob whose petal count (3..7) and depth morph over
/// time, giving the organic "breathing shape" look. Drop-in replacement for
/// CircularProgressIndicator — indeterminate, runs forever.
///
/// Usage:
///   const MorphSpinner()                              // theme primary, 44px
///   const MorphSpinner(size: 64, color: Colors.pink)  // custom
class MorphSpinner extends StatefulWidget {
  const MorphSpinner({
    super.key,
    this.size = 44,
    this.color,
    this.period = const Duration(milliseconds: 2400),
  });

  /// Width/height of the spinner box, in logical pixels.
  final double size;

  /// Fill color. Defaults to Theme.of(context).colorScheme.primary.
  final Color? color;

  /// One full morph + rotation cycle. Smaller = faster.
  final Duration period;

  @override
  State<MorphSpinner> createState() => _MorphSpinnerState();
}

class _MorphSpinnerState extends State<MorphSpinner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: widget.period)..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? Theme.of(context).colorScheme.primary;
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, _) => Transform.rotate(
          angle: _c.value * 2 * math.pi,
          child: CustomPaint(
            painter: _MorphBlobPainter(t: _c.value, color: color),
          ),
        ),
      ),
    );
  }
}

/// Paints a rounded n-lobe "blob" (cosine-lobe polar curve). [t] is the
/// animation value 0..1; lobe count and wobble depth are derived from it so the
/// shape morphs each frame.
class _MorphBlobPainter extends CustomPainter {
  _MorphBlobPainter({required this.t, required this.color});
  final double t;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;

    // Morph the number of "petals" (3..7) and their depth over time.
    final lobes = 5 + (math.sin(t * 2 * math.pi) * 2).round();
    final wobble = 0.18 + 0.12 * math.sin(t * 2 * math.pi * 2);

    final path = Path();
    const steps = 120;
    for (var i = 0; i <= steps; i++) {
      final a = i / steps * 2 * math.pi;
      final r = radius * (1 - wobble + wobble * math.cos(a * lobes));
      final p = center + Offset(math.cos(a) * r, math.sin(a) * r);
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    path.close();
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..isAntiAlias = true,
    );
  }

  @override
  bool shouldRepaint(_MorphBlobPainter old) => old.t != t || old.color != color;
}
