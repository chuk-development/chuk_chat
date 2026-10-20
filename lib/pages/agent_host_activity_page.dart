/// "Host & activity" on a phone: the agent's measured activity and the box
/// it works in ([AgentControlPanel]), in the settings-page frame.
///
/// The frame is the one every agent settings page wears (bead
/// chuk_chat-8hz4): `extendBodyBehindAppBar`, [FloatingAppBar] with the
/// shared back chip and the title pill, and a list that scrolls up behind a
/// bar that draws no fill.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/services/agents/agent_control_source.dart';
import 'package:chuk_chat/ui/expressive/feedback.dart';
import 'package:chuk_chat/widgets/agent_control_panel.dart';
import 'package:chuk_chat/widgets/floating_app_bar.dart';

class AgentHostActivityPage extends StatelessWidget {
  const AgentHostActivityPage({
    super.key,
    required this.agent,
    required this.source,
  });

  final AgentsAgent agent;
  final AgentControlSource source;

  /// The agent's thread key is its session key on the host.
  String get _sessionKey =>
      agent.threads.isEmpty ? agent.id : agent.threads.first.key;

  /// A host that cannot answer says so; the error itself may carry host
  /// detail, so it is not shown.
  Future<void> _refresh(BuildContext context) async {
    try {
      await source.refresh(_sessionKey);
    } catch (_) {
      if (!context.mounted) return;
      pillToast(context, 'Could not refresh. Try again in a moment.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l =
        AppLocalizations.of(context) ?? AppLocalizations(const Locale('en'));
    return Scaffold(
      // The page runs underneath the floating header.
      extendBodyBehindAppBar: true,
      appBar: FloatingAppBar(
        title: Text(l.agentsCwHost),
        actions: <Widget>[
          FloatingHeaderButton(
            icon: Icons.refresh,
            tooltip: 'Refresh',
            onPressed: () => unawaited(_refresh(context)),
          ),
        ],
      ),
      body: AgentControlPanel(agent: agent, source: source),
    );
  }
}
