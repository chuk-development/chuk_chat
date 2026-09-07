/// The phone home screen: the list of coworkers, after Grok Bot's bot list.
///
/// Grok Bot's home is a messenger inbox, not a sidebar: one row per bot with
/// its face and presence dot, the name, a small tag, the time of the last
/// message and one line of preview. Three round chips float above it —
/// account, search, add — on a soft fade. No tab bar, no drawer. Tap a row
/// and the chat opens; back returns here.
///
/// CoWork's roster is the same data (`AgentRosterSource`); this widget only
/// lays it out like an inbox. The desktop sidebar (`AgentRosterView`) keeps
/// its buckets — this is the phone's view of the same list.
library;

import 'package:flutter/material.dart';

import 'package:cowork/models/cowork_agent.dart';
import 'package:cowork/platform_specific/mobile/mobile_chips.dart';
import 'package:cowork/platform_specific/mobile/mobile_layout.dart';
import 'package:cowork/platform_specific/mobile/mobile_presence_avatar.dart';
import 'package:cowork/services/cowork/agent_roster_source.dart';

class MobileAgentList extends StatefulWidget {
  const MobileAgentList({
    super.key,
    required this.source,
    required this.onSelect,
    this.selectedAgentId,
    this.selectedThreadKey,
    this.onAddAgent,
    this.onOpenAccount,
    this.accountLabel,
    this.now,
  });

  final AgentRosterSource source;

  /// Opens a coworker's thread — the same callback the desktop sidebar uses.
  final void Function(String agentId, String threadKey) onSelect;

  final String? selectedAgentId;
  final String? selectedThreadKey;

  /// The accent "+" chip. Null hides it.
  final VoidCallback? onAddAgent;

  /// The account chip on the left. Null hides it.
  final VoidCallback? onOpenAccount;

  /// Text the account chip's monogram is taken from (the user's name or
  /// e-mail). Null shows a person icon.
  final String? accountLabel;

  /// Injectable clock for tests.
  final DateTime Function()? now;

  @override
  State<MobileAgentList> createState() => _MobileAgentListState();
}

class _MobileAgentListState extends State<MobileAgentList> {
  final TextEditingController _query = TextEditingController();
  bool _searching = false;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  DateTime _now() => (widget.now ?? DateTime.now)();

  void _toggleSearch() {
    setState(() {
      _searching = !_searching;
      if (!_searching) _query.clear();
    });
  }

