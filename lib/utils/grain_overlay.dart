// lib/utils/grain_overlay.dart
import 'dart:async'; // <-- for Timer
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

Uint8List _generateNoisePixels(List<int> params) {
  final size = params[0];
  final rnd = math.Random(params[1]);
  final bytes = Uint8List(size * size * 4);
  var i = 0;

  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final v = rnd.nextInt(256);
      final a = 60 + rnd.nextInt(70); // 60-130 alpha
      bytes[i++] = v; // R
      bytes[i++] = v; // G
      bytes[i++] = v; // B
      bytes[i++] = a; // A
    }
  }
  return bytes;
}

/// Full-screen film grain overlay.
/// Place as the top-most child in a Stack. Colors beneath remain unchanged.
class GrainOverlay extends StatefulWidget {
  const GrainOverlay({
    super.key,
    this.opacity = 0.12, // how strong the grain looks (0–1)
    this.speedMs = 180, // how often the noise "flickers"
    this.noiseSize = 140, // resolution of the generated noise tile
    this.blendMode =
        BlendMode.overlay, // overlay looks filmic; try softLight/multiply too
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

  bool get _shouldAnimateNoise =>
      !kIsWeb && defaultTargetPlatform != TargetPlatform.linux;

  @override
  void initState() {
    super.initState();
    // Generate noise after first frame. Linux gets a static grain layer
    // to avoid startup/interaction hitches from continuous regeneration.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_regenNoise());
      if (_shouldAnimateNoise) {
        _startNoiseTimer();
      }
    });
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
      final pixels = await compute(_generateNoisePixels, <int>[
        widget.noiseSize,
        DateTime.now().microsecondsSinceEpoch,
      ]);
      final img = await _decodePixelsToImage(
        pixels,
        widget.noiseSize,
        widget.noiseSize,
      );

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

  Future<ui.Image> _decodePixelsToImage(
    Uint8List pixels,
    int width,
    int height,
  ) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixels,
      width,
      height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }

  @override
  void didUpdateWidget(covariant GrainOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_shouldAnimateNoise && oldWidget.speedMs != widget.speedMs) {
      _startNoiseTimer();
    } else if (!_shouldAnimateNoise && oldWidget.speedMs != widget.speedMs) {
      _noiseTimer?.cancel();
      _noiseTimer = null;
    }
    if (oldWidget.noiseSize != widget.noiseSize) {
      unawaited(_regenNoise());
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
    final src = Rect.fromLTWH(
      0,
      0,
      noise.width.toDouble(),
      noise.height.toDouble(),
    );
    for (double y = 0; y < size.height; y += noise.height) {
      for (double x = 0; x < size.width; x += noise.width) {
        final dst = Rect.fromLTWH(
          x,
          y,
          noise.width.toDouble(),
          noise.height.toDouble(),
        );
        canvas.drawImageRect(noise, src, dst, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _GrainPainter old) =>
      old.noise != noise || old.blendMode != blendMode;
}
