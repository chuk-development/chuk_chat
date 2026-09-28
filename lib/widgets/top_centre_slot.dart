/// A slot that floats its child at the top centre of the window, kept clear
/// of the chrome at both ends of the row.
///
/// Used by the Chat | Agents switch on a desktop window
/// (`widgets/app_mode_switch.dart`): chuk_chat's desktop wrapper and the
/// Agents desktop layout each know where their own buttons are, and hand the
/// free band to this.
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Lays [child] out on the centre line of the box it fills, pushed sideways
/// only as far as it takes to stay inside the free band between [left] and
/// [right] (each measured from its own edge of the box).
///
/// Fill a full-width row of the window with it. A child wider than the band
/// is squeezed to the band; it is centred vertically in the box.
class TopCentreSlot extends StatelessWidget {
  const TopCentreSlot({
    super.key,
    required this.left,
    required this.right,
    required this.child,
  });

  final double left;
  final double right;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CustomSingleChildLayout(
      delegate: _TopCentreDelegate(left: left, right: right),
      child: child,
    );
  }
}

class _TopCentreDelegate extends SingleChildLayoutDelegate {
  const _TopCentreDelegate({required this.left, required this.right});

  final double left;
  final double right;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(
        maxWidth: math.max(0, constraints.maxWidth - left - right),
        maxHeight: constraints.maxHeight,
      );

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final double centred = (size.width - childSize.width) / 2;
    final double lowest = left;
    final double highest = size.width - right - childSize.width;
    final double x = highest < lowest
        ? lowest
        : centred.clamp(lowest, highest);
    return Offset(x, (size.height - childSize.height) / 2);
  }

  @override
  bool shouldRelayout(_TopCentreDelegate oldDelegate) =>
      oldDelegate.left != left || oldDelegate.right != right;
}
