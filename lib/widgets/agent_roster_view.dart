/// The roster: your coworkers down the side of the messenger (§1, §4).
///
/// One row per agent with its name, what it is doing, and when it was last
/// active. An agent can hold several threads; picking one opens that
/// conversation. "Last active" is left as "no activity yet" when the app has not
/// seen anything happen — it is never back-filled with a plausible time.
library;

import 'package:flutter/material.dart';

import 'package:cowork/models/cowork_agent.dart';
import 'package:cowork/widgets/agent_avatar.dart';
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
        final agents = widget.source.visibleAgents;
        final hidden = widget.source.hiddenAgents;
        final working = <CoworkAgent>[
          for (final a in agents)
            if (a.activity == AgentActivity.working) a,
        ];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(context),
            if (working.isNotEmpty) _activeNowStrip(context, working),
            const Divider(height: 1),
            Expanded(
              child: agents.isEmpty && hidden.isEmpty
                  ? _emptyState(context)
                  : ListView(
                      children: [
                        for (final agent in agents) _agentTile(context, agent),
                        if (hidden.isNotEmpty) _hiddenSection(context, hidden),
                      ],
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
          leading: AgentAvatar(seed: agent.id, label: agent.name, radius: 16),
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
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (threads.length > 1)
                Icon(expanded ? Icons.expand_less : Icons.expand_more, size: 18),
              PopupMenuButton<String>(
                tooltip: 'More',
                icon: const Icon(Icons.more_vert, size: 18),
                onSelected: (value) {
                  if (value == 'hide') widget.source.hideAgent(agent.id);
                },
                itemBuilder: (context) => const [
                  PopupMenuItem<String>(
                    value: 'hide',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.visibility_off_outlined, size: 18),
                      title: Text('Hide'),
                    ),
                  ),
                ],
              ),
            ],
          ),
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

  /// A row of the coworkers working right now (§16.1 "Active now"). It is the
  /// same truth as the activity dot in each row, hoisted to the top so a glance
  /// answers "is anything running" without scrolling a long roster. Shown only
  /// when something is actually working; never a placeholder.
  Widget _activeNowStrip(BuildContext context, List<CoworkAgent> working) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Active now',
            style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor),
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 34,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: working.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, i) {
                final agent = working[i];
                return Tooltip(
                  message: agent.name,
                  child: GestureDetector(
                    onTap: () {
                      if (agent.threads.isNotEmpty) {
                        widget.onSelect(agent.id, agent.threads.first.key);
                      }
                    },
                    child: AgentAvatar(
                      seed: agent.id,
                      label: agent.name,
                      radius: 16,
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// The hidden coworkers, folded away at the bottom (§16.1 hide/unhide). A
  /// hidden agent is not gone — this is where the user brings it back.
  Widget _hiddenSection(BuildContext context, List<CoworkAgent> hidden) {
    final theme = Theme.of(context);
    return ExpansionTile(
      key: const ValueKey('hidden-section'),
      leading: const Icon(Icons.visibility_off_outlined, size: 18),
      title: Text(
        'Hidden (${hidden.length})',
        style: theme.textTheme.bodyMedium,
      ),
      childrenPadding: EdgeInsets.zero,
      children: [
        for (final agent in hidden)
          ListTile(
            dense: true,
            leading: AgentAvatar(
              seed: agent.id,
              label: agent.name,
              radius: 14,
              dimmed: true,
            ),
            title: Text(agent.name, overflow: TextOverflow.ellipsis),
            trailing: TextButton(
              onPressed: () => widget.source.unhideAgent(agent.id),
              child: const Text('Unhide'),
            ),
          ),
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
