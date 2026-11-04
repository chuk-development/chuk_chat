// lib/widgets/agents_wait_label.dart
//
// The inbox's word for an agent that waits on the user: "Approval",
// "Answer", "Plan review" or "Needs you". It replaces the time on the row,
// so a waiting agent is found at a glance (docs/WIRE_CONTRACT.md, "Agent
// modes", and the run ledger's waitingForUser).

import 'package:flutter/material.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/services/agents/agents_derived_threads.dart';
import 'package:chuk_chat/services/agents/agents_run_ledger.dart';
import 'package:chuk_chat/services/agents/agents_thread_modes.dart';

/// Every thread key of [agent]: its own threads and the chats its
/// automations made.
List<String> agentThreadKeys(
  AgentsAgent agent, {
  AgentsDerivedThreads? derived,
}) {
  final AgentsDerivedThreads store = derived ?? AgentsDerivedThreads.instance;
  final List<String> keys = <String>[
    for (final AgentsThreadInfo t in agent.threads) t.key,
  ];
  for (final String owner in List<String>.of(keys)) {
    for (final AgentsDerivedThread t in store.forOwner(owner)) {
      if (!keys.contains(t.key)) keys.add(t.key);
    }
  }
  return keys;
}

/// What [keys] wait on the user for, or null. The mode frames name the
/// kind; a run the thread view marked as waiting (a secret request, a
/// takeover) without one reads "Needs you".
AgentsWaitKind? agentsWaitKindForKeys(
  Iterable<String> keys, {
  AgentsThreadModes? modes,
  AgentsRunLedger? ledger,
}) {
  final AgentsWaitKind? kind = (modes ?? AgentsThreadModes.instance)
      .waitKindOfAny(keys);
  if (kind != null) return kind;
  final AgentsRunLedger runs = ledger ?? AgentsRunLedger.instance;
  for (final String key in keys) {
    final AgentsRun? run = runs.runFor(key);
    if (run != null && run.running && run.waitingForUser) {
      return AgentsWaitKind.needsYou;
    }
  }
  return null;
}

AgentsWaitKind? agentsWaitKindFor(
  AgentsAgent agent, {
  AgentsThreadModes? modes,
  AgentsRunLedger? ledger,
}) => agentsWaitKindForKeys(agentThreadKeys(agent), modes: modes, ledger: ledger);

String agentsWaitLabel(AppLocalizations l, AgentsWaitKind kind) =>
    switch (kind) {
      AgentsWaitKind.approval => l.agentsWaitApproval,
      AgentsWaitKind.answer => l.agentsWaitAnswer,
      AgentsWaitKind.planReview => l.agentsWaitPlanReview,
      AgentsWaitKind.needsYou => l.agentsWaitNeedsYou,
    };

/// The small label in place of the time.
class AgentsWaitPill extends StatelessWidget {
  const AgentsWaitPill({super.key, required this.kind});

  final AgentsWaitKind kind;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final AppLocalizations l =
        AppLocalizations.of(context) ?? AppLocalizations(const Locale('en'));
    return Container(
      key: ValueKey<String>('agents-wait-${kind.name}'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.primary,
        borderRadius: BorderRadius.circular(kRadiusSm),
      ),
      child: Text(
        agentsWaitLabel(l, kind),
        maxLines: 1,
        style: theme.textTheme.labelSmall?.copyWith(
          color: scheme.onPrimary,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}
