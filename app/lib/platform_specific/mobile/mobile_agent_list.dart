/// The phone home screen: the coworkers, as a messenger inbox in the expressive
/// design language.
///
/// The shape is the one the reference messenger uses for its chat list, and the
/// content is CoWork's own roster ([AgentRosterSource]):
///
///  * one header row — the search target on the left, the connected filter
///    group All / Unread in the middle with the unread count on its second
///    segment ([AgentReadMarks] answers what is unread), the accent "+" on the
///    right; the search fades that whole row through into a rounded field that
///    carries its own glyph and its own clear target;
///  * one row per coworker: its blob face with the presence dot, the name, the
///    role tag, the time of the last activity, one line of preview, and an
///    unread dot. The row springs and morphs on press, and the list cascades in.
///
/// What the messenger has and this does NOT: no pinned/archived/starred buckets,
/// no groups filter, no message-body search. The roster has no such data, and a
/// filter that can never match is worse than no filter.
library;

import 'package:animations/animations.dart';
import 'dart:async';

import 'package:flutter/material.dart';

import 'package:cowork/platform_specific/mobile/mobile_container_transform.dart';
import 'package:cowork/ui/expressive/icon_map.dart';

import 'package:cowork/models/cowork_agent.dart';
import 'package:cowork/services/cowork/agent_profile_store.dart';
import 'package:cowork/services/cowork/agent_read_marks.dart';
import 'package:cowork/services/cowork/thread_preview_store.dart';
import 'package:cowork/services/cowork/agent_roster_source.dart';
import 'package:cowork/ui/expressive/agent_face.dart';
import 'package:cowork/ui/expressive/connected_group.dart';
import 'package:cowork/ui/expressive/huge_icon.dart';
import 'package:cowork/ui/expressive/motion.dart';
import 'package:cowork/ui/expressive/top_veil.dart';
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

