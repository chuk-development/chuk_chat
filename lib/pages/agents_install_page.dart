/// "Add your computer": one command to paste on the Linux computer.
///
/// The app makes a one-time token and shows ONE line:
///
///     curl -fsSL https://api.chuk.chat/agents/install.sh | bash -s -- --token=…
///
/// The user copies it, pastes it into a terminal on the computer, and waits.
/// The page waits too: when the computer has installed Agents and reports in,
/// the app links it to this account and the page closes. There is nothing to
/// scan and nothing to type back.
///
/// The words on screen follow the pairing page's rules: no host address, no
/// port and no protocol word. The command is the only technical text, because
/// it is the thing to paste. "Pair with a code instead" keeps the old way (a
/// code from a computer where Agents was started by hand) one tap away.
///
/// The state lives in [AgentsInstallFlow]; this file only draws it.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:chuk_chat/pages/agents_pairing_page.dart';
import 'package:chuk_chat/services/account_session.dart';
import 'package:chuk_chat/services/agents/agents_install_flow.dart';
import 'package:chuk_chat/services/agents/agents_install_ticket.dart';
import 'package:chuk_chat/services/agents/agents_pairing_uri.dart';
import 'package:chuk_chat/ui/expressive/expressive_screen.dart';
import 'package:chuk_chat/ui/expressive/icon_map.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/widgets/app_notification.dart';

/// Opens the code page and hands back what the user scanned or typed.
typedef AgentsCodePageOpener = Future<AgentsPairingInvite?> Function(
  BuildContext context,
);

class AgentsInstallPage extends StatefulWidget {
  const AgentsInstallPage({
    super.key,
    required this.ticketStore,
    required this.sessionSource,
    required this.claimWaiter,
    required this.pair,
    this.openCodePage,
    this.now,
  });

  final AgentsInstallTicketStore ticketStore;
  final AccountSessionSource sessionSource;

  /// Waits for the computer to report in (the relay claim).
  final AgentsInstallClaimWaiter claimWaiter;

  /// The shared invite pairing. The shell runs it on its live transport.
  final AgentsInstallPairer pair;

  /// Overrides the code page. Null opens [AgentsPairingPage].
  final AgentsCodePageOpener? openCodePage;

  /// Overrides the clock. Tests only.
  final DateTime Function()? now;

  static const ValueKey<String> commandKey = ValueKey<String>(
    'agents-install-command',
  );
  static const ValueKey<String> copyKey = ValueKey<String>(
    'agents-install-copy',
  );
  static const ValueKey<String> newCommandKey = ValueKey<String>(
    'agents-install-new-command',
  );
  static const ValueKey<String> useCodeKey = ValueKey<String>(
    'agents-install-use-code',
  );
  static const ValueKey<String> statusKey = ValueKey<String>(
    'agents-install-status',
  );
  static const ValueKey<String> messageKey = ValueKey<String>(
    'agents-install-message',
  );

  /// Opens the page. Completes with true when a computer was linked.
  static Future<bool> show(
    BuildContext context, {
    required AgentsInstallTicketStore ticketStore,
    required AccountSessionSource sessionSource,
    required AgentsInstallClaimWaiter claimWaiter,
    required AgentsInstallPairer pair,
  }) async {
    final bool? linked = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => AgentsInstallPage(
          ticketStore: ticketStore,
          sessionSource: sessionSource,
          claimWaiter: claimWaiter,
          pair: pair,
        ),
      ),
    );
    return linked ?? false;
  }

  /// "29 more minutes": whole minutes left, rounded up, so the last minute
  /// still reads "1 more minute" and never "0".
  static String timeLeftText(Duration left) {
    final int minutes = (left.inSeconds / 60).ceil();
    if (minutes <= 1) return 'You can use this command for 1 more minute.';
    return 'You can use this command for $minutes more minutes.';
  }

  @override
  State<AgentsInstallPage> createState() => _AgentsInstallPageState();
}

class _AgentsInstallPageState extends State<AgentsInstallPage> {
  late final AgentsInstallFlow _flow = AgentsInstallFlow(
    store: widget.ticketStore,
    sessionSource: widget.sessionSource,
    claimWaiter: widget.claimWaiter,
    pair: widget.pair,
    now: widget.now,
  );

  /// Repaints the time left. Not an animation: the text changes once in a
  /// while and nothing moves.
  Timer? _clock;

  bool _closed = false;

  @override
  void initState() {
    super.initState();
    _flow.addListener(_onFlow);
    unawaited(_flow.start());
    _clock = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    _flow.removeListener(_onFlow);
    _flow.dispose();
    super.dispose();
  }

  void _onFlow() {
    if (!mounted) return;
    if (_flow.phase == AgentsInstallPhase.linked && !_closed) {
      _closed = true;
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {});
  }

