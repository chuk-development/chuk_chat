/// The cloud computer add-on (CHAT-164): the size picker and the card on the
/// pricing page.
///
/// The add-on is optional and has its own monthly price. On the pricing page
/// it is pre-selected and marked "Recommended"; the user can switch it off
/// and run Agents on their own computer instead. The same size picker serves
/// the "book later" and the "change size" sheets.
library;

import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/agents_plans.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';

/// The specs line of [size]: "4 vCPU · 8 GB RAM · 100 GB storage".
String cloudBoxSpecsText(AppLocalizations l, AgentsCloudBoxSize size) =>
    l.cloudBoxSizeSpecs('${size.vcpu}', '${size.ramGb}', '${size.diskGb}');

/// "€7.55/month" / "7,55 €/Monat" for [size].
String cloudBoxPriceText(AppLocalizations l, AgentsCloudBoxSize size) =>
    l.cloudBoxPricePerMonth(
      formatEuroAmount(size.priceEur, l.locale.languageCode),
    );

/// "one-time €2.38 setup" / "einmalig 2,38 € Einrichtung" for [size], or
/// null when the size has no setup fee.
String? cloudBoxSetupFeeText(AppLocalizations l, AgentsCloudBoxSize size) =>
    size.hasSetupFee
    ? l.cloudBoxSetupFee(
        formatEuroAmount(size.setupFeeEur, l.locale.languageCode),
      )
    : null;

/// The checkout total under a plan: the plan alone, or plan plus add-on.
/// With a one-time setup fee it names the first invoice and the monthly
/// price after it.
String agentsTotalLine(
  AppLocalizations l,
  AgentsPlan plan,
  AgentsCloudBoxSize? box,
) {
  final String lang = l.locale.languageCode;
  final String total = formatEuroAmount(agentsMonthlyTotal(plan, box), lang);
  if (box == null) return l.agentsTotalPlanOnly(total);
  if (box.hasSetupFee) {
    return l.agentsTotalFirstInvoice(
      formatEuroAmount(agentsFirstInvoiceTotal(plan, box), lang),
      total,
    );
  }
  return l.agentsTotalWithBox(total);
}

/// One row per size: the size and its monthly price, the specs under it, a
/// "Recommended" badge and, in the change sheet, a "Current" badge.
class AgentsCloudBoxSizePicker extends StatelessWidget {
  const AgentsCloudBoxSizePicker({
    super.key,
    required this.sizes,
    required this.selectedId,
    required this.onSelected,
    this.currentId,
  });

  final List<AgentsCloudBoxSize> sizes;
  final String? selectedId;

  /// The booked size, marked "Current". Null when nothing is booked.
  final String? currentId;

  /// Null draws the list read-only.
  final ValueChanged<AgentsCloudBoxSize>? onSelected;

  static ValueKey<String> optionKey(String id) =>
      ValueKey<String>('cloud-box-size-$id');

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l =
        AppLocalizations.of(context) ?? AppLocalizations(const Locale('en'));
    final ThemeData theme = Theme.of(context);
    return ExpressiveGroup(
      children: <Widget>[
        for (final AgentsCloudBoxSize size in sizes)
          ExpressiveRow(
            key: optionKey(size.id),
            icon: size.id == selectedId
                ? Icons.check_circle
                : Icons.radio_button_unchecked,
            tone: size.id == selectedId
                ? theme.m3.primaryContainer
                : theme.m3.surfaceContainerHighest,
            title:
                '${l.cloudBoxSizeLabel(size.label)} · '
                '${cloudBoxPriceText(l, size)}',
            titleMaxLines: 2,
            subtitle: cloudBoxSpecsText(l, size),
            trailing: size.id == currentId
                ? ExpressiveBadge(l.cloudBoxCurrent)
                : size.recommended
                ? ExpressiveBadge(
                    l.cloudBoxRecommended,
                    tone: theme.m3.primaryContainer,
                  )
                : null,
            onTap: switch (onSelected) {
              final ValueChanged<AgentsCloudBoxSize> pick => () => pick(size),
              null => null,
            },
          ),
      ],
    );
  }
}

/// The add-on card under the Sidekicks plans.
class AgentsCloudBoxAddonCard extends StatelessWidget {
  const AgentsCloudBoxAddonCard({
    super.key,
    required this.sizes,
    required this.enabled,
    required this.selectedId,
    required this.onEnabledChanged,
    required this.onSizeChanged,
  });

  final List<AgentsCloudBoxSize> sizes;

  /// Whether the add-on goes into the checkout.
  final bool enabled;
  final String? selectedId;

  /// Null hides the switch (payments off in this build): the card then only
  /// tells what the add-on is and what it costs.
  final ValueChanged<bool>? onEnabledChanged;
  final ValueChanged<AgentsCloudBoxSize> onSizeChanged;

  static const ValueKey<String> cardKey = ValueKey<String>(
    'cloud-box-addon-card',
  );
  static const ValueKey<String> switchKey = ValueKey<String>(
    'cloud-box-addon-switch',
  );
  static const ValueKey<String> priceKey = ValueKey<String>(
    'cloud-box-addon-price',
  );
  static const ValueKey<String> setupFeeKey = ValueKey<String>(
    'cloud-box-addon-setup-fee',
  );

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l =
        AppLocalizations.of(context) ?? AppLocalizations(const Locale('en'));
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final AgentsCloudBoxSize selected =
        cloudBoxSizeById(sizes, selectedId) ?? defaultCloudBoxSize(sizes);
    final bool showPicker = enabled || onEnabledChanged == null;
    return Container(
      key: cardKey,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        color: theme.m3.surfaceContainer,
      ),
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  l.cloudBoxTitle,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
              ),
              ExpressiveBadge(
                l.cloudBoxRecommended,
                tone: theme.m3.primaryContainer,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            l.cloudBoxAddonBody,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.m3.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          if (onEnabledChanged != null) ...<Widget>[
            ExpressiveSwitchRow(
              key: switchKey,
              icon: Icons.cloud_outlined,
              title: l.cloudBoxAddonToggle,
              subtitle: l.cloudBoxMonthlyCancel,
              value: enabled,
              onChanged: onEnabledChanged,
            ),
            const SizedBox(height: 12),
          ],
          if (showPicker) ...<Widget>[
            AgentsCloudBoxSizePicker(
              sizes: sizes,
              selectedId: selected.id,
              onSelected: onSizeChanged,
            ),
            const SizedBox(height: 12),
            Text(
              l.cloudBoxAddonPrice(
                formatEuroAmount(selected.priceEur, l.locale.languageCode),
              ),
              key: priceKey,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: scheme.onSurface,
              ),
            ),
            if (cloudBoxSetupFeeText(l, selected) case final String fee)
              Text(
                fee,
                key: setupFeeKey,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.m3.onSurfaceVariant,
                ),
              ),
            if (onEnabledChanged == null)
              Text(
                l.cloudBoxMonthlyCancel,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.m3.onSurfaceVariant,
                ),
              ),
          ],
        ],
      ),
    );
  }
}
