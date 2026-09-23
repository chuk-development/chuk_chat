/// The panel the Agents shell shows where a conversation would be, while
/// there is none: no computer, a computer coming up, a computer that is off,
/// a connection with no agents yet (see `agents_shell_status.dart`).
///
/// One calm column: a glyph tile, one title, one line, at most one primary
/// action and one quiet secondary one. The app theme owns every colour; no
/// shadow, no glow, no gradient (docs/DESIGN.md §7–§8). It never names a host,
/// an address, a port or a socket — the user has nothing to do with any of it.
library;

import 'package:flutter/material.dart';

import 'package:chuk_chat/services/agents/agents_shell_status.dart';
import 'package:chuk_chat/ui/expressive/icon_map.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';

class AgentsStatusPanel extends StatelessWidget {
  const AgentsStatusPanel({
    super.key,
    required this.status,
    this.message,
    this.busy = false,
    this.onAddComputer,
    this.onReconnect,
    this.onAddAgent,
    this.footer,
    this.topInset = 0,
  });

  final AgentsShellStatus status;

  /// A plain sentence about the last failure, shown under the body.
  final String? message;

  /// A connect or reconnect is in flight: the action shows it and waits.
  final bool busy;

  final VoidCallback? onAddComputer;
  final VoidCallback? onReconnect;
  final VoidCallback? onAddAgent;

  /// Extra content under the actions (the developer's same-machine row).
  final Widget? footer;

  /// Room the panel keeps clear at the top for chrome painted over it.
  final double topInset;

  static const ValueKey<String> addComputerKey = ValueKey<String>(
    'agents-add-computer',
  );
  static const ValueKey<String> reconnectKey = ValueKey<String>(
    'agents-status-reconnect',
  );
  static const ValueKey<String> addAgentKey = ValueKey<String>(
    'agents-status-add-agent',
  );

  /// The title each status shows. Public so tests and the phone inbox read
  /// the same words.
  static String titleFor(AgentsShellStatus status) => switch (status) {
    AgentsShellStatus.starting => 'One moment…',
    AgentsShellStatus.notPaired => 'Add your computer',
    AgentsShellStatus.lookingForComputer => 'Looking for your computer…',
    AgentsShellStatus.connecting => 'Connecting to your computer…',
    AgentsShellStatus.healing => 'Renewing your computer’s sign-in…',
    AgentsShellStatus.offline => 'Your computer is offline',
    AgentsShellStatus.noAgents => 'No agents yet',
    AgentsShellStatus.ready => 'Choose an agent',
  };

  static String bodyFor(AgentsShellStatus status) => switch (status) {
    AgentsShellStatus.starting => '',
    AgentsShellStatus.notPaired =>
      'Your agents run on your own computer. Open Agents there and scan the '
          'code it shows.',
    AgentsShellStatus.lookingForComputer =>
      'Checking your account for a computer you added before.',
    AgentsShellStatus.connecting => 'This usually takes a few seconds.',
    AgentsShellStatus.healing => 'This takes a few seconds.',
    AgentsShellStatus.offline =>
      'Make sure it is on and Agents is running there.',
    AgentsShellStatus.noAgents =>
      'Your computer is connected. Add an agent to start.',
    AgentsShellStatus.ready => 'Pick one from the list to open its chat.',
  };

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final TextTheme text = theme.textTheme;
    final String title = titleFor(status);
    final String body = bodyFor(status);
    final bool emphasis =
        status == AgentsShellStatus.notPaired ||
        status == AgentsShellStatus.noAgents;

    final Widget tile = Container(
      key: const ValueKey<String>('agents-status-tile'),
      width: 88,
      height: 88,
      decoration: ShapeDecoration(
        color: emphasis
            ? scheme.primaryContainer
            : scheme.surfaceContainerHighest,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
      ),
      alignment: Alignment.center,
      // A still glyph, never a spinner: nothing on this screen moves for
      // ever (docs/DESIGN.md §8). The title's ellipsis says it is under way.
      child: AppIcon(
        status == AgentsShellStatus.noAgents ||
                status == AgentsShellStatus.ready
            ? Icons.groups_outlined
            : Icons.computer,
        size: 40,
        color: emphasis ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
      ),
    );

