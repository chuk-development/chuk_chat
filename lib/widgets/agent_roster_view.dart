/// The sidebar: your coworkers down the left of the messenger (§1, §4).
///
/// It is a clean vertical list of AGENTS and nothing else. There are no chats
/// and no sessions in here: every coworker has exactly one long-lived thread,
/// so a row is an agent, and picking it opens that one thread. The rail carries
/// a "new coworker" affordance at the top, a selection highlight on the active
/// agent, and it can collapse to a slim avatar rail on a wide window.
///
/// One row per agent with its name, an optional role, what it is doing, and
/// when it was last active. "Last active" is left as "no activity yet" when the
/// app has not seen anything happen — it is never back-filled with a plausible
/// time.
///
/// ## Why it is built out of `widgets/sidebar/sidebar_chrome.dart`
///
/// The chrome (`SidebarTokens`, `SbBrand`, `SbRailRow`, `SbSectionLabel`,
/// `SbHairline`) is chuk_chat's, imported verbatim. CoWork's sidebar shows
/// different CONTENT — agents, not chat history — but it must not look like a
/// different product, so it takes every colour, radius, weight and motion from
/// the same tokens chuk's own sidebar uses. Nothing here invents a colour:
/// `SidebarTokens.of(context)` is the only source, which is what keeps the rail
/// in step when the user changes theme or accent.
///
/// The agent row is the one thing chuk has no widget for. `SbChatTile` is a
/// single-line row (title + time); a coworker needs two lines — its role and
/// what it is doing right now. [_AgentTile] therefore reproduces `SbChatTile`'s
/// visual grammar exactly (same 12 px radius, the always-reserved 1.5 px border
/// so selection never resizes a row, accent @0.18 fill when selected, iconFg
/// @0.05 on hover, the same 110 ms cross-fade) and adds the second line.
///
/// ## The skeleton is chuk's `SidebarDesktop.build`
///
/// Top spacer of `kTopInitialSpacing`; a brand row exactly `kMenuButtonHeight`
/// tall whose text starts right of the shell's hamburger (the hamburger is
/// drawn by the shell at `kFixedLeftPadding`, on top of this widget, and never
/// moves); the rail rows in an `IntrinsicWidth` column so every hover pill is
/// as wide as the widest label — New coworker, Control Rooms, Agent's browser
/// in chuk's New chat / Workspaces / Media slots; the list; and chuk's footer
/// pill floating over the list's tail with a fade behind it. The pill's gear is
/// the Settings entry, as in chuk. chuk's hosted-only pieces — the
/// `BalanceBadge` and the `UpdateBanner` — are left out.
library;

import 'package:flutter/material.dart';

import 'package:cowork/constants.dart';
import 'package:cowork/models/cowork_agent.dart';
import 'package:cowork/services/cowork/agent_roster_source.dart';
import 'package:cowork/widgets/agent_avatar.dart';
import 'package:cowork/widgets/sidebar/sidebar_chrome.dart';

class AgentRosterView extends StatefulWidget {
  const AgentRosterView({
    super.key,
    required this.source,
    required this.onSelect,
    this.selectedAgentId,
    this.selectedThreadKey,
    this.onAddAgent,
    this.onDeleteAgent,
    this.onOpenRooms,
    this.onOpenBrowser,
    this.onOpenSettings,
    this.accountLabel,
    this.now,
  });

  final AgentRosterSource source;

  /// Called with the agent and the thread the user picked. A coworker has one
  /// permanent thread, so this always reports that single thread's key.
  final void Function(String agentId, String threadKey) onSelect;

  final String? selectedAgentId;
  final String? selectedThreadKey;

  /// Opens the onboarding flow. Hidden when null.
  final VoidCallback? onAddAgent;

  /// Deletes a coworker. When set, a Delete item appears for agents that are not
  /// the paired host (the host agent is the real device, not a bot to delete).
  final void Function(String agentId)? onDeleteAgent;

