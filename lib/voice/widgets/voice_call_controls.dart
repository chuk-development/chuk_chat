// lib/voice/widgets/voice_call_controls.dart
//
// The small pieces the call panel is built from: the call control target
// (the app's MorphTap squircle, docs/DESIGN.md §6), the microphone glyph with
// its muted slash, the hang-up handset, and the agent-speaking bars.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:chuk_chat/ui/expressive/huge_icon.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';

/// A square call control: the expressive squircle (corner = size x 0.34),
/// springing on press like every other button in the app.
class VoiceCallControl extends StatelessWidget {
  const VoiceCallControl({
    super.key,
    required this.child,
    required this.onTap,
    required this.tooltip,
    required this.fill,
    this.size = 40,
    this.toggled,
    this.semanticsId,
  });

  final Widget child;
  final VoidCallback? onTap;
  final String tooltip;
  final Color fill;
  final double size;

  /// Non-null for a toggle: its state for assistive tech.
  final bool? toggled;
  final String? semanticsId;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      identifier: semanticsId,
      button: true,
      toggled: toggled,
      enabled: onTap != null,
      label: tooltip,
      child: Tooltip(
        message: tooltip,
        excludeFromSemantics: true,
        child: MorphTap(
          onTap: onTap,
          color: fill,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(size * 0.34),
          ),
          pressedShape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(size * 0.20),
          ),
          child: SizedBox(
            width: size,
            height: size,
            child: Center(child: child),
          ),
        ),
      ),
    );
  }
}

/// The microphone, with a slash across it when [muted]. The icon set has no
/// "mic off" glyph, so the slash is painted over `mic01`, with a gap in
/// [gapColor] so it reads as a cut, not as a scratch.
class VoiceMicGlyph extends StatelessWidget {
  const VoiceMicGlyph({
    super.key,
    required this.muted,
    required this.color,
    required this.gapColor,
    this.size = 20,
  });

  final bool muted;
  final Color color;
  final Color gapColor;
  final double size;

  @override
  Widget build(BuildContext context) {
    final Widget mic = HugeIcon(HugeIcons.mic01, size: size, color: color);
    if (!muted) return mic;
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        foregroundPainter: _SlashPainter(color: color, gapColor: gapColor),
        child: mic,
      ),
    );
  }
}

class _SlashPainter extends CustomPainter {
  _SlashPainter({required this.color, required this.gapColor});

  final Color color;
  final Color gapColor;

  @override
  void paint(Canvas canvas, Size size) {
    final double inset = size.width * 0.12;
    final Offset a = Offset(inset, inset);
    final Offset b = Offset(size.width - inset, size.height - inset);
    final double stroke = size.width / 24 * 1.5;
    canvas.drawLine(
      a,
      b,
      Paint()
        ..color = gapColor
        ..strokeWidth = stroke * 3
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawLine(
      a,
      b,
      Paint()
        ..color = color
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_SlashPainter old) =>
      old.color != color || old.gapColor != gapColor;
}

/// The handset laid down: `call02` turned 135 degrees, the hang-up sign
/// every phone uses.
class VoiceHangUpGlyph extends StatelessWidget {
  const VoiceHangUpGlyph({super.key, required this.color, this.size = 20});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Transform.rotate(
    angle: math.pi * 0.75,
    child: HugeIcon(HugeIcons.call02, size: size, color: color),
  );
}

/// Three bars that move while the agent speaks and rest flat when it does
/// not. The motion stops with the speech (docs/DESIGN.md §8: nothing pulses
/// forever).
class VoiceSpeakingBars extends StatefulWidget {
  const VoiceSpeakingBars({
    super.key,
    required this.speaking,
    required this.color,
    this.size = 18,
  });

  final bool speaking;
  final Color color;
  final double size;

  @override
  State<VoiceSpeakingBars> createState() => _VoiceSpeakingBarsState();
}

class _VoiceSpeakingBarsState extends State<VoiceSpeakingBars>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    if (widget.speaking) _controller.repeat();
  }

  @override
  void didUpdateWidget(VoiceSpeakingBars old) {
    super.didUpdateWidget(old);
    if (widget.speaking == old.speaking) return;
    if (widget.speaking) {
      _controller.repeat();
    } else {
      _controller
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (BuildContext context, Widget? _) => CustomPaint(
            painter: _BarsPainter(
              t: _controller.value,
              active: widget.speaking,
              color: widget.color,
            ),
          ),
        ),
      ),
    );
  }
}

class _BarsPainter extends CustomPainter {
  _BarsPainter({required this.t, required this.active, required this.color});

  final double t;
  final bool active;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final double barWidth = size.width / 5;
    final Paint paint = Paint()
      ..color = color
      ..strokeWidth = barWidth
      ..strokeCap = StrokeCap.round;
    for (int i = 0; i < 3; i++) {
      final double phase = t * 2 * math.pi + i * 2.1;
      final double level = active
          ? 0.35 + 0.65 * (0.5 + 0.5 * math.sin(phase))
          : 0.2;
      final double h = (size.height - barWidth) * level;
      final double x = barWidth / 2 + i * barWidth * 2;
      final double cy = size.height / 2;
      canvas.drawLine(Offset(x, cy - h / 2), Offset(x, cy + h / 2), paint);
    }
  }

  @override
  bool shouldRepaint(_BarsPainter old) =>
      old.t != t || old.active != active || old.color != color;
}
