/// A group conversation (§16.1): every message the user sent and every
/// member's reply, in order, across exchanges — the way a group chat reads —
/// with a system line saying why the last exchange ended.
///
/// A room is a chat, so it is drawn with the chat's own message widgets —
/// [MessageBubble] for every turn and for the user's line, the run grouping of
/// `bubble_shape.dart`, the quiet system-line voice of the thread view. Nothing
/// here draws a bubble of its own. What a room has on top of a one-to-one
/// thread is several senders, so a run carries the member's face beside it and
/// its handle above it, the way a group messenger names who is talking; a run
/// of consecutive turns from one member is named once.
///
/// There is no round divider. The manager's round number is how the host's
/// `RoomRunner` walks its loop, not something the reader needs between two
/// messages — and a labelled rule across the thread is a shape this chat does
/// not otherwise have. The sender names already say who answered whom.
///
/// This is a pure render of what the host reports — the turns and the stop
/// reason. The app runs no room itself, so nothing here decides turn order or
/// caps; it only shows them.
library;

import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/models/agents_room.dart';
import 'package:chuk_chat/ui/expressive/agent_face.dart';
import 'package:chuk_chat/ui/expressive/bubble_shape.dart';
import 'package:chuk_chat/ui/expressive/icon_map.dart';
import 'package:chuk_chat/widgets/agents_host_tag.dart';
import 'package:chuk_chat/widgets/icons/huge_icon.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';
import 'package:chuk_chat/widgets/messenger_typing_indicator.dart';

/// The width of the gutter the member faces stand in, and the gap to the
/// bubble lane. One number, so a named run and a continuation line up.
const double _kFaceSize = 28;
const double _kFaceGap = 8;

/// The translated footer line for [stop].
String roomStopLabel(AgentsRoomStop stop, AppLocalizations l) => switch (stop) {
  AgentsRoomStop.noMoreMentions => l.agentsGroupStopNoMoreMentions,
  AgentsRoomStop.leadDone => l.agentsGroupStopNoMoreMentions,
  AgentsRoomStop.roundsExhausted => l.agentsGroupStopRounds,
  AgentsRoomStop.messagesExhausted => l.agentsGroupStopMessages,
  AgentsRoomStop.stopped => l.agentsGroupStopStopped,
  AgentsRoomStop.turnFailed => l.agentsGroupStopTurnFailed,
  AgentsRoomStop.noSuchRoom => l.agentsGroupStopNoSuchRoom,
  AgentsRoomStop.agentToAgentOff => l.agentsGroupStopAgentToAgentOff,
  AgentsRoomStop.noAddressee => l.agentsGroupStopNoAddressee,
};

/// The muted caption under an auto-routed reply, or null when the host did
/// not say auto routing chose it.
String? roomRoutingCaption(AgentsRoomRouting? routing, AppLocalizations l) {
  if (routing == null || !routing.isAuto) return null;
  if (routing.fallback) return l.agentsGroupPickedByAutoFallback;
  final double? c = routing.confidence;
  if (c == null) return l.agentsGroupPickedByAutoPlain;
  final int percent = (c.clamp(0, 1) * 100).round();
  return l.agentsGroupPickedByAuto('$percent');
}

/// The name a member is shown by: its roster name when the roster knows it,
/// else `@handle`.
String roomMemberName(List<AgentsAgent> agents, String agentId, String handle) {
  for (final AgentsAgent a in agents) {
    if (a.id == agentId && a.name.trim().isNotEmpty) return a.name;
  }
  return handle.isEmpty ? agentId : '@$handle';
}

class RoomThreadView extends StatelessWidget {
  const RoomThreadView({
    super.key,
    required this.roomName,
    this.userMessage,
    this.emptyHint,
    required this.turns,
    this.members = const <AgentsRoomMember>[],
    this.agents = const <AgentsAgent>[],
    this.stop,
    this.running = false,
    this.working,
  });

  final String roomName;

  /// The room's members, shown as a compact strip under the name so the user
  /// sees who is in the room they are talking to. Empty hides the strip.
  final List<AgentsRoomMember> members;

  /// The roster, only for the display names. A member it does not know is
  /// shown by its `@handle`.
  final List<AgentsAgent> agents;

  /// A message the user posted before [turns] begin, shown first. Null when
  /// [turns] carry the user's messages themselves (a group conversation does).
  final String? userMessage;

  /// The empty room's line ("Message the room to start."): one quiet centred
  /// line in the room intro's voice, shown while nothing was sent, no turn
  /// arrived and nothing runs. Never a bubble, never typing dots.
  final String? emptyHint;

