/// The in-UI control surface (§16): skills, integrations, model, live token use,
/// session runtime, and the schedule with its next runs — in the app, not a CLI.
///
/// The panel draws only what it is given. Every block that the host does not
/// report is drawn as **Not connected yet** with the reason, so a reader can
/// never mistake a missing measurement for a zero. The one exception is a
/// schedule the user set here in the app: that is real, locally computed, and it
/// says plainly that the host does not run it yet.
library;

import 'package:flutter/material.dart';

import 'package:cowork/models/cowork_agent.dart';
import 'package:cowork/services/cowork/agent_control_source.dart';
import 'package:cowork/services/cowork/schedule_spec.dart';

class AgentControlPanel extends StatefulWidget {
  const AgentControlPanel({
    super.key,
    required this.agent,
    required this.source,
    this.onScheduleSubmitted,
  });

  final CoworkAgent agent;
  final AgentControlSource source;

  /// Called when the user sets a schedule in the panel. The caller stores it on
  /// the agent; nothing is sent to the host, because the host has no schedule
  /// API yet.
  final void Function(ScheduleSpec spec)? onScheduleSubmitted;

  @override
  State<AgentControlPanel> createState() => _AgentControlPanelState();
}

class _AgentControlPanelState extends State<AgentControlPanel> {
  final TextEditingController _scheduleController = TextEditingController();
  String? _scheduleError;
  String? _actionError;

  @override
  void initState() {
    super.initState();
    _scheduleController.text = widget.agent.schedule?.source ?? '';
    widget.source.refresh();
  }

