import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

import 'package:chuk_chat/voice/widgets/voice_bars.dart' show VoiceBarsState;

/// The agent visualizer of LiveKit's Flutter agent sample
/// (`livekit_components` `AudioVisualizerWidget`, Apache-2.0), ported onto
/// `livekit_client` directly so the app needs no second UI package.
///
/// Five fat pills. While the agent speaks they follow the spectrum of its
/// audio track (`lk.createVisualizer`, native FFT); while it thinks a light
/// runs across them; while it listens the middle one breathes.
class VoiceVisualizer extends StatefulWidget {
  const VoiceVisualizer({
    super.key,
    required this.state,
    this.track,
    this.muted = false,
    this.color,
    this.barCount = 5,
    this.spacing = 8,
    this.maxBarWidth = 56,
    this.durationMs = 500,
    this.barMinOpacity = 0.2,
  });

  final VoiceBarsState state;

  /// The agent's speech track. Without it the bars still show the state.
  final lk.AudioTrack? track;
  final bool muted;
  final Color? color;
  final int barCount;
  final double spacing;
  final double maxBarWidth;
  final int durationMs;
  final double barMinOpacity;

  @override
  State<VoiceVisualizer> createState() => _VoiceVisualizerState();
}

class _VoiceVisualizerState extends State<VoiceVisualizer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;
  late List<double> _samples;
  lk.AudioVisualizer? _visualizer;
  lk.EventsListener<lk.AudioVisualizerEvent>? _listener;

  @override
  void initState() {
    super.initState();
    _samples = List<double>.filled(widget.barCount, 0);
    _pulse = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: widget.durationMs),
    )..repeat(reverse: true);
    unawaited(_attach());
  }

  @override
  void didUpdateWidget(VoiceVisualizer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.track?.sid != widget.track?.sid ||
        oldWidget.barCount != widget.barCount) {
      _samples = List<double>.filled(widget.barCount, 0);
      unawaited(_detach().then((_) => _attach()));
    }
  }

  Future<void> _attach() async {
    final lk.AudioTrack? track = widget.track;
    if (track == null) return;
    try {
      final lk.AudioVisualizer visualizer = lk.createVisualizer(
        track,
        options: lk.AudioVisualizerOptions(
          barCount: widget.barCount,
          centeredBands: true,
        ),
      );
      _visualizer = visualizer;
      _listener = visualizer.createListener()
        ..on<lk.AudioVisualizerEvent>((e) {
          if (!mounted) return;
          setState(() {
            _samples = e.event
                .map((v) => (v as num).toDouble().clamp(0.0, 1.0))
                .toList();
          });
        });
      await visualizer.start();
    } catch (_) {
      // No native visualizer on this platform: the state animation stays.
    }
  }

  Future<void> _detach() async {
    final visualizer = _visualizer;
    _visualizer = null;
    await _listener?.dispose();
    _listener = null;
    if (visualizer != null) {
      try {
        await visualizer.stop();
        await visualizer.dispose();
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    unawaited(_detach());
    super.dispose();
  }

  List<(double, double)> _bars(double t) {
    final int n = widget.barCount;
    final List<double> values = _samples.length == n
        ? _samples
        : List<double>.filled(n, 0);
    final double minAlpha = widget.barMinOpacity;
    switch (widget.muted ? VoiceBarsState.listening : widget.state) {
      case VoiceBarsState.thinking:
        final int active = (t * (n - 1)).round();
        final double reach = math.max(n / 4, 1);
        return List.generate(n, (i) {
          final double strength = (1 - (i - active).abs() / reach).clamp(
            0.0,
            1.0,
          );
          return (0.0, minAlpha + strength * (1 - minAlpha));
        });
      case VoiceBarsState.listening:
        final int center = n ~/ 2;
        const double base = 0.1;
        return List.generate(
          n,
          (i) => (0.0, i == center ? base + (t - base).clamp(0.0, 1.0) : base),
        );
      case VoiceBarsState.speaking:
        return List.generate(n, (i) => (values[i], 1.0));
    }
  }

  @override
  Widget build(BuildContext context) {
    final Color color = widget.color ?? Theme.of(context).colorScheme.onSurface;
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) {
        final double t = Curves.easeInOut.transform(_pulse.value);
        final List<(double, double)> bars = _bars(t);
        return LayoutBuilder(
          builder: (context, constraints) {
            final int n = bars.length;
            final double maxWidth = constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : widget.maxBarWidth * n;
            final double barWidth = math.min(
              widget.maxBarWidth,
              (maxWidth - widget.spacing * (n - 1)) / n,
            );
            final double maxHeight = constraints.maxHeight.isFinite
                ? constraints.maxHeight
                : barWidth * 6;
            return ClipRect(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  for (var i = 0; i < n; i++) ...<Widget>[
                    if (i > 0) SizedBox(width: widget.spacing),
                    AnimatedContainer(
                      duration: Duration(
                        milliseconds: widget.durationMs ~/ math.max(n, 1),
                      ),
                      width: barWidth,
                      height: math.min(
                        maxHeight,
                        math.max(
                          barWidth,
                          bars[i].$1 * (maxHeight - barWidth) + barWidth,
                        ),
                      ),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: bars[i].$2),
                        borderRadius: BorderRadius.circular(9999),
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        );
      },
    );
  }
}