  List<CoworkAgent> _filtered(List<CoworkAgent> agents) {
    final String q = _query.text.trim().toLowerCase();
    if (q.isEmpty) return agents;
    return agents
        .where(
          (agent) =>
              agent.name.toLowerCase().contains(q) ||
              (agent.role?.toLowerCase().contains(q) ?? false),
        )
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final double topInset =
        MobileLayout.chromeInset(context) +
        (_searching ? _SearchField.height : 0);
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[widget.source, _query]),
      builder: (BuildContext context, Widget? _) {
        final List<CoworkAgent> agents = _filtered(widget.source.visibleAgents);
        return Stack(
          children: [
            Positioned.fill(
              child: agents.isEmpty
                  ? _emptyState(context, topInset)
                  : ListView.builder(
                      padding: EdgeInsets.only(
                        top: topInset,
                        bottom: MediaQuery.paddingOf(context).bottom + 16,
                      ),
                      itemCount: agents.length,
                      itemBuilder: (BuildContext context, int index) {
                        final CoworkAgent agent = agents[index];
                        return MobileAgentRow(
                          key: ValueKey<String>('mobile-agent-${agent.id}'),
                          agent: agent,
                          selected: agent.id == widget.selectedAgentId,
                          now: _now(),
                          onTap: agent.threads.isEmpty
                              ? null
                              : () => widget.onSelect(
                                  agent.id,
                                  agent.threads.first.key,
                                ),
                        );
                      },
                    ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: MobileHomeBar(
                accountLabel: widget.accountLabel,
                onOpenAccount: widget.onOpenAccount,
                onSearch: _toggleSearch,
                searching: _searching,
                onAddAgent: widget.onAddAgent,
                searchField: _searching
                    ? _SearchField(controller: _query, onClose: _toggleSearch)
                    : null,
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _emptyState(BuildContext context, double topInset) {
    final theme = Theme.of(context);
    final bool filtering = _query.text.trim().isNotEmpty;
    return Padding(
      padding: EdgeInsets.fromLTRB(24, topInset + 24, 24, 24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              filtering ? 'No agent matches.' : 'No agents yet.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
            if (!filtering && widget.onAddAgent != null) ...[
              const SizedBox(height: 16),
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
}

/// The floating home bar: account chip left, search and add chips right.
class MobileHomeBar extends StatelessWidget {
  const MobileHomeBar({
    super.key,
    this.accountLabel,
    this.onOpenAccount,
    this.onSearch,
    this.searching = false,
    this.onAddAgent,
    this.searchField,
  });

  final String? accountLabel;
  final VoidCallback? onOpenAccount;
  final VoidCallback? onSearch;
  final bool searching;
  final VoidCallback? onAddAgent;

  /// Rendered under the chips while the search is open.
  final Widget? searchField;

  static String monogramOf(String? label) {
    final String trimmed = (label ?? '').trim();
    if (trimmed.isEmpty) return '';
    // "alex.smith@…" → "A"; "Alex Smith" → "AS".
    final List<String> parts = trimmed
        .split(RegExp(r'[\s@._-]+'))
        .where((String p) => p.isNotEmpty)
        .toList(growable: false);
    if (parts.length >= 2 && !trimmed.contains('@')) {
      return (parts[0].characters.first + parts[1].characters.first)
          .toUpperCase();
    }
    return parts.first.characters.first.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final String monogram = monogramOf(accountLabel);
    return MobileBarFade(
      child: SafeArea(
        bottom: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
              child: SizedBox(
                height: MobileLayout.chipDiameter,
                child: Row(
                  children: [
                    if (onOpenAccount != null)
                      _AccountChip(monogram: monogram, onTap: onOpenAccount!),
                    const Spacer(),
                    if (onSearch != null) ...[
                      MobileRoundChip(
                        icon: searching ? Icons.close : Icons.search,
                        onTap: onSearch,
                        tooltip: searching ? 'Close search' : 'Search',
                        semanticsId: 'mobile_home_search',
                      ),
                      const SizedBox(width: 8),
                    ],
                    if (onAddAgent != null)
                      MobileAccentChip(
                        icon: Icons.add,
                        onTap: onAddAgent,
                        tooltip: 'Add an agent',
                        semanticsId: 'mobile_home_add',
                      ),
                  ],
                ),
              ),
            ),
            if (searchField != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
                child: searchField,
              ),
          ],
        ),
      ),
    );
  }
}

/// The account chip: the user's monogram on a surface circle.
class _AccountChip extends StatelessWidget {
  const _AccountChip({required this.monogram, required this.onTap});

  final String monogram;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Color fg = theme.colorScheme.onSurface;
    return Semantics(
      identifier: 'mobile_home_account',
      button: true,
      label: 'Account',
      child: Tooltip(
        message: 'Account',
        child: SizedBox.square(
          dimension: MobileLayout.chipDiameter,
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: mobileChipShadow(theme),
            ),
            child: Material(
              color: theme.colorScheme.surface,
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onTap,
                child: Center(
                  child: monogram.isEmpty
                      ? Icon(Icons.person_outline, size: 22, color: fg)
                      : Text(
                          monogram,
                          style: TextStyle(
                            color: fg.withValues(alpha: 0.8),
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.onClose});

  static const double height = 48;

  final TextEditingController controller;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: height - 6,
      child: TextField(
        controller: controller,
        autofocus: true,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: 'Search agents',
          prefixIcon: const Icon(Icons.search, size: 20),
          isDense: true,
          filled: true,
          fillColor: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.6,
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(21),
            borderSide: BorderSide.none,
          ),
        ),
        onSubmitted: (_) {},
      ),
    );
  }
}

/// One inbox row: face + presence dot, name, role tag, time, preview line.
class MobileAgentRow extends StatelessWidget {
  const MobileAgentRow({
    super.key,
    required this.agent,
    required this.now,
    this.selected = false,
    this.onTap,
  });

  final CoworkAgent agent;
  final DateTime now;
  final bool selected;
  final VoidCallback? onTap;

  /// Rows are 72 dp: Grok Bot's 66 pt rounded up to a Material list row.
  static const double height = 72;

  /// The preview line under the name. What the coworker is doing now beats a
  /// stale thread title; a thread title beats the brief; the brief beats
  /// silence.
  static String previewOf(CoworkAgent agent) {
    if (agent.running) return 'Working…';
    for (final thread in agent.threads) {
      final String title = thread.title.trim();
      if (title.isNotEmpty && title != 'default') return title;
    }
    final String brief = agent.brief?.trim() ?? '';
    if (brief.isNotEmpty) return brief;
    return 'No activity yet';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Color fg = theme.colorScheme.onSurface;
    final Color muted = fg.withValues(alpha: 0.55);
    final String? role = agent.role?.trim();
    final String time = mobileTimeLabel(agent.lastActivity, now: now);
    return Semantics(
      identifier: 'mobile-agent-row-${agent.id}',
      button: onTap != null,
      selected: selected,
      child: Material(
        color: selected
            ? theme.colorScheme.primary.withValues(alpha: 0.06)
            : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: height),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  MobilePresenceAvatar(agent: agent, radius: 24),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                agent.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: fg,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            if (role != null && role.isNotEmpty) ...[
                              const SizedBox(width: 8),
                              _RoleTag(role: role),
                            ],
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(
                          previewOf(agent),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: muted, fontSize: 14),
                        ),
                      ],
                    ),
                  ),
                  if (time.isNotEmpty) ...[
                    const SizedBox(width: 10),
                    Text(time, style: TextStyle(color: muted, fontSize: 12)),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The small grey tag next to the name ("Meal prepping" in Grok Bot; the
/// coworker's role here).
class _RoleTag extends StatelessWidget {
  const _RoleTag({required this.role});

  final String role;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 120),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          child: Text(
            role,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
              fontSize: 12,
            ),
          ),
        ),
      ),
    );
  }
}

/// The time column of an inbox row, like a messenger: a clock time today,
/// "Yesterday", the weekday inside a week, a short date after that. Empty
/// when nothing has happened.
String mobileTimeLabel(DateTime? when, {required DateTime now}) {
  if (when == null) return '';
  final DateTime day = DateTime(when.year, when.month, when.day);
  final DateTime today = DateTime(now.year, now.month, now.day);
  final int days = today.difference(day).inDays;
  if (days <= 0) {
    final int h12 = when.hour % 12 == 0 ? 12 : when.hour % 12;
    final String mm = when.minute.toString().padLeft(2, '0');
    return '$h12:$mm ${when.hour < 12 ? 'AM' : 'PM'}';
  }
  if (days == 1) return 'Yesterday';
  if (days < 7) {
    const List<String> names = <String>[
      'Mon',
      'Tue',
      'Wed',
      'Thu',
      'Fri',
      'Sat',
      'Sun',
    ];
    return names[when.weekday - 1];
  }
  return '${when.day}.${when.month}.';
}
