/// A group room, app-side (§16.1). Several agents in one conversation.
///
/// This mirrors the manager's `GroupRoom`: an ordered set of members, with no
/// ceiling on how many. The app holds only what it needs to show and to build
/// one — an id, a
/// name, and the members as (agent id, handle) pairs. The orchestration (turn
/// order, the round and message caps) lives on the host; the app never runs a
/// room itself, so nothing here duplicates that logic.
library;

import 'package:flutter/foundation.dart';

/// One agent in a room: the agent id the app tracks and the handle it is
/// mentioned by.
@immutable
class AgentsRoomMember {
  const AgentsRoomMember({required this.agentId, required this.handle});

  final String agentId;
  final String handle;

  @override
  bool operator ==(Object other) =>
      other is AgentsRoomMember &&
      other.agentId == agentId &&
      other.handle == handle;

  @override
  int get hashCode => Object.hash(agentId, handle);
}

/// Who answers a user message in a group (`responder`, WIRE_CONTRACT).
///
/// The host decides who speaks; this only names the mode the user chose, so
/// the app can show it and send it. [everyone] is what a group has always done.
enum AgentsRoomResponder {
  /// Every member answers, in group order.
  everyone,

  /// Only the members the user @named answer (`@all` names everyone).
  mentions,

  /// The host picks the one member that fits the message best.
  auto,

  /// One lead member answers and hands work to the others.
  lead;

  /// The string on the wire.
  String get wire => name;

  /// Parse the wire string. An unknown or missing mode is [everyone], the
  /// behaviour a group had before the mode existed.
  static AgentsRoomResponder fromWire(Object? raw) => switch (raw) {
    'mentions' => AgentsRoomResponder.mentions,
    'auto' => AgentsRoomResponder.auto,
    'lead' => AgentsRoomResponder.lead,
    _ => AgentsRoomResponder.everyone,
  };
}

/// The longest group instructions (`bulletin`) the host keeps.
const int kRoomBulletinMaxChars = 12000;

/// A group room the app knows about: an id, a name, and its members in order.
/// Mirrors the manager's `GroupRoom`; the orchestration (turn order, caps) lives
/// on the host, so this holds only what the app shows.
@immutable
class AgentsRoom {
  const AgentsRoom({
    required this.id,
    required this.name,
    required this.members,
    this.agentToAgent = true,
    this.responder = AgentsRoomResponder.everyone,
    this.leadAgentId,
    this.fallbackAgentId,
    this.bulletin = '',
    this.workdir = '',
  });

  final String id;
  final String name;
  final List<AgentsRoomMember> members;

  /// Whether the agents may pull each other in by writing `@handle`
  /// (`agent_to_agent`, WIRE_CONTRACT). True is what a room has always done, so
  /// an old room and an old host both keep behaving exactly as before; false
  /// means every member answers the user and nobody answers an agent.
  final bool agentToAgent;

  /// Who answers a user message ([AgentsRoomResponder]).
  final AgentsRoomResponder responder;

  /// The lead member in [AgentsRoomResponder.lead] mode. Null: none chosen.
  final String? leadAgentId;

  /// The member that answers when auto routing is not sure. Null: none.
  final String? fallbackAgentId;

  /// The group instructions every member reads. Empty: none.
  final String bulletin;

  /// The shared folder the members work in. Empty: none.
  final String workdir;

  /// The members' handles, in room order — the "everyone speaks" sequence.
  List<String> get handles => <String>[for (final m in members) m.handle];

  /// The member with [agentId], or null.
  AgentsRoomMember? memberById(String? agentId) {
    if (agentId == null) return null;
    for (final m in members) {
      if (m.agentId == agentId) return m;
    }
    return null;
  }

  /// The settings as wire keys (`room_create` / `room_settings`). A cleared
  /// lead or fallback rides as null, so the host clears it too.
  Map<String, Object?> settingsWire() => <String, Object?>{
    'responder': responder.wire,
    'lead_agent_id': leadAgentId,
    'fallback_agent_id': fallbackAgentId,
    'bulletin': bulletin,
    'workdir': workdir,
  };

