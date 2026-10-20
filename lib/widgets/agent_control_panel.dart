/// The agent's host and activity (§16): what the last run used, what the
/// agent has spent, how long it has worked and the box it works in. It is
/// the body of the "Host & activity" page ([AgentHostActivityPage]) on every
/// form factor.
///
/// The panel draws only what the host measured. A block the host did not
/// report says so, with the reason, never a plausible-looking zero.
///
/// One screen owns each thing (bead chuk_chat-8hz4). The panel does not
/// repeat what another screen owns: the model, the permissions and the
/// budget are rows of the agent settings ([AgentSettingsView]), and the
/// skills are the Skills page ([AgentsSkillsSettingsPage]), which the panel
/// opens with one row.
library;

// The desktop pane's first page sits next to this panel; the messenger shell
// reaches both through this import.
export 'package:chuk_chat/widgets/agent_details_overview.dart'
    show AgentDetailsOverview;

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:chuk_chat/ui/expressive/icon_map.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/pages/skills_settings_page.dart'
    show AgentsSkillsSettingsPage;
import 'package:chuk_chat/services/agents/agent_control_source.dart';
import 'package:chuk_chat/services/agents/agents_permissions_service.dart';
import 'package:chuk_chat/services/agents/agent_model.dart';
import 'package:chuk_chat/services/chat_mode_service.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';
import 'package:chuk_chat/widgets/settings_list_view.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';

class AgentControlPanel extends StatefulWidget {
  const AgentControlPanel({
    super.key,
    required this.agent,
    required this.source,
    this.onOpenSkills,
  });

  /// Opens the Skills page. Null pushes [AgentsSkillsSettingsPage].
  final VoidCallback? onOpenSkills;

  final AgentsAgent agent;
  final AgentControlSource source;

  @override
  State<AgentControlPanel> createState() => _AgentControlPanelState();
}

class _AgentControlPanelState extends State<AgentControlPanel> {
  /// The agent's thread key IS its session key on the host, so the panel
  /// asks about exactly the agent it is showing.
  String get _sessionKey => widget.agent.threads.isEmpty
      ? widget.agent.id
      : widget.agent.threads.first.key;

  @override
  void initState() {
    super.initState();
    widget.source.refresh(_sessionKey);
  }

