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

import 'package:chuk_chat/utils/theme_extensions.dart';

import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/ui/expressive/pill_geometry.dart';

class ConnectedGroup extends StatefulWidget {
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

  /// The key of the one filled capsule that slides under the selection.
  static const Key pillKey = ValueKey<String>('connected-group-pill');

  /// How long the capsule takes to slide from one segment to the next.
  static const Duration slideDuration = Duration(milliseconds: 280);

  /// The curve of the slide: fast off the mark, soft landing, no overshoot
  /// (an overshoot would push the capsule past the ends of the strip).
  static const Curve slideCurve = Curves.easeOutCubic;

  @override
  State<ConnectedGroup> createState() => _ConnectedGroupState();
}

class _ConnectedGroupState extends State<ConnectedGroup>
    with SingleTickerProviderStateMixin {
  /// The capsule's position in segments: 0 under the first, 1 under the
  /// second, 0.5 half way between them. One value drives the capsule and the
  /// label colours, so the two can never disagree.
  late final AnimationController _slide = AnimationController.unbounded(
    vsync: this,
    value: widget.selected.toDouble(),
  );

  bool get _hasSelection =>
      widget.selected >= 0 && widget.selected < widget.labels.length;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context) && _slide.isAnimating) {
      _slide.value = widget.selected.toDouble();
    }
  }

  @override
  void didUpdateWidget(ConnectedGroup oldWidget) {
    super.didUpdateWidget(oldWidget);
    final double target = widget.selected.toDouble();
    if (_slide.value == target && !_slide.isAnimating) {
      return;
    }
    final bool fromNowhere =
        oldWidget.selected < 0 ||
        oldWidget.selected >= oldWidget.labels.length ||
        oldWidget.labels.length != widget.labels.length;
    if (!_hasSelection ||
        fromNowhere ||
        MediaQuery.disableAnimationsOf(context)) {
      // Reduced motion, or no old place to slide from: land at once.
      _slide.value = target;
      return;
    }
    if (widget.selected != oldWidget.selected) {
      _slide.animateTo(
        target,
        duration: ConnectedGroup.slideDuration,
        curve: ConnectedGroup.slideCurve,
      );
    }
  }

  @override
  void dispose() {
    _slide.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final List<String> labels = widget.labels;
    const double inset = PillGeometry.filterInset;
    // The strip paints short and the targets reach past it: a switch over a
    // list is a strip, not a bar, but a finger still gets its 48. What the
    // segments take above and below the strip is transparent and lies inside
    // the room [margin] leaves anyway. A strip given a [height] of its own is
    // usually already past 48, and then there is nothing left to reach for.
    final double barHeight = widget.height ?? PillGeometry.filterHeight;
    final double segmentHeight = barHeight - inset * 2;
    final double tapHeight = math.max(PillGeometry.filterTapHeight, barHeight);
    final double overhang = (tapHeight - barHeight) / 2;
    // Concentric with the capsule inside it, whatever the height.
    final double shellRadius = segmentHeight / 2 + inset;
    return Padding(
      padding: widget.margin,
      child: SizedBox(
        height: tapHeight,
        child: AnimatedBuilder(
          animation: _slide,
          builder: (BuildContext context, Widget? track) {
            final double position = _slide.value;
            final int n = labels.length;
            return Stack(
              children: <Widget>[
                track ?? const SizedBox.shrink(),
                // ONE capsule for the whole switch. It slides from the old
                // segment to the new one; it never fades in per segment.
                // It measures the width inside a positioned child: a Stack
                // never asks positioned children for intrinsic sizes, so the
                // switch still works inside IntrinsicWidth.
                if (_hasSelection && n > 0)
                  Positioned.fill(
                    child: LayoutBuilder(
                      builder: (BuildContext context, BoxConstraints box) {
                        // The segments split the width evenly, so neither
                        // label is cramped and the first and the last capsule
                        // end at the same distance from the ends of the strip.
                        final double segmentWidth = math.max(
                          0.0,
                          (box.maxWidth - inset * 2 - inset * (n - 1)) / n,
                        );
                        return Stack(
                          children: <Widget>[
                            Positioned(
                              left: inset + position * (segmentWidth + inset),
                              top: overhang + inset,
                              width: segmentWidth,
                              height: segmentHeight,
                              child: IgnorePointer(
                                child: DecoratedBox(
                                  key: ConnectedGroup.pillKey,
                                  decoration: ShapeDecoration(
                                    color: Theme.of(context).m3.selectedFill,
                                    shape: const StadiumBorder(),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: inset),
                  child: Row(
                    children: <Widget>[
                      for (int i = 0; i < n; i++) ...<Widget>[
                        if (i > 0) const SizedBox(width: inset),
                        Expanded(
                          child: _Segment(
                            label: labels[i],
                            count: widget.badges[i] ?? 0,
                            selected: i == widget.selected,
                            // How much of the capsule sits under this
                            // segment right now: the label colour follows
                            // the capsule, not the tap.
                            lit: _hasSelection
                                ? (1 - (position - i).abs()).clamp(0.0, 1.0)
                                : 0.0,
                            height: segmentHeight,
                            slop: overhang + inset,
                            onTap: () => widget.onSelected(i),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            );
          },
          child: Positioned(
            left: 0,
            right: 0,
            top: overhang,
            bottom: overhang,
            child: DecoratedBox(
              decoration: BoxDecoration(
                // One step below the capsule's fill: the picked segment has
                // to stand out at a glance (Plane: track #222425, capsule
                // #45484A).
                color: scheme.surfaceContainerHigh.withValues(alpha: 0.96),
                borderRadius: BorderRadius.circular(shellRadius),
              ),
            ),
          ),
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
    required this.lit,
    required this.height,
    required this.slop,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool selected;

  /// 0 = the capsule is elsewhere, 1 = the capsule sits right under this
  /// label. The label colour and weight follow it.
  final double lit;

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
        // No fill of its own: the one capsule of the group slides under the
        // selected label. The press still springs the label.
        color: Colors.transparent,
        // A stadium at rest and a stadium while held: the press springs, it
        // does not turn the capsule into a rounded box.
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 8),
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
                fontWeight: FontWeight.lerp(
                  FontWeight.w500,
                  FontWeight.w700,
                  lit,
                ),
                fontSize: 14,
                color: Color.lerp(
                  scheme.onSurfaceVariant,
                  Theme.of(context).m3.onSelectedFill,
                  lit,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
