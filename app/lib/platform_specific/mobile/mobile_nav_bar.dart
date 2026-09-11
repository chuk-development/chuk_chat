/// The home navigation: one floating pill, four places to be.
///
/// The shape is the messenger's: a single rounded bar that floats over the
/// content instead of sitting in a frame, the active destination carried in a
/// filled capsule, everything else a bare icon. It appears on the home surfaces
/// only — inside a conversation the screen belongs to the conversation.
library;

import 'package:flutter/material.dart';

import 'package:cowork/ui/expressive/motion.dart';

/// One destination of [MobileNavBar].
@immutable
class MobileNavDestination {
  const MobileNavDestination({
    required this.icon,
    required this.label,
    this.badge = 0,
  });

  final IconData icon;

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

  /// The height the content has to keep free at the bottom.
  static const double height = 64;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // Centred and only as wide as its targets: the bar is a control, not a
    // frame across the bottom of the screen.
    return Padding(
      padding: EdgeInsets.only(
        bottom: 10 + MediaQuery.paddingOf(context).bottom,
      ),
      child: Center(
        child: Container(
          height: MobileNavBar.height - 12,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.96),
            borderRadius: BorderRadius.circular(30),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (int i = 0; i < destinations.length; i++) ...<Widget>[
                if (i > 0) const SizedBox(width: 4),
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
          color: selected ? scheme.primary : Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
          pressedShape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 9),
          child: Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              Icon(
                destination.icon,
                size: 24,
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
