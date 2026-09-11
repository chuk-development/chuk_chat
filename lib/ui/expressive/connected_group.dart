/// The Material 3 Expressive connected button group — the filter row above the
/// inbox ("All" / "Unread").
///
/// The shape is the bottom navigation's: ONE rounded container that holds the
/// segments, centred and only as wide as its labels, never a bar stretched
/// across the screen. The selected segment is a filled capsule inside that
/// container; the others are bare text. A pressed segment springs and morphs
/// blockier, the same press the whole app uses.
library;

import 'package:flutter/material.dart';

import 'package:cowork/ui/expressive/icon_map.dart';
import 'package:cowork/ui/expressive/motion.dart';

class ConnectedGroup extends StatelessWidget {
  const ConnectedGroup({
    super.key,
    required this.labels,
    required this.selected,
    required this.onSelected,
    this.badges = const <int, int>{},
  });

  final List<String> labels;
  final int selected;
  final ValueChanged<int> onSelected;

  /// Optional count shown after a label (segment index → count). A zero or a
  /// missing entry shows nothing.
  final Map<int, int> badges;

  /// The corner of the container that holds the segments.
  static const double outerRadius = 30;

  /// The corner of the filled capsule under the selected segment.
  static const double selectedRadius = 22;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      // Edge to edge, unlike the navigation pill: this control belongs to the
      // list under it and sits over its whole width, and the segments split
      // that width evenly so neither label is cramped.
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.96),
          borderRadius: BorderRadius.circular(outerRadius),
        ),
        child: Row(
          children: <Widget>[
            for (int i = 0; i < labels.length; i++) ...<Widget>[
              if (i > 0) const SizedBox(width: 4),
              Expanded(
                child: _Segment(
                  label: labels[i],
                  count: badges[i] ?? 0,
                  selected: i == selected,
                  onTap: () => onSelected(i),
                ),
              ),
            ],
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
    required this.onTap,
  });

  final String label;
  final int count;
  final bool selected;
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
        color: selected ? scheme.primary : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ConnectedGroup.selectedRadius),
        ),
        pressedShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: SizedBox(
          height: 48,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              AnimatedSize(
                duration: kExpressiveShort,
                curve: kExpressiveDecelerate,
                child: selected
                    ? Padding(
                        padding: const EdgeInsets.only(right: 5),
                        child: AppIcon(
                          Icons.check_rounded,
                          size: 17,
                          color: scheme.onPrimary,
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
              Flexible(
                child: Text(
                  count > 0 ? '$label $count' : label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    color: selected
                        ? scheme.onPrimary
                        : scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