  /// The conversation, in order: the user's messages, the members' turns and
  /// the lead's handoffs ([AgentsRoomTurn.kind]).
  final List<AgentsRoomTurn> turns;

  /// Why the exchange ended, or null while it is still running.
  final AgentsRoomStop? stop;

  /// True while the host is still producing turns.
  final bool running;

  /// The member working right now (`room_working`), or null. Shown as a
  /// typing row with its face and name while [running].
  final AgentsRoomMember? working;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l =
        AppLocalizations.of(context) ?? AppLocalizations(const Locale('en'));
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // The lane a bubble may fill, once the face gutter is taken off it.
        final double lane =
            (constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : MediaQuery.sizeOf(context).width) -
            24 - // the list's own horizontal padding
            _kFaceSize -
            _kFaceGap;

        final String? sent = userMessage;
        final String? hint = emptyHint;
        final bool empty =
            sent == null && turns.isEmpty && !running && stop == null;
        final List<Widget> children = <Widget>[
          _roomIntro(context),
          if (sent != null) _userMessage(context, sent, lane),
          if (empty && hint != null) _emptyLine(context, hint),
        ];

        for (int i = 0; i < turns.length; i++) {
          final AgentsRoomTurn turn = turns[i];
          if (turn.isUser) {
            children.add(_userMessage(context, turn.text, lane));
          } else if (turn.isHandoff) {
            children.add(_handoffLine(context, turn));
          } else {
            children.add(_turn(context, i, lane, l));
          }
        }

        final AgentsRoomMember? who = working;
        if (running) {
          children.add(
            who == null ? _runningRow(context) : _workingRow(context, who, l),
          );
        } else if (stop != null) {
          children.add(_stopLine(context, stop!, l));
        }

