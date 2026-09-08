/// The voice waveform: a row of rounded vertical bars.
///
/// The reference messenger draws a voice message this way — evenly spaced,
/// round-capped bars with a comfortable minimum height, the played part in the
/// foreground colour and the rest muted. CoWork has no voice MESSAGE (the
/// microphone dictates a message instead of attaching one), so the same painter
/// draws the live level while the microphone is open: the reader sees their own
/// voice in the same shape a voice note would have.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

/// Paints [bars] (each 0..1) as rounded vertical bars, colouring everything
/// left of [progress] with [playedColor] and the rest with [restColor].
class WaveformPainter extends CustomPainter {
  WaveformPainter({
    required this.bars,
    required this.progress,
    required this.playedColor,
    required this.restColor,
    this.barWidth = 3.0,
  });

  final List<double> bars;

  /// 0..1. Pass 1 to paint every bar in [playedColor] (a live level meter).
  final double progress;
  final Color playedColor;
  final Color restColor;
  final double barWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final int n = bars.length;
    if (n == 0) return;
    final double gap = n == 1 ? 0 : (size.width - n * barWidth) / (n - 1);
    final Paint paint = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = barWidth;
    final double mid = size.height / 2;
    for (int i = 0; i < n; i++) {
      final double x = barWidth / 2 + i * (barWidth + gap);
      final double h = (bars[i] * size.height).clamp(4.0, size.height);
      paint.color = (i + 0.5) / n <= progress ? playedColor : restColor;
      canvas.drawLine(Offset(x, mid - h / 2), Offset(x, mid + h / 2), paint);
    }
  }

  @override
  bool shouldRepaint(WaveformPainter old) =>
      old.progress != progress ||
      old.playedColor != playedColor ||
      old.restColor != restColor ||
      !listEquals(old.bars, bars);
}

/// The live level meter of an open microphone, in the waveform shape.
///
/// [levels] is the rolling buffer the recorder writes (0..1, oldest first); the
/// last [barCount] entries are drawn. Quiet speech is lifted with a square root
/// so a normal voice fills the shape instead of hugging the baseline.
class LiveWaveform extends StatelessWidget {
  const LiveWaveform({
    super.key,
    required this.levels,
    required this.color,
    this.barCount = 24,
    this.height = 26,
  });

  final List<double> levels;
  final Color color;
  final int barCount;
  final double height;

  @override
  Widget build(BuildContext context) {
    final int start = levels.length > barCount ? levels.length - barCount : 0;
    final List<double> bars = <double>[
      for (int i = 0; i < barCount; i++)
        () {
          final int index = start + i;
          final double raw = index < levels.length ? levels[index] : 0.0;
          if (raw < 0.01) return 0.08;
          return (math.sqrt(raw) * 0.95).clamp(0.08, 1.0);
        }(),
    ];
    return SizedBox(
      height: height,
      child: CustomPaint(
        painter: WaveformPainter(
          bars: bars,
          progress: 1,
          playedColor: color,
          restColor: color.withValues(alpha: 0.32),
        ),
      ),
    );
  }
}