  /// Control Rooms — chuk's Workspaces rail slot. Hidden when null.
  final VoidCallback? onOpenRooms;

  /// The agent's browser — chuk's Media rail slot. Hidden when null (the shell
  /// passes it once a coworker is selected).
  final VoidCallback? onOpenBrowser;

  /// Settings — the gear in chuk's footer pill. The whole footer is hidden
  /// when null (a shell without a shell config has no settings to open).
  final VoidCallback? onOpenSettings;

  /// What the footer pill says where chuk shows the account's display name.
  /// Null falls back to a plain label.
  final String? accountLabel;

  /// Clock seam so "5m ago" is deterministic in a test.
  final DateTime Function()? now;

  @override
  State<AgentRosterView> createState() => _AgentRosterViewState();
}

class _AgentRosterViewState extends State<AgentRosterView> {
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.source,
      builder: (context, _) {
        final t = SidebarTokens.of(context);
        final agents = widget.source.visibleAgents;
        final hidden = widget.source.hiddenAgents;

        // Three buckets, in the order a glance wants them: what is running now,
        // what will run on its own, what is idle. An empty bucket draws no
        // header — the rail never shows a label with nothing under it.
        final working = _bucket(agents, AgentActivity.working);
        final scheduled = _bucket(agents, AgentActivity.scheduled);
        final waiting = _bucket(agents, AgentActivity.waiting);

        // Hamburger stays anchored to the top-left always — brand text starts
        // just to the right of it so the two share the same baseline.
        const double brandLeftPadding =
            kFixedLeftPadding + kMenuButtonHeight + 4;
        final bool hasFooter = widget.onOpenSettings != null;

        return ColoredBox(
          color: t.bg,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Top spacer matches the hamburger's `top` offset.
              const SizedBox(height: kTopInitialSpacing),

              // Brand row is exactly kMenuButtonHeight tall and vertically
              // centred — that puts the label on the hamburger's baseline.
              const SizedBox(
                height: kMenuButtonHeight,
                child: SbBrand(
                  label: 'Coworkers',
                  showLogo: true,
                  fontSize: 18,
                  padding: EdgeInsets.fromLTRB(brandLeftPadding, 0, 16, 0),
                ),
              ),

              // The rail rows share a uniform pill width = the widest child's
              // intrinsic width (chuk's IntrinsicWidth + Column(stretch)).
              Align(
                alignment: Alignment.centerLeft,
                child: IntrinsicWidth(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (widget.onAddAgent != null)
                        SbRailRow(
                          icon: Icons.person_add_alt,
                          label: 'New coworker',
                          primary: true,
                          onTap: widget.onAddAgent!,
                        ),
                      if (widget.onOpenRooms != null)
                        SbRailRow(
                          icon: Icons.groups_outlined,
                          label: 'Control Rooms',
                          onTap: widget.onOpenRooms!,
                        ),
                      if (widget.onOpenBrowser != null)
                        SbRailRow(
                          icon: Icons.desktop_windows_outlined,
                          label: "Agent's browser",
                          onTap: widget.onOpenBrowser!,
                        ),
                    ],
                  ),
                ),
              ),
              SbHairline(
                margin: const EdgeInsets.fromLTRB(6, 8, 6, 0),
              ),
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: agents.isEmpty && hidden.isEmpty
                          ? _emptyState(context, t)
                          : ListView(
                              // The list runs under the footer; the padding
                              // keeps the last row reachable above the pill.
                              padding: EdgeInsets.only(
                                top: 2,
                                bottom: hasFooter ? 96 : 12,
                              ),
                              children: [
                                ..._section(context, 'Working', working),
                                ..._section(context, 'Scheduled', scheduled),
                                ..._section(context, 'Waiting', waiting),
                                if (hidden.isNotEmpty)
                                  ..._hiddenSection(context, t, hidden),
                              ],
                            ),
                    ),
                    if (hasFooter)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: _footer(context, t),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// chuk's sidebar footer: one long fade over the list's tail, then the name
  /// pill with the settings gear. The fade is a `Positioned.fill` behind the
  /// pill wrapped in `IgnorePointer`, so it never swallows a tap meant for a
  /// row showing through it.
  Widget _footer(BuildContext context, SidebarTokens t) {
    return Stack(
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    t.bg.withValues(alpha: 0),
                    t.bg.withValues(alpha: 0.35),
                    t.bg.withValues(alpha: 0.6),
                  ],
                  stops: const [0.0, 0.55, 1.0],
                ),
              ),
            ),
          ),
        ),
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 34),
            _footerRow(context, t),
          ],
        ),
      ],
    );
  }

  /// chuk's `_buildFooterRow`, minus the hosted `BalanceBadge`. The pill is
  /// opaque on purpose: only the space around it fades into the list, so the
  /// label stays legible over any row behind it.
  Widget _footerRow(BuildContext context, SidebarTokens t) {
    final Color pillColor = Color.alphaBlend(
      t.accent.withValues(alpha: 0.08),
      t.bg,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
      child: Material(
        color: pillColor,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: widget.onOpenSettings,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 5, 4, 5),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.accountLabel ?? 'Account',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: t.iconFg,
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Material(
                  color: Colors.transparent,
                  shape: const CircleBorder(),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: widget.onOpenSettings,
                    child: Tooltip(
                      message: 'Settings',
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Icon(
                          Icons.settings_rounded,
                          size: 24,
                          color: t.iconFg.withValues(alpha: 0.8),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<CoworkAgent> _bucket(List<CoworkAgent> agents, AgentActivity activity) =>
      <CoworkAgent>[
        for (final a in agents)
          if (a.activity == activity) a,
      ];

  /// A labelled group. Returns nothing at all when the bucket is empty, so the
  /// rail shows only the states that actually exist right now.
  List<Widget> _section(
    BuildContext context,
    String label,
    List<CoworkAgent> agents,
  ) {
    if (agents.isEmpty) return const <Widget>[];
    return <Widget>[
      SbSectionLabel(label: label, count: agents.length),
      for (final agent in agents) _tile(context, agent),
    ];
  }

  Widget _tile(BuildContext context, CoworkAgent agent) => _AgentTile(
        key: ValueKey<String>('agent-tile-${agent.id}'),
        agent: agent,
        selected: agent.id == widget.selectedAgentId,
        now: _now(),
        onTap: agent.threads.isEmpty
            ? null
            : () => widget.onSelect(agent.id, agent.threads.first.key),
        onHide: () => widget.source.hideAgent(agent.id),
        onDelete: widget.onDeleteAgent == null || agent.onHost
            ? null
            : () => widget.onDeleteAgent!(agent.id),
      );

  Widget _emptyState(BuildContext context, SidebarTokens t) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'No coworkers yet.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: t.muted),
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

  /// The hidden coworkers, folded away at the bottom (§16.1 hide/unhide). A
  /// hidden agent is not gone — this is where the user brings it back.
  List<Widget> _hiddenSection(
    BuildContext context,
    SidebarTokens t,
    List<CoworkAgent> hidden,
  ) {
    return <Widget>[
      SbSectionLabel(
        label: 'Hidden',
        count: hidden.length,
        color: t.muted,
      ),
      for (final agent in hidden)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 4, 8, 4),
            child: Row(
              children: [
                AgentAvatar(
                  seed: agent.id,
                  label: agent.name,
                  radius: 13,
                  dimmed: true,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    agent.name,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      color: t.iconFg.withValues(alpha: 0.45),
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => widget.source.unhideAgent(agent.id),
                  child: const Text('Unhide'),
                ),
              ],
            ),
          ),
        ),
    ];
  }

  DateTime _now() => (widget.now ?? DateTime.now)();
}

/// One coworker, in chuk's tile grammar.
///
/// Deliberately NOT `SbChatTile`: that row carries a title and a timestamp on
/// one line, and a coworker needs two — the role it was given, and what it is
/// doing. Every visual value below is copied from `SbChatTile` so the two read
/// as the same component: 12 px radius, a border that is always 1.5 px wide
/// (transparent when unselected) so selecting a row changes only its colour and
/// never the list's layout, accent @0.18 as the selected fill with accent @0.55
/// as its edge, iconFg @0.05 on hover, and the same 110 ms cross-fade.
class _AgentTile extends StatefulWidget {
  const _AgentTile({
    super.key,
    required this.agent,
    required this.selected,
    required this.now,
    this.onTap,
    required this.onHide,
    this.onDelete,
  });

  final CoworkAgent agent;
  final bool selected;
  final DateTime now;
  final VoidCallback? onTap;
  final VoidCallback onHide;

  /// Null for the paired host: it is the user's real device, not a bot to
  /// delete, so the menu simply does not offer it.
  final VoidCallback? onDelete;

  @override
  State<_AgentTile> createState() => _AgentTileState();
}

class _AgentTileState extends State<_AgentTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final t = SidebarTokens.of(context);
    final agent = widget.agent;
    final selected = widget.selected;
    final working = agent.activity == AgentActivity.working;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(12),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 110),
            padding: const EdgeInsets.fromLTRB(10, 7, 6, 7),
            decoration: BoxDecoration(
              color: selected
                  ? t.accent.withValues(alpha: 0.18)
                  : (_hovered ? t.iconFg.withValues(alpha: 0.05) : null),
              border: Border.all(
                color: selected
                    ? t.accent.withValues(alpha: 0.55)
                    : Colors.transparent,
                width: 1.5,
              ),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                AgentAvatar(seed: agent.id, label: agent.name, radius: 15),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        agent.name,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15,
                          height: 1.2,
                          fontWeight:
                              selected ? FontWeight.w700 : FontWeight.w500,
                          color: selected ? t.accent : t.iconFg,
                        ),
                      ),
                      if (agent.role != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: Text(
                            agent.role!,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.25,
                              color: t.accent.withValues(alpha: 0.85),
                            ),
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Row(
                          children: [
                            _ActivityDot(activity: agent.activity, tokens: t),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                '${activityLabel(agent.activity)} · '
                                '${lastActivityLabel(agent.lastActivity, now: widget.now)}',
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  height: 1.25,
                                  color: working
                                      ? t.accent.withValues(alpha: 0.9)
                                      : t.iconFg.withValues(alpha: 0.55),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                // The row menu stays in the tree at all times — a hover-only
                // control is invisible on a touch screen — but it sits back at
                // low contrast until the pointer is on the row.
                AnimatedOpacity(
                  duration: const Duration(milliseconds: 110),
                  opacity: _hovered || selected ? 1 : 0.45,
                  child: PopupMenuButton<String>(
                    tooltip: 'More',
                    padding: EdgeInsets.zero,
                    iconSize: 18,
                    icon: Icon(
                      Icons.more_vert,
                      size: 18,
                      color: t.iconFg.withValues(alpha: 0.7),
                    ),
                    onSelected: (value) {
                      if (value == 'hide') widget.onHide();
                      if (value == 'delete') widget.onDelete?.call();
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
                      if (widget.onDelete != null)
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
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The state dot. A working agent gets the accent plus a soft glow, the same
/// treatment `SbChatTile` gives a streaming chat, so "something is running" is
/// the one thing that catches the eye in a long rail.
class _ActivityDot extends StatelessWidget {
  const _ActivityDot({required this.activity, required this.tokens});

  final AgentActivity activity;
  final SidebarTokens tokens;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = switch (activity) {
      AgentActivity.working => tokens.accent,
      AgentActivity.scheduled => theme.colorScheme.tertiary,
      AgentActivity.waiting => tokens.iconFg.withValues(alpha: 0.35),
    };
    return Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: activity == AgentActivity.working
            ? [
                BoxShadow(
                  color: color.withValues(alpha: 0.5),
                  blurRadius: 4,
                  spreadRadius: 1,
                ),
              ]
            : null,
      ),
    );
  }
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
