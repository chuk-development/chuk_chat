/// The `@mention` autocomplete of the group-room composer (§16.1).
///
/// The manager already routes a turn by the `@handle` it finds in the message
/// (`parse_mentions` in `group_room.py`), so the app's job is only to stop the
/// user from having to remember a handle: while the caret sits inside an
/// `@token`, the room's members are offered above the composer and picking one
/// writes the handle into the text.
///
/// The two things that are easy to get wrong — which token the caret is in, and
/// what the text looks like afterwards — are plain functions here
/// ([activeMentionToken], [applyMention], [filterMentions]). They take a string
/// and an offset and return a value, so the awkward cases (an email address, an
/// `@` inside a word, a token mid-sentence) are tested without pumping a widget.
library;

import 'package:flutter/material.dart';

import 'package:chuk_chat/ui/expressive/agent_face.dart';
import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/models/agents_room.dart';
import 'package:chuk_chat/widgets/menu_tile_group.dart';

/// The handle `@all` is written as. The manager reads `@all`, `@everyone` and
/// `@room` alike (`BROADCAST_HANDLES`); the picker writes the shortest one.
const String kBroadcastHandle = 'all';

/// The other spellings the manager accepts. Typing any prefix of one of them
/// finds the broadcast row, but what lands in the text is [kBroadcastHandle].
const List<String> kBroadcastAliases = <String>['all', 'everyone', 'room'];

/// A character that may sit inside a handle. Mirrors the manager's `_MENTION`
/// (`@[A-Za-z0-9][A-Za-z0-9-]*`), minus the first-character rule: a token that
/// is still being typed may be empty.
bool _isHandleChar(int code) =>
    (code >= 0x30 && code <= 0x39) || // 0-9
    (code >= 0x41 && code <= 0x5A) || // A-Z
    (code >= 0x61 && code <= 0x7A) || // a-z
    code == 0x2D; // -

bool _isSpace(int code) =>
    code == 0x20 || code == 0x09 || code == 0x0A || code == 0x0D;

/// The `@token` the caret is inside, as a range over the text.
@immutable
class MentionToken {
  const MentionToken({
    required this.start,
    required this.end,
    required this.query,
  });

  /// Offset of the `@` itself.
  final int start;

  /// Offset just past the last handle character.
  final int end;

  /// What was typed after the `@` — empty right after the `@` was typed, which
  /// is the "show me everyone" case.
  final String query;

  @override
  bool operator ==(Object other) =>
      other is MentionToken &&
      other.start == start &&
      other.end == end &&
      other.query == query;

  @override
  int get hashCode => Object.hash(start, end, query);

  @override
  String toString() => 'MentionToken($start..$end, "$query")';
}

/// The `@token` [caret] sits in, or null when it sits nowhere near one.
///
/// A token starts at an `@` that is either the first character or follows
/// whitespace — so `foo@bar` and `a@example.com` are not mentions, exactly as
/// the manager reads them. The caret must be after that `@` and no further than
/// the end of the run of handle characters.
MentionToken? activeMentionToken(String text, int caret) {
  if (caret < 0 || caret > text.length) return null;
  int i = caret;
  // Walk back over the handle characters to the '@'.
  while (i > 0) {
    final int code = text.codeUnitAt(i - 1);
    if (code == 0x40) {
      i -= 1;
      break;
    }
    if (!_isHandleChar(code)) return null;
    i -= 1;
  }
  if (i >= text.length || text.codeUnitAt(i) != 0x40) return null;
  final int start = i;
  // The '@' has to open a word, or it is an address, not a mention.
  if (start > 0 && !_isSpace(text.codeUnitAt(start - 1))) return null;
  int end = start + 1;
  while (end < text.length && _isHandleChar(text.codeUnitAt(end))) {
    end += 1;
  }
  if (caret <= start || caret > end) return null;
  return MentionToken(
    start: start,
    end: end,
    query: text.substring(start + 1, end),
  );
}

