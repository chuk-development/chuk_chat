/// A coworker's permissions on a phone: the same sections the desktop shows
/// on the coworker's profile and in its details pane, on one settings page.
///
/// * [AgentPermissionsSection]: the sandbox switches. It draws the per-action
///   approvals ([AgentApprovalsSection]) under them for a host that names
///   `action_approvals` (docs/WIRE_CONTRACT.md, "Per-action approvals").
/// * [WeeklyBudgetField]: only for a host that names `cost_budget`
///   (docs/WIRE_CONTRACT.md, "The budget setting").
///
/// Telegram is not here: the phone reaches it through Host & activity
/// ([AgentControlPanel]), which shows it for a host that runs channels.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/agents/agents_permissions_service.dart';
import 'package:chuk_chat/widgets/agent_control_panel.dart'
    show WeeklyBudgetField;
import 'package:chuk_chat/widgets/agents_permissions/agent_permissions_section.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';
import 'package:chuk_chat/widgets/floating_app_bar.dart';
import 'package:chuk_chat/widgets/settings_list_view.dart';

class MobileAgentPermissionsPage extends StatefulWidget {
  const MobileAgentPermissionsPage({
    super.key,
    required this.agentId,
    this.service,
  });

  /// The coworker, which is also its thread's `session_key`.
  final String agentId;

  /// Defaults to [AgentsPermissionsService.instance].
  final AgentsPermissionsService? service;

  static Future<void> open(
    BuildContext context, {
    required String agentId,
    AgentsPermissionsService? service,
  }) => Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) =>
          MobileAgentPermissionsPage(agentId: agentId, service: service),
    ),
  );

  @override
  State<MobileAgentPermissionsPage> createState() =>
      _MobileAgentPermissionsPageState();
}

class _MobileAgentPermissionsPageState
    extends State<MobileAgentPermissionsPage> {
  /// Coworkers whose budget this page already asked for: a host that never
  /// answers is not asked again on every rebuild.
  final Set<String> _budgetAsked = <String>{};

  AgentsPermissionsService get _service =>
      widget.service ?? AgentsPermissionsService.instance;

  AppLocalizations get _l =>
      AppLocalizations.of(context) ?? AppLocalizations(const Locale('en'));

  /// The same ask the desktop details pane makes: once the host keeps
  /// budgets and has not said this coworker's yet.
  void _askBudget() {
    final AgentsPermissionsService service = _service;
    if (!service.budgetSupported) return;
    if (service.budgetOf(widget.agentId) != null) return;
    if (!_budgetAsked.add(widget.agentId)) return;
    service.attach();
    unawaited(service.refresh(widget.agentId));
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = _l;
    final AgentsPermissionsService service = _service;
    return Scaffold(
      // The page runs underneath the floating header.
      extendBodyBehindAppBar: true,
      appBar: FloatingAppBar(title: Text(l.agentsCwPermissions)),
      body: SettingsListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: <Widget>[
          AgentPermissionsSection(agentId: widget.agentId, service: service),
          ListenableBuilder(
            listenable: service,
            builder: (BuildContext context, Widget? _) {
              if (!service.budgetSupported) return const SizedBox.shrink();
              // A host that names the capability only after the page opened.
              if (service.budgetOf(widget.agentId) == null) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _askBudget();
                });
              }
              return Column(
                key: const ValueKey<String>('mobile-permissions-budget'),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  ExpressiveSectionHeader(l.budgetWeeklyLabel),
                  WeeklyBudgetField(agentId: widget.agentId, service: service),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
