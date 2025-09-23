// lib/utils/grain_overlay.dart
import 'dart:async'; // <-- for Timer
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

/// Full-screen film grain overlay.
/// Place as the top-most child in a Stack. Colors beneath remain unchanged.
class GrainOverlay extends StatefulWidget {
  const GrainOverlay({
    super.key,
    this.opacity = 0.12,                // how strong the grain looks (0–1)
    this.speedMs = 180,                 // how often the noise "flickers"
    this.noiseSize = 140,               // resolution of the generated noise tile
    this.blendMode = BlendMode.overlay, // overlay looks filmic; try softLight/multiply too
  });

  final double opacity;
  final int speedMs;
  final int noiseSize;
  final BlendMode blendMode;

  @override
  State<GrainOverlay> createState() => _GrainOverlayState();
}

class _GrainOverlayState extends State<GrainOverlay> {
  Timer? _noiseTimer;
  ui.Image? _noiseImage;
  bool _regenInFlight = false;

  @override
  void initState() {
    super.initState();
    _regenNoise();     // draw one immediately
    _startNoiseTimer(); // then flicker at the requested cadence
  }

  void _startNoiseTimer() {
    _noiseTimer?.cancel();
    _noiseTimer = Timer.periodic(
      Duration(milliseconds: widget.speedMs),
      (_) => _regenNoise(),
    );
  }

  Future<void> _regenNoise() async {
    if (_regenInFlight) return; // prevent overlapping async work
    _regenInFlight = true;
    try {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final size = widget.noiseSize.toDouble();
      final paint = Paint();

      // Base gray so very dark UIs still show grain subtly.
      canvas.drawRect(
        Rect.fromLTWH(0, 0, size, size),
        Paint()..color = const Color(0xFF7F7F7F),
      );

      final rnd = math.Random();
      const step = 2.0; // dot spacing; lower = more dots

      // Scatter tiny dots with random brightness & alpha
      for (double y = 0; y < size; y += step) {
        for (double x = 0; x < size; x += step) {
          final v = rnd.nextInt(256);
          final a = 60 + rnd.nextInt(70); // 60–130 alpha (out of 255)
          paint.color = Color.fromARGB(a, v, v, v);
          canvas.drawRect(Rect.fromLTWH(x, y, 1, 1), paint);
        }
      }

      final picture = recorder.endRecording();
      final img = await picture.toImage(widget.noiseSize, widget.noiseSize);

      if (!mounted) {
        img.dispose(); // avoid leaking if widget got disposed mid-frame
        return;
      }

      // dispose previous image to prevent memory leak
      final oldImage = _noiseImage;
      setState(() {
        _noiseImage = img;
      });
      oldImage?.dispose();
    } finally {
      _regenInFlight = false;
    }
  }

  @override
  void didUpdateWidget(covariant GrainOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.speedMs != widget.speedMs) {
      _startNoiseTimer();
    }
    if (oldWidget.noiseSize != widget.noiseSize) {
      _regenNoise();
    }
  }

  @override
  void dispose() {
    _noiseTimer?.cancel();
    _noiseImage?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_noiseImage == null) return const SizedBox.shrink();
    return IgnorePointer(
      child: Opacity(
        opacity: widget.opacity,
        child: CustomPaint(
          painter: _GrainPainter(_noiseImage!, widget.blendMode),
          size: Size.infinite, // fills in a Stack; fine to keep as-is
        ),
      ),
    );
  }
}

class _GrainPainter extends CustomPainter {
  final ui.Image noise;
  final BlendMode blendMode;
  _GrainPainter(this.noise, this.blendMode);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..isAntiAlias = false
      ..filterQuality = FilterQuality.none
      ..blendMode = blendMode;

    // Tile the noise image to fill the screen.
    final src = Rect.fromLTWH(0, 0, noise.width.toDouble(), noise.height.toDouble());
    for (double y = 0; y < size.height; y += noise.height) {
      for (double x = 0; x < size.width; x += noise.width) {
        final dst = Rect.fromLTWH(x, y, noise.width.toDouble(), noise.height.toDouble());
        canvas.drawImageRect(noise, src, dst, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _GrainPainter old) =>
      old.noise != noise || old.blendMode != blendMode;
}