/// The text and caret after a pick.
@immutable
class MentionEdit {
  const MentionEdit({required this.text, required this.caret});

  final String text;
  final int caret;

  @override
  bool operator ==(Object other) =>
      other is MentionEdit && other.text == text && other.caret == caret;

  @override
  int get hashCode => Object.hash(text, caret);

  @override
  String toString() => 'MentionEdit("$text", $caret)';
}

/// Replace [token] with `@handle ` and say where the caret goes.
///
/// The trailing space is what closes the token, so the picker does not reopen
/// on the handle that was just chosen. When the text already has a space there
/// — the token sat mid-sentence — no second one is added and the caret hops
/// over the existing one.
MentionEdit applyMention({
  required String text,
  required MentionToken token,
  required String handle,
}) {
  final String rest = text.substring(token.end);
  final bool needsSpace = !rest.startsWith(' ');
  final String insert = '@$handle${needsSpace ? ' ' : ''}';
  return MentionEdit(
    text: text.substring(0, token.start) + insert + rest,
    caret: token.start + insert.length + (needsSpace ? 0 : 1),
  );
}

/// One row of the picker: a member of the room, or the broadcast row.
@immutable
class MentionEntry {
  const MentionEntry({
    required this.handle,
    required this.label,
    this.agentId,
    this.role,
    this.trailing,
    this.aliases = const <String>[],
    this.broadcast = false,
  });

  /// What is written into the composer, without the `@`.
  final String handle;

  /// The display name.
  final String label;

  /// The agent this row stands for, for the face. Null on the broadcast row,
  /// which has no face.
  final String? agentId;

  /// The role the user gave the coworker, when it has one.
  final String? role;

  /// A quiet line on the right for a row with no role — the member count on the
  /// broadcast row.
  final String? trailing;

  /// Other spellings that find this row (the manager's `@everyone` / `@room`).
  final List<String> aliases;

  /// True for `@all`: it sorts to the top and draws no face.
  final bool broadcast;
}

/// The room's members as picker rows, with `@all` first.
///
/// [agents] only supplies the display name and the role; a member with no agent
/// in the list still gets a row, labelled by its handle. Room order is kept.
List<MentionEntry> mentionEntriesFor({
  required List<AgentsRoomMember> members,
  List<AgentsAgent> agents = const <AgentsAgent>[],
}) {
  if (members.isEmpty) return const <MentionEntry>[];
  final Map<String, AgentsAgent> byId = <String, AgentsAgent>{
    for (final AgentsAgent a in agents) a.id: a,
  };
  return <MentionEntry>[
    MentionEntry(
      handle: kBroadcastHandle,
      label: 'Everyone',
      trailing: members.length == 1
          ? '1 coworker'
          : '${members.length} coworkers',
      aliases: kBroadcastAliases,
      broadcast: true,
    ),
    for (final AgentsRoomMember m in members)
      MentionEntry(
        handle: m.handle,
        label: byId[m.agentId]?.name ?? m.handle,
        agentId: m.agentId,
        role: byId[m.agentId]?.role,
      ),
  ];
}

bool _prefix(String value, String query) =>
    value.toLowerCase().startsWith(query);

/// The rows that match what is typed: the broadcast row first, then the ones
/// whose handle starts with [query], then the ones whose name does. Room order
/// is kept inside each group, and an empty query lists everything.
List<MentionEntry> filterMentions(List<MentionEntry> entries, String query) {
  final String q = query.toLowerCase();
  final List<MentionEntry> broadcast = <MentionEntry>[];
  final List<MentionEntry> byHandle = <MentionEntry>[];
  final List<MentionEntry> byName = <MentionEntry>[];
  for (final MentionEntry e in entries) {
    final bool handleHit =
        _prefix(e.handle, q) || e.aliases.any((String a) => _prefix(a, q));
    if (e.broadcast) {
      if (handleHit || _prefix(e.label, q)) broadcast.add(e);
      continue;
    }
    if (handleHit) {
      byHandle.add(e);
    } else if (_prefix(e.label, q)) {
      byName.add(e);
    }
  }
  return <MentionEntry>[...broadcast, ...byHandle, ...byName];
}

