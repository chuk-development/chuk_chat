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

/// What the create-room form produces: a name and the chosen members. It is not
/// a live room yet — the host makes it real — so it carries no id.
@immutable
class CoworkRoomDraft {
  const CoworkRoomDraft({required this.name, required this.members});

  final String name;
  final List<CoworkRoomMember> members;
}
