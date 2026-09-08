/// The staggered list entrance.
///
/// Every row fades, slides up and scales in, delayed by its index, so a list
/// cascades into place each time it is (re)built — on the first load and on
/// every filter switch. The delay is capped so a long list does not make the
/// last rows wait.
///
/// The delay is an [Interval] inside ONE controller, not a `Future.delayed`: a
/// pending timer outlives a disposed widget (and fails a widget test), while a
/// controller is cancelled with the row it belongs to.
library;

import 'package:flutter/material.dart';

class StaggeredItem extends StatefulWidget {
  const StaggeredItem({super.key, required this.index, required this.child});

  final int index;
  final Widget child;

  /// How long one row's own motion takes.
  static const Duration motion = Duration(milliseconds: 460);

  /// Delay per row, capped at the 13th row.
  static Duration delayFor(int index) =>
      Duration(milliseconds: 40 + index.clamp(0, 12) * 55);

  @override
  State<StaggeredItem> createState() => _StaggeredItemState();
}

class _StaggeredItemState extends State<StaggeredItem>
    with SingleTickerProviderStateMixin {
  late final int _delayMs = StaggeredItem.delayFor(widget.index).inMilliseconds;
  late final int _totalMs = _delayMs + StaggeredItem.motion.inMilliseconds;

  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: _totalMs),
  );

  late final Animation<double> _t = CurvedAnimation(
    parent: _c,
    curve: Interval(_delayMs / _totalMs, 1, curve: Curves.easeOutCubic),
  );

  @override
  void initState() {
    super.initState();
    _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _t,
      builder: (BuildContext context, Widget? child) {
        final double v = _t.value;
        return Opacity(
          opacity: v,
          child: Transform.translate(
            offset: Offset(0, (1 - v) * 22),
            child: Transform.scale(scale: 0.94 + 0.06 * v, child: child),
          ),
        );
      },
      child: widget.child,
    );
  }
}
