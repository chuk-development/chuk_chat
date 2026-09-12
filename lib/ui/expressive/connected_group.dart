/// The Material 3 Expressive connected button group — the switch that sits
/// above a list ("All" / "Unread", "Pictures" / "Files").
///
/// The shape is the bottom navigation's, down to the numbers: both controls
/// read [PillGeometry], so one capsule holds the segments, the selected
/// segment is a filled capsule inside it, and the ring of background around
/// that capsule is the same thickness everywhere — at the ends, between the
/// segments, above and below. A press springs and lands the fill at once, on
/// pointer down, so no scroll can take the tap away and nothing has to hint
/// at a selection that has not happened. It does NOT square off: an oval
/// stays an oval while the finger is down.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:cowork/ui/expressive/motion.dart';
import 'package:cowork/ui/expressive/pill_geometry.dart';

class ConnectedGroup extends StatelessWidget {
  const ConnectedGroup({
    super.key,
    required this.labels,
    required this.selected,
    required this.onSelected,
    this.badges = const <int, int>{},
    this.margin = const EdgeInsets.symmetric(horizontal: 16),
    this.height,
  });

  final List<String> labels;
  final int selected;
  final ValueChanged<int> onSelected;

  /// Optional count shown after a label (segment index → count). A zero or a
  /// missing entry shows nothing.
  final Map<int, int> badges;

  /// The room left around the pill. Edge to edge, unlike the navigation pill:
  /// this control belongs to the list under it and sits over its whole width.
  final EdgeInsetsGeometry margin;

  /// The painted height of the strip. Null keeps [PillGeometry.filterHeight],
  /// the height of a switch that sits above a list on its own. A switch that
  /// shares a row with icon buttons is given their height instead, so the row
  /// reads as one control and not as a strip between two taller boxes.
  final double? height;

  /// The corner of the container that holds the segments.
  static const double outerRadius = PillGeometry.filterRadius;

  /// The corner of the filled capsule under the selected segment.
  static const double selectedRadius = PillGeometry.filterSegmentRadius;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // The strip paints short and the targets reach past it: a switch over a
    // list is a strip, not a bar, but a finger still gets its 48. What the
    // segments take above and below the strip is transparent and lies inside
    // the room [margin] leaves anyway. A strip given a [height] of its own is
    // usually already past 48, and then there is nothing left to reach for.
    final double barHeight = height ?? PillGeometry.filterHeight;
    final double segmentHeight = barHeight - PillGeometry.filterInset * 2;
    final double tapHeight = math.max(PillGeometry.filterTapHeight, barHeight);
    final double overhang = (tapHeight - barHeight) / 2;
    // Concentric with the capsule inside it, whatever the height.
    final double shellRadius = segmentHeight / 2 + PillGeometry.filterInset;
    return Padding(
      padding: margin,
      child: SizedBox(
        height: tapHeight,
        child: Stack(
          children: <Widget>[
            Positioned(
              left: 0,
              right: 0,
              top: overhang,
              bottom: overhang,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.96),
                  borderRadius: BorderRadius.circular(shellRadius),
                ),
              ),
            ),
            // The segments split the width evenly, so neither label is cramped
            // and the first and the last capsule end at the same distance from
            // the ends of the strip.
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: PillGeometry.filterInset,
              ),
              child: Row(
                children: <Widget>[
                  for (int i = 0; i < labels.length; i++) ...<Widget>[
                    if (i > 0)
                      const SizedBox(width: PillGeometry.filterInset),
                    Expanded(
                      child: _Segment(
                        label: labels[i],
                        count: badges[i] ?? 0,
                        selected: i == selected,
                        height: segmentHeight,
                        slop: overhang + PillGeometry.filterInset,
                        onTap: () => onSelected(i),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.label,
    required this.count,
    required this.selected,
    required this.height,
    required this.slop,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool selected;

  /// The painted height of the capsule.
  final double height;

  /// Transparent room above and below the capsule that still takes the press.
  final double slop;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Semantics(
      identifier: 'connected-group-${label.toLowerCase()}',
      button: true,
      selected: selected,
      label: label,
      child: MorphTap(
        onTap: onTap,
        // The selection commits on pointer down: the switch is the one
        // control that must never lose its tap to the list it sits above.
        instant: true,
        // The tap reaches into the hairline, so the capsule can paint short of
        // a touch target while the finger still gets one.
        hitPadding: EdgeInsets.symmetric(vertical: slop),
        color: selected ? scheme.primary : Colors.transparent,
        // A stadium at rest and a stadium while held: the press springs, it
        // does not turn the capsule into a rounded box.
        shape: const StadiumBorder(),
        pressedShape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: SizedBox(
          height: height,
          // No tick: the filled capsule already says which segment is on, and
          // a mark that appears on one side only pushes its label off centre.
          // Every label sits in the middle of its own segment.
          child: Center(
            child: Text(
              count > 0 ? '$label $count' : label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 14,
                color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
