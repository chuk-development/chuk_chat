/// A group room, app-side (§16.1). Several coworkers in one conversation.
///
/// This mirrors the manager's `GroupRoom`: an ordered set of members, capped at
/// six. The app holds only what it needs to show and to build one — an id, a
/// name, and the members as (agent id, handle) pairs. The orchestration (turn
/// order, the round and message caps) lives on the host; the app never runs a
/// room itself, so nothing here duplicates that logic.
library;

import 'package:flutter/foundation.dart';

/// The member cap, matching the manager's `DEFAULT_MAX_MEMBERS`. Kept here so
/// the picker can enforce it without a round-trip to the host.
const int kRoomMaxMembers = 6;

/// One coworker in a room: the agent id the app tracks and the handle it is
/// mentioned by.
@immutable
class CoworkRoomMember {
  const CoworkRoomMember({required this.agentId, required this.handle});

  final String agentId;
  final String handle;

  @override
  bool operator ==(Object other) =>
      other is CoworkRoomMember &&
      other.agentId == agentId &&
      other.handle == handle;

  @override
  int get hashCode => Object.hash(agentId, handle);
}

/// A group room the app knows about: an id, a name, and its members in order.
/// Mirrors the manager's `GroupRoom`; the orchestration (turn order, caps) lives
/// on the host, so this holds only what the app shows.
@immutable
class CoworkRoom {
  const CoworkRoom({
    required this.id,
    required this.name,
    required this.members,
  });

  final String id;
  final String name;
  final List<CoworkRoomMember> members;

  /// The members' handles, in room order — the "everyone speaks" sequence.
  List<String> get handles => <String>[for (final m in members) m.handle];

  CoworkRoom copyWith({String? name, List<CoworkRoomMember>? members}) =>
      CoworkRoom(
        id: id,
        name: name ?? this.name,
        members: members ?? this.members,
      );
}

/// What the create-room form produces: a name and the chosen members. It is not
/// a live room yet — the host makes it real — so it carries no id.
@immutable
class CoworkRoomDraft {
  const CoworkRoomDraft({required this.name, required this.members});

  final String name;
  final List<CoworkRoomMember> members;
}

/// One agent turn in a room exchange, as the app shows it. Mirrors the manager's
/// `RoomTurn`: which round it belonged to, who spoke, and what they said.
@immutable
class CoworkRoomTurn {
  const CoworkRoomTurn({
    required this.round,
    required this.agentId,
    required this.handle,
    required this.text,
  });

  final int round;
  final String agentId;
  final String handle;
  final String text;
}

/// Why a room exchange ended, as the host reported it. The strings match the
/// manager's `RoomSession`/`RoomRunner` stop reasons so the UI never invents a
/// state the host did not send.
enum CoworkRoomStop {
  /// No unanswered @mention was left — the exchange ran itself out.
  noMoreMentions,

  /// The three-round cap was hit.
  roundsExhausted,

  /// The ten-message-per-send cap was hit.
  messagesExhausted,

  /// The user stopped it.
  stopped,

  /// A member's turn crashed.
  turnFailed,

  /// The host does not have this room (it was never synced, or was deleted on
  /// the host). The app can re-create it and try again.
  noSuchRoom;

  /// Parse the wire string, or null for one this build does not know.
  static CoworkRoomStop? fromWire(String? reason) => switch (reason) {
        'no_more_mentions' => CoworkRoomStop.noMoreMentions,
        'rounds_exhausted' => CoworkRoomStop.roundsExhausted,
        'messages_exhausted' => CoworkRoomStop.messagesExhausted,
        'stopped' => CoworkRoomStop.stopped,
        'turn_failed' => CoworkRoomStop.turnFailed,
        'no_such_room' => CoworkRoomStop.noSuchRoom,
        _ => null,
      };

  /// A short human line for the thread footer.
  String get label => switch (this) {
        CoworkRoomStop.noMoreMentions => 'Everyone has weighed in',
        CoworkRoomStop.roundsExhausted => 'Reached the round limit',
        CoworkRoomStop.messagesExhausted => 'Reached the message limit',
        CoworkRoomStop.stopped => 'Stopped',
        CoworkRoomStop.turnFailed => 'A coworker\'s turn failed',
        CoworkRoomStop.noSuchRoom => 'This room is not on your host yet',
      };
}
