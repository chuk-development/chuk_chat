/// The Material 3 Expressive loading indicator.
///
/// Official spec (m3.material.io/components/loading-indicator, Compose
/// `LoadingIndicatorDefaults`): one shape that keeps morphing through
/// soft burst → 9-sided cookie → pentagon → pill → sunny → 4-sided cookie →
/// oval while it turns. It is for short waits of unknown length (under about
/// five seconds) and pull-to-refresh; measured work takes a progress
/// indicator instead.
///
/// - Uncontained: the shape in `primary`.
/// - Contained: a circular container in `primaryContainer` with the shape in
///   `onPrimaryContainer`, for a loader that floats over content.
/// - The active shape fills 38 / 48 of the box, as in the spec.
///
/// The morph runs on the official expressive spatial spring curve shape: each
/// step settles with a small overshoot, then holds briefly before the next.
/// It never stops on its own, so a test must not `pumpAndSettle` with one on
/// screen.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:material_ui/material_ui.dart'
    show MaterialShapeBorder, MaterialShapes, RoundedPolygon;

import 'package:chuk_chat/ui/expressive/motion.dart'
    show SpringCurve, kM3eSpatialDefault;

/// The official indeterminate shape sequence.
final List<RoundedPolygon> kLoadingIndicatorShapes = <RoundedPolygon>[
  MaterialShapes.softBurst,
  MaterialShapes.cookie9Sided,
  MaterialShapes.pentagon,
  MaterialShapes.pill,
  MaterialShapes.sunny,
  MaterialShapes.cookie4Sided,
  MaterialShapes.oval,
];

/// One morph step, including the short hold at the end of it.
const Duration _kStep = Duration(milliseconds: 650);

/// Extra turn added by each morph step, on top of the steady rotation.
const double _kStepTurn = math.pi / 2;

/// One full steady turn.
const Duration _kTurn = Duration(milliseconds: 4666);

/// Active shape size as a fraction of the box (38 of 48).
const double _kActiveFraction = 38 / 48;

/// The settle curve of one step: the expressive spatial default spring,
/// sampled once, so a repeating controller can drive it.
final Curve _kSpringCurve = SpringCurve(kM3eSpatialDefault, hold: 0.2);

class M3LoadingIndicator extends StatefulWidget {
  const M3LoadingIndicator({
    super.key,
    this.size = 48,
    this.color,
    this.contained = false,
    this.containerColor,
    this.semanticsLabel = 'Loading',
  });

  /// Edge of the square box. The spec size is 48.
  final double size;

  /// Shape colour. Defaults to `primary`, or `onPrimaryContainer` when
  /// [contained].
  final Color? color;

  /// Draw the circular container behind the shape.
  final bool contained;

  /// Container colour. Defaults to `primaryContainer`.
  final Color? containerColor;

  final String semanticsLabel;

  @override
  State<M3LoadingIndicator> createState() => _M3LoadingIndicatorState();
}

class _M3LoadingIndicatorState extends State<M3LoadingIndicator>
    with SingleTickerProviderStateMixin {
  late final int _steps = kLoadingIndicatorShapes.length;
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: _kStep * _steps,
  );

  bool _reducedMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reducedMotion = MediaQuery.disableAnimationsOf(context);
    if (_reducedMotion) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color shapeColor =
        widget.color ??
        (widget.contained ? scheme.onPrimaryContainer : scheme.primary);
    final double active = widget.size * _kActiveFraction;

    Widget shape = AnimatedBuilder(
      animation: _c,
      builder: (BuildContext context, Widget? _) {
        final double total = _c.value * _steps;
        final int index = total.floor() % _steps;
        final double local = _kSpringCurve.transform(total - total.floor());
        // The spring overshoots a little; the turn shows that, the morph
        // itself stays between its two shapes.
        final double morph = local.clamp(0.0, 1.0);
        final ShapeBorder from = MaterialShapeBorder(
          shape: kLoadingIndicatorShapes[index],
        );
        final ShapeBorder border =
            ShapeBorder.lerp(
              from,
              MaterialShapeBorder(
                shape: kLoadingIndicatorShapes[(index + 1) % _steps],
              ),
              morph,
            ) ??
            from;
        final double steady =
            (_c.lastElapsedDuration?.inMicroseconds ?? 0) /
            _kTurn.inMicroseconds *
            2 *
            math.pi;
        final double angle = steady + (index + local) * _kStepTurn;
        return Transform.rotate(
          angle: _reducedMotion ? 0 : angle,
          child: DecoratedBox(
            decoration: ShapeDecoration(color: shapeColor, shape: border),
            child: SizedBox.square(dimension: active),
          ),
        );
      },
    );

    if (widget.contained) {
      shape = DecoratedBox(
        decoration: ShapeDecoration(
          color: widget.containerColor ?? scheme.primaryContainer,
          shape: const CircleBorder(),
        ),
        child: Center(child: shape),
      );
    }

    return Semantics(
      label: widget.semanticsLabel,
      child: SizedBox.square(
        dimension: widget.size,
        child: Center(child: shape),
      ),
    );
  }
}
