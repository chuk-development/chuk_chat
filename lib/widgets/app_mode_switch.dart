/// The Chat | Agents switch of the Agents build: one app, two halves.
///
/// It is the app's own two-way control, [ConnectedGroup] (the one All / Unread
/// uses), at the height of chuk's floating chips. The shell puts it in the
/// same place in both halves:
///
///  * **Phone**: the middle of the top row, right of the first chip. In Chat
///    it replaces chuk's title pill (`RootWrapperMobile.headerCenter`); in
///    Agents it sits in the inbox header, whose row has chuk's geometry for
///    exactly that reason (`MobileAgentList.headerCenter`).
///  * **Desktop**: floating at the top centre of the window, on the line of
///    the 40 px chrome buttons, pushed sideways only as far as it takes to
///    clear them (`TopCentreSlot`, `widgets/top_centre_slot.dart`).
library;

import 'package:flutter/material.dart';

import 'package:chuk_chat/services/app_mode_service.dart';
import 'package:chuk_chat/ui/expressive/connected_group.dart';

class AppModeSwitch extends StatelessWidget {
  const AppModeSwitch({
    super.key,
    required this.mode,
    required this.onChanged,
  });

  /// The half in front.
  final AppMode mode;

  /// Called with the other half when the user picks it. A press on the half
  /// that is already in front calls nothing.
  final ValueChanged<AppMode> onChanged;

  /// The labels, in [AppMode] order.
  static const List<String> labels = <String>['Chat', 'Agents'];

  /// The painted height of the strip: chuk's floating chip is 42 px, and the
  /// switch sits between two of them.
  static const double height = 42;

  /// The height of the box it takes: the strip plus the press reach above and
  /// below it, so a finger gets 48.
  static const double boxHeight = 48;

  /// Its width at normal text size. It grows with the text, and a slot that is
  /// narrower squeezes it.
  static const double width = 176;

  /// The width it asks for at the current text scale.
  static double preferredWidth(BuildContext context) =>
      MediaQuery.textScalerOf(context).scale(width);

  @override
  Widget build(BuildContext context) {
    return Semantics(
      identifier: 'app_mode_switch',
      container: true,
      explicitChildNodes: true,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: preferredWidth(context)),
        child: ConnectedGroup(
          labels: labels,
          selected: mode.index,
          margin: EdgeInsets.zero,
          height: height,
          onSelected: (int i) {
            final AppMode picked = AppMode.values[i];
            if (picked != mode) onChanged(picked);
          },
        ),
      ),
    );
  }
}
