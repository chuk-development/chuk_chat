/// The quick switcher (Ctrl+K): one field, the agents and rooms under it,
/// type to filter, arrows to move, Enter to open.
///
/// chuk_chat has no switcher, so it is put together from chuk's pieces: the
/// app's dialog surface, the sidebar's search field, and rows that light up
/// in the fill a selected sidebar card takes.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/models/agents_room.dart';
import 'package:chuk_chat/services/agents/agent_profile_store.dart';
import 'package:chuk_chat/services/agents/agent_read_marks.dart';
import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/ui/expressive/agent_face.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/agents_desktop/desktop_metrics.dart';
import 'package:chuk_chat/widgets/room_faces.dart';
import 'package:chuk_chat/widgets/sidebar/sidebar_chrome.dart';

/// What the user picked.
sealed class QuickSwitcherPick {
  const QuickSwitcherPick();
}

class QuickSwitcherAgent extends QuickSwitcherPick {
  const QuickSwitcherAgent(this.agent);
  final AgentsAgent agent;
}

class QuickSwitcherRoom extends QuickSwitcherPick {
  const QuickSwitcherRoom(this.room);
  final AgentsRoom room;
}

/// Opens the switcher near the top of the window. Returns the pick, or null
/// when the user closed it (Esc, a click outside).
Future<QuickSwitcherPick?> showQuickSwitcher(
  BuildContext context, {
  required List<AgentsAgent> agents,
  required List<AgentsRoom> rooms,
  AgentProfileStore? profiles,
  AgentReadMarks? readMarks,
}) => showDialog<QuickSwitcherPick>(
  context: context,
  barrierColor: Colors.black.withValues(alpha: 0.32),
  builder: (_) => QuickSwitcher(
    agents: agents,
    rooms: rooms,
    profiles: profiles,
    readMarks: readMarks,
  ),
);

class QuickSwitcher extends StatefulWidget {
  const QuickSwitcher({
    super.key,
    required this.agents,
    required this.rooms,
    this.profiles,
    this.readMarks,
  });

  final List<AgentsAgent> agents;
  final List<AgentsRoom> rooms;
  final AgentProfileStore? profiles;
  final AgentReadMarks? readMarks;

  @override
  State<QuickSwitcher> createState() => _QuickSwitcherState();
}

class _QuickSwitcherState extends State<QuickSwitcher> {
  final TextEditingController _query = TextEditingController();
  final FocusNode _queryFocus = FocusNode(debugLabel: 'quick-switcher-field');
  final ScrollController _scroll = ScrollController();
  int _index = 0;

  static const double _rowHeight = 40;

  /// The face in a row.
  static const double _faceSize = 26;

  @override
  void initState() {
    super.initState();
    _query.addListener(() => setState(() => _index = 0));
  }