  Future<void> _copy(String command) async {
    await Clipboard.setData(ClipboardData(text: command));
    if (!mounted) return;
    AppNotifications.show(context, 'Command copied.');
  }

  Future<void> _useCode() async {
    final AgentsCodePageOpener open =
        widget.openCodePage ?? AgentsPairingPage.show;
    final AgentsPairingInvite? invite = await open(context);
    if (invite == null || !mounted) return;
    await _flow.pairWithInvite(invite);
  }

  @override
  Widget build(BuildContext context) {
    return ExpressiveScreen(
      title: 'Add your computer',
      builder: (BuildContext context) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: EdgeInsets.fromLTRB(
              16,
              MediaQuery.paddingOf(context).top + 8,
              16,
              MediaQuery.paddingOf(context).bottom + 24,
            ),
            children: _children(context),
          ),
        ),
      ),
    );
  }

  List<Widget> _children(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final TextTheme text = theme.textTheme;
    final AgentsInstallPhase phase = _flow.phase;
    final AgentsInstallTicket? ticket = _flow.ticket;
    final bool showCommand =
        ticket != null &&
        (phase == AgentsInstallPhase.waiting ||
            phase == AgentsInstallPhase.linking);

    return <Widget>[
      Text(
        'Run this command in a terminal on your Linux computer. It installs '
        'Agents and links the computer to your account.',
        style: text.bodyLarge?.copyWith(color: scheme.onSurface),
      ),
      const SizedBox(height: 16),
      if (showCommand) ...<Widget>[
        _CommandBox(command: ticket.command),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: ExpressiveButton(
            key: AgentsInstallPage.copyKey,
            icon: Icons.copy,
            label: 'Copy command',
            onTap: () => unawaited(_copy(ticket.command)),
          ),
        ),
        const SizedBox(height: 24),
      ],
      _status(context),
      const SizedBox(height: 24),
      if (phase != AgentsInstallPhase.linking &&
          phase != AgentsInstallPhase.signedOut &&
          phase != AgentsInstallPhase.preparing)
        Align(
          alignment: Alignment.centerLeft,
          child: ExpressiveButton(
            key: AgentsInstallPage.newCommandKey,
            icon: Icons.refresh,
            label: 'New command',
            // The primary action once the old command cannot work any more.
            tonal: phase == AgentsInstallPhase.waiting,
            onTap: () => unawaited(_flow.newCommand()),
          ),
        ),
      const SizedBox(height: 8),
      if (phase != AgentsInstallPhase.linking &&
          phase != AgentsInstallPhase.signedOut)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            key: AgentsInstallPage.useCodeKey,
            onPressed: () => unawaited(_useCode()),
            child: const Text('Pair with a code instead'),
          ),
        ),
    ];
  }

  /// One title and one line about where things stand.
  Widget _status(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final TextTheme text = theme.textTheme;
    final AgentsInstallTicket? ticket = _flow.ticket;
    final (String title, String? body) = switch (_flow.phase) {
      AgentsInstallPhase.preparing => ('One moment…', null),
      AgentsInstallPhase.waiting => (
        'Waiting for your computer…',
        ticket == null
            ? null
            : AgentsInstallPage.timeLeftText(ticket.remainingAt(_flow.now())),
      ),
      AgentsInstallPhase.linking => ('Linking your computer…', null),
      AgentsInstallPhase.linked => ('Your computer is linked.', null),
      AgentsInstallPhase.expired => (
        'This command has expired.',
        'Make a new command and run it on your computer.',
      ),
      AgentsInstallPhase.failed => ('Your computer is not linked.', null),
      AgentsInstallPhase.signedOut => ('You are not signed in.', null),
    };
    final String? message = _flow.message;
    return Column(
      key: AgentsInstallPage.statusKey,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          title,
          style: text.titleMedium?.copyWith(
            color: scheme.onSurface,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (body != null) ...<Widget>[
          const SizedBox(height: 4),
          Text(
            body,
            style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
        if (message != null && message.isNotEmpty) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            message,
            key: AgentsInstallPage.messageKey,
            style: text.bodyMedium?.copyWith(color: scheme.error),
          ),
        ],
      ],
    );
  }
}

/// The command, in a flat card, selectable. A long line wraps instead of
/// running off the screen.
class _CommandBox extends StatelessWidget {
  const _CommandBox({required this.command});

  final String command;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: scheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.only(top: 2, right: 12),
              child: AppIcon(
                Icons.terminal,
                size: 18,
                color: scheme.onSurfaceVariant,
              ),
            ),
            Expanded(
              child: SelectableText(
                command,
                key: AgentsInstallPage.commandKey,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontFamily: 'monospace',
                  color: scheme.onSurface,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
