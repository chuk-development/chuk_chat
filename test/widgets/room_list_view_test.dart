import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cowork/models/cowork_room.dart';
import 'package:cowork/services/cowork/room_source.dart';
import 'package:cowork/widgets/room_list_view.dart';

CoworkRoomMember _m(String id, String handle) =>
    CoworkRoomMember(agentId: id, handle: handle);

CoworkRoomDraft _draft(String name, int members) => CoworkRoomDraft(
      name: name,
      members: [for (var i = 0; i < members; i++) _m('id$name$i', '$name-$i')],
    );

void main() {
  Future<List<String>> pump(
    WidgetTester tester,
    RoomSource source, {
    VoidCallback? onCreate,
    String? selectedRoomId,
  }) async {
    final picks = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RoomListView(
            source: source,
            onCreate: onCreate,
            selectedRoomId: selectedRoomId,
            onSelect: picks.add,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return picks;
  }

  testWidgets('an empty list says so and offers New room', (tester) async {
    var created = 0;
    await pump(tester, LocalRoomSource(), onCreate: () => created++);
    expect(find.text('No rooms yet.'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'New room'));
    expect(created, 1);
  });

  testWidgets('rooms list with name and member count; tapping selects',
      (tester) async {
    final source = LocalRoomSource(random: Random(1));
    final a = source.addRoom(_draft('launch', 2));
    source.addRoom(_draft('ops', 4));
    final picks = await pump(tester, source);

    expect(find.text('launch'), findsOneWidget);
    expect(find.text('2 members'), findsOneWidget);
    expect(find.text('ops'), findsOneWidget);
    expect(find.text('4 members'), findsOneWidget);

    await tester.tap(find.text('launch'));
    expect(picks, [a.id]);
  });

  testWidgets('a room with more than three members shows a +N chip',
      (tester) async {
    final source = LocalRoomSource(random: Random(2));
    source.addRoom(_draft('big', 5)); // 3 shown + "+2"
    await pump(tester, source);
    expect(find.text('+2'), findsOneWidget);
    expect(find.text('5 members'), findsOneWidget);
  });

  testWidgets('the create affordance is hidden when onCreate is null',
      (tester) async {
    await pump(tester, LocalRoomSource());
    expect(find.text('No rooms yet.'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'New room'), findsNothing);
    expect(find.byIcon(Icons.group_add_outlined), findsNothing);
  });

  testWidgets('adding a room updates the list live', (tester) async {
    final source = LocalRoomSource(random: Random(3));
    await pump(tester, source);
    expect(find.text('No rooms yet.'), findsOneWidget);

    source.addRoom(_draft('launch', 2));
    await tester.pumpAndSettle();
    expect(find.text('launch'), findsOneWidget);
  });
}
