/// The phone home screen: the coworkers, as a messenger inbox in the expressive
/// design language.
///
/// The shape is the one the reference messenger uses for its chat list, and the
/// content is CoWork's own roster ([AgentRosterSource]):
///
///  * a compact title bar — the account face on the left, "Coworkers", and a
///    search target that swaps the title for an inline field;
///  * the connected filter group, All / Unread, with the unread count on the
///    second segment ([AgentReadMarks] answers what is unread);
///  * one row per coworker: its blob face with the presence dot, the name, the
///    role tag, the time of the last activity, one line of preview, and an
///    unread dot. The row springs and morphs on press, and the list cascades in.
///
/// What the messenger has and this does NOT: no pinned/archived/starred buckets,
/// no groups filter, no message-body search. The roster has no such data, and a
/// filter that can never match is worse than no filter.
library;

import 'package:animations/animations.dart';
import 'package:flutter/material.dart';

import 'package:cowork/models/cowork_agent.dart';
import 'package:cowork/services/cowork/agent_profile_store.dart';
import 'package:cowork/services/cowork/agent_read_marks.dart';
import 'package:cowork/services/cowork/agent_roster_source.dart';
import 'package:cowork/ui/expressive/agent_face.dart';
import 'package:cowork/ui/expressive/connected_group.dart';
import 'package:cowork/ui/expressive/motion.dart';
import 'package:cowork/ui/expressive/staggered.dart';
import 'package:cowork/widgets/anchored_menu.dart';

