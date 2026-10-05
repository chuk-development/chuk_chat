/// The "Approvals" part of a coworker's permissions (docs/WIRE_CONTRACT.md,
/// "Per-action approvals").
///
/// One row per action class with a three-way choice, Ask / Allow / Deny, and
/// the host's default named under it. Under "Act in the browser" the sites
/// the user allowed with "Always on (site)", each with a remove action. Shown
/// only for a host that names `action_approvals`, and only once that host
/// sent the coworker's policy. Every `agent_permissions` frame replaces what
/// is shown, so an "always" given on a card in a run shows up at once.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/agents/agents_permissions_service.dart';
import 'package:chuk_chat/ui/expressive/connected_group.dart';
import 'package:chuk_chat/ui/expressive/feedback.dart';
import 'package:chuk_chat/ui/expressive/huge_icon.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';

class AgentApprovalsSection extends StatelessWidget {
  const AgentApprovalsSection({
    super.key,
    required this.agentId,
    required this.service,
    required this.editable,
  });

  final String agentId;
  final AgentsPermissionsService service;

  /// The host answered and is connected. Before that the choices are shown
  /// but cannot be changed.
  final bool editable;

  @override
  Widget build(BuildContext context) {
    final AgentApprovals? approvals = service.approvalsOf(agentId);
    if (!service.approvalsSupported || approvals == null) {
      return const SizedBox.shrink();
    }
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    final AppLocalizations? l = AppLocalizations.of(context);
    final List<String> classes = approvals.shownClasses;
    if (classes.isEmpty) return const SizedBox.shrink();
    return Column(
      key: const ValueKey<String>('agent-approvals-section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
          child: Text(
            l?.approvalsHeading ?? 'APPROVALS',
            style: text.labelMedium?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.8,
            ),
          ),
        ),
        ExpressiveGroup(
          children: <Widget>[
            for (final String actionClass in classes)
              _ClassCard(
                agentId: agentId,
                service: service,
                approvals: approvals,
                actionClass: actionClass,
                editable: editable,
              ),
          ],
        ),
        const SizedBox(height: 8),
        ExpressiveInfoCard(
          key: const ValueKey<String>('agent-approvals-applies'),
          text: l?.approvalsApplies ?? 'Applies from the next action.',
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

class _ClassCard extends StatelessWidget {
  const _ClassCard({
    required this.agentId,
    required this.service,
    required this.approvals,
    required this.actionClass,
    required this.editable,
  });

  final String agentId;
  final AgentsPermissionsService service;
  final AgentApprovals approvals;
  final String actionClass;
  final bool editable;

  static String modeLabel(AppLocalizations? l, String mode) => switch (mode) {
    AgentApprovals.modeAllow => l?.approvalsModeAllow ?? 'Allow',
    AgentApprovals.modeDeny => l?.approvalsModeDeny ?? 'Deny',
    _ => l?.approvalsModeAsk ?? 'Ask',
  };

  static (String, String) words(AppLocalizations? l, String actionClass) =>
      switch (actionClass) {
        AgentApprovals.classSendExternal => (
          l?.approvalsSendExternal ?? 'Send mail',
          l?.approvalsSendExternalHelp ?? 'Send or reply to a mail.',
        ),
        AgentApprovals.classMcpDestructive => (
          l?.approvalsMcpDestructive ?? 'Connector changes',
          l?.approvalsMcpDestructiveHelp ??
              'Connector tools that the service marks as destructive.',
        ),
        AgentApprovals.classBrowserAct => (
          l?.approvalsBrowserAct ?? 'Act in the browser',
          l?.approvalsBrowserActHelp ??
              'Clicks, typing and forms on a web page.',
        ),
        AgentApprovals.classPublish => (
          l?.approvalsPublish ?? 'Publish to the web',
          l?.approvalsPublishHelp ?? 'Put a site on here.now.',
        ),
        _ => (actionClass, ''),
      };

  static HugeIconData iconFor(String actionClass) => switch (actionClass) {
    AgentApprovals.classSendExternal => HugeIcons.mail01,
    AgentApprovals.classMcpDestructive => HugeIcons.puzzle,
    AgentApprovals.classBrowserAct => HugeIcons.globe02,
    AgentApprovals.classPublish => HugeIcons.share08,
    _ => HugeIcons.alertCircle,
  };

  Future<void> _pick(BuildContext context, String mode) async {
    if (mode == approvals.modeOf(actionClass)) return;
    final bool sent = await service.setApprovalMode(agentId, actionClass, mode);
    if (sent || !context.mounted) return;
    pillToast(
      context,
      AppLocalizations.of(context)?.approvalsNotConnected ??
          'Not connected to the host',
    );
  }

  Future<void> _remove(BuildContext context, String site) async {
    final bool sent = await service.removeApprovalSite(
      agentId,
      actionClass,
      site,
    );
    if (sent || !context.mounted) return;
    pillToast(
      context,
      AppLocalizations.of(context)?.approvalsNotConnected ??
          'Not connected to the host',
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final AppLocalizations? l = AppLocalizations.of(context);
    final (String title, String help) = words(l, actionClass);
    final String mode = approvals.modeOf(actionClass);
    final String defaultMode = approvals.defaultOf(actionClass);
    final List<String> sites = approvals.sitesOf(actionClass);
    final bool hasSites = actionClass == AgentApprovals.classBrowserAct;
    final String subtitle = <String>[
      if (help.isNotEmpty) help,
      l?.approvalsDefault(modeLabel(l, defaultMode)) ??
          'Default: ${modeLabel(l, defaultMode)}',
    ].join(' ');
    return ExpressiveCard(
      key: ValueKey<String>('agent-approval-$actionClass'),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Container(
                width: 42,
                height: 42,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: HugeIcon(
                  iconFor(actionClass),
                  size: 21,
                  color: scheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 14),
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
                      key: ValueKey<String>('agent-approval-help-$actionClass'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Opacity(
            opacity: editable ? 1 : 0.5,
            child: IgnorePointer(
              ignoring: !editable,
              child: ConnectedGroup(
                key: ValueKey<String>('agent-approval-mode-$actionClass'),
                labels: <String>[
                  for (final String m in AgentApprovals.modes) modeLabel(l, m),
                ],
                selected: AgentApprovals.modes.indexOf(mode).clamp(0, 2),
                margin: EdgeInsets.zero,
                onSelected: (int index) =>
                    unawaited(_pick(context, AgentApprovals.modes[index])),
              ),
            ),
          ),
          if (hasSites) ...<Widget>[
            const SizedBox(height: 10),
            Text(
              l?.approvalsSites ?? 'Allowed sites',
              style: theme.textTheme.labelMedium?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            if (sites.isEmpty)
              Text(
                l?.approvalsNoSites ??
                    'No sites yet. "Always on <site>" on a card adds one.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              )
            else
              for (final String site in sites)
                Row(
                  key: ValueKey<String>('agent-approval-site-$site'),
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        site,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    ExpressiveIconButton(
                      key: ValueKey<String>('agent-approval-remove-$site'),
                      hugeIcon: HugeIcons.cancel01,
                      size: 40,
                      color: Colors.transparent,
                      onColor: scheme.onSurfaceVariant,
                      tooltip: l?.approvalsRemoveSite(site) ?? 'Remove $site',
                      onTap: editable
                          ? () => unawaited(_remove(context, site))
                          : null,
                    ),
                  ],
                ),
          ],
        ],
      ),
    );
  }
}
