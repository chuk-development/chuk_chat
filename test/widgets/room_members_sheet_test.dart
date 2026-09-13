import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/icon_finder.dart';

import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/models/agents_room.dart';
import 'package:chuk_chat/widgets/room_members_sheet.dart';

AgentsRoomMember _m(String id, String h) =>
    AgentsRoomMember(agentId: id, handle: h);

AgentsAgent _agent(String id, String name) =>
    AgentsAgent(id: id, name: name, threads: const <AgentsThreadInfo>[]);

AgentsRoom _room(List<AgentsRoomMember> members) =>
    AgentsRoom(id: 'r1', name: 'launch', members: members);

void main() {
  Future<(List<AgentsRoomMember>, List<String>)> pump(
    WidgetTester tester, {
    required AgentsRoom room,
    required List<AgentsAgent> candidates,
  }) async {
    final added = <AgentsRoomMember>[];
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
    await tester.tap(findIcon(Icons.add_circle_outline));
    expect(added, hasLength(1));
    expect(added.single.agentId, 'c');
    expect(added.single.handle, 'jade');
  });

  testWidgets('removing a member fires onRemove above the minimum', (
    tester,
  ) async {
    final (_, removed) = await pump(
      tester,
      room: _room([_m('a', 'amber'), _m('b', 'cobalt'), _m('c', 'jade')]),
      candidates: const [],
    );
    await tester.tap(findIcon(Icons.remove_circle_outline).first);
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

  testWidgets('a long member list scrolls under an open keyboard', (
    tester,
  ) async {
    // A short phone with the keyboard up: 360x640 minus a 300 px inset. Twelve
    // members do not fit, so the sheet must scroll instead of overflowing.
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final room = _room([for (var i = 0; i < 12; i++) _m('id$i', 'h$i')]);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(viewInsets: const EdgeInsets.only(bottom: 300)),
            child: Scaffold(
              body: RoomMembersSheet(
                room: room,
                candidates: [_agent('x', 'extra')],
                onAdd: (_) {},
                onRemove: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Nothing ran off the edge: a Column of bare rows threw a RenderFlex
    // overflow here before the list became scrollable.
    expect(tester.takeException(), isNull);

    // The last member starts below the fold ...
    final screen =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    expect(tester.getRect(find.text('@h11')).top, greaterThan(screen - 300));

    // ... and scrolling brings it, and the candidate list under it, into view.
    final list = find.byType(ListView);
    expect(list, findsOneWidget);
    await tester.drag(list, const Offset(0, -1500));
    await tester.pumpAndSettle();

    expect(tester.getRect(find.text('@h11')).bottom, lessThan(screen - 300));
    expect(find.text('extra'), findsOneWidget);
    expect(tester.takeException(), isNull);
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
