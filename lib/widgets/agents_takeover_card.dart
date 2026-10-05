// lib/widgets/agents_takeover_card.dart
//
// "<Coworker> needs you in the browser": the one card a thread shows when the
// agent's browser reached a step only the user can do — a login, a 2FA code,
// a CAPTCHA (research item 6, docs/research/AGENT_COMPETITORS_2026-10.md).
//
// The request is an `approval_request` with action `browser_takeover`
// (docs/WIRE_CONTRACT.md, "Browser takeover"); the run waits on the host
// until the user answers. The card has one job: get the user into the live
// browser view, where they act themselves, and let them say "done". Once the
// agent picks up again the card says so and goes away.

import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/ui/expressive/huge_icon.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';

/// Where a takeover stands, as the card draws it.
enum AgentsTakeoverStage {
  /// The run waits on the user.
  waiting,

  /// The user said done (or the host saw it); the agent is picking up.
  continuing,
}

class AgentsTakeoverCard extends StatelessWidget {
  const AgentsTakeoverCard({
    super.key,
    required this.request,
    required this.coworkerName,
    required this.stage,
    required this.visited,
    required this.onOpenBrowser,
    required this.onDone,
    required this.onSkip,
    this.dense = false,
  });

  /// The host's request: what the agent hit, on which site, and why.
  final AgentsRelayApprovalRequest request;

  /// The coworker's name for the title. Empty falls back to "Your coworker".
  final String coworkerName;

  final AgentsTakeoverStage stage;

  /// The user has opened the browser view at least once for this request.
  /// Until then the card offers only the way in; after it, "Done" as well.
  final bool visited;

  /// Opens the live browser view. Null while no paired transport exists.
  final VoidCallback? onOpenBrowser;

  /// Tells the host the step is done, so the run continues.
  final VoidCallback onDone;

  /// Tells the host the user will not do the step. Always offered, also
  /// before the view was opened and while no transport exists, so the
  /// user can always end the wait.
  final VoidCallback onSkip;

  /// Desktop size (docs/DESIGN.md §14.8): the dense buttons.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final AppLocalizations? l = AppLocalizations.of(context);
    final String name = coworkerName.trim().isEmpty
        ? (l?.takeoverSomeone ?? 'Your coworker')
        : coworkerName.trim();

    final Widget body = stage == AgentsTakeoverStage.continuing
        ? _continuing(theme, l, name)
        : _waiting(context, theme, l, name);

    return Semantics(
      container: true,
      liveRegion: true,
      child: Container(
        key: const ValueKey<String>('agents-takeover-card'),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(18),
        ),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: AnimatedSize(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topLeft,
          child: body,
        ),
      ),
    );
  }

  Widget _waiting(
    BuildContext context,
    ThemeData theme,
    AppLocalizations? l,
    String name,
  ) {
    final ColorScheme scheme = theme.colorScheme;
    final String site = request.site ?? (l?.takeoverThisSite ?? 'this site');
    final String instruction = switch (request.takeoverKind) {
      'login' => l?.takeoverLogin(site) ?? 'Sign in to $site, then tap Done.',
      'two_factor' =>
        l?.takeoverTwoFactor(site) ??
            'Enter the security code for $site, then tap Done.',
      'captcha' =>
        l?.takeoverCaptcha(site) ?? 'Solve the check on $site, then tap Done.',
      _ => l?.takeoverOther(site) ?? 'Finish the step on $site, then tap Done.',
    };
    final String? reason = request.reason;
    return Column(
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
                _iconFor(request.takeoverKind),
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
                    l?.takeoverTitle(name) ?? '$name needs you in the browser',
                    key: const ValueKey<String>('agents-takeover-title'),
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    instruction,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  if (reason != null) ...<Widget>[
                    const SizedBox(height: 2),
                    Text(
                      reason,
                      maxLines: 3,
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
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          // A button never grows wider than the card: on a narrow phone at a
          // large text size it scales down instead of overflowing.
          children: <Widget>[
            for (final Widget button in <Widget>[
              ExpressiveButton(
                key: const ValueKey<String>('agents-takeover-open'),
                label: l?.takeoverOpen ?? 'Open browser',
                icon: Icons.desktop_windows_rounded,
                dense: dense,
                // Never a dead tap: with no transport the view cannot open,
                // and the press simply does nothing until the link is back.
                onTap: onOpenBrowser ?? () {},
                color: onOpenBrowser == null
                    ? scheme.primary.withValues(alpha: 0.38)
                    : null,
              ),
              if (visited)
                ExpressiveButton(
                  key: const ValueKey<String>('agents-takeover-done'),
                  label: l?.takeoverDone ?? 'Done',
                  icon: Icons.check_circle_outline,
                  tonal: true,
                  dense: dense,
                  onTap: onDone,
                ),
              ExpressiveButton(
                key: const ValueKey<String>('agents-takeover-skip'),
                label: l?.takeoverSkip ?? 'Skip',
                icon: Icons.skip_next_rounded,
                tonal: true,
                dense: dense,
                onTap: onSkip,
              ),
            ])
              FittedBox(fit: BoxFit.scaleDown, child: button),
          ],
        ),
      ],
    );
  }

  Widget _continuing(ThemeData theme, AppLocalizations? l, String name) {
    final ColorScheme scheme = theme.colorScheme;
    return Row(
      children: <Widget>[
        HugeIcon(HugeIcons.checkmarkCircle02, size: 18, color: scheme.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            l?.takeoverContinues(name) ?? '$name continues',
            key: const ValueKey<String>('agents-takeover-continues'),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  /// One glyph per kind, from the app's own set (docs/DESIGN.md §5).
  static HugeIconData _iconFor(String? kind) => switch (kind) {
    'login' || 'two_factor' => HugeIcons.key01,
    'captcha' => HugeIcons.robot01,
    _ => HugeIcons.globe02,
  };
}
