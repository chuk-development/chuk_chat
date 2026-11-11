// lib/widgets/text_shimmer.dart
//
// A light sweep across running text ("Searching the web"), so the reader
// sees the step is alive. Only running text shimmers; settled text is still.
//
// Timing (deepseek-harness `ui-primitives/TextShimmer`): wait 300 ms, sweep
// for 1 s, rest 500 ms, repeat while active. With reduced motion
// (`MediaQuery.disableAnimations`) the text does not move. The sweep is a
// change of text colour only: no glow, no shadow (docs/DESIGN.md §8).

import 'dart:async';

import 'package:flutter/material.dart';

class TextShimmer extends StatefulWidget {
  const TextShimmer({super.key, required this.child, this.active = true});

  /// The text. Its own colour is the base; the sweep is a lighter band.
  final Widget child;

  /// Animate only while true.
  final bool active;

  /// Global switch. Widget tests turn it off (test/flutter_test_config.dart),
  /// because a repeating animation never lets `pumpAndSettle` settle. The
  /// shimmer's own test turns it back on.
  static bool enabled = true;

  static const Duration delay = Duration(milliseconds: 300);
  static const Duration sweep = Duration(seconds: 1);
  static const Duration rest = Duration(milliseconds: 500);

  @override
  State<TextShimmer> createState() => _TextShimmerState();
}

class _TextShimmerState extends State<TextShimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: TextShimmer.sweep + TextShimmer.rest,
  );
  Timer? _delay;
  bool _running = false;

  bool _shouldRun(BuildContext context) =>
      TextShimmer.enabled &&
      widget.active &&
      !(MediaQuery.maybeDisableAnimationsOf(context) ?? false);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(TextShimmer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) _sync();
  }

  void _sync() {
    final bool run = _shouldRun(context);
    if (run == _running) return;
    _running = run;
    _delay?.cancel();
    if (run) {
      _delay = Timer(TextShimmer.delay, () {
        if (mounted && _running) _controller.repeat();
      });
    } else {
      _controller
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _delay?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_running) return widget.child;
    final Color highlight = Theme.of(context).colorScheme.onSurface;
    final double sweepShare =
        TextShimmer.sweep.inMilliseconds /
        (TextShimmer.sweep + TextShimmer.rest).inMilliseconds;
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (BuildContext context, Widget? child) {
        final double t = _controller.value / sweepShare;
        // Resting: the plain text, no mask at all.
        if (_controller.value == 0 || t >= 1) return child!;
        // The band runs from left of the text to right of it.
        final double centre = -0.3 + 1.6 * t;
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (Rect bounds) => LinearGradient(
            colors: <Color>[
              highlight.withValues(alpha: 0),
              highlight.withValues(alpha: 0.9),
              highlight.withValues(alpha: 0),
            ],
            stops: <double>[
              (centre - 0.15).clamp(0.0, 1.0),
              centre.clamp(0.0, 1.0),
              (centre + 0.15).clamp(0.0, 1.0),
            ],
          ).createShader(bounds),
          child: child,
        );
      },
    );
  }
}
