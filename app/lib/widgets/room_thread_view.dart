/// A group-room conversation (§16.1): the user's message, then each coworker's
/// reply, grouped by round, with a footer saying why the exchange ended.
///
/// This is a pure render of what the host reports — the turns and the stop
/// reason from the manager's `RoomRunner`. The app runs no room itself, so
/// nothing here decides turn order or caps; it only shows them. A round divider
/// makes the back-and-forth legible: round one is who the user reached, round
/// two is who those coworkers pulled in, and so on up to the host's cap.
library;

import 'package:flutter/material.dart';

import 'package:cowork/ui/expressive/bubble_shape.dart';
import 'package:cowork/ui/expressive/agent_face.dart';
import 'package:cowork/models/cowork_room.dart';

class RoomThreadView extends StatelessWidget {
  const RoomThreadView({
    super.key,
    required this.roomName,
    required this.userMessage,
    required this.turns,
    this.members = const <CoworkRoomMember>[],
    this.stop,
    this.running = false,
  });

  final String roomName;

  /// The room's members, shown as a compact strip under the name so the user
  /// sees who is in the room they are talking to. Empty hides the strip.
  final List<CoworkRoomMember> members;

  /// What the user posted to the room. Shown at the top so the replies have a
  /// subject.
  final String userMessage;

  /// The agent turns, in order. Rendered grouped by [CoworkRoomTurn.round].
  final List<CoworkRoomTurn> turns;

  /// Why the exchange ended, or null while it is still running.
  final CoworkRoomStop? stop;

  /// True while the host is still producing turns.
  final bool running;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[_userMessage(context)];

    int? lastRound;
    for (final turn in turns) {
      if (turn.round != lastRound) {
        children.add(_roundDivider(context, turn.round));
        lastRound = turn.round;
      }
      children.add(_turnBubble(context, turn));
    }

    if (running) {
      children.add(_runningRow(context));
    } else if (stop != null) {
      children.add(_stopFooter(context, stop!));
    }

    return ListView(padding: const EdgeInsets.all(12), children: children);
  }

  Widget _userMessage(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(roomName, style: theme.textTheme.titleSmall),
          if (members.isNotEmpty) ...[
            const SizedBox(height: 6),
            _memberStrip(context),
          ],
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerRight,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(userMessage),
            ),
          ),
        ],
      ),
    );
  }

  Widget _memberStrip(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 24,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: members.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, i) {
          final m = members[i];
          return Row(
            children: [
              ExpressiveFace(id: m.agentId, label: m.handle, size: 18),
              const SizedBox(width: 4),
              Text('@${m.handle}', style: theme.textTheme.bodySmall),
            ],
          );
        },
      ),
    );
  }

  Widget _roundDivider(BuildContext context, int round) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          const Expanded(child: Divider()),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              'Round $round',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.hintColor,
              ),
            ),
          ),
          const Expanded(child: Divider()),
        ],
      ),
    );
  }

  Widget _turnBubble(BuildContext context, CoworkRoomTurn turn) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExpressiveFace(id: turn.agentId, label: turn.handle, size: 28),
          const SizedBox(width: 8),
          // One member's turn is one bubble, in the same shape a coworker's
          // message has in a one-to-one thread.
          Flexible(
            child: Container(
              padding: const EdgeInsets.fromLTRB(14, 9, 14, 10),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHigh,
                borderRadius: bubbleRadius(false, BubblePosition.single),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '@${turn.handle}',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(turn.text),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _runningRow(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Text('the room is talking…', style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }

  Widget _stopFooter(BuildContext context, CoworkRoomStop stop) {
    final theme = Theme.of(context);
    final failed = stop == CoworkRoomStop.turnFailed;
    final color = failed ? theme.colorScheme.error : theme.hintColor;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          const Expanded(child: Divider()),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              stop.label,
              style: theme.textTheme.bodySmall?.copyWith(color: color),
            ),
          ),
          const Expanded(child: Divider()),
        ],
      ),
    );
  }
}
