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

/// The two ways to look at the roster (§16.1 Bot Mode's `SESSIONS | BOTS`).
/// BOTS is the coworker list; SESSIONS is a flat, most-recent-first list of
/// every conversation across all coworkers.
enum RosterTab { bots, sessions }

class AgentRosterView extends StatefulWidget {
  const AgentRosterView({
    super.key,
    required this.source,
    required this.onSelect,
    this.selectedAgentId,
    this.selectedThreadKey,
    this.onAddAgent,
    this.onDeleteAgent,
    this.now,
  });

  final AgentRosterSource source;

  /// Called with the agent and the thread the user picked.
  final void Function(String agentId, String threadKey) onSelect;

  final String? selectedAgentId;
  final String? selectedThreadKey;

  /// Opens the onboarding flow. Hidden when null.
  final VoidCallback? onAddAgent;

  /// Deletes a coworker. When set, a Delete item appears for agents that are not
  /// the paired host (the host agent is the real device, not a bot to delete).
  final void Function(String agentId)? onDeleteAgent;

  /// Clock seam so "5m ago" is deterministic in a test.
  final DateTime Function()? now;

  @override
  State<AgentRosterView> createState() => _AgentRosterViewState();
}

class _AgentRosterViewState extends State<AgentRosterView> {
  final Set<String> _expanded = <String>{};
  RosterTab _tab = RosterTab.bots;

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
            _tabStrip(context),
            if (_tab == RosterTab.bots && working.isNotEmpty)
              _activeNowStrip(context, working),
            const Divider(height: 1),
            Expanded(
              child: _tab == RosterTab.bots
                  ? (agents.isEmpty && hidden.isEmpty
                      ? _emptyState(context)
                      : ListView(
                          children: [
                            for (final agent in agents)
                              _agentTile(context, agent),
                            if (hidden.isNotEmpty)
                              _hiddenSection(context, hidden),
                          ],
                        ))
                  : _sessionsList(context, agents),
            ),
          ],
        );
      },
    );
  }

  /// The `SESSIONS | BOTS` selector (§16.1). A plain segmented control rather
  /// than a TabController — the two views share this widget's state, so a
  /// separate controller lifecycle would only be ceremony.
  Widget _tabStrip(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: SegmentedButton<RosterTab>(
        segments: const [
          ButtonSegment<RosterTab>(
            value: RosterTab.bots,
            label: Text('Bots'),
            icon: Icon(Icons.people_alt_outlined, size: 16),
          ),
          ButtonSegment<RosterTab>(
            value: RosterTab.sessions,
            label: Text('Sessions'),
            icon: Icon(Icons.forum_outlined, size: 16),
          ),
        ],
        selected: <RosterTab>{_tab},
        showSelectedIcon: false,
        style: const ButtonStyle(visualDensity: VisualDensity.compact),
        onSelectionChanged: (sel) => setState(() => _tab = sel.first),
      ),
    );
  }

  /// Every conversation across every (visible) coworker, most-recent first —
  /// the SESSIONS view. Built from the roster the app already holds: agent +
  /// thread + the thread's own last-activity. A thread that never saw activity
  /// sorts to the bottom, never gets a fabricated time.
  Widget _sessionsList(BuildContext context, List<CoworkAgent> agents) {
    final theme = Theme.of(context);
    final rows = <(CoworkAgent, CoworkThreadInfo)>[
      for (final agent in agents)
        for (final thread in agent.threads) (agent, thread),
    ];
    rows.sort((a, b) {
      final at = a.$2.lastActivity;
      final bt = b.$2.lastActivity;
      if (at == null && bt == null) return 0;
      if (at == null) return 1; // no-activity threads sink
      if (bt == null) return -1;
      return bt.compareTo(at); // most recent first
    });
    if (rows.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'No conversations yet.',
            style: TextStyle(color: theme.hintColor),
          ),
        ),
      );
    }
    return ListView.builder(
      itemCount: rows.length,
      itemBuilder: (context, i) {
        final (agent, thread) = rows[i];
        final selected = agent.id == widget.selectedAgentId &&
            thread.key == widget.selectedThreadKey;
        return ListTile(
          selected: selected,
          leading: AgentAvatar(seed: agent.id, label: agent.name, radius: 16),
          title: Text(agent.name, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '${thread.title} · '
            '${lastActivityLabel(thread.lastActivity, now: _now())}',
            style: theme.textTheme.bodySmall,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => widget.onSelect(agent.id, thread.key),
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
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (agent.role != null)
                Text(
                  agent.role!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              Row(
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
                  if (value == 'delete') widget.onDeleteAgent?.call(agent.id);
                },
                itemBuilder: (context) => [
                  const PopupMenuItem<String>(
                    value: 'hide',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.visibility_off_outlined, size: 18),
                      title: Text('Hide'),
                    ),
                  ),
                  // The paired host is the user's real device, not a bot to
                  // delete, so Delete is offered only for other coworkers.
                  if (widget.onDeleteAgent != null && !agent.onHost)
                    const PopupMenuItem<String>(
                      value: 'delete',
                      child: ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.delete_outline, size: 18),
                        title: Text('Delete'),
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
