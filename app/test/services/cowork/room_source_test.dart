import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:cowork/models/cowork_room.dart';
import 'package:cowork/services/cowork/room_source.dart';

CoworkRoomMember _m(String id, String handle) =>
    CoworkRoomMember(agentId: id, handle: handle);

CoworkRoomDraft _draft(
  String name, {
  List<CoworkRoomMember>? members,
}) =>
    CoworkRoomDraft(
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
}