  @override
  void didUpdateWidget(AgentControlPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.agent.id != widget.agent.id) {
      widget.source.refresh(_sessionKey);
    }
  }

  void _openSkills() {
    final VoidCallback? open = widget.onOpenSkills;
    if (open != null) return open();
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => const AgentsSkillsSettingsPage(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AgentControlSnapshot>(
      valueListenable: widget.source.snapshotFor(_sessionKey),
      builder: (context, snapshot, _) {
        // The settings-page frame: the page's floating header sits over the
        // list, and the list scrolls up behind it.
        return SettingsListView(
          key: const ValueKey<String>('host-activity'),
          padding: EdgeInsets.fromLTRB(
            16,
            8,
            16,
            24 + MediaQuery.paddingOf(context).bottom,
          ),
          children: <Widget>[
            ..._notes(context, snapshot),
            ..._measured(context, snapshot),
            const SizedBox(height: 8),
            ExpressiveGroup(children: <Widget>[_skillsRow(context)]),
          ],
        );
      },
    );
  }

  /// The note over the blocks for an agent the host does not run yet.
  List<Widget> _notes(BuildContext context, AgentControlSnapshot snapshot) {
    return <Widget>[
      // "Not installed" only while the host reports nothing for this agent.
      // A sandbox the host measured is proof it runs there: the note used to
      // sit next to 44 runs in its own container.
      if (!widget.agent.runsOnHost &&
          snapshot.sandbox is! ControlAvailable<AgentSandbox>)
        const Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: ExpressiveInfoCard(
            icon: Icons.cloud_off_rounded,
            text: 'Created in the app. It is not installed on the host yet.',
          ),
        ),
    ];
  }

  /// What the host measured: the activity group, then the machine group.
  List<Widget> _measured(BuildContext context, AgentControlSnapshot snapshot) {
    final AppLocalizations l = _l10n(context);
    return <Widget>[
      ExpressiveSectionHeader(l.agentsCwSectionActivity),
      ExpressiveGroup(
        children: <Widget>[
          _fact(
            context,
            Icons.auto_awesome_outlined,
            'Last run',
            _buildModel(context, snapshot.model),
          ),
          _fact(
            context,
            Icons.bolt_outlined,
            'Token use',
            _buildTokens(context, snapshot.tokens),
          ),
          if (snapshot.cost case ControlAvailable<AgentCostTotals>(
            value: final AgentCostTotals cost,
          ))
            _fact(
              context,
              Icons.credit_card,
              l.costHeading,
              _buildCost(context, cost),
            ),
          _fact(
            context,
            Icons.timer_outlined,
            'Session runtime',
            _buildRuntime(context, snapshot.runtime),
          ),
        ],
      ),
      ExpressiveSectionHeader(l.agentsCwSectionMachine),
      ExpressiveGroup(
        children: <Widget>[
          _fact(
            context,
            Icons.computer_outlined,
            'Sandbox',
            _buildSandbox(context, snapshot.sandbox),
          ),
        ],
      ),
    ];
  }

  /// The one way to the agent's skills: the Skills page owns them.
  Widget _skillsRow(BuildContext context) {
    final AppLocalizations l = _l10n(context);
    return ExpressiveRow(
      key: const ValueKey<String>('panel-skills-row'),
      icon: Icons.extension_outlined,
      title: l.skills,
      subtitle:
          _skillsSummary(widget.source.snapshotFor(_sessionKey).value.skills) ??
          l.agentsCwSkillsSubtitle,
      trailing: _chevron(context),
      onTap: _openSkills,
    );
  }

  /// `3 of 5 on`, or null before the host listed its skills.
  static String? _skillsSummary(ControlValue<List<AgentSkill>> value) =>
      switch (value) {
        ControlAvailable<List<AgentSkill>>(value: final skills) =>
          skills.isEmpty
              ? 'No skills.'
              : '${skills.where((s) => s.enabled).length} of '
                    '${skills.length} on',
        _ => null,
      };

  Widget _chevron(BuildContext context) => AppIcon(
    Icons.chevron_right,
    size: 20,
    color: Theme.of(context).colorScheme.onSurfaceVariant,
  );

  /// One measured fact as a row of the group: the icon tile, the name of the
  /// fact, and the host's figures under it.
  Widget _fact(
    BuildContext context,
    IconData icon,
    String title,
    Widget value,
  ) {
    final ThemeData theme = Theme.of(context);
    return ExpressiveTile(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ExpressiveIconTile(icon: icon),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                DefaultTextStyle.merge(
                  style: theme.textTheme.bodyMedium,
                  child: value,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // --- blocks ----------------------------------------------------------------

  /// What the last run used. The fact row names it "Last run".
  Widget _buildModel(
    BuildContext context,
    ControlValue<AgentModelChoice> value,
  ) {
    final theme = Theme.of(context);
    return switch (value) {
      ControlUnavailable<AgentModelChoice>(:final reason) => _notReported(
        context,
        reason,
      ),
      ControlLoading<AgentModelChoice>() => _loading(),
      // What the host says the last run really used — the proof that a
      // change applied, once the next message has run.
      ControlAvailable<AgentModelChoice>(value: final choice) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(choice.id),
          if (_runDetail(choice) case final String detail)
            Text(
              detail,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.hintColor,
              ),
            ),
        ],
      ),
    };
  }

  Widget _buildTokens(
    BuildContext context,
    ControlValue<AgentTokenUsage> value,
  ) {
    final theme = Theme.of(context);
    return switch (value) {
      ControlUnavailable<AgentTokenUsage>(:final reason) => _notReported(
        context,
        reason,
      ),
      ControlLoading<AgentTokenUsage>() => _loading(),
      ControlAvailable<AgentTokenUsage>(value: final usage) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${formatCount(usage.total)} tokens'),
          Text(
            '${formatCount(usage.lastRun)} in the last run · '
            '${usage.runs} ${usage.runs == 1 ? 'run' : 'runs'}',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
        ],
      ),
    };
  }

  Widget _buildRuntime(
    BuildContext context,
    ControlValue<AgentSessionRuntime> value,
  ) {
    final theme = Theme.of(context);
    return switch (value) {
      ControlUnavailable<AgentSessionRuntime>(:final reason) => _notReported(
        context,
        reason,
      ),
      ControlLoading<AgentSessionRuntime>() => _loading(),
      ControlAvailable<AgentSessionRuntime>(value: final runtime) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${formatRuntime(runtime.active)} working'),
          if (runtime.running && runtime.current != null)
            Text(
              'Running now, ${formatRuntime(runtime.current!)} into this run.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          if (runtime.startedAt != null)
            Text(
              'First run ${formatTimestamp(runtime.startedAt!)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.hintColor,
              ),
            ),
        ],
      ),
    };
  }

  Widget _buildSandbox(BuildContext context, ControlValue<AgentSandbox> value) {
    final theme = Theme.of(context);
    return switch (value) {
      ControlUnavailable<AgentSandbox>(:final reason) => _notReported(
        context,
        reason,
      ),
      ControlLoading<AgentSandbox>() => _loading(),
      ControlAvailable<AgentSandbox>(value: final sandbox) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            sandbox.isContainer
                ? 'Its own container'
                : 'On the host, no container',
          ),
          if (sandbox.container != null)
            Text(
              sandbox.containerId == null
                  ? sandbox.container!
                  : '${sandbox.container!} · ${sandbox.containerId!}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.hintColor,
              ),
            ),
          if (sandbox.workspace != null)
            Text(
              sandbox.workspace!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.hintColor,
              ),
            ),
        ],
      ),
    };
  }

  // ── F2: automations + cost totals ──
  static AppLocalizations _l10n(BuildContext context) =>
      AppLocalizations.of(context) ?? AppLocalizations(const Locale('en'));

  /// This thread, today and this week in euro, with the week against the
  /// budget when one is set. The bar takes the warning colour at 80 % and the
  /// error colour at 100 %, as the host's `budget_state` says.
  Widget _buildCost(BuildContext context, AgentCostTotals cost) {
    final ThemeData theme = Theme.of(context);
    final AppLocalizations l = _l10n(context);
    final double? share = cost.weekShare;
    final Color barColor = switch (cost.budgetState) {
      'exceeded' => theme.colorScheme.error,
      'warning' => theme.m3.warning,
      _ => theme.colorScheme.primary,
    };
    final String week = cost.hasBudget
        ? l.costWeekOfBudget(
            formatEuro(cost.week),
            formatEuro(cost.budgetWeekly!),
          )
        : formatEuro(cost.week);
    // Label left, amount right; a narrow pane at a large text size puts the
    // amount on its own line instead of cutting it (a cut price reads as a
    // price and is not one).
    Widget line(String label, String value, {Key? key}) => Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        spacing: 12,
        children: <Widget>[
          Text(label),
          Text(
            value,
            key: key,
            style: const TextStyle(
              fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        line(
          l.costThisThread,
          formatEuro(cost.sessionTotal),
          key: const ValueKey<String>('cost-thread'),
        ),
        line(
          l.costToday,
          formatEuro(cost.today),
          key: const ValueKey<String>('cost-today'),
        ),
        line(l.costThisWeek, week, key: const ValueKey<String>('cost-week')),
        if (share != null) ...<Widget>[
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              key: const ValueKey<String>('cost-week-bar'),
              value: share,
              minHeight: 4,
              color: barColor,
              backgroundColor: theme.m3.surfaceContainerHighest,
            ),
          ),
        ],
        if (cost.budgetState == 'warning' || cost.budgetState == 'exceeded')
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              cost.budgetState == 'exceeded'
                  ? l.costBudgetExceeded
                  : l.costBudgetWarning,
              style: theme.textTheme.bodySmall?.copyWith(
                color: cost.budgetState == 'exceeded'
                    ? theme.colorScheme.error
                    : theme.m3.onSurfaceVariant,
              ),
            ),
          ),
        if (cost.lastRun != null)
          Text(
            '${l.costLastRun} ${formatEuro(cost.lastRun!)}',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
      ],
    );
  }

  // ── end F2 ──

  // --- helpers ---------------------------------------------------------------

  /// `Fireworks · Reasoning low` for a run's provider and level, or null when
  /// the host named neither.
  static String? _runDetail(AgentModelChoice choice) {
    final String? provider = choice.provider;
    final String? effort = choice.reasoningEffort;
    final List<String> parts = <String>[
      if (provider != null && provider.isNotEmpty)
        providerLabelFromSlug(provider),
      if (effort != null && effort.isNotEmpty)
        'Reasoning ${ChatModeService.reasoningLabel(effort).toLowerCase()}',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  /// The host measured nothing here — said plainly, with the reason, so a
  /// reader can never take a missing measurement for a zero.
  Widget _notReported(BuildContext context, String reason) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppIcon(Icons.remove_circle_outline, size: 14, color: theme.hintColor),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            reason,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
        ),
      ],
    );
  }

  Widget _loading() => const Padding(
    padding: EdgeInsets.symmetric(vertical: 4),
    child: SizedBox(
      height: 16,
      width: 16,
      child: CircularProgressIndicator(strokeWidth: 2),
    ),
  );
}