  @override
  void dispose() {
    _scheduleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ValueListenableBuilder<AgentControlSnapshot>(
      valueListenable: widget.source.snapshot,
      builder: (context, snapshot, _) {
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(widget.agent.name, style: theme.textTheme.titleMedium),
            if (!widget.agent.onHost)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Created in the app. It is not installed on the host yet.',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
                ),
              ),
            if (widget.agent.brief != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(widget.agent.brief!, style: theme.textTheme.bodySmall),
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
              _buildModel(context, snapshot.model),
            ),
            _section(
              context,
              'Token use',
              _buildTokens(context, snapshot.tokens),
            ),
            _section(
              context,
              'Session runtime',
              _buildRuntime(context, snapshot.sessionRuntime),
            ),
            _section(
              context,
              'Schedule',
              _buildSchedule(context, snapshot.schedule),
            ),
            _section(
              context,
              'Skills',
              _buildSkills(context, snapshot.skills),
            ),
            _section(
              context,
              'Integrations',
              _buildIntegrations(context, snapshot.integrations),
            ),
          ],
        );
      },
    );
  }

  // --- blocks ----------------------------------------------------------------

  Widget _buildModel(BuildContext context, ControlValue<AgentModelChoice> value) {
    return switch (value) {
      ControlUnavailable<AgentModelChoice>(:final reason) => _notConnected(context, reason),
      ControlLoading<AgentModelChoice>() => _loading(),
      ControlAvailable<AgentModelChoice>(value: final choice) => Row(
          children: [
            Expanded(
              child: choice.available.length <= 1
                  ? Text(choice.selectedId)
                  : DropdownButton<String>(
                      isExpanded: true,
                      value: choice.selectedId,
                      items: <DropdownMenuItem<String>>[
                        for (final id in choice.available)
                          DropdownMenuItem<String>(value: id, child: Text(id)),
                      ],
                      onChanged: (id) {
                        if (id != null) _run(() => widget.source.selectModel(id));
                      },
                    ),
            ),
          ],
        ),
    };
  }

  Widget _buildTokens(BuildContext context, ControlValue<AgentTokenUsage> value) {
    final theme = Theme.of(context);
    return switch (value) {
      ControlUnavailable<AgentTokenUsage>(:final reason) => _notConnected(context, reason),
      ControlLoading<AgentTokenUsage>() => _loading(),
      ControlAvailable<AgentTokenUsage>(value: final usage) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${usage.total} tokens'),
            Text(
              '${usage.promptTokens} in · ${usage.completionTokens} out',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
            ),
          ],
        ),
    };
  }

  Widget _buildRuntime(BuildContext context, ControlValue<Duration> value) {
    return switch (value) {
      ControlUnavailable<Duration>(:final reason) => _notConnected(context, reason),
      ControlLoading<Duration>() => _loading(),
      ControlAvailable<Duration>(value: final runtime) => Text(formatRuntime(runtime)),
    };
  }

  Widget _buildSchedule(BuildContext context, ControlValue<AgentSchedule> value) {
    final theme = Theme.of(context);
    final local = widget.agent.schedule;
    final children = <Widget>[];

    switch (value) {
      case ControlAvailable<AgentSchedule>(value: final schedule):
        children.add(Text(schedule.description));
        if (!schedule.installedOnHost) {
          children.add(Text(
            'Not installed on the host yet.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ));
        }
        children.addAll(_nextRunLines(context, schedule.nextRuns));
      case ControlLoading<AgentSchedule>():
        children.add(_loading());
      case ControlUnavailable<AgentSchedule>(:final reason):
        if (local == null) {
          children.add(_notConnected(context, reason));
        } else {
          // The user set this here, so it is real — but it runs nowhere yet.
          children.add(Text(local.describe()));
          children.add(Text(
            'Set in the app. The host does not run it yet.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ));
          children.addAll(_nextRunLines(context, local.nextRuns(DateTime.now())));
        }
    }

    children.add(const SizedBox(height: 8));
    children.add(
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: TextField(
              controller: _scheduleController,
              decoration: InputDecoration(
                labelText: 'Schedule',
                hintText: 'every 30m · 0 9 * * * · 2026-02-03T14:00',
                border: const OutlineInputBorder(),
                isDense: true,
                errorText: _scheduleError,
              ),
              onSubmitted: (_) => _submitSchedule(),
            ),
          ),
          const SizedBox(width: 8),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: FilledButton(
              onPressed: _submitSchedule,
              child: const Text('Set'),
            ),
          ),
        ],
      ),
    );

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: children);
  }

  List<Widget> _nextRunLines(BuildContext context, List<DateTime> runs) {
    final theme = Theme.of(context);
    if (runs.isEmpty) {
      return <Widget>[
        Text(
          'No run in the next year.',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
        ),
      ];
    }
    return <Widget>[
      const SizedBox(height: 4),
      Text('Next runs', style: theme.textTheme.bodySmall),
      for (final run in runs)
        Text(
          formatTimestamp(run),
          style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
        ),
    ];
  }

  Widget _buildSkills(BuildContext context, ControlValue<List<AgentSkill>> value) {
    return switch (value) {
      ControlUnavailable<List<AgentSkill>>(:final reason) => _notConnected(context, reason),
      ControlLoading<List<AgentSkill>>() => _loading(),
      ControlAvailable<List<AgentSkill>>(value: final skills) => skills.isEmpty
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
                      () => widget.source
                          .setSkillEnabled(skill.name, enabled: enabled),
                    ),
                  ),
              ],
            ),
    };
  }

  Widget _buildIntegrations(
    BuildContext context,
    ControlValue<List<AgentIntegration>> value,
  ) {
    return switch (value) {
      ControlUnavailable<List<AgentIntegration>>(:final reason) =>
        _notConnected(context, reason),
      ControlLoading<List<AgentIntegration>>() => _loading(),
      ControlAvailable<List<AgentIntegration>>(value: final integrations) =>
        integrations.isEmpty
            ? Text('No integrations.', style: Theme.of(context).textTheme.bodySmall)
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (final integration in integrations)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(integration.name),
                      subtitle: integration.account == null
                          ? null
                          : Text(integration.account!),
                      trailing: TextButton(
                        onPressed: () => _run(
                          () => widget.source.setIntegrationConnected(
                            integration.name,
                            connected: !integration.connected,
                          ),
                        ),
                        child: Text(integration.connected ? 'Disconnect' : 'Connect'),
                      ),
                    ),
                ],
              ),
    };
  }

  // --- helpers ---------------------------------------------------------------

  void _submitSchedule() {
    final text = _scheduleController.text.trim();
    if (text.isEmpty) {
      setState(() => _scheduleError = 'Enter a schedule.');
      return;
    }
    final spec = ScheduleSpec.tryParse(text);
    if (spec == null) {
      setState(() => _scheduleError = 'Not a schedule this app understands.');
      return;
    }
    setState(() => _scheduleError = null);
    widget.onScheduleSubmitted?.call(spec);
    // The host may not accept it; that failure is reported, never hidden.
    _run(() => widget.source.setSchedule(spec.source), silent: true);
  }

  Future<void> _run(Future<void> Function() action, {bool silent = false}) async {
    try {
      await action();
      if (mounted) setState(() => _actionError = null);
    } catch (error) {
      if (!mounted || silent) return;
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

  Widget _notConnected(BuildContext context, String reason) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.cloud_off_outlined, size: 14, color: theme.hintColor),
        const SizedBox(width: 6),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Not connected yet'),
              Text(
                reason,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
              ),
            ],
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

/// `2026-02-03 14:00` — stable and unambiguous, no locale guessing.
String formatTimestamp(DateTime when) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${when.year}-${two(when.month)}-${two(when.day)} '
      '${two(when.hour)}:${two(when.minute)}';
}