/// The account monogram: "alex.smith@…" → "A", "Alex Smith" → "AS".
String accountMonogram(String? label) {
  final String trimmed = (label ?? '').trim();
  if (trimmed.isEmpty) return '';
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

class MobileAgentList extends StatefulWidget {
  const MobileAgentList({
    super.key,
    required this.source,
    required this.onSelect,
    this.selectedAgentId,
    this.selectedThreadKey,
    this.onAddAgent,
    this.onOpenAccount,
    this.onOpenProfile,
    this.onRenameAgent,
    this.onDeleteAgent,
    this.accountLabel,
    this.now,
    this.readMarks,
    this.profiles,
  });

  final AgentRosterSource source;

  /// Opens a coworker's thread — the same callback the desktop sidebar uses.
  final void Function(String agentId, String threadKey) onSelect;

  final String? selectedAgentId;
  final String? selectedThreadKey;

  /// The accent "+" target. Null hides it.
  final VoidCallback? onAddAgent;

  /// The account face on the left. Null hides it.
  final VoidCallback? onOpenAccount;

  /// Opens a coworker's profile page (long-press → Profile).
  final void Function(CoworkAgent agent)? onOpenProfile;

  /// Renames a coworker (long-press → Rename). This is the one profile field
  /// that reaches the host.
  final void Function(CoworkAgent agent)? onRenameAgent;

  /// Deletes a coworker (long-press → Delete).
  final void Function(CoworkAgent agent)? onDeleteAgent;

  /// Text the account monogram is taken from (the user's name or e-mail).
  final String? accountLabel;

  /// Injectable clock for tests.
  final DateTime Function()? now;

  /// Injectable stores for tests; default to the app-wide ones.
  final AgentReadMarks? readMarks;
  final AgentProfileStore? profiles;

  @override
  State<MobileAgentList> createState() => _MobileAgentListState();
}

class _MobileAgentListState extends State<MobileAgentList> {
  static const List<String> _filters = <String>['All', 'Unread'];

  final TextEditingController _query = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  int _filter = 0;

  /// Direction of the last filter change — drives the shared-axis slide.
  bool _reverse = false;

  /// Whether the rows play their cascade. Off right after a search closes, so
  /// the list comes back instantly instead of re-staggering.
  bool _animate = true;

  bool _searching = false;

  AgentReadMarks get _marks => widget.readMarks ?? AgentReadMarks.instance;
  AgentProfileStore get _profiles =>
      widget.profiles ?? AgentProfileStore.instance;

  @override
  void dispose() {
    _query.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  DateTime _now() => (widget.now ?? DateTime.now)();

  void _openSearch() {
    setState(() => _searching = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  void _closeSearch() {
    _query.clear();
    _searchFocus.unfocus();
    setState(() {
      _searching = false;
      _animate = false;
    });
  }

  List<CoworkAgent> _visible() {
    Iterable<CoworkAgent> list = widget.source.visibleAgents;
    if (_filter == 1) list = list.where(_marks.isUnread);
    final String q = _query.text.trim().toLowerCase();
    if (q.isNotEmpty) {
      list = list.where(
        (CoworkAgent agent) =>
            agent.name.toLowerCase().contains(q) ||
            (_roleOf(agent)?.toLowerCase().contains(q) ?? false) ||
            MobileAgentRow.previewOf(
              agent,
              profiles: _profiles,
            ).toLowerCase().contains(q),
      );
    }
    return list.toList(growable: false);
  }

  /// The role line: the one the user set in the profile wins over the one the
  /// agent was created with.
  String? _roleOf(CoworkAgent agent) {
    final String? stored = _profiles.profileOf(agent.id).role?.trim();
    if (stored != null && stored.isNotEmpty) return stored;
    final String? own = agent.role?.trim();
    return (own == null || own.isEmpty) ? null : own;
  }

  Future<void> _openRowMenu(BuildContext rowContext, CoworkAgent agent) async {
    final ThemeData theme = Theme.of(rowContext);
    final ColorScheme scheme = theme.colorScheme;
    final bool unread = _marks.isUnread(agent);
    final String? choice = await showAnchoredMenu<String>(
      rowContext,
      color: scheme.surfaceContainerHigh,
      borderColor: scheme.outlineVariant,
      items: <PopupMenuEntry<String>>[
        if (widget.onOpenProfile != null)
          const PopupMenuItem<String>(
            value: 'profile',
            child: _MenuRow(icon: Icons.person_rounded, label: 'Profile'),
          ),
        if (widget.onRenameAgent != null)
          const PopupMenuItem<String>(
            value: 'rename',
            child: _MenuRow(icon: Icons.edit_rounded, label: 'Rename'),
          ),
        PopupMenuItem<String>(
          value: 'read',
          child: _MenuRow(
            icon: unread
                ? Icons.mark_chat_read_rounded
                : Icons.mark_chat_unread_rounded,
            label: unread ? 'Mark as read' : 'Already read',
          ),
        ),
        const PopupMenuItem<String>(
          value: 'hide',
          child: _MenuRow(
            icon: Icons.visibility_off_rounded,
            label: 'Hide from list',
          ),
        ),
        if (widget.onDeleteAgent != null)
          PopupMenuItem<String>(
            value: 'delete',
            child: _MenuRow(
              icon: Icons.delete_rounded,
              label: 'Delete coworker',
              color: scheme.error,
            ),
          ),
      ],
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'profile':
        widget.onOpenProfile?.call(agent);
      case 'rename':
        widget.onRenameAgent?.call(agent);
      case 'read':
        for (final CoworkThreadInfo thread in agent.threads) {
          await _marks.markRead(thread.key);
        }
      case 'hide':
        widget.source.hideAgent(agent.id);
      case 'delete':
        widget.onDeleteAgent?.call(agent);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[
        widget.source,
        _query,
        _marks,
        _profiles,
      ]),
      builder: (BuildContext context, Widget? _) => _buildList(context),
    );
  }

  Widget _buildList(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    final List<CoworkAgent> agents = _visible();
    final int unread = _marks.unreadCount(widget.source.visibleAgents);

    return CustomScrollView(
      slivers: <Widget>[
        SliverAppBar(
          pinned: true,
          backgroundColor: scheme.surface,
          automaticallyImplyLeading: false,
          titleSpacing: _searching ? 8 : 10,
          toolbarHeight: 58,
          leadingWidth: 56,
          leading: _searching
              ? Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: ExpressiveIconButton(
                      icon: Icons.arrow_back_rounded,
                      onTap: _closeSearch,
                      size: 40,
                      tooltip: 'Close search',
                      semanticsId: 'mobile_home_search_close',
                    ),
                  ),
                )
              : (widget.onOpenAccount == null
                    ? null
                    : Padding(
                        padding: const EdgeInsets.only(left: 16),
                        child: _AccountFace(
                          monogram: accountMonogram(widget.accountLabel),
                          onTap: widget.onOpenAccount!,
                        ),
                      )),
          title: _searching
              ? TextField(
                  controller: _query,
                  focusNode: _searchFocus,
                  textInputAction: TextInputAction.search,
                  cursorColor: scheme.primary,
                  style: text.titleLarge,
                  decoration: InputDecoration(
                    isCollapsed: true,
                    hintText: 'Search coworkers',
                    hintStyle: text.titleLarge?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                    border: InputBorder.none,
                  ),
                )
              : Text(
                  'Coworkers',
                  style: text.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                  ),
                ),
          actions: <Widget>[
            if (_searching)
              if (_query.text.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: IconButton(
                    icon: Icon(
                      Icons.close_rounded,
                      color: scheme.onSurfaceVariant,
                    ),
                    onPressed: () => setState(_query.clear),
                  ),
                )
              else
                const SizedBox.shrink()
            else ...<Widget>[
              ExpressiveIconButton(
                icon: Icons.search_rounded,
                onTap: _openSearch,
                size: 44,
                tooltip: 'Search',
                semanticsId: 'mobile_home_search',
              ),
              if (widget.onAddAgent != null) ...<Widget>[
                const SizedBox(width: 8),
                ExpressiveIconButton(
                  icon: Icons.add_rounded,
                  onTap: widget.onAddAgent,
                  size: 44,
                  color: scheme.primary,
                  onColor: scheme.onPrimary,
                  tooltip: 'Add a coworker',
                  semanticsId: 'mobile_home_add',
                ),
              ],
              const SizedBox(width: 12),
            ],
          ],
        ),

        const SliverToBoxAdapter(child: SizedBox(height: 6)),

        SliverToBoxAdapter(
          child: ConnectedGroup(
            labels: _filters,
            selected: _filter,
            badges: <int, int>{1: unread},
            onSelected: (int i) => setState(() {
              _reverse = i < _filter;
              _filter = i;
              _animate = true;
            }),
          ),
        ),

        const SliverToBoxAdapter(child: SizedBox(height: 12)),

        SliverFillRemaining(
          hasScrollBody: true,
          // The whole list moves as one: a later filter slides in from the
          // right, a earlier one from the left.
          child: PageTransitionSwitcher(
            duration: const Duration(milliseconds: 350),
            reverse: _reverse,
            transitionBuilder:
                (Widget child, Animation<double> primary, Animation<double> secondary) =>
                    SharedAxisTransition(
                      animation: primary,
                      secondaryAnimation: secondary,
                      transitionType: SharedAxisTransitionType.horizontal,
                      fillColor: Colors.transparent,
                      child: child,
                    ),
            child: KeyedSubtree(
              key: ValueKey<int>(_filter),
              child: agents.isEmpty
                  ? _EmptyState(
                      filter: _filters[_filter],
                      query: _query.text.trim(),
                      onAddAgent: widget.onAddAgent,
                    )
                  : ListView.builder(
                      padding: EdgeInsets.only(
                        bottom: MediaQuery.paddingOf(context).bottom + 24,
                      ),
                      itemCount: agents.length,
                      itemBuilder: (BuildContext context, int index) {
                        final CoworkAgent agent = agents[index];
                        final Widget row = MobileAgentRow(
                          key: ValueKey<String>('mobile-agent-${agent.id}'),
                          agent: agent,
                          selected: agent.id == widget.selectedAgentId,
                          unread: _marks.isUnread(agent),
                          role: _roleOf(agent),
                          now: _now(),
                          profiles: _profiles,
                          onTap: agent.threads.isEmpty
                              ? null
                              : () => widget.onSelect(
                                  agent.id,
                                  agent.threads.first.key,
                                ),
                          onLongPress: (BuildContext rowContext) =>
                              _openRowMenu(rowContext, agent),
                        );
                        if (_searching || !_animate) return row;
                        return StaggeredItem(
                          key: ValueKey<String>('stagger-${agent.id}'),
                          index: index,
                          child: row,
                        );
                      },
                    ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The account face: the user's monogram in a blob, top left of the title bar.
class _AccountFace extends StatelessWidget {
  const _AccountFace({required this.monogram, required this.onTap});

  final String monogram;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Semantics(
      identifier: 'mobile_home_account',
      button: true,
      label: 'Account',
      child: Tooltip(
        message: 'Account',
        child: MorphTap(
          onTap: onTap,
          color: scheme.primaryContainer,
          shape: const CircleBorder(),
          pressedShape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: EdgeInsets.zero,
          child: SizedBox.square(
            dimension: 38,
            child: Center(
              child: monogram.isEmpty
                  ? Icon(
                      Icons.person_rounded,
                      size: 20,
                      color: scheme.onPrimaryContainer,
                    )
                  : Text(
                      monogram,
                      style: TextStyle(
                        color: scheme.onPrimaryContainer,
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One inbox row: blob face with the presence dot, name, role tag, time,
/// preview line, unread dot.
class MobileAgentRow extends StatelessWidget {
  const MobileAgentRow({
    super.key,
    required this.agent,
    required this.now,
    this.selected = false,
    this.unread = false,
    this.role,
    this.onTap,
    this.onLongPress,
    this.profiles,
  });

  final CoworkAgent agent;
  final DateTime now;
  final bool selected;
  final bool unread;

  /// The role line to show; null hides the tag.
  final String? role;

  final VoidCallback? onTap;

  /// Long press, with the row's own context so a menu can anchor to it.
  final void Function(BuildContext rowContext)? onLongPress;

  final AgentProfileStore? profiles;

  /// Rows keep the old height so the list rhythm does not change.
  static const double height = 72;

  /// The preview line under the name. What the coworker is doing now beats a
  /// stale thread title; a thread title beats the brief; the brief beats
  /// silence.
  static String previewOf(CoworkAgent agent, {AgentProfileStore? profiles}) {
    if (agent.running) return 'Working…';
    for (final CoworkThreadInfo thread in agent.threads) {
      final String title = thread.title.trim();
      if (title.isNotEmpty && title != 'default' && title != 'General') {
        return title;
      }
    }
    final String stored =
        (profiles ?? AgentProfileStore.instance)
            .profileOf(agent.id)
            .brief
            ?.trim() ??
        '';
    if (stored.isNotEmpty) return stored;
    final String brief = agent.brief?.trim() ?? '';
    if (brief.isNotEmpty) return brief;
    return 'No activity yet';
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    final Color accent = agentAccent(context, agent.id, store: profiles);
    final String time = mobileTimeLabel(agent.lastActivity, now: now);

    return Semantics(
      identifier: 'mobile-agent-row-${agent.id}',
      button: onTap != null,
      selected: selected,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
        child: Builder(
          builder: (BuildContext rowContext) => MorphTap(
            onTap: onTap,
            onLongPress: onLongPress == null
                ? null
                : () => onLongPress!(rowContext),
            color: unread
                ? accent.withValues(alpha: 0.13)
                : selected
                ? scheme.primary.withValues(alpha: 0.08)
                : Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(30),
            ),
            pressedShape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: height - 4),
              child: Row(
                children: <Widget>[
                  AgentFace(agent: agent, size: 52, store: profiles),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Flexible(
                              child: Text(
                                agent.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: text.titleMedium?.copyWith(
                                  fontWeight: unread
                                      ? FontWeight.w800
                                      : FontWeight.w600,
                                ),
                              ),
                            ),
                            if (role != null && role!.isNotEmpty) ...<Widget>[
                              const SizedBox(width: 8),
                              _RoleTag(role: role!),
                            ],
                            const Spacer(),
                            if (time.isNotEmpty)
                              Text(
                                time,
                                style: text.labelMedium?.copyWith(
                                  color: unread
                                      ? accent
                                      : scheme.onSurfaceVariant,
                                  fontWeight: unread
                                      ? FontWeight.w800
                                      : FontWeight.w500,
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: <Widget>[
                            Expanded(
                              child: Text(
                                previewOf(agent, profiles: profiles),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: text.bodyMedium?.copyWith(
                                  color: unread
                                      ? scheme.onSurface
                                      : scheme.onSurfaceVariant,
                                  fontWeight: unread
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                ),
                              ),
                            ),
                            if (unread)
                              Container(
                                margin: const EdgeInsets.only(left: 8),
                                width: 11,
                                height: 11,
                                decoration: BoxDecoration(
                                  color: accent,
                                  shape: BoxShape.circle,
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The small grey tag next to the name (the coworker's role).
class _RoleTag extends StatelessWidget {
  const _RoleTag({required this.role});

  final String role;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 110),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(9),
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
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.icon, required this.label, this.color});

  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final Color c = color ?? Theme.of(context).colorScheme.onSurface;
    return Row(
      children: <Widget>[
        Icon(icon, size: 19, color: c),
        const SizedBox(width: 12),
        Text(
          label,
          style: TextStyle(color: c, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.filter,
    required this.query,
    this.onAddAgent,
  });

  final String filter;
  final String query;
  final VoidCallback? onAddAgent;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    final bool searching = query.isNotEmpty;
    final bool filtering = filter == 'Unread';
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 104,
            height: 104,
            decoration: ShapeDecoration(
              color: scheme.primaryContainer,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(42),
              ),
            ),
            child: Icon(
              searching
                  ? Icons.search_off_rounded
                  : filtering
                  ? Icons.mark_chat_read_rounded
                  : Icons.groups_rounded,
              size: 48,
              color: scheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            searching
                ? 'No agent matches.'
                : filtering
                ? 'Nothing unread.'
                : 'No agents yet.',
            style: text.titleLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          Text(
            searching ? 'for "$query"' : 'Your coworkers show up here',
            style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
          if (!searching && !filtering && onAddAgent != null) ...<Widget>[
            const SizedBox(height: 18),
            FilledButton(
              onPressed: onAddAgent,
              child: const Text('Add an agent'),
            ),
          ],
        ],
      ),
    );
  }
}

/// The time column of an inbox row, like a messenger: a clock time today,
/// "Yesterday", the weekday inside a week, a short date after that. Empty when
/// nothing has happened.
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
