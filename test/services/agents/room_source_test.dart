import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/agents_room.dart';
import 'package:chuk_chat/services/agents/room_source.dart';

AgentsRoomMember _m(String id, String handle) =>
    AgentsRoomMember(agentId: id, handle: handle);

AgentsRoomDraft _draft(
  String name, {
  List<AgentsRoomMember>? members,
}) =>
    AgentsRoomDraft(
      name: name,
      members: members ?? [_m('a', 'amber'), _m('b', 'cobalt')],
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

  test('the six-member cap is enforced defensively', () {
    final source = LocalRoomSource(random: Random(4));
    final seven = [for (var i = 0; i < 7; i++) _m('id$i', 'h$i')];
    expect(
      () => source.addRoom(_draft('big', members: seven)),
      throwsArgumentError,
    );
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

  test('addMemberToRoom adds, and refuses full/duplicate', () {
    final source = LocalRoomSource(random: Random(30));
    final room = source.addRoom(_draft('r')); // amber, cobalt
    source.addMemberToRoom(room.id, _m('c', 'jade'));
    expect(source.byId(room.id)!.members.map((m) => m.handle),
        ['amber', 'cobalt', 'jade']);

    // Duplicate agent -> ignored.
    source.addMemberToRoom(room.id, _m('c', 'other'));
    expect(source.byId(room.id)!.members.length, 3);

    // Fill to six, then a seventh is refused.
    source.addMemberToRoom(room.id, _m('d', 'onyx'));
    source.addMemberToRoom(room.id, _m('e', 'slate'));
    source.addMemberToRoom(room.id, _m('f', 'teal'));
    expect(source.byId(room.id)!.members.length, 6);
    source.addMemberToRoom(room.id, _m('g', 'rust'));
    expect(source.byId(room.id)!.members.length, 6);
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
