/// The Material 3 Expressive connected button group — the filter row above the
/// inbox ("All" / "Unread").
///
/// The segments share one track. The selected segment morphs to a full pill and
/// grows a check; a pressed segment morphs SQUARE and springs. The group
/// divides the width evenly, so it fits any phone.
library;

import 'package:flutter/material.dart';

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

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          for (int i = 0; i < labels.length; i++)
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(right: i == labels.length - 1 ? 0 : 4),
                child: _Segment(
                  label: labels[i],
                  count: badges[i] ?? 0,
                  selected: i == selected,
                  onTap: () => onSelected(i),
                  scheme: scheme,
                  first: i == 0,
                  last: i == labels.length - 1,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Segment extends StatefulWidget {
  const _Segment({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
    required this.scheme,
    required this.first,
    required this.last,
  });

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;
  final ColorScheme scheme;
  final bool first;
  final bool last;

  @override
  State<_Segment> createState() => _SegmentState();
}

class _SegmentState extends State<_Segment> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final ColorScheme s = widget.scheme;
    final bool on = widget.selected;
    final double radius = _down
        ? 9.0
        : on
        ? 26.0
        : 14.0;
    final double endRadius = _down ? 12.0 : 26.0;

    return AnimatedScale(
      scale: _down ? 0.94 : 1,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutBack,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutBack,
        height: 48,
        decoration: ShapeDecoration(
          color: on ? s.primary : s.surfaceContainerHighest,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.horizontal(
              left: Radius.circular(widget.first ? endRadius : radius),
              right: Radius.circular(widget.last ? endRadius : radius),
            ),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onTap,
            onHighlightChanged: (bool v) => setState(() => _down = v),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  AnimatedSize(
                    duration: const Duration(milliseconds: 240),
                    curve: Curves.easeOutBack,
                    child: on
                        ? Padding(
                            padding: const EdgeInsets.only(right: 5),
                            child: Icon(
                              Icons.check_rounded,
                              size: 17,
                              color: s.onPrimary,
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                  Flexible(
                    child: Text(
                      widget.count > 0
                          ? '${widget.label} ${widget.count}'
                          : widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                        color: on ? s.onPrimary : s.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