    final List<Widget> children = <Widget>[
      tile,
      if (title.isNotEmpty) ...<Widget>[
        const SizedBox(height: 20),
        Text(
          title,
          key: const ValueKey<String>('agents-status-title'),
          style: text.titleLarge?.copyWith(color: scheme.onSurface),
          textAlign: TextAlign.center,
        ),
      ],
      if (body.isNotEmpty) ...<Widget>[
        const SizedBox(height: 8),
        Text(
          body,
          style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          textAlign: TextAlign.center,
        ),
      ],
      if (message != null && message!.isNotEmpty) ...<Widget>[
        const SizedBox(height: 12),
        Text(
          message!,
          key: const ValueKey<String>('agents-status-message'),
          style: text.bodyMedium?.copyWith(color: scheme.error),
          textAlign: TextAlign.center,
        ),
      ],
      ..._actions(context),
      if (footer != null) ...<Widget>[const SizedBox(height: 16), footer!],
    ];

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(24, 24 + topInset, 24, 24),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: constraints.hasBoundedHeight
                  ? (constraints.maxHeight - 48 - topInset).clamp(
                      0,
                      double.infinity,
                    )
                  : 0,
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 380),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: children,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  List<Widget> _actions(BuildContext context) {
    final VoidCallback? addComputer = onAddComputer;
    final VoidCallback? reconnect = onReconnect;
    final VoidCallback? addAgent = onAddAgent;
    switch (status) {
      case AgentsShellStatus.notPaired:
        if (addComputer == null) return const <Widget>[];
        return <Widget>[
          const SizedBox(height: 24),
          _Primary(
            key: addComputerKey,
            label: 'Add your computer',
            icon: Icons.qr_code_scanner,
            busy: busy,
            busyLabel: 'Adding…',
            onTap: addComputer,
          ),
        ];
      case AgentsShellStatus.lookingForComputer:
        // Never a dead end: an account that never added a computer can add
        // one now instead of waiting for a search that finds nothing.
        if (addComputer == null) return const <Widget>[];
        return <Widget>[
          const SizedBox(height: 20),
          ExpressiveButton(
            key: addComputerKey,
            label: 'Add a computer',
            icon: Icons.qr_code_scanner,
            tonal: true,
            onTap: busy ? () {} : addComputer,
          ),
        ];
      case AgentsShellStatus.offline:
        if (reconnect == null) return const <Widget>[];
        return <Widget>[
          const SizedBox(height: 24),
          _Primary(
            key: reconnectKey,
            label: 'Reconnect',
            icon: Icons.refresh,
            busy: busy,
            busyLabel: 'Reconnecting…',
            onTap: reconnect,
          ),
        ];
      case AgentsShellStatus.noAgents:
        if (addAgent == null) return const <Widget>[];
        return <Widget>[
          const SizedBox(height: 24),
          _Primary(
            key: addAgentKey,
            label: 'Add an agent',
            icon: Icons.person_add_alt,
            busy: false,
            busyLabel: '',
            onTap: addAgent,
          ),
        ];
      case AgentsShellStatus.starting:
      case AgentsShellStatus.connecting:
      case AgentsShellStatus.healing:
      case AgentsShellStatus.ready:
        return const <Widget>[];
    }
  }
}

/// The one filled action. While [busy] it says what it is doing and ignores
/// taps, so a second tap cannot start a second attempt.
class _Primary extends StatelessWidget {
  const _Primary({
    super.key,
    required this.label,
    required this.icon,
    required this.busy,
    required this.busyLabel,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool busy;
  final String busyLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ExpressiveButton(
      label: busy ? busyLabel : label,
      icon: icon,
      onTap: busy ? () {} : onTap,
      tonal: busy,
    );
  }
}
