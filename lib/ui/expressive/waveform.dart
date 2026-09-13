/// The voice waveform: a row of rounded vertical bars.
///
/// The reference messenger draws a voice message this way — evenly spaced,
/// round-capped bars with a comfortable minimum height, the played part in the
/// foreground colour and the rest muted. Agents has no voice MESSAGE (the
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
/// newest level is the bar at the trailing edge, so the row scrolls to the left
/// while the microphone is open. Quiet speech is lifted with a square root so a
/// normal voice fills the shape instead of hugging the baseline. Silence still
/// reads as a line, never as nothing.
///
/// [barCount] is optional: without it the bar count follows the width, so the
/// bars keep the same spacing on a narrow phone and on a wide composer.
class LiveWaveform extends StatelessWidget {
  const LiveWaveform({
    super.key,
    required this.levels,
    required this.color,
    this.barCount,
    this.height = 26,
    this.barWidth = 3.0,
    this.barSpacing = 6.0,
  });

  final List<double> levels;
  final Color color;
  final int? barCount;
  final double height;
  final double barWidth;

  /// Distance from one bar to the next when [barCount] is not given.
  final double barSpacing;

  /// The last [count] levels, right-aligned: the newest level is always the
  /// bar at the trailing edge, so the row scrolls even before the buffer is
  /// full. A left-aligned buffer left the last third of the row dead.
  List<double> _bars(int count) {
    final int offset = levels.length - count;
    return <double>[
      for (int i = 0; i < count; i++)
        () {
          final int index = offset + i;
          final double raw = (index >= 0 && index < levels.length)
              ? levels[index]
              : 0.0;
          // The floor is a short tick, not a dot: silence has to read as a
          // line across the row.
          if (raw < 0.01) return 0.22;
          return (math.sqrt(raw) * 0.95).clamp(0.22, 1.0);
        }(),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double width = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : 0;
          // Never more bars than the recorder has levels: extra bars would
          // only pad the row with silence and the shape would stop reading as
          // a waveform.
          final int count =
              barCount ??
              math.min(
                math.max(levels.length, 12),
                width <= 0 ? 24 : (width / barSpacing).floor().clamp(12, 64),
              );
          return CustomPaint(
            size: Size(width, height),
            painter: WaveformPainter(
              bars: _bars(count),
              progress: 1,
              playedColor: color,
              restColor: color.withValues(alpha: 0.32),
              barWidth: barWidth,
            ),
          );
        },
      ),
    );
  }
}