/// `1h 04m` / `4m 12s` / `12s`.
String formatRuntime(Duration d) {
  if (d.inHours > 0) {
    return '${d.inHours}h ${(d.inMinutes % 60).toString().padLeft(2, '0')}m';
  }
  if (d.inMinutes > 0) {
    return '${d.inMinutes}m ${(d.inSeconds % 60).toString().padLeft(2, '0')}s';
  }
  return '${d.inSeconds}s';
}

/// `1 234 567` — grouped, so a six-figure token count is readable at a glance.
String formatCount(int value) {
  final digits = value.abs().toString();
  final buffer = StringBuffer(value < 0 ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(' ');
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

/// `2026-02-03 14:00` — stable and unambiguous, no locale guessing.
String formatTimestamp(DateTime when) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${when.year}-${two(when.month)}-${two(when.day)} '
      '${two(when.hour)}:${two(when.minute)}';
}

// ── F2: automations + cost totals ──
/// The agent's weekly budget in euro (docs/WIRE_CONTRACT.md, "The budget
/// setting"): empty or 0 = no limit, at most 10000. Sent as
/// `agent_permissions_set` with `budget_weekly` only; the host's reply
/// replaces what the field shows.
class WeeklyBudgetField extends StatefulWidget {
  const WeeklyBudgetField({
    super.key,
    required this.agentId,
    required this.service,
  });

  final String agentId;
  final AgentsPermissionsService service;

  @override
  State<WeeklyBudgetField> createState() => _WeeklyBudgetFieldState();
}

class _WeeklyBudgetFieldState extends State<WeeklyBudgetField> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();
  double? _shown;
  String? _error;
  bool _waiting = false;

  @override
  void initState() {
    super.initState();
    widget.service.addListener(_onService);
    _takeHostValue();
  }

  @override
  void didUpdateWidget(WeeklyBudgetField old) {
    super.didUpdateWidget(old);
    if (old.service != widget.service) {
      old.service.removeListener(_onService);
      widget.service.addListener(_onService);
    }
    if (old.agentId != widget.agentId) {
      _shown = null;
      _error = null;
      _waiting = false;
      _takeHostValue(force: true);
    }
  }

  @override
  void dispose() {
    widget.service.removeListener(_onService);
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  static String _text(double euro) => euro <= 0 ? '' : euro.toStringAsFixed(2);

  /// Shows the host's value, unless the user is typing a new one.
  void _takeHostValue({bool force = false}) {
    final double? host = widget.service.budgetOf(widget.agentId);
    if (host == null || (host == _shown && !force)) return;
    _shown = host;
    if (force || !_focus.hasFocus || _waiting) _controller.text = _text(host);
  }

  void _onService() {
    if (!mounted) return;
    setState(() {
      _takeHostValue(force: _waiting);
      if (_waiting) {
        final String? error = widget.service.errorOf(widget.agentId);
        _error = error;
        _waiting = false;
      }
    });
  }

  Future<void> _save() async {
    final AppLocalizations l =
        AppLocalizations.of(context) ?? AppLocalizations(const Locale('en'));
    // Until the host said its value the field is empty, and an empty field
    // parses as 0 ("no limit"): a Save now would wipe a budget nobody saw.
    if (widget.service.budgetOf(widget.agentId) == null) return;
    final double? value = parseBudgetWeekly(_controller.text);
    if (value == null) {
      setState(() => _error = l.budgetInvalid);
      return;
    }
    setState(() {
      _error = null;
      _waiting = true;
    });
    final bool sent = await widget.service.setBudget(widget.agentId, value);
    if (!mounted) return;
    if (!sent) {
      setState(() {
        _waiting = false;
        _error = l.budgetSendFailed;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppLocalizations l =
        AppLocalizations.of(context) ?? AppLocalizations(const Locale('en'));
    final bool known = widget.service.budgetOf(widget.agentId) != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                key: const ValueKey<String>('budget-weekly-field'),
                controller: _controller,
                focusNode: _focus,
                enabled: known,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  isDense: true,
                  prefixText: '€ ',
                  hintText: l.budgetNoLimit,
                  errorText: _error,
                  errorMaxLines: 3,
                ),
                onChanged: (_) {
                  if (_error != null) setState(() => _error = null);
                },
                onSubmitted: (_) => _save(),
              ),
            ),
            const SizedBox(width: 8),
            // Off until the host's value is known (see [_save]).
            IgnorePointer(
              ignoring: !known,
              child: AnimatedOpacity(
                opacity: known ? 1 : 0.38,
                duration: const Duration(milliseconds: 150),
                child: ExpressiveButton(
                  key: const ValueKey<String>('budget-weekly-save'),
                  label: l.save,
                  dense: true,
                  tonal: true,
                  onTap: _save,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          l.budgetHelp,
          style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
        ),
      ],
    );
  }
}
// ── end F2 ──