        // The top inset comes from the frame: under a floating header the
        // Scaffold puts the header's height here, so the list starts below
        // the header but still scrolls behind it.
        return ListView(
          padding: EdgeInsets.fromLTRB(
            12,
            12 + MediaQuery.paddingOf(context).top,
            12,
            16,
          ),
          children: children,
        );
      },
    );
  }

  bool _isAgent(int i) =>
      i >= 0 && i < turns.length && turns[i].kind == AgentsRoomTurnKind.agent;

  /// A run breaks on a different speaker, or on anything that is not a
  /// member's turn (the user's line, a handoff) — the only things that can
  /// break one here, because a room's turns carry no clock and no day (see
  /// `messageStartsRun`, which the one-to-one thread uses for the same job).
  bool _startsRun(int i) =>
      !_isAgent(i - 1) || turns[i - 1].agentId != turns[i].agentId;

  bool _endsRun(int i) =>
      !_isAgent(i + 1) || turns[i + 1].agentId != turns[i].agentId;

  String _name(String agentId, String handle) =>
      roomMemberName(agents, agentId, handle);

  /// Who you are talking to, in the thread's quiet system voice — the room's
  /// name and the faces in it. Not a bubble: nobody said it.
  Widget _roomIntro(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color color = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        children: <Widget>[
          Text(
            roomName,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (members.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            _memberStrip(context),
          ],
        ],
      ),
    );
  }

  Widget _memberStrip(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final AgentsRoomMember m in members)
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    ExpressiveFace(id: m.agentId, label: m.handle, size: 18),
                    const SizedBox(width: 4),
                    Text(
                      '@${m.handle}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// The user's own line, in the user's own bubble — the same widget, the same
  /// side and the same fill a one-to-one thread gives it.
  Widget _userMessage(BuildContext context, String text, double lane) =>
      MessageBubble(
        message: text,
        isUser: true,
        messengerMode: true,
        showToolCalls: false,
        maxWidth: lane * 0.82,
      );

  /// The empty room's line, in the intro's quiet voice: centred, muted, no
  /// bubble.
  Widget _emptyLine(BuildContext context, String hint) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      key: const ValueKey<String>('room-empty-hint'),
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      child: Text(
        hint,
        textAlign: TextAlign.center,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  /// One agent's turn: the chat's agent bubble, with the member's face
  /// in the gutter and its name over the run. An auto-routed reply carries a
  /// muted caption saying so.
  Widget _turn(BuildContext context, int i, double lane, AppLocalizations l) {
    final AgentsRoomTurn turn = turns[i];
    final String? caption = roomRoutingCaption(turn.routedBy, l);
    final bool startsRun = _startsRun(i);
    final bool endsRun = _endsRun(i);
    final ThemeData theme = Theme.of(context);

    // The agent's own accent names it, the same colour the roster and the
    // one-to-one thread give it.
    final Color accent = agentAccent(context, turn.agentId);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: _kFaceSize,
          // The face stands level with the handle over the run, so it opens
          // the run rather than floating beside its middle. A continuation
          // keeps the gutter empty — one face per run, like any messenger.
          child: startsRun
              ? Padding(
                  padding: const EdgeInsets.only(top: kBubbleGapBetweenGroups),
                  child: ExpressiveFace(
                    id: turn.agentId,
                    label: turn.handle,
                    size: _kFaceSize,
                  ),
                )
              : null,
        ),
        const SizedBox(width: _kFaceGap),
        Expanded(
          child: _withCaption(
            context,
            caption,
            _withFileChip(
              turn.text,
              MessageBubble(
                // A shared file's reference is drawn as the chip below.
                message: RoomSharedFile.withoutRef(turn.text),
                isUser: false,
                messengerMode: true,
                showToolCalls: false,
                startsNewGroup: startsRun,
                endsGroup: endsRun,
                maxWidth: lane,
                senderLabel: startsRun
                    ? Text(
                        _name(turn.agentId, turn.handle),
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: accent,
                          fontWeight: FontWeight.w800,
                        ),
                        overflow: TextOverflow.ellipsis,
                      )
                    : null,
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// [bubble] with a chip for the file a member shared (CHAT-177 phase 2),
  /// or [bubble] alone when the turn carries no file reference.
  Widget _withFileChip(String text, Widget bubble) {
    final RoomSharedFile? file = RoomSharedFile.tryParse(text);
    if (file == null) return bubble;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        bubble,
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: RoomSharedFileChip(file: file),
        ),
      ],
    );
  }

  /// [bubble] with the routing caption under it, or [bubble] alone.
  Widget _withCaption(BuildContext context, String? caption, Widget bubble) {
    if (caption == null) return bubble;
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        bubble,
        Padding(
          key: const ValueKey<String>('room-routing-caption'),
          padding: const EdgeInsets.only(left: 4, top: 2),
          child: Text(
            caption,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  /// The lead handed work to a member: one quiet line, never a bubble.
  /// "lead [arrow] @member: task", the arrow an icon centred in the row.
  Widget _handoffLine(BuildContext context, AgentsRoomTurn turn) {
    final ThemeData theme = Theme.of(context);
    final Color color = theme.colorScheme.onSurfaceVariant;
    final TextStyle style =
        (theme.textTheme.bodySmall ?? const TextStyle(fontSize: 12)).copyWith(
          color: color,
        );
    final String toHandle = turn.toHandle ?? '';
    final String to = toHandle.isEmpty
        ? _name(turn.toAgentId ?? '', '')
        : '@$toHandle';
    final String task = turn.text.trim();
    return Padding(
      key: const ValueKey<String>('room-handoff'),
      padding: const EdgeInsets.only(
        top: kBubbleGapBetweenGroups,
        left: _kFaceSize + _kFaceGap,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Text(
            _name(turn.agentId, turn.handle),
            style: style.copyWith(fontWeight: FontWeight.w700),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: AppIcon(Icons.arrow_forward_rounded, size: 14, color: color),
          ),
          Flexible(
            child: Text(
              task.isEmpty ? to : '$to: $task',
              style: style,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  /// A member is working: its face, "name is working…" and the typing
  /// pill, where its answer will appear.
  Widget _workingRow(
    BuildContext context,
    AgentsRoomMember member,
    AppLocalizations l,
  ) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      key: const ValueKey<String>('room-working'),
      padding: const EdgeInsets.only(top: kBubbleGapBetweenGroups, bottom: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          SizedBox(
            width: _kFaceSize,
            child: ExpressiveFace(
              id: member.agentId,
              label: member.handle,
              size: _kFaceSize,
            ),
          ),
          const SizedBox(width: _kFaceGap),
          const MessengerTypingIndicator(),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              l.agentsGroupWorking(_name(member.agentId, member.handle)),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  /// The room is still talking: the chat's own typing pill, in the bubble lane
  /// so it sits where the next turn will.
  Widget _runningRow(BuildContext context) => const Padding(
    padding: EdgeInsets.only(
      top: kBubbleGapBetweenGroups,
      left: _kFaceSize + _kFaceGap,
      bottom: 2,
    ),
    child: Align(
      alignment: Alignment.centerLeft,
      child: MessengerTypingIndicator(),
    ),
  );

  /// Why the exchange ended: one quiet centred line, in the same voice the
  /// thread's other system lines use (the automation wake and the quiet work
  /// line in `message_bubble/layout.dart`). Never a rule across the thread.
  Widget _stopLine(
    BuildContext context,
    AgentsRoomStop stop,
    AppLocalizations l,
  ) {
    final ThemeData theme = Theme.of(context);
    final bool failed = stop == AgentsRoomStop.turnFailed;
    final Color color = failed
        ? theme.colorScheme.error
        : theme.colorScheme.onSurfaceVariant;
    final TextStyle style =
        (theme.textTheme.bodySmall ?? const TextStyle(fontSize: 12)).copyWith(
          color: color,
        );
    return Padding(
      padding: const EdgeInsets.only(top: kBubbleGapBetweenGroups, bottom: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          AppIcon(
            failed
                ? Icons.error_outline
                : (stop == AgentsRoomStop.noAddressee
                      ? Icons.alternate_email_rounded
                      : Icons.check_circle_outline),
            size: 14,
            color: color,
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              roomStopLabel(stop, l),
              style: style,
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}

/// A file a group member shared (CHAT-177 phase 2). The turn reads
/// `Shared file NAME (SIZE bytes). ref: {...}`, and the reference carries
/// `sha256`, `name`, `size` and `host_id`. The file stays on its computer;
/// the chip only names it.
@immutable
class RoomSharedFile {
  const RoomSharedFile({
    required this.name,
    required this.size,
    required this.sha256,
    this.hostId,
  });

  final String name;
  final int size;
  final String sha256;

  /// The computer the file lives on, or null when the reference names none.
  final String? hostId;

  static final RegExp _ref = RegExp(r'ref:\s*(\{.*\})\s*$', dotAll: true);

  /// The reference at the end of [text], or null when there is none.
  static RoomSharedFile? tryParse(String text) {
    if (!text.contains('ref:')) return null;
    final RegExpMatch? match = _ref.firstMatch(text);
    if (match == null) return null;
    try {
      final String? body = match.group(1);
      if (body == null) return null;
      final Object? raw = jsonDecode(body);
      if (raw is! Map) return null;
      final Object? name = raw['name'];
      final Object? size = raw['size'];
      final Object? sha = raw['sha256'];
      final Object? host = raw['host_id'];
      if (name is! String || name.isEmpty || sha is! String || sha.isEmpty) {
        return null;
      }
      if (size is! num || size < 0) return null;
      return RoomSharedFile(
        name: name,
        size: size.toInt(),
        sha256: sha,
        hostId: host is String && host.isNotEmpty ? host : null,
      );
    } catch (_) {
      return null;
    }
  }

  /// [text] without a trailing file reference, or [text] when it has none
  /// (the chip names the file, the bubble keeps the sentence).
  static String withoutRef(String text) {
    final RegExpMatch? match = _ref.firstMatch(text);
    if (match == null || tryParse(text) == null) return text;
    final String head = text.substring(0, match.start).trim();
    return head.isEmpty ? text : head;
  }

  /// The size for people: bytes, KB, MB or GB.
  String get sizeLabel {
    if (size < 1024) return '$size B';
    const List<String> units = <String>['KB', 'MB', 'GB'];
    double value = size / 1024;
    int unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(value < 10 ? 1 : 0)} ${units[unit]}';
  }
}

/// A flat chip with the file icon, the name, the size and the computer the
/// file lives on (only while two or more computers are paired). No action:
/// the agents fetch the file themselves.
class RoomSharedFileChip extends StatelessWidget {
  const RoomSharedFileChip({super.key, required this.file, this.labels});

  final RoomSharedFile file;

  /// The computer labels. Null reads [AgentsHostLabels.instance].
  final AgentsHostLabels? labels;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final AgentsHostLabels source = labels ?? AgentsHostLabels.instance;
    return ListenableBuilder(
      listenable: source,
      builder: (BuildContext context, Widget? _) {
        final String? computer = file.hostId == null
            ? null
            : source.labelFor(file.hostId);
        final String detail = computer == null
            ? file.sizeLabel
            : '${file.sizeLabel} · $computer';
        return Container(
          key: const ValueKey<String>('room-shared-file'),
          constraints: const BoxConstraints(maxWidth: 320),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              HugeIcon(HugeIcons.file01, size: 20, color: scheme.primary),
              const SizedBox(width: 8),
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      file.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: scheme.onSurface,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
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
}
