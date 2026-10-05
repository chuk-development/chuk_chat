/// The in-UI control surface (§16): the model this coworker runs on (its own
/// or the app default, with the way to change it, and what the last run
/// really used), what it has spent, how long it has worked, the box it works in, and its skills.
///
/// The panel draws only what the host measured. A block the host did not report
/// says so, with the reason — never a plausible-looking zero. There are no
/// blocks here that nothing can fill: the schedule field and the integrations
/// list were removed when it became clear that neither reached the host (the
/// Automations page and the connector settings own those).
library;

import 'package:flutter/material.dart';

import 'package:chuk_chat/ui/expressive/icon_map.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/services/agents/agent_control_source.dart';
import 'package:chuk_chat/services/agents/agents_channels_service.dart';
import 'package:chuk_chat/services/agents/agents_permissions_service.dart';
import 'package:chuk_chat/services/agents/schedule_spec.dart';
import 'package:chuk_chat/services/agents/coworker_model.dart';
import 'package:chuk_chat/services/chat_mode_service.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/agents_channels/agent_telegram_section.dart';
import 'package:chuk_chat/widgets/coworker_model_tile.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';

class AgentControlPanel extends StatefulWidget {
  const AgentControlPanel({
    super.key,
    required this.agent,
    required this.source,
    this.onScheduleSubmitted,
    this.showHeader = true,
    this.showRefresh = true,
    this.channels,
    this.permissions,
  });

  /// Where the weekly budget is read and sent (F2). Defaults to
  /// [AgentsPermissionsService.instance]; the field shows only for a host
  /// that names `cost_budget`.
  final AgentsPermissionsService? permissions;

  /// The coworker's messenger channels. Defaults to
  /// [AgentsChannelsService.instance]; the section shows only for a host
  /// that runs channels.
  final AgentsChannelsService? channels;

  /// The name row at the top. The desktop details pane keeps it; the pane
  /// header above it already carries Refresh, so it turns [showRefresh] off.
  final bool showHeader;
  final bool showRefresh;

  final AgentsAgent agent;
  final AgentControlSource source;

  /// Retired. The panel no longer sets schedules: nothing installed them on the
  /// host, and the Automations page is where a real schedule lives. Kept only
  /// because `agents_shell_state.dart` still passes it; it is never called.
  final void Function(ScheduleSpec spec)? onScheduleSubmitted;

  @override
  State<AgentControlPanel> createState() => _AgentControlPanelState();
}

class _AgentControlPanelState extends State<AgentControlPanel> {
  String? _actionError;

  /// The coworker's thread key IS its session key on the host, so the panel
  /// asks about exactly the coworker it is showing.
  String get _sessionKey => widget.agent.threads.isEmpty
      ? widget.agent.id
      : widget.agent.threads.first.key;

  // ── F2: automations + cost totals ──
  final Set<String> _budgetAsked = <String>{};

  AgentsPermissionsService get _permissions =>
      widget.permissions ?? AgentsPermissionsService.instance;

  /// Asks the host for the budget once it can answer and has not yet.
  void _askBudget() {
    final AgentsPermissionsService service = _permissions;
    if (!service.budgetSupported) return;
    if (service.budgetOf(widget.agent.id) != null) return;
    // Once per coworker and panel: a host that never answers is not asked
    // again on every rebuild.
    if (!_budgetAsked.add(widget.agent.id)) return;
    service.attach();
    service.refresh(widget.agent.id);
  }
  // ── end F2 ──

  @override
  void initState() {
    super.initState();
    widget.source.refresh(_sessionKey);
    _askBudget(); // F2
  }

