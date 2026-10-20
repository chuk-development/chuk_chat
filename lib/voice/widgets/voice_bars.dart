import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// What the bars show.
enum VoiceBarsState { listening, thinking, speaking }

/// Five rounded strokes in the theme's foreground colour. A small pulse while
/// listening, a sweep while thinking, and a field that follows the agent's
/// voice while it speaks. Nothing around them.
///
/// The bars never leave the box they get: every height is clamped to it and
/// the row is clipped, so a loud word cannot reach into what sits below.
class VoiceBars extends StatefulWidget {
  const VoiceBars({
    super.key,
    required this.state,
    this.muted = false,
    this.level,
    this.compact = false,
    this.color,
  });

  final VoiceBarsState state;
  final bool muted;

  /// The agent's audio level, 0..1. Drives the bars while it speaks.
  final ValueListenable<double>? level;

  /// The slim variant above a raised stage.
  final bool compact;
  final Color? color;

  @override
  State<VoiceBars> createState() => _VoiceBarsState();
}

class _VoiceBarsState extends State<VoiceBars>
    with SingleTickerProviderStateMixin {
  static const int _count = 5;

  late final Ticker _ticker;
  final List<double> _height = List<double>.filled(_count, 0.06);
  Duration _last = Duration.zero;
  double _time = 0;
  double _voice = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
    widget.level?.addListener(_onLevel);
  }

  void _onLevel() {
    if (!_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    }
  }

  void _onTick(Duration elapsed) {
    final double dt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    if (dt <= 0 || dt > 0.1) return;
    _time += dt;
    final double raw = widget.level?.value ?? 0;
    // The level arrives in steps every 80 ms; ease it so the bars glide.
    final double heard = math.pow(raw.clamp(0.0, 1.0), 0.6).toDouble();
    _voice += (heard - _voice) * (1 - math.exp(-dt * 9));

    var settled = true;
    for (var i = 0; i < _count; i++) {
      final double want;
      if (widget.muted) {
        want = 0.04;
      } else {
        switch (widget.state) {
          case VoiceBarsState.speaking:
            // Middle bars carry more of the voice than the outer ones.
            final double shape = const <double>[0.55, 0.8, 1, 0.8, 0.55][i];
            final double drift =
                0.75 + 0.25 * math.sin(_time * (2.1 + i * 0.37) + i * 1.7);
            final double energy = widget.level == null
                ? 0.35 + 0.25 * math.sin(_time * 2.6 + i)
                : _voice;
            want = 0.08 + 0.52 * energy * shape * drift;
          case VoiceBarsState.thinking:
            final double active = (_time * 1.1) % (_count + 1) - 0.5;
            final double d = (i - active).abs();
            want = d < 1.4 ? 0.06 + 0.26 * (1 - d / 1.4) : 0.06;
          case VoiceBarsState.listening:
            final double shape = const <double>[0.55, 0.8, 1, 0.8, 0.55][i];
            final double drift =
                0.8 + 0.2 * math.sin(_time * (1.7 + i * 0.29) + i);
            final double energy = widget.level == null
                ? (i == 2 ? 0.12 : 0.04)
                : _voice;
            want = 0.06 + 0.42 * energy * shape * drift;
        }
      }
      // Frame-rate independent easing: soft enough that nothing snaps.
      _height[i] += (want - _height[i]) * (1 - math.exp(-dt * 7));
      if ((want - _height[i]).abs() > 0.002) settled = false;
    }
    setState(() {});
    // At rest the bars stand still, so the ticker stops until they move.
    if (settled && !_moving) _ticker.stop();
  }

  bool get _moving =>
      !widget.muted &&
      (widget.state != VoiceBarsState.listening || _voice > 0.02);

  @override
  void didUpdateWidget(covariant VoiceBars oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    }
    if (oldWidget.level != widget.level) {
      oldWidget.level?.removeListener(_onLevel);
      widget.level?.addListener(_onLevel);
    }
  }

  @override
  void dispose() {
    widget.level?.removeListener(_onLevel);
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Color color = widget.color ?? Theme.of(context).colorScheme.onSurface;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool compact = widget.compact;
        final double barWidth = compact ? 7 : 16;
        final double gap = compact ? 4 : 7;
        final double available = constraints.hasBoundedHeight
            ? constraints.maxHeight
            : (compact ? 80 : 200);
        final double maxHeight = math.max(
          0,
          math.min(available, compact ? 80.0 : 200.0),
        );
        final double minHeight = math.min(barWidth, maxHeight);
        return ClipRect(
          child: SizedBox(
            height: maxHeight,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                for (var i = 0; i < _count; i++)
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: gap),
                    child: Container(
                      width: barWidth,
                      height:
                          (minHeight +
                                  _height[i].clamp(0.0, 1.0) *
                                      (maxHeight - minHeight))
                              .clamp(0.0, maxHeight),
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: BorderRadius.circular(barWidth),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