  /// [clearLead] / [clearFallback] set the member to none (a null argument
  /// keeps the current one, as everywhere in `copyWith`).
  AgentsRoom copyWith({
    String? name,
    List<AgentsRoomMember>? members,
    bool? agentToAgent,
    AgentsRoomResponder? responder,
    String? leadAgentId,
    bool clearLead = false,
    String? fallbackAgentId,
    bool clearFallback = false,
    String? bulletin,
    String? workdir,
  }) => AgentsRoom(
    id: id,
    name: name ?? this.name,
    members: members ?? this.members,
    agentToAgent: agentToAgent ?? this.agentToAgent,
    responder: responder ?? this.responder,
    leadAgentId: clearLead ? null : (leadAgentId ?? this.leadAgentId),
    fallbackAgentId: clearFallback
        ? null
        : (fallbackAgentId ?? this.fallbackAgentId),
    bulletin: bulletin ?? this.bulletin,
    workdir: workdir ?? this.workdir,
  );

  /// The local copy (the app keeps its groups across restarts). The keys are
  /// the wire's, so one shape serves both.
  Map<String, Object?> toJson() => <String, Object?>{
    'room_id': id,
    'name': name,
    'members': <Map<String, String>>[
      for (final m in members)
        <String, String>{'agent_id': m.agentId, 'handle': m.handle},
    ],
    'agent_to_agent': agentToAgent,
    ...settingsWire(),
  };

  /// Reads [toJson]'s shape, which is also the shape of one `room_list`
  /// entry. Null for an entry without an id, a name or two valid members:
  /// a group of one is not a group.
  static AgentsRoom? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['room_id'];
    final name = raw['name'];
    final rawMembers = raw['members'];
    if (id is! String || id.isEmpty || name is! String || rawMembers is! List) {
      return null;
    }
    final members = <AgentsRoomMember>[];
    final seen = <String>{};
    for (final Object? m in rawMembers) {
      if (m is! Map) continue;
      final agentId = m['agent_id'];
      final handle = m['handle'];
      if (agentId is! String || agentId.isEmpty || handle is! String) continue;
      if (!seen.add(agentId)) continue;
      members.add(AgentsRoomMember(agentId: agentId, handle: handle));
    }
    if (members.length < 2) return null;
    String? optionalId(Object? v) => v is String && v.isNotEmpty ? v : null;
    final bulletin = raw['bulletin'];
    final workdir = raw['workdir'];
    return AgentsRoom(
      id: id,
      name: name.trim().isEmpty ? id : name,
      members: List<AgentsRoomMember>.unmodifiable(members),
      agentToAgent: raw['agent_to_agent'] != false,
      responder: AgentsRoomResponder.fromWire(raw['responder']),
      leadAgentId: optionalId(raw['lead_agent_id']),
      fallbackAgentId: optionalId(raw['fallback_agent_id']),
      bulletin: bulletin is String ? bulletin : '',
      workdir: workdir is String ? workdir : '',
    );
  }
}

/// What the create-room form produces: a name and the chosen members. It is not
/// a live room yet — the host makes it real — so it carries no id.
@immutable
class AgentsRoomDraft {
  const AgentsRoomDraft({
    required this.name,
    required this.members,
    this.agentToAgent = true,
    this.responder = AgentsRoomResponder.everyone,
    this.leadAgentId,
    this.fallbackAgentId,
    this.bulletin = '',
    this.workdir = '',
  });

  final String name;
  final List<AgentsRoomMember> members;

  /// The policy the form chose; see [AgentsRoom.agentToAgent]. Defaults to the
  /// behaviour a room has always had, so a caller that knows nothing about the
  /// switch still builds the room the user expects.
  final bool agentToAgent;

  /// See [AgentsRoom.responder].
  final AgentsRoomResponder responder;

  /// See [AgentsRoom.leadAgentId].
  final String? leadAgentId;

  /// See [AgentsRoom.fallbackAgentId].
  final String? fallbackAgentId;

  /// See [AgentsRoom.bulletin].
  final String bulletin;

  /// See [AgentsRoom.workdir].
  final String workdir;
}

/// What one entry of a group conversation is.
enum AgentsRoomTurnKind {
  /// A member's answer.
  agent,

  /// What the user sent.
  user,

  /// The lead handed a task to another member.
  handoff;

  /// Parse the wire string; a missing or unknown kind is [agent], what every
  /// turn was before the key existed.
  static AgentsRoomTurnKind fromWire(Object? raw) => switch (raw) {
    'user' => AgentsRoomTurnKind.user,
    'handoff' => AgentsRoomTurnKind.handoff,
    _ => AgentsRoomTurnKind.agent,
  };
}

