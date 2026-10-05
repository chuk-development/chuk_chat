// lib/widgets/agents_run_cost_meta.dart
//
// The quiet line under a coworker's answer that says what the run cost:
// "€0.41 · 5.2k tokens", "< €0.01 · 900 tokens", or the tokens alone when
// the host has no price (docs/WIRE_CONTRACT.md, "Cost per run and weekly
// budget"). A tap opens a small sheet with one row per kind of model use.
//
// The figure comes from the answer's own `agents_run_cost` call
// ([splitRunMeta]); the line is the meta text style, no chip, no glow.

import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/agents/agents_run_cost.dart';
import 'package:chuk_chat/widgets/menu_tile_group.dart';

/// The line under an answer.
class AgentsRunCostMeta extends StatelessWidget {
  const AgentsRunCostMeta({super.key, required this.cost});

  final AgentsRunCost cost;

  /// "€0.41 · 5.2k tokens" in the reader's language.
  static String label(BuildContext context, AgentsRunCost cost) {
    final AppLocalizations? l = AppLocalizations.of(context);
    final String locale =
        Localizations.maybeLocaleOf(context)?.toString() ?? 'en';
    final String count = formatTokenCount(cost.totalTokens, locale: locale);
    final String tokens = l?.runCostTokens(count) ?? '$count tokens';
    final double? eur = cost.eur;
    if (eur == null) return tokens;
    return '${formatRunCostEur(eur, locale: locale)} · $tokens';
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppLocalizations? l = AppLocalizations.of(context);
    return Semantics(
      button: true,
      hint: l?.runCostDetails ?? 'Cost details',
      child: InkWell(
        key: const ValueKey<String>('agents-run-cost-meta'),
        borderRadius: BorderRadius.circular(8),
        onTap: () => showRunCostSheet(context, cost),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            label(context, cost),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

/// The sheet behind the meta line: the total, then one row per line
/// ("Answer", "Summary and memory", "Browser") with its model, tokens and
/// euro. The app's one menu surface, so it reads like every other sheet.
Future<void> showRunCostSheet(BuildContext context, AgentsRunCost cost) {
  final AppLocalizations? l = AppLocalizations.of(context);
  final ThemeData theme = Theme.of(context);
  final String locale =
      Localizations.maybeLocaleOf(context)?.toString() ?? 'en';
  final double? total = cost.eur;
  final Widget header = Padding(
    padding: const EdgeInsets.symmetric(horizontal: 6),
    child: Row(
      children: <Widget>[
        Expanded(
          child: Text(
            l?.runCostSheetTitle ?? 'Cost of this answer',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Text(
          total == null
              ? (l?.runCostNoPrice ?? 'No price')
              : formatRunCostLineEur(total, locale: locale),
          key: const ValueKey<String>('agents-run-cost-total'),
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    ),
  );
  final List<Widget> rows = <Widget>[
    for (final AgentsRunCostLine line in cost.lines)
      _CostLineRow(line: line, locale: locale),
  ];
  return showMenuSheet<void>(
    context,
    header: header,
    groups: <List<Widget>>[
      if (rows.isNotEmpty)
        rows
      else
        <Widget>[_TotalsRow(cost: cost, locale: locale)],
    ],
  );
}

String _kindLabel(AppLocalizations? l, String kind) => switch (kind) {
  'run' => l?.runCostLineRun ?? 'Answer',
  'aux' => l?.runCostLineAux ?? 'Summary and memory',
  'browser' => l?.runCostLineBrowser ?? 'Browser',
  _ => kind,
};

String _tokensLine(AppLocalizations? l, int total, int cached, String locale) {
  final String count = formatTokenCount(total, locale: locale);
  final String tokens = l?.runCostTokens(count) ?? '$count tokens';
  if (cached <= 0) return tokens;
  final String hit = formatTokenCount(cached, locale: locale);
  return '$tokens · ${l?.runCostCached(hit) ?? '$hit cached'}';
}

class _CostLineRow extends StatelessWidget {
  const _CostLineRow({required this.line, required this.locale});

  final AgentsRunCostLine line;
  final String locale;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations? l = AppLocalizations.of(context);
    final double? eur = line.eur;
    return _SheetRow(
      key: ValueKey<String>('agents-run-cost-line-${line.kind}'),
      title: _kindLabel(l, line.kind),
      subtitle: <String>[
        ?line.model,
        _tokensLine(l, line.totalTokens, line.cachedTokens, locale),
      ].join(' · '),
      trailing: eur == null
          ? (l?.runCostNoPrice ?? 'No price')
          : formatRunCostLineEur(eur, locale: locale),
    );
  }
}

/// A block from a host that sent totals and no lines.
class _TotalsRow extends StatelessWidget {
  const _TotalsRow({required this.cost, required this.locale});

  final AgentsRunCost cost;
  final String locale;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations? l = AppLocalizations.of(context);
    final double? eur = cost.eur;
    return _SheetRow(
      title: l?.runCostTotal ?? 'Total',
      subtitle: _tokensLine(l, cost.totalTokens, cost.cachedTokens, locale),
      trailing: eur == null
          ? (l?.runCostNoPrice ?? 'No price')
          : formatRunCostLineEur(eur, locale: locale),
    );
  }
}

class _SheetRow extends StatelessWidget {
  const _SheetRow({
    super.key,
    required this.title,
    required this.subtitle,
    required this.trailing,
  });

  final String title;
  final String subtitle;
  final String trailing;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  title,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            trailing,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
