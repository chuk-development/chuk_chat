import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cowork/models/cowork_agent.dart';
import 'package:cowork/models/cowork_room.dart';
import 'package:cowork/widgets/room_members_sheet.dart';

CoworkRoomMember _m(String id, String h) =>
    CoworkRoomMember(agentId: id, handle: h);

CoworkAgent _agent(String id, String name) =>
    CoworkAgent(id: id, name: name, threads: const <CoworkThreadInfo>[]);

CoworkRoom _room(List<CoworkRoomMember> members) =>
    CoworkRoom(id: 'r1', name: 'launch', members: members);

void main() {
  Future<(List<CoworkRoomMember>, List<String>)> pump(
    WidgetTester tester, {
    required CoworkRoom room,
    required List<CoworkAgent> candidates,
  }) async {
    final added = <CoworkRoomMember>[];
    final removed = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RoomMembersSheet(
            room: room,
            candidates: candidates,
            onAdd: added.add,
            onRemove: removed.add,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (added, removed);
  }

  testWidgets('lists members and candidates with the count', (tester) async {
    await pump(
      tester,
      room: _room([_m('a', 'amber'), _m('b', 'cobalt'), _m('c', 'jade')]),
      candidates: [_agent('d', 'onyx')],
    );
    expect(find.text('@amber'), findsOneWidget);
    expect(find.text('@cobalt'), findsOneWidget);
    expect(find.text('onyx'), findsOneWidget);
    expect(find.text('3/6'), findsOneWidget);
  });

  testWidgets('adding a candidate fires onAdd with the member', (tester) async {
    final (added, _) = await pump(
      tester,
      room: _room([_m('a', 'amber'), _m('b', 'cobalt')]),
      candidates: [_agent('c', 'jade')],
    );
    await tester.tap(find.byIcon(Icons.add_circle_outline));
    expect(added, hasLength(1));
    expect(added.single.agentId, 'c');
    expect(added.single.handle, 'jade');
  });

  testWidgets('removing a member fires onRemove above the minimum',
      (tester) async {
    final (_, removed) = await pump(
      tester,
      room: _room([_m('a', 'amber'), _m('b', 'cobalt'), _m('c', 'jade')]),
      candidates: const [],
    );
    await tester.tap(find.byIcon(Icons.remove_circle_outline).first);
    expect(removed, ['a']);
  });

  testWidgets('remove is disabled at two members', (tester) async {
    await pump(
      tester,
      room: _room([_m('a', 'amber'), _m('b', 'cobalt')]),
      candidates: const [],
    );
    final buttons = tester.widgetList<IconButton>(
      find.widgetWithIcon(IconButton, Icons.remove_circle_outline),
    );
    expect(buttons, isNotEmpty);
    expect(buttons.every((b) => b.onPressed == null), isTrue);
  });

  testWidgets('add is disabled when the room is full', (tester) async {
    await pump(
      tester,
      room: _room([for (var i = 0; i < 6; i++) _m('id$i', 'h$i')]),
      candidates: [_agent('x', 'extra')],
    );
    expect(find.text('6/6'), findsOneWidget);
    final add = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.add_circle_outline),
    );
    expect(add.onPressed, isNull);
  });

  testWidgets('an empty candidate list says so', (tester) async {
    await pump(
      tester,
      room: _room([_m('a', 'amber'), _m('b', 'cobalt')]),
      candidates: const [],
    );
    expect(find.text('No other coworkers to add.'), findsOneWidget);
  });
}
