/// A group-room conversation (§16.1): the user's message, then each coworker's
/// reply, with a system line saying why the exchange ended.
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

import 'package:flutter/material.dart';

import 'package:chuk_chat/models/agents_room.dart';
import 'package:chuk_chat/ui/expressive/agent_face.dart';
import 'package:chuk_chat/ui/expressive/bubble_shape.dart';
import 'package:chuk_chat/ui/expressive/icon_map.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';
import 'package:chuk_chat/widgets/messenger_typing_indicator.dart';

/// The width of the gutter the member faces stand in, and the gap to the
/// bubble lane. One number, so a named run and a continuation line up.
const double _kFaceSize = 28;
const double _kFaceGap = 8;

class RoomThreadView extends StatelessWidget {
  const RoomThreadView({
    super.key,
    required this.roomName,
    required this.userMessage,
    required this.turns,
    this.members = const <AgentsRoomMember>[],
    this.stop,
    this.running = false,
  });

  final String roomName;

  /// The room's members, shown as a compact strip under the name so the user
  /// sees who is in the room they are talking to. Empty hides the strip.
  final List<AgentsRoomMember> members;

  /// What the user posted to the room. Shown at the top so the replies have a
  /// subject.
  final String userMessage;

  /// The agent turns, in order.
  final List<AgentsRoomTurn> turns;

  /// Why the exchange ended, or null while it is still running.
  final AgentsRoomStop? stop;

  /// True while the host is still producing turns.
  final bool running;

  @override
  Widget build(BuildContext context) {
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

        final List<Widget> children = <Widget>[
          _roomIntro(context),
          _userMessage(context, lane),
        ];

        for (int i = 0; i < turns.length; i++) {
          children.add(_turn(context, i, lane));
        }

        if (running) {
          children.add(_runningRow(context));
        } else if (stop != null) {
          children.add(_stopLine(context, stop!));
        }

        return ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
          children: children,
        );
      },
    );
  }

  /// A run breaks on a different speaker — the only thing that can break one
  /// here, because a room's turns carry no clock and no day (see
  /// `messageStartsRun`, which the one-to-one thread uses for the same job).
  bool _startsRun(int i) => i == 0 || turns[i - 1].agentId != turns[i].agentId;

  bool _endsRun(int i) =>
      i == turns.length - 1 || turns[i + 1].agentId != turns[i].agentId;

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
  Widget _userMessage(BuildContext context, double lane) => MessageBubble(
    message: userMessage,
    isUser: true,
    messengerMode: true,
    showToolCalls: false,
    maxWidth: lane * 0.82,
  );

  /// One coworker's turn: the chat's coworker bubble, with the member's face
  /// in the gutter and its handle over the run.
  Widget _turn(BuildContext context, int i, double lane) {
    final AgentsRoomTurn turn = turns[i];
    final bool startsRun = _startsRun(i);
    final bool endsRun = _endsRun(i);
    final ThemeData theme = Theme.of(context);

    // The coworker's own accent names it, the same colour the roster and the
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
          child: MessageBubble(
            message: turn.text,
            isUser: false,
            messengerMode: true,
            showToolCalls: false,
            startsNewGroup: startsRun,
            endsGroup: endsRun,
            maxWidth: lane,
            senderLabel: startsRun
                ? Text(
                    '@${turn.handle}',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: accent,
                      fontWeight: FontWeight.w800,
                    ),
                    overflow: TextOverflow.ellipsis,
                  )
                : null,
          ),
        ),
      ],
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
  Widget _stopLine(BuildContext context, AgentsRoomStop stop) {
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
            failed ? Icons.error_outline : Icons.check_circle_outline,
            size: 14,
            color: color,
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(stop.label, style: style, textAlign: TextAlign.center),
          ),
        ],
      ),
    );
  }
}
