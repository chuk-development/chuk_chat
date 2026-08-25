import 'package:flutter/widgets.dart';

/// A one-shot entrance for a just-sent message: the bubble starts a little
/// below its resting place and faintly transparent, then rises into position
/// as it fades in — so the message reads as flying up out of the composer
/// rather than snapping into the list.
///
/// The animation plays exactly once, on first mount. Give it a [key] tied to
/// the message so the element (and its finished state) is preserved across the
/// list's rebuilds and never replays. Applied only to the message that was
/// just sent — never to the whole history on chat open.
class MessageFlyIn extends StatefulWidget {
  const MessageFlyIn({
    super.key,
    required this.child,
    this.rise = 40,
    this.duration = const Duration(milliseconds: 380),
  });

  final Widget child;

  /// How far below its resting place the bubble starts, in logical pixels.
  final double rise;

  final Duration duration;

  @override
  State<MessageFlyIn> createState() => _MessageFlyInState();
}

class _MessageFlyInState extends State<MessageFlyIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  );
  late final Animation<double> _t = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );

  @override
  void initState() {
    super.initState();
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _t,
      child: widget.child,
      builder: (context, child) {
        final double v = _t.value;
        final double dy = (1 - v) * widget.rise;
        return Opacity(
          opacity: v.clamp(0.0, 1.0),
          child: Transform.translate(
            offset: Offset(0, dy),
            child: child,
          ),
        );
      },
    );
  }
}