  @override
  void dispose() {
    _query.dispose();
    _queryFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Matches first by a name that starts with the query, then by one that
  /// contains it, agents before rooms within each group.
  List<QuickSwitcherPick> get _matches {
    final String q = _query.text.trim().toLowerCase();
    if (q.isEmpty) {
      return <QuickSwitcherPick>[
        for (final AgentsAgent a in widget.agents) QuickSwitcherAgent(a),
        for (final AgentsRoom r in widget.rooms) QuickSwitcherRoom(r),
      ];
    }
    final List<QuickSwitcherPick> starts = <QuickSwitcherPick>[];
    final List<QuickSwitcherPick> contains = <QuickSwitcherPick>[];
    void sort(String name, QuickSwitcherPick pick) {
      final String n = name.toLowerCase();
      if (n.startsWith(q)) {
        starts.add(pick);
      } else if (n.contains(q)) {
        contains.add(pick);
      }
    }

    for (final AgentsAgent a in widget.agents) {
      sort(a.name, QuickSwitcherAgent(a));
    }
    for (final AgentsRoom r in widget.rooms) {
      sort(r.name, QuickSwitcherRoom(r));
    }
    return <QuickSwitcherPick>[...starts, ...contains];
  }

  void _move(int delta, int count) {
    if (count == 0) return;
    setState(() => _index = (_index + delta) % count);
    if (_index < 0) _index += count;
    // Keep the highlighted row in view.
    if (_scroll.hasClients) {
      final double top = _index * _rowHeight;
      final double bottom = top + _rowHeight;
      final double viewTop = _scroll.offset;
      final double viewBottom = viewTop + _scroll.position.viewportDimension;
      if (top < viewTop) _scroll.jumpTo(top);
      if (bottom > viewBottom) {
        _scroll.jumpTo(bottom - _scroll.position.viewportDimension);
      }
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event, int count) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _move(1, count);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _move(-1, count);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _open(QuickSwitcherPick pick) => Navigator.of(context).pop(pick);

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final DialogThemeData dialog = DialogTheme.of(context);
    final Color muted = theme.m3.onSurfaceVariant;
    final List<QuickSwitcherPick> matches = _matches;
    final int index = matches.isEmpty ? 0 : _index.clamp(0, matches.length - 1);
    return Align(
      alignment: const Alignment(0, -0.55),
      child: Padding(
        padding: const EdgeInsets.all(24),
        // The app's dialog surface: the same fill, corner and lift an
        // AlertDialog takes.
        child: Material(
          color: dialog.backgroundColor ?? theme.m3.surfaceContainerHigh,
          elevation: dialog.elevation ?? 3,
          shape:
              dialog.shape ??
              RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(kRadiusDialog),
              ),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: kDeskDialogMaxWidth,
              maxHeight: 440,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                  child: Focus(
                    canRequestFocus: false,
                    skipTraversal: true,
                    onKeyEvent: (FocusNode node, KeyEvent event) =>
                        _onKey(node, event, matches.length),
                    // The sidebar's search field.
                    child: SbSearchField(
                      key: const ValueKey<String>('quick-switcher-field'),
                      controller: _query,
                      focusNode: _queryFocus,
                      autofocus: true,
                      hintText: 'Jump to an agent or a room',
                      onClear: _query.clear,
                      onSubmitted: (_) {
                        if (matches.isNotEmpty) _open(matches[index]);
                      },
                    ),
                  ),
                ),
                Flexible(
                  child: matches.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                          child: Text(
                            'Nothing matches.',
                            style: TextStyle(color: muted, fontSize: 14),
                          ),
                        )
                      : ListView.builder(
                          controller: _scroll,
                          shrinkWrap: true,
                          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                          itemCount: matches.length,
                          itemExtent: _rowHeight,
                          itemBuilder: (BuildContext context, int i) =>
                              _row(context, matches[i], i == index, i),
                        ),
                ),
                const SbHairline(),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: Text(
                    '↑↓ to move · Enter to open · Esc to close',
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(
    BuildContext context,
    QuickSwitcherPick pick,
    bool highlighted,
    int i,
  ) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    // The fill a selected sidebar card takes ([SbCard]).
    final Color lit = Color.alphaBlend(
      scheme.primary.withValues(alpha: 0.20),
      theme.m3.surfaceContainer,
    );
    final Color rest =
        DialogTheme.of(context).backgroundColor ??
        theme.m3.surfaceContainerHigh;
    final (Widget face, String name, String kind, bool unread) = switch (pick) {
      QuickSwitcherAgent(:final AgentsAgent agent) => (
        AgentFace(agent: agent, size: _faceSize, store: widget.profiles),
        agent.name,
        'Agent',
        (widget.readMarks ?? AgentReadMarks.instance).isUnread(agent),
      ),
      QuickSwitcherRoom(:final AgentsRoom room) => (
        RoomFaces(
          members: room.members,
          size: _faceSize,
          store: widget.profiles,
          ringColor: highlighted ? lit : rest,
        ),
        room.name,
        'Room',
        false,
      ),
    };
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onHover: (_) {
        if (_index != i) setState(() => _index = i);
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _open(pick),
        child: Container(
          key: ValueKey<String>('quick-switcher-row-$i'),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: highlighted ? lit : null,
            borderRadius: BorderRadius.circular(kSbCardJointRadius * 2),
          ),
          child: Row(
            children: <Widget>[
              SizedBox(width: _faceSize, height: _faceSize, child: face),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  // The sidebar tile's title: primary while it is the one.
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: unread || highlighted
                        ? FontWeight.w700
                        : FontWeight.w500,
                    color: highlighted ? scheme.primary : scheme.onSurface,
                  ),
                ),
              ),
              Text(
                kind,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.m3.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