  @override
  void didUpdateWidget(AgentControlPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.agent.id != widget.agent.id) {
      widget.source.refresh(_sessionKey);
      _askBudget(); // F2
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ValueListenableBuilder<AgentControlSnapshot>(
      valueListenable: widget.source.snapshotFor(_sessionKey),
      builder: (context, snapshot, _) {
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (widget.showHeader)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.agent.name,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  if (widget.showRefresh)
                    IconButton(
                      tooltip: 'Refresh',
                      // No compact density here: it shrank the only control on
                      // the panel to 40 dp.
                      icon: const AppIcon(Icons.refresh, size: 18),
                      onPressed: () =>
                          _run(() => widget.source.refresh(_sessionKey)),
                    ),
                ],
              ),
            if (widget.agent.role != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  widget.agent.role!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
            // "Not installed" only while the host reports nothing for this
            // coworker. A sandbox the host measured is proof it runs there:
            // the note used to sit next to 44 runs in its own container.
            if (!widget.agent.runsOnHost &&
                snapshot.sandbox is! ControlAvailable<AgentSandbox>)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Created in the app. It is not installed on the host yet.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.hintColor,
                  ),
                ),
              ),
            if (widget.agent.brief != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  widget.agent.brief!,
                  style: theme.textTheme.bodySmall,
                ),
              ),
            if (_actionError != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _actionError!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            const SizedBox(height: 8),
            _section(
              context,
              'Model',
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  // What the next message runs on, and the way to change it:
                  // the coworker's model page, the one place for it.
                  CoworkerModelTile(
                    chatId: _sessionKey,
                    coworkerName: widget.agent.name,
                    controlSource: widget.source,
                  ),
                  const SizedBox(height: 8),
                  _buildModel(context, snapshot.model),
                ],
              ),
            ),
            _section(
              context,
              'Token use',
              _buildTokens(context, snapshot.tokens),
            ),
            // ── F2: automations + cost totals ──
            if (snapshot.cost case ControlAvailable<AgentCostTotals>(
              value: final AgentCostTotals cost,
            ))
              _section(
                context,
                _l10n(context).costHeading,
                _buildCost(context, cost),
              ),
            _buildBudget(context),
            // ── end F2 ──
            _section(
              context,
              'Session runtime',
              _buildRuntime(context, snapshot.runtime),
            ),
            _section(
              context,
              'Sandbox',
              _buildSandbox(context, snapshot.sandbox),
            ),
            _section(context, 'Skills', _buildSkills(context, snapshot.skills)),
            _buildChannels(context),
          ],
        );
      },
    );
  }

  // --- blocks ----------------------------------------------------------------

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
          Text(
            'Last run',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.hintColor,
            ),
          ),
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

  Widget _buildSkills(
    BuildContext context,
    ControlValue<List<AgentSkill>> value,
  ) {
    return switch (value) {
      ControlUnavailable<List<AgentSkill>>(:final reason) => _notReported(
        context,
        reason,
      ),
      ControlLoading<List<AgentSkill>>() => _loading(),
      ControlAvailable<List<AgentSkill>>(value: final skills) =>
        skills.isEmpty
            ? Text('No skills.', style: Theme.of(context).textTheme.bodySmall)
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (final skill in skills)
                    SwitchListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      value: skill.enabled,
                      title: Text(skill.name),
                      subtitle: Text(
                        skill.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onChanged: (enabled) => _run(
                        () => widget.source.setSkillEnabled(
                          skill.name,
                          enabled: enabled,
                        ),
                      ),
                    ),
                ],
              ),
    };
  }

  /// Telegram, under its own label, only while the host runs channels
  /// (`host_route.capabilities` has `agent_channels`).
  Widget _buildChannels(BuildContext context) {
    final AgentsChannelsService channels =
        widget.channels ?? AgentsChannelsService.instance;
    return ListenableBuilder(
      listenable: channels,
      builder: (BuildContext context, Widget? _) {
        if (!channels.supported) return const SizedBox.shrink();
        return _section(
          context,
          AppLocalizations.of(context)?.agentsChannels ?? 'Channels',
          AgentTelegramSection(agentId: widget.agent.id, service: channels),
        );
      },
    );
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

  /// The weekly budget field, only for a host that keeps budgets.
  Widget _buildBudget(BuildContext context) {
    final AgentsPermissionsService service = _permissions;
    return ListenableBuilder(
      listenable: service,
      builder: (BuildContext context, Widget? _) {
        if (!service.budgetSupported) return const SizedBox.shrink();
        // A host that names the capability only after the panel opened.
        if (service.budgetOf(widget.agent.id) == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _askBudget();
          });
        }
        return _section(
          context,
          _l10n(context).budgetWeeklyLabel,
          WeeklyBudgetField(agentId: widget.agent.id, service: service),
        );
      },
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

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
      if (mounted) setState(() => _actionError = null);
    } catch (error) {
      if (!mounted) return;
      setState(() => _actionError = '$error');
    }
  }

  Widget _section(BuildContext context, String title, Widget child) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor),
          ),
          const SizedBox(height: 4),
          child,
        ],
      ),
    );
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
/// The coworker's weekly budget in euro (docs/WIRE_CONTRACT.md, "The budget
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
                enabled: widget.service.budgetOf(widget.agentId) != null,
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
            ExpressiveButton(
              key: const ValueKey<String>('budget-weekly-save'),
              label: l.save,
              dense: true,
              tonal: true,
              onTap: _save,
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
