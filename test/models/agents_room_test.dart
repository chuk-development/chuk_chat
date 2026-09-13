/// The room model's `agent_to_agent` policy (bead cowork-h46g) and the stop
/// reason the host sends when the policy silenced a coworker's @mention.
///
/// Default ON is the whole point of the contract: a room built by an older
/// screen, or restored without the key, must behave exactly the way rooms have
/// always behaved.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/agents_room.dart';

AgentsRoomMember _m(String id, String handle) =>
    AgentsRoomMember(agentId: id, handle: handle);

void main() {
  test('a room lets the coworkers reply to each other unless told otherwise',
      () {
    final room = AgentsRoom(
      id: 'r1',
      name: 'launch',
      members: [_m('a', 'amber'), _m('b', 'cobalt')],
    );
    expect(room.agentToAgent, isTrue);
  });

  test('copyWith carries the policy, and can flip it alone', () {
    final room = AgentsRoom(
      id: 'r1',
      name: 'launch',
      members: [_m('a', 'amber'), _m('b', 'cobalt')],
      agentToAgent: false,
    );
    // A rename must not quietly turn the policy back on.
    expect(room.copyWith(name: 'ops').agentToAgent, isFalse);
    expect(room.copyWith(name: 'ops').name, 'ops');
    // And the flip keeps everything else.
    final on = room.copyWith(agentToAgent: true);
    expect(on.agentToAgent, isTrue);
    expect(on.name, 'launch');
    expect(on.handles, ['amber', 'cobalt']);
  });

  test('a draft defaults to on and carries an explicit false', () {
    const members = <AgentsRoomMember>[];
    expect(
      const AgentsRoomDraft(name: 'x', members: members).agentToAgent,
      isTrue,
    );
    expect(
      const AgentsRoomDraft(
        name: 'x',
        members: members,
        agentToAgent: false,
      ).agentToAgent,
      isFalse,
    );
  });

  test('a room takes as many members as it is given', () {
    final many = <AgentsRoomMember>[
      for (var i = 0; i < 30; i++) _m('id$i', 'h$i'),
    ];
    final room = AgentsRoom(id: 'r1', name: 'all hands', members: many);
    expect(room.members, hasLength(30));
    expect(room.handles.last, 'h29');
  });

  test('agent_to_agent_off maps to its own stop reason, with a footer line',
      () {
    expect(
      AgentsRoomStop.fromWire('agent_to_agent_off'),
      AgentsRoomStop.agentToAgentOff,
    );
    expect(
      AgentsRoomStop.agentToAgentOff.label,
      'Coworkers do not reply to each other here',
    );
  });

  test('the reasons that were already known keep their labels', () {
    expect(AgentsRoomStop.fromWire('no_more_mentions'),
        AgentsRoomStop.noMoreMentions);
    expect(AgentsRoomStop.noMoreMentions.label, 'Everyone has weighed in');
    expect(AgentsRoomStop.roundsExhausted.label, 'Reached the round limit');
  });

  test('a reason this build does not know is null, not a guess', () {
    expect(AgentsRoomStop.fromWire('agent_to_agent'), isNull);
    expect(AgentsRoomStop.fromWire('who knows'), isNull);
    expect(AgentsRoomStop.fromWire(null), isNull);
  });
}
