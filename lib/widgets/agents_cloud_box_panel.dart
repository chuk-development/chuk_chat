/// The calm screen of the zero-click cloud computer setup (CHAT-164).
///
/// The Agents shell draws it where the "Add your computer" panel would be,
/// while [AgentsCloudBoxFlow] is setting up, waiting longer than usual,
/// linking, paused for a payment problem, or failed. It has the same shape
/// as [AgentsStatusPanel]: one tile, one title, one line, at most one primary
/// action and one quiet secondary one. The loader is the only thing that
/// moves, and only while the setup really runs (docs/DESIGN.md §8).
///
/// It is a panel, not a route: the user can switch to Chat or leave at any
/// time, and the setup goes on behind it.
library;

import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/agents/agents_cloud_box_flow.dart';
import 'package:chuk_chat/ui/expressive/icon_map.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';

class AgentsCloudBoxPanel extends StatelessWidget {
  const AgentsCloudBoxPanel({
    super.key,
    required this.phase,
    this.onRetry,
    this.onOpenBilling,
    this.onUseOwnComputer,
    this.topInset = 0,
  });

  final AgentsCloudBoxPhase phase;
  final VoidCallback? onRetry;
  final VoidCallback? onOpenBilling;

  /// The self-hosting way out: the install page with its command.
  final VoidCallback? onUseOwnComputer;

  /// Room the panel keeps clear at the top for chrome painted over it.
  final double topInset;

  static const ValueKey<String> titleKey = ValueKey<String>(
    'agents-cloud-box-title',
  );
  static const ValueKey<String> loaderKey = ValueKey<String>(
    'agents-cloud-box-loader',
  );
  static const ValueKey<String> retryKey = ValueKey<String>(
    'agents-cloud-box-retry',
  );
  static const ValueKey<String> billingKey = ValueKey<String>(
    'agents-cloud-box-billing',
  );
  static const ValueKey<String> ownComputerKey = ValueKey<String>(
    'agents-cloud-box-own-computer',
  );

  bool get _working =>
      phase == AgentsCloudBoxPhase.settingUp ||
      phase == AgentsCloudBoxPhase.slow ||
      phase == AgentsCloudBoxPhase.linking ||
      phase == AgentsCloudBoxPhase.checking;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l =
        AppLocalizations.of(context) ?? AppLocalizations(const Locale('en'));
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final TextTheme text = theme.textTheme;

    final (String title, String body) = switch (phase) {
      AgentsCloudBoxPhase.slow => (l.cloudBoxSlowTitle, l.cloudBoxSlowBody),
      AgentsCloudBoxPhase.linking => (l.cloudBoxLinkingTitle, ''),
      AgentsCloudBoxPhase.suspended => (
        l.cloudBoxSuspendedTitle,
        l.cloudBoxSuspendedBody,
      ),
      AgentsCloudBoxPhase.failed => (
        l.cloudBoxFailedTitle,
        l.cloudBoxFailedBody,
      ),
      _ => (l.cloudBoxSettingUpTitle, l.cloudBoxSettingUpBody),
    };
    final VoidCallback? billing = onOpenBilling;
    final VoidCallback? retry = onRetry;
    final bool problem =
        phase == AgentsCloudBoxPhase.suspended ||
        phase == AgentsCloudBoxPhase.failed;

    final Widget tile = Container(
      width: 88,
      height: 88,
      decoration: ShapeDecoration(
        color: problem
            ? scheme.surfaceContainerHighest
            : scheme.primaryContainer,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
      ),
      alignment: Alignment.center,
      child: AppIcon(
        problem ? Icons.cloud_off_outlined : Icons.cloud_outlined,
        size: 40,
        color: problem ? scheme.onSurfaceVariant : scheme.onPrimaryContainer,
      ),
    );

    final List<Widget> children = <Widget>[
      tile,
      const SizedBox(height: 20),
      Text(
        title,
        key: titleKey,
        style: text.titleLarge?.copyWith(color: scheme.onSurface),
        textAlign: TextAlign.center,
      ),
      if (body.isNotEmpty) ...<Widget>[
        const SizedBox(height: 8),
        Text(
          body,
          style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          textAlign: TextAlign.center,
        ),
      ],
      if (_working) ...<Widget>[
        const SizedBox(height: 24),
        const ExpressiveLoader(key: loaderKey, size: 40),
      ],
      if (phase == AgentsCloudBoxPhase.suspended &&
          billing != null) ...<Widget>[
        const SizedBox(height: 24),
        ExpressiveButton(
          key: billingKey,
          label: l.cloudBoxOpenBilling,
          icon: Icons.credit_card,
          onTap: billing,
        ),
      ],
      if (phase == AgentsCloudBoxPhase.failed && retry != null) ...<Widget>[
        const SizedBox(height: 24),
        ExpressiveButton(
          key: retryKey,
          label: l.cloudBoxRetry,
          icon: Icons.refresh,
          onTap: retry,
        ),
      ],
      if (onUseOwnComputer != null &&
          phase != AgentsCloudBoxPhase.linking) ...<Widget>[
        const SizedBox(height: 12),
        TextButton(
          key: ownComputerKey,
          onPressed: onUseOwnComputer,
          child: Text(l.cloudBoxUseOwnComputer),
        ),
      ],
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
}
