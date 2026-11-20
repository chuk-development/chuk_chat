// lib/widgets/agents_mode_bar.dart
//
// What sits right above the Agents composer: the sandbox warning when the
// host runs the agent without a container, the goal strip and the todo card
// (docs/WIRE_CONTRACT.md, "Agent modes" and "Sandbox fallback"). Everything is
// read from [AgentsThreadModes]; the bar draws nothing when there is nothing
// to say. There is no plan-mode toggle (owner, 2026-11-20).

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/agents/agents_thread_modes.dart';
import 'package:chuk_chat/ui/expressive/huge_icon.dart';
import 'package:chuk_chat/widgets/agents_goal_strip.dart';
import 'package:chuk_chat/widgets/agents_todo_card.dart';

/// The small banner: "Running without sandbox: Docker unavailable".
class AgentsSandboxBanner extends StatelessWidget {
  const AgentsSandboxBanner({super.key, this.long = false});

  /// The longer sentence of the settings page.
  final bool long;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final AppLocalizations l =
        AppLocalizations.of(context) ?? AppLocalizations(const Locale('en'));
    return Semantics(
      container: true,
      liveRegion: true,
      identifier: 'agents-sandbox-fallback',
      child: Container(
        key: ValueKey<String>(
          long ? 'agents-sandbox-warning' : 'agents-sandbox-banner',
        ),
        decoration: BoxDecoration(
          color: scheme.errorContainer,
          borderRadius: BorderRadius.circular(long ? kRadiusLg : kRadiusMd),
        ),
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: long ? 12 : 7),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              height: 20,
              child: Center(
                child: HugeIcon(
                  HugeIcons.shieldAlert,
                  size: 16,
                  color: scheme.onErrorContainer,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                long
                    ? l.agentsSandboxFallbackWarning
                    : l.agentsSandboxFallbackBanner,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onErrorContainer,
                  fontWeight: FontWeight.w600,
                  height: 1.45,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The stack above the composer for one thread.
class AgentsModeBar extends StatelessWidget {
  const AgentsModeBar({
    super.key,
    required this.threadKey,
    this.modes,
    this.dense = false,
    this.onGoalControlFailed,
  });

  final String threadKey;

  /// Defaults to [AgentsThreadModes.instance].
  final AgentsThreadModes? modes;
  final bool dense;

  /// Called when a goal button could not reach the host.
  final VoidCallback? onGoalControlFailed;

  @override
  Widget build(BuildContext context) {
    final AgentsThreadModes store = modes ?? AgentsThreadModes.instance;
    return ListenableBuilder(
      listenable: store,
      builder: (BuildContext context, Widget? _) {
        final AgentsGoal? goal = store.goalOf(threadKey);
        final List<AgentsTodo> todos = store.todosOf(threadKey);
        final List<Widget> rows = <Widget>[
          if (store.sandboxFallback) const AgentsSandboxBanner(),
          if (goal != null)
            AgentsGoalStrip(
              goal: goal,
              dense: dense,
              onControl: (String action) => unawaited(
                store.goalControl(threadKey, action).then((bool sent) {
                  if (!sent) onGoalControlFailed?.call();
                }),
              ),
            ),
          if (todos.isNotEmpty) AgentsTodoCard(todos: todos),
        ];
        if (rows.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            key: const ValueKey<String>('agents-mode-bar'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (int i = 0; i < rows.length; i++) ...<Widget>[
                if (i > 0) const SizedBox(height: 6),
                rows[i],
              ],
            ],
          ),
        );
      },
    );
  }
}
