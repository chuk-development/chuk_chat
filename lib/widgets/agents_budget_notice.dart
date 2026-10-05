// lib/widgets/agents_budget_notice.dart
//
// The two things the weekly budget says in a thread (docs/WIRE_CONTRACT.md,
// "Cost per run and weekly budget"):
//
//  * [AgentsBudgetWarningNotice] — one line when the coworker's week reached
//    80 % or 100 % of its budget (`budget_warning`).
//  * [AgentsBudgetRefusalCard] — the host refused a task because the budget
//    is used up (`done.reason == "budget_exceeded"`). It is not an answer and
//    not a failure: it says why, and offers "Run anyway" (the same task once
//    more, over the budget) and "Change budget".
//
// Both sit at the end of the transcript, where the run is, like the takeover
// card. No glow; the app's own buttons.

import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/agents/agents_run_cost.dart';
import 'package:chuk_chat/ui/expressive/huge_icon.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';

/// "Weekly budget: 80 % used (€4.02 of €5.00)".
class AgentsBudgetWarningNotice extends StatelessWidget {
  const AgentsBudgetWarningNotice({
    super.key,
    required this.warning,
    required this.onDismiss,
  });

  final AgentsBudgetWarning warning;
  final VoidCallback onDismiss;

  static String text(BuildContext context, AgentsBudgetWarning warning) {
    final AppLocalizations? l = AppLocalizations.of(context);
    final String locale =
        Localizations.maybeLocaleOf(context)?.toString() ?? 'en';
    final double? spent = warning.spentEur;
    final double? budget = warning.budgetEur;
    if (spent == null || budget == null) {
      return warning.isExceeded
          ? (l?.budgetNoticeExceededPlain ?? 'Weekly budget reached')
          : (l?.budgetNoticeWarningPlain ?? 'Weekly budget: 80 % used');
    }
    // The budget is whole cents; the spend too, for this line.
    final String s = formatRunCostLineEur(
      spent < 0.01 ? 0 : spent,
      locale: locale,
    );
    final String b = formatRunCostLineEur(budget, locale: locale);
    return warning.isExceeded
        ? (l?.budgetNoticeExceeded(s, b) ?? 'Weekly budget reached ($s of $b)')
        : (l?.budgetNoticeWarning(s, b) ??
              'Weekly budget: 80 % used ($s of $b)');
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final AppLocalizations? l = AppLocalizations.of(context);
    final bool exceeded = warning.isExceeded;
    return Semantics(
      container: true,
      liveRegion: true,
      child: Container(
        key: const ValueKey<String>('agents-budget-warning'),
        decoration: BoxDecoration(
          color: exceeded ? scheme.errorContainer : scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(14),
        ),
        padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
        child: Row(
          children: <Widget>[
            HugeIcon(
              HugeIcons.alertCircle,
              size: 18,
              color: exceeded ? scheme.onErrorContainer : scheme.primary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text(context, warning),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: exceeded
                      ? scheme.onErrorContainer
                      : scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            ExpressiveIconButton(
              key: const ValueKey<String>('agents-budget-warning-dismiss'),
              hugeIcon: HugeIcons.cancel01,
              size: 40,
              color: Colors.transparent,
              onColor: exceeded
                  ? scheme.onErrorContainer
                  : scheme.onSurfaceVariant,
              tooltip: l?.budgetDismiss ?? 'Dismiss',
              onTap: onDismiss,
            ),
          ],
        ),
      ),
    );
  }
}

/// A task the weekly budget refused.
class AgentsBudgetRefusalCard extends StatelessWidget {
  const AgentsBudgetRefusalCard({
    super.key,
    required this.message,
    this.onRunAnyway,
    this.onChangeBudget,
    this.dense = false,
  });

  /// The host's own sentence (`final_answer`): why, and what happens now.
  final String message;

  /// Sends the same task again with `budget_override`. Null when the refused
  /// run was not the user's own task (a schedule, a mail): there is nothing
  /// to run anyway then.
  final VoidCallback? onRunAnyway;

  /// Opens the coworker's controls, where the budget is set. Null hides it.
  final VoidCallback? onChangeBudget;

  /// Desktop size (docs/DESIGN.md §14.8): the dense buttons.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final AppLocalizations? l = AppLocalizations.of(context);
    final VoidCallback? runAnyway = onRunAnyway;
    final VoidCallback? change = onChangeBudget;
    return Semantics(
      container: true,
      liveRegion: true,
      child: Container(
        key: const ValueKey<String>('agents-budget-refusal'),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(18),
        ),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: scheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: HugeIcon(
                    HugeIcons.creditCard,
                    size: 20,
                    color: scheme.onSecondaryContainer,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        l?.budgetRefusedTitle ?? 'Weekly budget reached',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (message.trim().isNotEmpty) ...<Widget>[
                        const SizedBox(height: 2),
                        Text(
                          message.trim(),
                          key: const ValueKey<String>(
                            'agents-budget-refusal-text',
                          ),
                          maxLines: 5,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            if (runAnyway != null || change != null) ...<Widget>[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  if (runAnyway != null)
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: ExpressiveButton(
                        key: const ValueKey<String>('agents-budget-run-anyway'),
                        label: l?.budgetRunAnyway ?? 'Run anyway',
                        dense: dense,
                        onTap: runAnyway,
                      ),
                    ),
                  if (change != null)
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: ExpressiveButton(
                        key: const ValueKey<String>('agents-budget-change'),
                        label: l?.budgetChange ?? 'Change budget',
                        tonal: true,
                        dense: dense,
                        onTap: change,
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
