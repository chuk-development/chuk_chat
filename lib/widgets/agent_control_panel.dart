/// The in-UI control surface (§16): the model this coworker runs on, what it
/// has spent, how long it has worked, the box it works in, and its skills.
///
/// The panel draws only what the host measured. A block the host did not report
/// says so, with the reason — never a plausible-looking zero. There are no
/// blocks here that nothing can fill: the schedule field and the integrations
/// list were removed when it became clear that neither reached the host (the
/// Automations page and the connector settings own those).
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

  /// Retired. The panel no longer sets schedules: nothing installed them on the
  /// host, and the Automations page is where a real schedule lives. Kept only
  /// because `cowork_shell_state.dart` still passes it; it is never called.
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ValueListenableBuilder<AgentControlSnapshot>(
      valueListenable: widget.source.snapshotFor(_sessionKey),
      builder: (context, snapshot, _) {
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(widget.agent.name, style: theme.textTheme.titleMedium),
                ),
                IconButton(
                  tooltip: 'Refresh',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.refresh, size: 18),
                  onPressed: () => _run(
                    () => widget.source.refresh(_sessionKey),
                  ),
                ),
              ],
            ),
            if (widget.agent.role != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  widget.agent.role!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.primary),
                ),
              ),
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
            _section(context, 'Model', _buildModel(context, snapshot.model)),
            _section(context, 'Token use', _buildTokens(context, snapshot.tokens)),
            _section(
              context,
              'Session runtime',
              _buildRuntime(context, snapshot.runtime),
            ),
            _section(context, 'Sandbox', _buildSandbox(context, snapshot.sandbox)),
            _section(context, 'Skills', _buildSkills(context, snapshot.skills)),
          ],
        );
      },
    );
  }

  // --- blocks ----------------------------------------------------------------

  Widget _buildModel(BuildContext context, ControlValue<AgentModelChoice> value) {
    final theme = Theme.of(context);
    return switch (value) {
      ControlUnavailable<AgentModelChoice>(:final reason) =>
        _notReported(context, reason),
      ControlLoading<AgentModelChoice>() => _loading(),
      ControlAvailable<AgentModelChoice>(value: final choice) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(choice.id),
            if (choice.detail != null)
              Text(
                choice.detail!,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
              ),
          ],
        ),
    };
  }

  Widget _buildTokens(BuildContext context, ControlValue<AgentTokenUsage> value) {
    final theme = Theme.of(context);
    return switch (value) {
      ControlUnavailable<AgentTokenUsage>(:final reason) =>
        _notReported(context, reason),
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
      ControlUnavailable<AgentSessionRuntime>(:final reason) =>
        _notReported(context, reason),
      ControlLoading<AgentSessionRuntime>() => _loading(),
      ControlAvailable<AgentSessionRuntime>(value: final runtime) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${formatRuntime(runtime.active)} working'),
            if (runtime.running && runtime.current != null)
              Text(
                'Running now, ${formatRuntime(runtime.current!)} into this run.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.primary),
              ),
            if (runtime.startedAt != null)
              Text(
                'First run ${formatTimestamp(runtime.startedAt!)}',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
              ),
          ],
        ),
    };
  }

  Widget _buildSandbox(BuildContext context, ControlValue<AgentSandbox> value) {
    final theme = Theme.of(context);
    return switch (value) {
      ControlUnavailable<AgentSandbox>(:final reason) => _notReported(context, reason),
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
                style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
              ),
            if (sandbox.workspace != null)
              Text(
                sandbox.workspace!,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
              ),
          ],
        ),
    };
  }

  Widget _buildSkills(BuildContext context, ControlValue<List<AgentSkill>> value) {
    return switch (value) {
      ControlUnavailable<List<AgentSkill>>(:final reason) =>
        _notReported(context, reason),
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

  // --- helpers ---------------------------------------------------------------

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
        Icon(Icons.remove_circle_outline, size: 14, color: theme.hintColor),
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