/// How the host chose the member that answered (`routed_by`).
@immutable
class AgentsRoomRouting {
  const AgentsRoomRouting({
    required this.mode,
    this.confidence,
    this.fallback = false,
  });

  /// `auto` or `lead` (any string the host sends).
  final String mode;

  /// How sure auto routing was, 0..1. Null when the host sent none.
  final double? confidence;

  /// True when auto routing was not sure and the fallback member answered.
  final bool fallback;

  bool get isAuto => mode == 'auto';
}

/// One entry in a group conversation, as the app shows it. Mirrors the
/// manager's `RoomTurn`: which round it belonged to, who spoke, and what they
/// said. A [AgentsRoomTurnKind.user] entry has an empty agent id and handle;
/// a [AgentsRoomTurnKind.handoff] entry names the member the task went to.
@immutable
class AgentsRoomTurn {
  const AgentsRoomTurn({
    required this.round,
    required this.agentId,
    required this.handle,
    required this.text,
    this.kind = AgentsRoomTurnKind.agent,
    this.routedBy,
    this.toAgentId,
    this.toHandle,
  });

  /// What the user sent, as one entry of the conversation.
  const AgentsRoomTurn.user(this.text)
    : round = 0,
      agentId = '',
      handle = '',
      kind = AgentsRoomTurnKind.user,
      routedBy = null,
      toAgentId = null,
      toHandle = null;

  final int round;
  final String agentId;
  final String handle;
  final String text;
  final AgentsRoomTurnKind kind;

  /// How the host chose this member, or null.
  final AgentsRoomRouting? routedBy;

  /// For a handoff: the member the task went to.
  final String? toAgentId;
  final String? toHandle;

  bool get isUser => kind == AgentsRoomTurnKind.user;
  bool get isHandoff => kind == AgentsRoomTurnKind.handoff;
}

/// Why a room exchange ended, as the host reported it. The strings match the
/// manager's `RoomSession`/`RoomRunner` stop reasons so the UI never invents a
/// state the host did not send.
enum AgentsRoomStop {
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
  noSuchRoom,

  /// The room's `agent_to_agent` policy is off, so an agent's @mention of
  /// another agent was not followed — the exchange ends after everyone has
  /// answered the user.
  agentToAgentOff,

  /// The group answers only @named members and the message named nobody.
  noAddressee,

  /// The lead finished its work normally.
  leadDone;

  /// Parse the wire string, or null for one this build does not know.
  static AgentsRoomStop? fromWire(String? reason) => switch (reason) {
    'no_more_mentions' => AgentsRoomStop.noMoreMentions,
    'rounds_exhausted' => AgentsRoomStop.roundsExhausted,
    'messages_exhausted' => AgentsRoomStop.messagesExhausted,
    'stopped' => AgentsRoomStop.stopped,
    'turn_failed' => AgentsRoomStop.turnFailed,
    'no_such_room' => AgentsRoomStop.noSuchRoom,
    'agent_to_agent_off' => AgentsRoomStop.agentToAgentOff,
    'no_addressee' => AgentsRoomStop.noAddressee,
    'lead_done' => AgentsRoomStop.leadDone,
    _ => null,
  };

  /// True for a stop that is the normal end of an exchange.
  bool get isNormalEnd =>
      this == AgentsRoomStop.noMoreMentions || this == AgentsRoomStop.leadDone;

  /// A short English line for the thread footer. The thread itself shows the
  /// translated line (`roomStopLabel` in `room_thread_view.dart`).
  String get label => switch (this) {
    AgentsRoomStop.noMoreMentions => 'Everyone has weighed in',
    AgentsRoomStop.roundsExhausted => 'Reached the round limit',
    AgentsRoomStop.messagesExhausted => 'Reached the message limit',
    AgentsRoomStop.stopped => 'Stopped',
    AgentsRoomStop.turnFailed => 'An agent\'s turn failed',
    AgentsRoomStop.noSuchRoom => 'This group is not on your computer yet',
    AgentsRoomStop.agentToAgentOff =>
      'Agents do not reply to each other here',
    AgentsRoomStop.noAddressee =>
      'Nobody was mentioned. Write @name or @all.',
    AgentsRoomStop.leadDone => 'Everyone has weighed in',
  };
}
