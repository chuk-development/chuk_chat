import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/agents_room.dart';
import 'package:chuk_chat/services/agents/room_source.dart';

AgentsRoomMember _m(String id, String handle) =>
    AgentsRoomMember(agentId: id, handle: handle);

AgentsRoomDraft _draft(
  String name, {
  List<AgentsRoomMember>? members,
  bool agentToAgent = true,
}) =>
    AgentsRoomDraft(
      name: name,
      members: members ?? [_m('a', 'amber'), _m('b', 'cobalt')],
      agentToAgent: agentToAgent,
    );

void main() {
  test('addRoom assigns an id, lists the room, and notifies', () {
    final source = LocalRoomSource(random: Random(1));
    var notified = 0;
    source.addListener(() => notified++);

    final room = source.addRoom(_draft('launch'));
    expect(room.id, isNotEmpty);
    expect(room.name, 'launch');
    expect(room.handles, ['amber', 'cobalt']);
    expect(source.rooms, hasLength(1));
    expect(source.byId(room.id), isNotNull);
    expect(notified, 1);
  });

  test('the name is trimmed and an empty name is refused', () {
    final source = LocalRoomSource(random: Random(2));
    expect(source.addRoom(_draft('  launch  ')).name, 'launch');
    expect(() => source.addRoom(_draft('   ')), throwsArgumentError);
  });

  test('a room needs at least two members', () {
    final source = LocalRoomSource(random: Random(3));
    expect(
      () => source.addRoom(_draft('x', members: [_m('a', 'amber')])),
      throwsArgumentError,
    );
  });

  test('there is no member ceiling: a twelve-member room is created and listed',
      () {
    final source = LocalRoomSource(random: Random(4));
    final twelve = [for (var i = 0; i < 12; i++) _m('id$i', 'h$i')];
    final room = source.addRoom(_draft('all hands', members: twelve));
    expect(room.members, hasLength(12));
    expect(source.rooms.single.members, hasLength(12));
    expect(source.byId(room.id)!.handles.last, 'h11');
  });

  test('a draft carries its agent_to_agent policy onto the created room', () {
    final source = LocalRoomSource(random: Random(40));
    expect(source.addRoom(_draft('on')).agentToAgent, isTrue);
    expect(
      source.addRoom(_draft('off', agentToAgent: false)).agentToAgent,
      isFalse,
    );
  });

  test('setAgentToAgent flips the policy, notifies once, ignores an unknown id',
      () {
    final source = LocalRoomSource(random: Random(41));
    final room = source.addRoom(_draft('launch'));
    var notified = 0;
    source.addListener(() => notified++);

    source.setAgentToAgent(room.id, false);
    expect(source.byId(room.id)!.agentToAgent, isFalse);
    expect(notified, 1);

    source.setAgentToAgent(room.id, false); // same -> no notify
    expect(notified, 1);

    source.setAgentToAgent(room.id, true);
    expect(source.byId(room.id)!.agentToAgent, isTrue);
    expect(notified, 2);

    source.setAgentToAgent('nope', false); // unknown -> no-op
    expect(notified, 2);
  });

  test('the policy survives a rename and a member change', () {
    final source = LocalRoomSource(random: Random(42));
    final room = source.addRoom(_draft('launch', agentToAgent: false));
    source.renameRoom(room.id, 'ops');
    expect(source.byId(room.id)!.agentToAgent, isFalse);
    source.addMemberToRoom(room.id, _m('c', 'jade'));
    expect(source.byId(room.id)!.agentToAgent, isFalse);
    source.removeMemberFromRoom(room.id, 'c');
    expect(source.byId(room.id)!.agentToAgent, isFalse);
  });

  test('duplicate handle or agent is refused', () {
    final source = LocalRoomSource(random: Random(5));
    expect(
      () => source.addRoom(
        _draft('x', members: [_m('a', 'amber'), _m('b', 'amber')]),
      ),
      throwsArgumentError,
    );
    expect(
      () => source.addRoom(
        _draft('x', members: [_m('a', 'amber'), _m('a', 'cobalt')]),
      ),
      throwsArgumentError,
    );
  });

  test('removeRoom drops it and notifies only on a real removal', () {
    final source = LocalRoomSource(random: Random(6));
    final room = source.addRoom(_draft('launch'));
    var notified = 0;
    source.addListener(() => notified++);

    source.removeRoom('nope');
    expect(notified, 0);

    source.removeRoom(room.id);
    expect(notified, 1);
    expect(source.rooms, isEmpty);
  });

  test('members list is unmodifiable on the stored room', () {
    final source = LocalRoomSource(random: Random(7));
    final room = source.addRoom(_draft('launch'));
    expect(() => room.members.add(_m('c', 'jade')), throwsUnsupportedError);
  });

  test('renameRoom updates the name, trims, and notifies on a real change', () {
    final source = LocalRoomSource(random: Random(8));
    final room = source.addRoom(_draft('old'));
    var notified = 0;
    source.addListener(() => notified++);

    source.renameRoom(room.id, '  new  ');
    expect(source.byId(room.id)!.name, 'new');
    expect(notified, 1);

    source.renameRoom(room.id, 'new'); // same -> no notify
    expect(notified, 1);
    source.renameRoom(room.id, '   '); // blank -> ignored
    expect(notified, 1);
    source.renameRoom('nope', 'x'); // unknown -> ignored
    expect(notified, 1);
  });

  test('removeAgentFromRooms shrinks a big room and deletes a sub-2 one', () {
    final source = LocalRoomSource(random: Random(20));
    // Room A: 3 members incl. amber -> shrinks to 2.
    final a = source.addRoom(AgentsRoomDraft(name: 'A', members: [
      _m('amber', 'amber'),
      _m('b', 'cobalt'),
      _m('c', 'jade'),
    ]));
    // Room B: 2 members incl. amber -> falls to 1, deleted.
    final b = source.addRoom(AgentsRoomDraft(name: 'B', members: [
      _m('amber', 'amber'),
      _m('d', 'onyx'),
    ]));

    final deleted = source.removeAgentFromRooms('amber');
    expect(deleted, [b.id]);
    expect(source.byId(b.id), isNull);
    final roomA = source.byId(a.id)!;
    expect(roomA.members.map((m) => m.handle), ['cobalt', 'jade']);
  });

  test('removeAgentFromRooms is a no-op when the agent is in no room', () {
    final source = LocalRoomSource(random: Random(21));
    source.addRoom(_draft('A'));
    var notified = 0;
    source.addListener(() => notified++);
    expect(source.removeAgentFromRooms('nobody'), isEmpty);
    expect(notified, 0);
  });

  test('addMemberToRoom adds, refuses a duplicate, and has no ceiling', () {
    final source = LocalRoomSource(random: Random(30));
    final room = source.addRoom(_draft('r')); // amber, cobalt
    source.addMemberToRoom(room.id, _m('c', 'jade'));
    expect(source.byId(room.id)!.members.map((m) => m.handle),
        ['amber', 'cobalt', 'jade']);

    // Duplicate agent -> ignored.
    source.addMemberToRoom(room.id, _m('c', 'other'));
    expect(source.byId(room.id)!.members.length, 3);
    // Duplicate handle -> ignored.
    source.addMemberToRoom(room.id, _m('zz', 'jade'));
    expect(source.byId(room.id)!.members.length, 3);

    // Past the old six-member wall and on to twenty: nothing is refused.
    for (var i = 0; i < 17; i++) {
      source.addMemberToRoom(room.id, _m('extra$i', 'extra$i'));
    }
    expect(source.byId(room.id)!.members.length, 20);
  });

  test('removeMemberFromRoom shrinks, and deletes a sub-2 room', () {
    final source = LocalRoomSource(random: Random(31));
    final big = source.addRoom(AgentsRoomDraft(name: 'big', members: [
      _m('a', 'amber'), _m('b', 'cobalt'), _m('c', 'jade'),
    ]));
    expect(source.removeMemberFromRoom(big.id, 'a'), isFalse);
    expect(source.byId(big.id)!.members.map((m) => m.handle), ['cobalt', 'jade']);

    // Removing again drops to 1 -> the room is deleted.
    expect(source.removeMemberFromRoom(big.id, 'b'), isTrue);
    expect(source.byId(big.id), isNull);
  });
}
