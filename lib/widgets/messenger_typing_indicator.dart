import 'dart:math' as math;
import 'package:flutter/material.dart';

/// A local presentation of a real in-flight turn; never a synthetic message.
class MessengerTypingIndicator extends StatefulWidget {
  const MessengerTypingIndicator({super.key, this.connectedAbove = false});
  final bool connectedAbove;

  @override
  State<MessengerTypingIndicator> createState() =>
      _MessengerTypingIndicatorState();
}

class _MessengerTypingIndicatorState extends State<MessengerTypingIndicator>
    with SingleTickerProviderStateMixin {
  late final _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );
  bool _reducedMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reducedMotion = MediaQuery.disableAnimationsOf(context);
    if (_reducedMotion) {
      _animation.stop();
    } else if (!_animation.isAnimating) {
      _animation.repeat();
    }
  }

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: Localizations.localeOf(context).languageCode == 'de'
          ? 'Antwort wird geschrieben'
          : 'Writing a reply',
      child: ExcludeSemantics(
        child: Container(
          key: const ValueKey('messenger-typing-pill'),
          width: 60,
          height: 38,
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(widget.connectedAbove ? 7 : 22),
              topRight: const Radius.circular(22),
              bottomLeft: const Radius.circular(22),
              bottomRight: const Radius.circular(22),
            ),
          ),
          child: AnimatedBuilder(
            animation: _animation,
            builder: (context, _) => Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(3, (i) {
                final wave = _reducedMotion
                    ? 0.5
                    : (math.sin((_animation.value * 2 * math.pi) - i * 0.9) +
                              1) /
                          2;
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: Transform.translate(
                    offset: Offset(0, _reducedMotion ? 0 : -2 * wave),
                    child: Opacity(
                      opacity: 0.35 + wave * 0.5,
                      child: Container(
                        key: ValueKey('messenger-typing-dot-$i'),
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: scheme.onSurfaceVariant,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
        ),
      ),
    );
  }
}
