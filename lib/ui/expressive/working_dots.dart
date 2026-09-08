/// "working" with three softly pulsing dots — the header subtitle while a run
/// is in flight.
///
/// In the reference messenger this is the "typing" indicator. Here it says
/// something the app can actually observe: the coworker has a run open
/// ([CoworkAgent.running]). Nothing pretends to know that it is "typing".
library;

import 'package:flutter/material.dart';

class WorkingDots extends StatefulWidget {
  const WorkingDots({super.key, required this.color, this.label = 'working'});

  final Color color;
  final String label;

  @override
  State<WorkingDots> createState() => _WorkingDotsState();
}

class _WorkingDotsState extends State<WorkingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          widget.label,
          style: TextStyle(
            color: widget.color,
            fontSize: 11,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(width: 4),
        for (int i = 0; i < 3; i++)
          AnimatedBuilder(
            animation: _c,
            builder: (BuildContext context, Widget? _) {
              // Each dot peaks at a staggered phase of the cycle.
              final double phase = (_c.value - i * 0.18) % 1.0;
              final double t = (1 - (phase * 2 - 1).abs()).clamp(0.0, 1.0);
              return Padding(
                padding: const EdgeInsets.only(left: 2),
                child: Opacity(
                  opacity: 0.35 + 0.65 * t,
                  child: Container(
                    width: 4,
                    height: 4,
                    decoration: BoxDecoration(
                      color: widget.color,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}
