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

  /// How long the pointer must dwell before the marquee starts, so a quick
  /// pass over the row doesn't twitch every title into motion.
  static const Duration _startDelay = Duration(milliseconds: 500);

  /// Bumped on every stop so an in-flight scroll loop bails at its next await.
  int _cycleToken = 0;

  Future<void> _start(double overflow) async {
    if (!mounted || _active || overflow <= 0) return;
    _active = true;
    final int token = ++_cycleToken;

    // Dwell first — no motion on a quick hover.
    await Future<void>.delayed(_startDelay);
    if (!_stillRunning(token)) return;

    final int ms =
        (overflow / widget.velocity * 1000).clamp(600, 6000).round();
    _controller.duration = Duration(milliseconds: ms);

    // One direction only: show the start, scroll left to reveal the end, hold,
    // then snap back to the start and repeat. Never scroll the text backwards
    // at reading pace — nobody reads right-to-left, so the return is an instant
    // reset, not a reverse animation.
    while (_stillRunning(token)) {
      _controller.value = 0;
      await Future<void>.delayed(const Duration(milliseconds: 400));
      if (!_stillRunning(token)) return;
      try {
        await _controller.animateTo(1, curve: Curves.linear);
      } catch (_) {
        return;
      }
      if (!_stillRunning(token)) return;
      await Future<void>.delayed(const Duration(milliseconds: 1000));
      // Loop back to the top: `_controller.value = 0` snaps to the start.
    }
  }

  /// True while the loop started under [token] is still the active one.
  bool _stillRunning(int token) =>
      mounted && _active && token == _cycleToken;

  void _stop() {
    if (!_active) return;
    _active = false;
    _cycleToken++; // invalidate any in-flight scroll loop
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

        // Every title reserves the SAME height, with a little slack below the
        // bare line box so descenders (g, y, p) always have room and the line
        // sits vertically centred. Pinning a Text to exactly the line height —
        // as the old overflow path did — clipped descenders on long titles
        // while short ones (plain self-sized Text) escaped, which is why the
        // list looked uneven. One height for both keeps every row identical.
        final double fontSize = style?.fontSize ?? 14.0;
        final double boxHeight = (textHeight + fontSize * 0.18).ceilToDouble();

        // Fits: plain ellipsized text, no gestures, no animation.
        if (!overflows) {
          // Defensively wind down any leftover animation (e.g. the title was
          // renamed to something shorter while scrolling).
          if (_active) {
            WidgetsBinding.instance.addPostFrameCallback((_) => _stop());
          }
          return SizedBox(
            height: boxHeight,
            child: Align(alignment: Alignment.centerLeft, child: resting),
          );
        }

        final Widget marquee = SizedBox(
          width: maxWidth,
          height: boxHeight,
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              if (!_active && _controller.value == 0) {
                return Align(
                  alignment: Alignment.centerLeft,
                  child: resting,
                );
              }
              final double dx = -overflow * _controller.value;
              return ClipRect(
                child: Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.centerLeft,
                  children: [
                    Positioned(
                      left: dx,
                      top: 0,
                      bottom: 0,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          widget.text,
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.visible,
                          style: style,
                        ),
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
