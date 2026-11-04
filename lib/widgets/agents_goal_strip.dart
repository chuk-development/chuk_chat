// lib/widgets/agents_goal_strip.dart
//
// The goal of a thread (docs/WIRE_CONTRACT.md, "Goal mode"): one compact
// strip above the composer with the objective, the phase, the round n/max
// and, when blocked, why. Pause / Resume / Clear send `goal_control`; the
// host answers with a `goal` frame, which is what changes the strip.

import 'package:flutter/material.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/agents/agents_thread_modes.dart';
import 'package:chuk_chat/ui/expressive/huge_icon.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';

class AgentsGoalStrip extends StatelessWidget {
  const AgentsGoalStrip({
    super.key,
    required this.goal,
    required this.onControl,
    this.dense = false,
  });

  final AgentsGoal goal;

  /// `pause`, `resume` or `clear`.
  final ValueChanged<String> onControl;
  final bool dense;

  String _phaseLabel(AppLocalizations l) {
    if (goal.isComplete) return l.agentsGoalComplete;
    if (goal.isBlocked) return l.agentsGoalBlocked;
    if (goal.isPaused) return l.agentsGoalPaused;
    if (!goal.isArmed) return l.agentsGoalDisarmed;
    return l.agentsGoalActive;
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final AppLocalizations l =
        AppLocalizations.of(context) ?? AppLocalizations(const Locale('en'));
    final String rounds = goal.maxRounds > 0
        ? l.agentsGoalRounds('${goal.roundsStarted}', '${goal.maxRounds}')
        : l.agentsGoalRoundsOpen('${goal.roundsStarted}');
    final String? blocked = goal.isBlocked
        ? (goal.blockedMessage ??
              (goal.blockedCode == 'round-limit'
                  ? l.agentsGoalRoundLimit
                  : null))
        : null;
    final Color tone = goal.isBlocked
        ? scheme.errorContainer
        : scheme.surfaceContainerHigh;
    final Color onTone = goal.isBlocked
        ? scheme.onErrorContainer
        : scheme.onSurface;
    return Semantics(
      container: true,
      identifier: 'agents-goal-strip',
      child: Container(
        key: const ValueKey<String>('agents-goal-strip'),
        decoration: BoxDecoration(
          color: tone,
          borderRadius: BorderRadius.circular(kRadiusLg),
        ),
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              height: 20,
              child: Center(
                child: HugeIcon(
                  goal.isComplete
                      ? HugeIcons.checkmarkCircle02
                      : HugeIcons.target01,
                  size: 18,
                  color: onTone,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    goal.objective.isEmpty ? l.agentsGoalTitle : goal.objective,
                    key: const ValueKey<String>('agents-goal-objective'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: onTone,
                      fontWeight: FontWeight.w600,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${_phaseLabel(l)} · $rounds',
                    key: const ValueKey<String>('agents-goal-phase'),
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: onTone.withValues(alpha: 0.75),
                    ),
                  ),
                  if (blocked != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        blocked,
                        key: const ValueKey<String>('agents-goal-blocked'),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: onTone,
                        ),
                      ),
                    ),
                  const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          alignment: WrapAlignment.start,
                          children: <Widget>[
                            if (goal.canResume)
                              ExpressiveButton(
                                key: const ValueKey<String>('agents-goal-resume'),
                                label: l.agentsGoalResume,
                                dense: true,
                                onTap: () => onControl('resume'),
                              ),
                            if (goal.canPause)
                              ExpressiveButton(
                                key: const ValueKey<String>('agents-goal-pause'),
                                label: l.agentsGoalPause,
                                tonal: true,
                                dense: true,
                                onTap: () => onControl('pause'),
                              ),
                            ExpressiveButton(
                              key: const ValueKey<String>('agents-goal-clear'),
                              label: l.agentsGoalClear,
                              tonal: true,
                              dense: true,
                              onTap: () => onControl('clear'),
                            ),
                          ],
                        ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