/// The height every control in the home header row takes: the search target,
/// the All/Unread switch, the "+", and the search field that replaces the
/// first two. One number, because a row of controls that do not agree on their
/// height reads as three controls borrowed from three screens.
const double kHomeBarHeight = 52;

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
    this.onOpenFrom,
    this.hiddenAgentId,
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

  /// Where the tapped row is, and a copy of it — everything the chat-open
  /// container transform needs to grow out of that row
  /// (`mobile_container_transform.dart`). Called just before [onSelect]. Null
  /// where the list is only a picker and nothing grows out of it.
  final void Function(ContainerTransformSource source)? onOpenFrom;

  /// The coworker whose row is currently inside the growing container. Its row
  /// keeps its space in the list but is not drawn, so the copy in the container
  /// is the only one on screen — the package's `_Hideable`.
  final String? hiddenAgentId;

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
        ThreadPreviewStore.instance,
      ]),
      builder: (BuildContext context, Widget? _) => _buildList(context),
    );
  }

  Widget _buildList(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final List<CoworkAgent> agents = _visible();
    // Threads this device already holds but has not previewed yet (a restart,
    // a fresh install that synced). Reads once per thread, then never again.
    unawaited(
      ThreadPreviewStore.instance.ensureFor(<String>[
        for (final CoworkAgent agent in agents)
          for (final CoworkThreadInfo thread in agent.threads) thread.key,
      ]),
    );
    final int unread = _marks.unreadCount(widget.source.visibleAgents);

    // The roster floats over its own list: the rows travel up behind the
    // header and fade out in the veil, the same way the chat does. A pinned
    // SliverAppBar could not do this — the list inside it is its own scroller,
    // so nothing ever passed under the bar.
    // The two faces of the same row. They do not swap hard: one fades through
    // the other, so opening the search reads as the row changing its mind and
    // not as a screen replacing another.
    // The home bar, left to right: the search target, the All/Unread switch,
    // the accent "+". The page headline is gone — the switch says what the
    // list under it is showing, and a headline that repeated the app's own
    // name said nothing the roster did not already say.
    final Widget titleRow = Row(
      key: const ValueKey<bool>(false),
      children: <Widget>[
        ExpressiveIconButton(
          hugeIcon: HugeIcons.search01,
          onTap: _openSearch,
          size: kHomeBarHeight,
          color: scheme.surfaceContainerHighest,
          tooltip: 'Search coworkers',
          semanticsId: 'mobile_home_search',
        ),
        const SizedBox(width: 10),
        // The switch takes the middle and the whole width left between the
        // two targets, so it is the thing the eye lands on first.
        Expanded(
          child: ConnectedGroup(
            labels: _filters,
            selected: _filter,
            badges: <int, int>{1: unread},
            margin: EdgeInsets.zero,
            height: kHomeBarHeight,
            onSelected: (int i) => setState(() {
              _reverse = i < _filter;
              _filter = i;
              _animate = true;
            }),
          ),
        ),
        const SizedBox(width: 10),
        if (widget.onAddAgent != null)
          ExpressiveIconButton(
            hugeIcon: HugeIcons.plusSign,
            onTap: widget.onAddAgent,
            size: kHomeBarHeight,
            color: scheme.primary,
            onColor: scheme.onPrimary,
            tooltip: 'Add a coworker',
            semanticsId: 'mobile_home_add',
          ),
      ],
    );

    final Widget searchRow = Row(
      key: const ValueKey<bool>(true),
      children: <Widget>[
        // Only the search back target lives on the left. The account used to
        // sit here and opened settings — the navigation bar has that now, and
        // one way in is enough.
        ExpressiveIconButton(
          hugeIcon: HugeIcons.arrowLeft02,
          onTap: _closeSearch,
          size: kHomeBarHeight,
          tooltip: 'Close search',
          semanticsId: 'mobile_home_search_close',
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _SearchField(
            controller: _query,
            focusNode: _searchFocus,
            onClear: () => setState(_query.clear),
          ),
        ),
      ],
    );

    final Widget header = Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: SizedBox(
        height: 58,
        child: PageTransitionSwitcher(
          duration: const Duration(milliseconds: 280),
          transitionBuilder:
              (
                Widget child,
                Animation<double> primary,
                Animation<double> secondary,
              ) => FadeThroughTransition(
                animation: primary,
                secondaryAnimation: secondary,
                fillColor: Colors.transparent,
                child: child,
              ),
          child: _searching ? searchRow : titleRow,
        ),
      ),
    );

    // Status bar + the header row: what the list has to clear before its
    // first row is readable. The switch rides inside that row now, so there is
    // no second row to make room for.
    final double headerSpace = MediaQuery.paddingOf(context).top + 58 + 12;

    return Stack(
      children: <Widget>[
        Positioned.fill(
          // The whole list moves as one: a later filter slides in from the
          // right, a earlier one from the left.
          child: PageTransitionSwitcher(
            duration: const Duration(milliseconds: 350),
            reverse: _reverse,
            transitionBuilder:
                (
                  Widget child,
                  Animation<double> primary,
                  Animation<double> secondary,
                ) => SharedAxisTransition(
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
                        top: headerSpace,
                        bottom: MediaQuery.paddingOf(context).bottom + 24,
                      ),
                      itemCount: agents.length,
                      itemBuilder: (BuildContext context, int index) {
                        final CoworkAgent agent = agents[index];
                        // One description, built twice: the row in the list,
                        // and — when the chat grows out of it — the copy that
                        // rides inside the container while this one is hidden.
                        MobileAgentRow buildRow({required bool padded}) =>
                            MobileAgentRow(
                              key: padded
                                  ? ValueKey<String>('mobile-agent-${agent.id}')
                                  : null,
                              agent: agent,
                              selected: agent.id == widget.selectedAgentId,
                              unread: _marks.isUnread(agent),
                              unreadThreads: _marks.unreadThreads(agent),
                              role: _roleOf(agent),
                              now: _now(),
                              profiles: _profiles,
                              padded: padded,
                              onTap: !padded || agent.threads.isEmpty
                                  ? null
                                  : (Rect rect) {
                                      widget.onOpenFrom?.call(
                                        ContainerTransformSource(
                                          rect: rect,
                                          child: buildRow(padded: false),
                                        ),
                                      );
                                      widget.onSelect(
                                        agent.id,
                                        agent.threads.first.key,
                                      );
                                    },
                              onLongPress: !padded
                                  ? null
                                  : (BuildContext rowContext) =>
                                        _openRowMenu(rowContext, agent),
                            );
                        final Widget row = Visibility(
                          // Hidden, not removed: the list must not reflow
                          // under the growing container.
                          visible: agent.id != widget.hiddenAgentId,
                          maintainSize: true,
                          maintainAnimation: true,
                          maintainState: true,
                          child: buildRow(padded: true),
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
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: TopVeil(
            fadeBelow: 14,
            child: header,
          ),
        ),
      ],
    );
  }
}

/// The roster's search input: one rounded, filled field that carries its own
/// glyph and its own clear target.
///
/// It is a field and it looks like one. A bare [TextField] on the header's
/// background had no shape at all, so the row simply lost its title and gained
/// a caret. It takes [kHomeBarHeight], the height of the switch it replaces
/// and of the target beside it, and its corner is that switch's corner — a
/// field that grew taller than the button next to it was the one thing in the
/// row that looked borrowed from another screen.
class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.focusNode,
    required this.onClear,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    final bool hasText = controller.text.isNotEmpty;
    return Container(
      height: kHomeBarHeight,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(kHomeBarHeight / 2),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 7, 0),
        child: Row(
          children: <Widget>[
            HugeIcon(
              HugeIcons.search01,
              size: 20,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                textInputAction: TextInputAction.search,
                cursorColor: scheme.primary,
                style: text.titleMedium,
                decoration: InputDecoration(
                  isCollapsed: true,
                  // The field's height comes from the box around it now, so
                  // the input takes only the room its own line needs.
                  contentPadding: EdgeInsets.zero,
                  hintText: 'Search coworkers',
                  hintStyle: text.titleMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w500,
                  ),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  filled: false,
                ),
              ),
            ),
            // The clear target appears only when there is something to clear,
            // and it grows in rather than popping into the field.
            AnimatedSwitcher(
              duration: kExpressiveShort,
              switchInCurve: kExpressiveDecelerate,
              transitionBuilder: (Widget child, Animation<double> t) =>
                  ScaleTransition(
                    scale: t,
                    child: FadeTransition(opacity: t, child: child),
                  ),
              child: hasText
                  ? ExpressiveIconButton(
                      key: const ValueKey<bool>(true),
                      hugeIcon: HugeIcons.cancel01,
                      onTap: onClear,
                      size: 40,
                      color: scheme.surfaceContainerHigh,
                      tooltip: 'Clear',
                      semanticsId: 'mobile_home_search_clear',
                    )
                  : const SizedBox(
                      key: ValueKey<bool>(false),
                      width: 8,
                      height: 40,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class MobileAgentRow extends StatelessWidget {
  const MobileAgentRow({
    super.key,
    required this.agent,
    required this.now,
    this.selected = false,
    this.unread = false,
    this.unreadThreads = 1,
    this.role,
    this.onTap,
    this.onLongPress,
    this.profiles,
    this.padded = true,
  });

  final CoworkAgent agent;
  final DateTime now;
  final bool selected;
  final bool unread;

  /// How many of this coworker's threads have something new in them. Shown as
  /// the number on the badge.
  final int unreadThreads;

  /// The role line to show; null hides the tag.
  final String? role;

  /// Opens the coworker's thread. It is handed the row's own rounded rect, in
  /// global coordinates: the chat grows out of exactly that rect
  /// (`mobile_container_transform.dart`).
  final void Function(Rect globalRect)? onTap;

  /// Long press, with the row's own context so a menu can anchor to it.
  final void Function(BuildContext rowContext)? onLongPress;

  final AgentProfileStore? profiles;

  /// False builds the row without the list's outer padding, so it fills the
  /// rect [onTap] reported. That is the copy the container transform draws.
  final bool padded;

  /// One row's minimum height. Tight enough that a screen holds the roster,
  /// loose enough for a 52 px face plus two lines of text.
  static const double height = 64;

  /// The preview line under the name. What the coworker is doing now beats a
  /// stale thread title; a thread title beats the brief; the brief beats
  /// silence.
  static String previewOf(CoworkAgent agent, {AgentProfileStore? profiles}) {
    if (agent.running) return 'Working…';
    // What was actually said last, whoever said it. This is the line a roster
    // is read for; a thread title is what it falls back to.
    final ThreadPreview? preview = ThreadPreviewStore.instance.newestOf(
      agent.threads.map((CoworkThreadInfo thread) => thread.key),
    );
    if (preview != null && preview.text.isNotEmpty) {
      return preview.fromUser ? 'You: ${preview.text}' : preview.text;
    }
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
    // Nothing to say beats saying "No activity yet" on every row of a fresh
    // install: the line is for what happened, and an empty line reads as
    // "nothing yet" without spelling it out. The real last message lands here
    // with the preview cache (bead: thread preview store).
    return '';
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
        padding: padded
            ? const EdgeInsets.symmetric(horizontal: 12, vertical: 1)
            : EdgeInsets.zero,
        child: Builder(
          builder: (BuildContext rowContext) => MorphTap(
            onTap: onTap == null
                ? null
                : () {
                    // The box under this Builder is the MorphTap's own: the
                    // rounded rect the user actually tapped, without the
                    // list's padding around it.
                    final RenderObject? box = rowContext.findRenderObject();
                    if (box is! RenderBox || !box.hasSize) return;
                    onTap!(box.localToGlobal(Offset.zero) & box.size);
                  },
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
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: height - 4),
              child: Row(
                children: <Widget>[
                  AgentFace(agent: agent, size: 48, store: profiles),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            // Expanded, not Flexible: the name takes the room
                            // the tag and the time leave, instead of shrinking
                            // to its own width and ellipsising early.
                            Expanded(
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
                            if (time.isNotEmpty) ...<Widget>[
                              const SizedBox(width: 8),
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
                          ],
                        ),
                        const SizedBox(height: 2),
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
                              Padding(
                                padding: const EdgeInsets.only(left: 8),
                                child: _UnreadBadge(
                                  count: unreadThreads,
                                  colour: accent,
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
        AppIcon(icon, size: 19, color: c),
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
            child: AppIcon(
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

/// The number of new threads on a coworker, in that coworker's colour.
///
/// A bare dot said "something happened" and nothing more; the roster is read at
/// a glance and the glance should carry the amount.
class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge({required this.count, required this.colour});

  final int count;
  final Color colour;

  @override
  Widget build(BuildContext context) {
    final String label = count > 99 ? '99+' : '${count < 1 ? 1 : count}';
    return Container(
      constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      alignment: Alignment.center,
      decoration: BoxDecoration(color: colour, shape: BoxShape.circle),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: ThemeData.estimateBrightnessForColor(colour) == Brightness.dark
              ? Colors.white
              : Colors.black,
        ),
      ),
    );
  }
}