/// The list that floats over the composer while a token is open.
///
/// It draws on the app's one menu surface ([MenuTileGroup], §6 of the design):
/// a filled tile per row, big corners at the ends of the run and small ones
/// where two rows meet. The highlighted row is the one Enter accepts.
class RoomMentionPicker extends StatefulWidget {
  const RoomMentionPicker({
    super.key,
    required this.entries,
    required this.selected,
    required this.onPick,
    this.maxHeight = 248,
  });

  final List<MentionEntry> entries;

  /// Index of the highlighted row.
  final int selected;

  final void Function(MentionEntry entry) onPick;

  final double maxHeight;

  @override
  State<RoomMentionPicker> createState() => _RoomMentionPickerState();
}

class _RoomMentionPickerState extends State<RoomMentionPicker> {
  final ScrollController _scroll = ScrollController();
  final Map<int, GlobalKey> _rowKeys = <int, GlobalKey>{};

  @override
  void didUpdateWidget(RoomMentionPicker old) {
    super.didUpdateWidget(old);
    if (old.selected != widget.selected) {
      _revealSelected(down: widget.selected > old.selected);
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Keep the highlighted row on screen when the arrows walk past the edge.
  ///
  /// It moves as little as it has to — the row that came into view sits at the
  /// edge it came from — and it moves at once: a list that slides under a key
  /// that is being held down reads as lag, not as motion.
  void _revealSelected({required bool down}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final BuildContext? ctx = _rowKeys[widget.selected]?.currentContext;
      if (ctx == null || !mounted) return;
      Scrollable.ensureVisible(
        ctx,
        alignmentPolicy: down
            ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd
            : ScrollPositionAlignmentPolicy.keepVisibleAtStart,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: widget.maxHeight),
      child: SingleChildScrollView(
        controller: _scroll,
        child: MenuTileGroup.single(
          color: scheme.surfaceContainerHigh,
          children: <Widget>[
            for (int i = 0; i < widget.entries.length; i++)
              _MentionRow(
                key: _rowKeys.putIfAbsent(i, GlobalKey.new),
                entry: widget.entries[i],
                selected: i == widget.selected,
                onTap: () => widget.onPick(widget.entries[i]),
              ),
          ],
        ),
      ),
    );
  }
}

/// One compact line: the face, the name, the handle in the quiet colour, and
/// the role on the right when there is one.
class _MentionRow extends StatelessWidget {
  const _MentionRow({
    super.key,
    required this.entry,
    required this.selected,
    required this.onTap,
  });

  final MentionEntry entry;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Color name = selected ? scheme.onPrimaryContainer : scheme.onSurface;
    final Color quiet = selected
        ? scheme.onPrimaryContainer.withValues(alpha: 0.72)
        : scheme.onSurfaceVariant;
    final String? aside = entry.role ?? entry.trailing;
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        child: ColoredBox(
          color: selected ? scheme.primaryContainer : Colors.transparent,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: <Widget>[
                if (entry.agentId != null)
                  ExpressiveFace(
                    id: entry.agentId!,
                    label: entry.label,
                    size: 28,
                  )
                else
                  // The broadcast row has no face; the gap keeps the names
                  // in one column.
                  const SizedBox(width: 28, height: 28),
                const SizedBox(width: 10),
                Flexible(
                  flex: 3,
                  child: Text(
                    entry.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: name,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Flexible(
                  flex: 2,
                  child: Text(
                    '@${entry.handle}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: quiet),
                  ),
                ),
                if (aside != null) ...<Widget>[
                  const SizedBox(width: 10),
                  Flexible(
                    flex: 2,
                    child: Text(
                      aside,
                      maxLines: 1,
                      textAlign: TextAlign.end,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(color: quiet),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
