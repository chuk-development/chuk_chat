/// The home navigation: one floating pill, four places to be.
///
/// The shape is the messenger's: a single rounded bar that floats over the
/// content instead of sitting in a frame, the active destination carried in a
/// filled capsule, everything else a bare icon. It appears on the home surfaces
/// only — inside a conversation the screen belongs to the conversation.
library;

import 'package:flutter/material.dart';

import 'package:chuk_chat/ui/expressive/huge_icon.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/ui/expressive/pill_geometry.dart';

/// One destination of [MobileNavBar].
@immutable
class MobileNavDestination {
  const MobileNavDestination({
    required this.icon,
    required this.label,
    this.badge = 0,
  });

  final HugeIconData icon;

  /// Read out by screen readers and used as the tooltip. The bar itself shows
  /// icons only — four labels do not fit a phone without shrinking the targets.
  final String label;

  /// A count drawn on the icon. Zero draws nothing.
  final int badge;
}

class MobileNavBar extends StatelessWidget {
  const MobileNavBar({
    super.key,
    required this.destinations,
    required this.index,
    required this.onSelected,
  });

  final List<MobileNavDestination> destinations;
  final int index;
  final ValueChanged<int> onSelected;

  /// The height the content has to keep free at the bottom: the pill itself
  /// plus the air under it.
  static const double height = PillGeometry.height + _lift;

  /// How far the pill floats above the safe area.
  static const double _lift = 10;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // Centred and only as wide as its targets: the bar is a control, not a
    // frame across the bottom of the screen.
    return Padding(
      padding: EdgeInsets.only(
        bottom: MobileNavBar._lift + MediaQuery.paddingOf(context).bottom,
      ),
      child: Center(
        child: Container(
          padding: PillGeometry.shellPadding,
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.96),
            borderRadius: BorderRadius.circular(PillGeometry.radius),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (int i = 0; i < destinations.length; i++) ...<Widget>[
                if (i > 0) const SizedBox(width: PillGeometry.inset),
                _NavTarget(
                  destination: destinations[i],
                  selected: i == index,
                  onTap: () => onSelected(i),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _NavTarget extends StatelessWidget {
  const _NavTarget({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final MobileNavDestination destination;
  final bool selected;
  final VoidCallback onTap;

  /// Sized so the icon plus its air is exactly one segment tall.
  static const double _iconSize = 24;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Semantics(
      identifier: 'mobile-nav-${destination.label.toLowerCase()}',
      button: true,
      selected: selected,
      label: destination.label,
      child: Tooltip(
        message: destination.label,
        child: MorphTap(
          onTap: onTap,
          // The destination changes on pointer down. A bar that floats over a
          // scrolling list loses a recognised tap to that list far too often.
          instant: true,
          // The tap reaches into the ring around the capsule, so the target
          // is bigger than what the capsule paints.
          hitPadding: const EdgeInsets.symmetric(
            vertical: PillGeometry.tapSlop,
          ),
          color: selected ? scheme.primary : Colors.transparent,
          // A stadium at rest and a stadium while held: the press springs, it
          // does not turn the capsule into a rounded box.
          shape: const StadiumBorder(),
          pressedShape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: (PillGeometry.segmentHeight - _iconSize) / 2,
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              HugeIcon(
                destination.icon,
                size: _iconSize,
                color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
              ),
              if (destination.badge > 0)
                Positioned(
                  right: -8,
                  top: -6,
                  child: Container(
                    constraints: const BoxConstraints(
                      minWidth: 18,
                      minHeight: 18,
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: scheme.error,
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      destination.badge > 99 ? '99+' : '${destination.badge}',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: scheme.onError,
                      ),
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
