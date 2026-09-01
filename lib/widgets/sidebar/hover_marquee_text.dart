import 'package:flutter/material.dart';

/// A single-line title that shows an ellipsis at rest and, when the pointer
/// hovers over it (desktop) or the user drags across it horizontally
/// (mobile), gently ping-pong scrolls the text so the full, overflowing
/// title becomes readable. It returns to the start when the pointer leaves.
///
/// Nothing animates when the text fits — short titles render as a plain
/// ellipsized [Text] with no controller work.
class HoverMarqueeText extends StatefulWidget {
  const HoverMarqueeText(
    this.text, {
    super.key,
    this.style,
    this.velocity = 45,
    this.textAlign,
  });

  /// The full title to display.
  final String text;

  /// Text style, forwarded verbatim to the underlying [Text] widgets.
  final TextStyle? style;

  /// Scroll speed of the marquee, in logical pixels per second. The scroll
  /// duration is derived from this and the overflow distance, so long titles
  /// and short titles scroll at the same visual pace.
  final double velocity;

  /// Alignment for the resting (non-overflowing) text.
  final TextAlign? textAlign;

  @override
  State<HoverMarqueeText> createState() => _HoverMarqueeTextState();
}

class _HoverMarqueeTextState extends State<HoverMarqueeText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _active = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _start(double overflow) {
    if (!mounted || _active || overflow <= 0) return;
    _active = true;
    final int ms =
        (overflow / widget.velocity * 1000).clamp(600, 6000).round();
    _controller
      ..duration = Duration(milliseconds: ms)
      ..value = 0
      ..repeat(reverse: true);
  }

  void _stop() {
    if (!_active) return;
    _active = false;
    _controller.stop();
    if (!mounted) return;
    _controller.animateBack(
      0,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final TextStyle? style = widget.style;
    final TextDirection direction = Directionality.of(context);
    final TextScaler scaler = MediaQuery.textScalerOf(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final double maxWidth = constraints.maxWidth;

        final TextPainter painter = TextPainter(
          text: TextSpan(text: widget.text, style: style),
          maxLines: 1,
          textDirection: direction,
          textScaler: scaler,
        )..layout();
        final double textWidth = painter.width;
        final double textHeight = painter.height;
        final double overflow = textWidth - maxWidth;
        final bool overflows =
            maxWidth.isFinite && maxWidth > 0 && overflow > 0.5;

        final Text resting = Text(
          widget.text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          softWrap: false,
          textAlign: widget.textAlign,
          style: style,
        );

        // Fits: plain ellipsized text, no gestures, no animation.
        if (!overflows) {
          // Defensively wind down any leftover animation (e.g. the title was
          // renamed to something shorter while scrolling).
          if (_active) {
            WidgetsBinding.instance.addPostFrameCallback((_) => _stop());
          }
          return resting;
        }

        final Widget marquee = SizedBox(
          width: maxWidth,
          height: textHeight,
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              if (!_active && _controller.value == 0) {
                return resting;
              }
              final double dx = -overflow * _controller.value;
              return ClipRect(
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned(
                      left: dx,
                      top: 0,
                      child: Text(
                        widget.text,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.visible,
                        style: style,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );

        return MouseRegion(
          onEnter: (_) => _start(overflow),
          onExit: (_) => _stop(),
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragStart: (_) => _start(overflow),
            onHorizontalDragEnd: (_) => _stop(),
            onHorizontalDragCancel: _stop,
            child: marquee,
          ),
        );
      },
    );
  }
}
