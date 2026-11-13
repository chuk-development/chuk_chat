/// The Chats | Agents switch of the Agents build: one app, two halves.
///
/// Chats is chuk_chat's own chats (chuk's root wrapper); Agents is the agent
/// list and its threads, with Home (the dashboard, docs/DASHBOARD.md) as its
/// first page. It is the app's own two-way control, [ConnectedGroup] (the one
/// All / Unread uses), at the height of chuk's floating chips. The shell puts
/// it in the same place in both halves:
///
///  * **Phone**: the middle of the top row. In Chats it replaces chuk's title
///    pill (`RootWrapperMobile.headerCenter`); in Agents it floats at the top
///    centre of the Agents pages.
///  * **Desktop**: floating at the top centre of the window, on the line of
///    the 40 px chrome buttons, pushed sideways only as far as it takes to
///    clear them (`TopCentreSlot`, `widgets/top_centre_slot.dart`).
///
/// On a phone the switch has a third segment on the left, Home (owner,
/// 2026-11-05): **Home | Chats | Agents**. Home is the dashboard; it is not
/// a page to swipe to. Pass [onHome] to get it.
library;

import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/app_mode_service.dart';
import 'package:chuk_chat/ui/expressive/connected_group.dart';

class AppModeSwitch extends StatelessWidget {
  const AppModeSwitch({
    super.key,
    required this.mode,
    required this.onChanged,
    this.home = false,
    this.onHome,
    this.large = false,
  });

  /// The head of the phone's sidebar: the switch takes the whole width it
  /// is given and is [largeHeight] high, so a thumb hits a segment easily.
  final bool large;

  /// The painted height of the [large] switch.
  static const double largeHeight = 46;

  /// The half in front.
  final AppMode mode;

  /// Called with the other half when the user picks it. A press on the half
  /// that is already in front calls nothing.
  final ValueChanged<AppMode> onChanged;

  /// Home is in front (it lives in the Agents half). Only read with [onHome].
  final bool home;

  /// Shows the Home segment; called when the user picks it.
  final VoidCallback? onHome;

  /// The labels in English, in [AppMode] order. The switch shows the
  /// localised ones ([labelsOf]) when the tree has localisations.
  static const List<String> labels = <String>['Chats', 'Sidekicks'];

  /// The labels for [context], in [AppMode] order.
  static List<String> labelsOf(BuildContext context) {
    final AppLocalizations? l = AppLocalizations.of(context);
    if (l == null) return labels;
    return <String>[l.agentsModeChats, l.agentsModeAgents];
  }

  /// The painted height of the strip: chuk's floating chip is 42 px, and the
  /// switch sits between two of them.
  static const double height = 42;

  /// The height of the box it takes: the strip plus the press reach above and
  /// below it, so a finger gets 48.
  static const double boxHeight = 48;

  /// Its width at normal text size. It grows with the text, and a slot that is
  /// narrower squeezes it.
  static const double width = 190;

  /// Its width with the Home segment.
  static const double widthWithHome = 288;

  /// The width it asks for at the current text scale.
  static double preferredWidth(BuildContext context, {bool withHome = false}) =>
      MediaQuery.textScalerOf(context).scale(withHome ? widthWithHome : width);

  @override
  Widget build(BuildContext context) {
    final VoidCallback? onHome = this.onHome;
    final bool withHome = onHome != null;
    final List<String> modeLabels = labelsOf(context);
    final List<String> shown = withHome
        ? <String>[
            AppLocalizations.of(context)?.agentsModeHome ?? 'Home',
            ...modeLabels,
          ]
        : modeLabels;
    final int selected = !withHome
        ? mode.index
        : (home && mode == AppMode.agents ? 0 : mode.index + 1);
    return Semantics(
      identifier: 'app_mode_switch',
      container: true,
      explicitChildNodes: true,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: large
              ? double.infinity
              : preferredWidth(context, withHome: withHome),
        ),
        child: ConnectedGroup(
          labels: shown,
          selected: selected,
          margin: EdgeInsets.zero,
          height: large ? largeHeight : height,
          onSelected: (int i) {
            if (i == selected) return;
            if (withHome && i == 0) {
              onHome();
              return;
            }
            final AppMode picked = AppMode.values[withHome ? i - 1 : i];
            onChanged(picked);
          },
        ),
      ),
    );
  }
}
