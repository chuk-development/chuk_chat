/// The roster: your coworkers down the side of the messenger (§1, §4).
///
/// One row per agent with its name, what it is doing, and when it was last
/// active. An agent can hold several threads; picking one opens that
/// conversation. "Last active" is left as "no activity yet" when the app has not
/// seen anything happen — it is never back-filled with a plausible time.
library;

import 'package:flutter/material.dart';

import 'package:cowork/models/cowork_agent.dart';
import 'package:cowork/services/cowork/agent_roster_source.dart';

class AgentRosterView extends StatefulWidget {
  const AgentRosterView({
    super.key,
    required this.source,
    required this.onSelect,
    this.selectedAgentId,
    this.selectedThreadKey,
    this.onAddAgent,
    this.now,
  });

  final AgentRosterSource source;

  /// Called with the agent and the thread the user picked.
  final void Function(String agentId, String threadKey) onSelect;

  final String? selectedAgentId;
  final String? selectedThreadKey;

  /// Opens the onboarding flow. Hidden when null.
  final VoidCallback? onAddAgent;

  /// Clock seam so "5m ago" is deterministic in a test.
  final DateTime Function()? now;

  @override
  State<AgentRosterView> createState() => _AgentRosterViewState();
}

class _AgentRosterViewState extends State<AgentRosterView> {
  final Set<String> _expanded = <String>{};

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.source,
      builder: (context, _) {
        final agents = widget.source.agents;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(context),
            const Divider(height: 1),
            Expanded(
              child: agents.isEmpty
                  ? _emptyState(context)
                  : ListView.builder(
                      itemCount: agents.length,
                      itemBuilder: (context, index) =>
                          _agentTile(context, agents[index]),
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _header(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 8, top: 12, bottom: 12),
      child: Row(
        children: [
          Expanded(
            child: Text('Coworkers', style: theme.textTheme.titleSmall),
          ),
          if (widget.onAddAgent != null)
            IconButton(
              tooltip: 'Add an agent',
              icon: const Icon(Icons.person_add_alt),
              onPressed: widget.onAddAgent,
            ),
        ],
      ),
    );
  }

  Widget _emptyState(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'No coworkers yet.',
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.hintColor),
            ),
            if (widget.onAddAgent != null) ...[
              const SizedBox(height: 12),
              FilledButton(
                onPressed: widget.onAddAgent,
                child: const Text('Add an agent'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _agentTile(BuildContext context, CoworkAgent agent) {
    final theme = Theme.of(context);
    final selected = agent.id == widget.selectedAgentId;
    final expanded = _expanded.contains(agent.id) || selected;
    final threads = agent.threads;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          selected: selected,
          leading: CircleAvatar(
            radius: 16,
            child: Text(
              agent.name.isEmpty ? '?' : agent.name.characters.first.toUpperCase(),
            ),
          ),
          title: Text(agent.name, overflow: TextOverflow.ellipsis),
          subtitle: Row(
            children: [
              _activityDot(context, agent.activity),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${activityLabel(agent.activity)} · '
                  '${lastActivityLabel(agent.lastActivity, now: _now())}',
                  style: theme.textTheme.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          trailing: threads.length > 1
              ? Icon(expanded ? Icons.expand_less : Icons.expand_more, size: 18)
              : null,
          onTap: () {
            setState(() {
              if (expanded && !selected) {
                _expanded.remove(agent.id);
              } else {
                _expanded.add(agent.id);
              }
            });
            if (threads.isNotEmpty) {
              widget.onSelect(agent.id, threads.first.key);
            }
          },
        ),
        if (expanded && threads.length > 1)
          for (final thread in threads)
            Padding(
              padding: const EdgeInsets.only(left: 32),
              child: ListTile(
                dense: true,
                selected: selected && thread.key == widget.selectedThreadKey,
                title: Text(thread.title, overflow: TextOverflow.ellipsis),
                subtitle: thread.lastActivity == null
                    ? null
                    : Text(lastActivityLabel(thread.lastActivity, now: _now())),
                onTap: () => widget.onSelect(agent.id, thread.key),
              ),
            ),
        const Divider(height: 1),
      ],
    );
  }

  Widget _activityDot(BuildContext context, AgentActivity activity) {
    final theme = Theme.of(context);
    final color = switch (activity) {
      AgentActivity.working => theme.colorScheme.primary,
      AgentActivity.scheduled => theme.colorScheme.tertiary,
      AgentActivity.waiting => theme.hintColor,
    };
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }

  DateTime _now() => (widget.now ?? DateTime.now)();
}

/// The word for a coworker's state, as shown in the roster.
String activityLabel(AgentActivity activity) => switch (activity) {
      AgentActivity.working => 'working',
      AgentActivity.waiting => 'waiting',
      AgentActivity.scheduled => 'scheduled',
    };

/// "just now" / "5m ago" / "2h ago" / "3d ago", or a plain statement that
/// nothing has happened. Never a fabricated time.
String lastActivityLabel(DateTime? when, {required DateTime now}) {
  if (when == null) return 'no activity yet';
  final delta = now.difference(when);
  if (delta.isNegative || delta.inSeconds < 45) return 'just now';
  if (delta.inMinutes < 60) return '${delta.inMinutes}m ago';
  if (delta.inHours < 24) return '${delta.inHours}h ago';
  return '${delta.inDays}d ago';
}
