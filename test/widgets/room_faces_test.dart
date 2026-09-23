/// The room slot on the front page: several faces in one coworker-sized box,
/// and the room rows that carry it in both rosters.
///
/// The footprint is the point. A room row sits next to coworker rows, so the
/// slot it draws must be the same box a single [AgentFace] would have taken —
/// otherwise every name on the list starts on a different x.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/models/agents_room.dart';
import 'package:chuk_chat/platform_specific/mobile/mobile_agent_list.dart';
import 'package:chuk_chat/services/agents/agent_roster_source.dart';
import 'package:chuk_chat/services/agents/room_source.dart';
import 'package:chuk_chat/ui/expressive/agent_face.dart';
import 'package:chuk_chat/widgets/agent_roster_view.dart';
import 'package:chuk_chat/widgets/room_faces.dart';

AgentsRoomMember _m(String id, String handle) =>
    AgentsRoomMember(agentId: id, handle: handle);

AgentsRoomDraft _draft(String name, int members) => AgentsRoomDraft(
  name: name,
  members: <AgentsRoomMember>[
    for (int i = 0; i < members; i++) _m('$name-agent-$i', '$name$i'),
  ],
);

AgentsAgent _agent(String id, String name) => AgentsAgent(
  id: id,
  name: name,
  threads: <AgentsThreadInfo>[AgentsThreadInfo(key: '$id:main', title: name)],
);

Future<void> _pumpFaces(WidgetTester tester, int members, double size) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: RoomFaces(members: _draft('r', members).members, size: size),
        ),
      ),
    ),
  );
}

void main() {
  group('RoomFaces', () {
    for (final int members in <int>[1, 2, 3, 6, 12]) {
      testWidgets('$members members keep one 48 px slot', (tester) async {
        await _pumpFaces(tester, members, 48);
        expect(tester.getSize(find.byType(RoomFaces)), const Size(48, 48));
      });
    }

    testWidgets('a single coworker face is the same box', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: AgentFace(agent: _agent('a', 'Amber'), size: 48),
            ),
          ),
        ),
      );
      final Size single = tester.getSize(find.byType(AgentFace));
      await _pumpFaces(tester, 5, 48);
      expect(tester.getSize(find.byType(RoomFaces)), single);
    });

    testWidgets('it stacks at most two faces', (tester) async {
      await _pumpFaces(tester, 2, 48);
      expect(find.byType(ExpressiveFace), findsNWidgets(2));

      for (final int members in <int>[3, 6, 9]) {
        await _pumpFaces(tester, members, 48);
        expect(find.byType(ExpressiveFace), findsNWidgets(kRoomFacesMax));
      }
      expect(kRoomFacesMax, 2);
    });

    // The reason the stack is two and not three: a third face drops the
    // monogram to 8.4 px, and the layout suite refuses text under 10 px.
    for (final double slot in <double>[kRoomFacesInbox, kRoomFacesRail]) {
      testWidgets('a monogram in a ${slot.toInt()} px slot stays over 10 px', (
        tester,
      ) async {
        await _pumpFaces(tester, 5, slot);
        final Iterable<Text> monograms = tester.widgetList<Text>(
          find.descendant(
            of: find.byType(RoomFaces),
            matching: find.byType(Text),
          ),
        );
        expect(monograms, isNotEmpty);
        for (final Text monogram in monograms) {
          expect(monogram.style?.fontSize, greaterThanOrEqualTo(10.0));
        }
      });
    }

    testWidgets('one member fills the slot, like a coworker', (tester) async {
      await _pumpFaces(tester, 1, 48);
      expect(find.byType(ExpressiveFace), findsOneWidget);
      expect(tester.getSize(find.byType(ExpressiveFace)), const Size(48, 48));
    });

    testWidgets('every face is drawn inside the slot', (tester) async {
      await _pumpFaces(tester, 5, 48);
      final Rect slot = tester.getRect(find.byType(RoomFaces));
      for (final Element element
          in find.byType(ExpressiveFace).evaluate().toList()) {
        final Rect face = tester.getRect(find.byWidget(element.widget));
        expect(slot.contains(face.topLeft), isTrue);
        expect(slot.contains(face.bottomRight - const Offset(0.01, 0.01)),
            isTrue);
      }
    });

    test('the two faces are offset from each other, never concentric', () {
      final List<RoomFacePlacement> boxes = RoomFaces.placements(2, 48);
      expect(boxes.length, 2);
      expect(Offset(boxes[0].left, boxes[0].top), Offset.zero);
      expect(boxes[1].left, greaterThan(0));
      expect(boxes[1].top, greaterThan(0));
      for (final RoomFacePlacement b in boxes) {
        expect(b.left + b.size, lessThanOrEqualTo(48.001));
        expect(b.top + b.size, lessThanOrEqualTo(48.001));
      }
    });
  });

  group('the phone inbox lists rooms', () {
    Future<List<String>> pumpInbox(
      WidgetTester tester, {
      required AgentRosterSource roster,
      RoomSource? rooms,
      VoidCallback? onCreateRoom,
      double width = 360,
      double textScale = 1.0,
    }) async {
      final List<String> opened = <String>[];
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
              child: MobileAgentList(
                source: roster,
                rooms: rooms,
                onOpenRoom: opened.add,
                onCreateRoom: onCreateRoom,
                onAddAgent: () {},
                onSelect: (_, _) {},
                now: () => DateTime(2026, 9, 13, 12),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return opened;
    }

    testWidgets('a room is a row, and tapping it opens the room', (
      tester,
    ) async {
      final LocalAgentRosterSource roster = LocalAgentRosterSource();
      addTearDown(roster.dispose);
      roster.addAgent(name: 'Amber');
      final LocalRoomSource rooms = LocalRoomSource();
      addTearDown(rooms.dispose);
      rooms.addRoom(_draft('launch', 3));

      final List<String> opened = await pumpInbox(
        tester,
        roster: roster,
        rooms: rooms,
      );

      expect(find.text('launch'), findsOneWidget);
      expect(find.byType(MobileRoomRow), findsOneWidget);
      // Every member is named on the preview line, even the ones the stack
      // does not have room to draw.
      expect(find.text('@launch0, @launch1, @launch2'), findsOneWidget);

      await tester.tap(find.byType(MobileRoomRow));
      await tester.pumpAndSettle();
      expect(opened, <String>[rooms.rooms.single.id]);
    });

    testWidgets('a roster with no rooms is unchanged', (tester) async {
      final LocalAgentRosterSource roster = LocalAgentRosterSource();
      addTearDown(roster.dispose);
      roster.addAgent(name: 'Amber');
      final LocalRoomSource rooms = LocalRoomSource();
      addTearDown(rooms.dispose);

      await pumpInbox(tester, roster: roster, rooms: rooms);
      expect(find.byType(MobileRoomRow), findsNothing);
      expect(find.byType(MobileAgentRow), findsOneWidget);

      // And with no room source at all.
      await pumpInbox(tester, roster: roster);
      expect(find.byType(MobileRoomRow), findsNothing);
      expect(find.byType(MobileAgentRow), findsOneWidget);
    });

    testWidgets('rooms sit above the coworkers', (tester) async {
      final LocalAgentRosterSource roster = LocalAgentRosterSource();
      addTearDown(roster.dispose);
      roster.addAgent(name: 'Amber');
      final LocalRoomSource rooms = LocalRoomSource();
      addTearDown(rooms.dispose);
      rooms.addRoom(_draft('launch', 2));

      await pumpInbox(tester, roster: roster, rooms: rooms);
      expect(
        tester.getTopLeft(find.byType(MobileRoomRow)).dy,
        lessThan(tester.getTopLeft(find.byType(MobileAgentRow)).dy),
      );
    });

    testWidgets('room and coworker rows line up at 360 px and 1.3', (
      tester,
    ) async {
      final LocalAgentRosterSource roster = LocalAgentRosterSource();
      addTearDown(roster.dispose);
      roster.addAgent(name: 'Amber');
      final LocalRoomSource rooms = LocalRoomSource();
      addTearDown(rooms.dispose);
      rooms.addRoom(_draft('launch', 4));

      await pumpInbox(
        tester,
        roster: roster,
        rooms: rooms,
        textScale: 1.3,
      );
      expect(tester.takeException(), isNull);

      final Rect roomSlot = tester.getRect(find.byType(RoomFaces));
      final Rect agentSlot = tester.getRect(find.byType(AgentFace));
      expect(roomSlot.size, agentSlot.size);
      expect(roomSlot.left, agentSlot.left);

      final Rect roomRow = tester.getRect(find.byType(MobileRoomRow));
      final Rect agentRow = tester.getRect(find.byType(MobileAgentRow));
      expect(roomRow.left, agentRow.left);
      expect(roomRow.width, agentRow.width);
      expect(roomRow.width, lessThanOrEqualTo(360));
    });

    testWidgets('"+" offers a coworker and a room, coworker first', (
      tester,
    ) async {
      final LocalAgentRosterSource roster = LocalAgentRosterSource();
      addTearDown(roster.dispose);
      roster.addAgent(name: 'Amber');
      final LocalRoomSource rooms = LocalRoomSource();
      addTearDown(rooms.dispose);
      bool createdRoom = false;

      await pumpInbox(
        tester,
        roster: roster,
        rooms: rooms,
        onCreateRoom: () => createdRoom = true,
      );

      await tester.tap(find.bySemanticsIdentifier('mobile_home_add'));
      await tester.pumpAndSettle();
      expect(find.text('New coworker'), findsOneWidget);
      expect(find.text('New room'), findsOneWidget);

      await tester.tap(find.text('New room'));
      await tester.pumpAndSettle();
      expect(createdRoom, isTrue);
    });
  });

  group('the desktop roster lists rooms', () {
    testWidgets('a room row opens the room, and Control Rooms stays', (
      tester,
    ) async {
      final LocalAgentRosterSource roster = LocalAgentRosterSource();
      addTearDown(roster.dispose);
      roster.addAgent(name: 'Amber');
      final LocalRoomSource rooms = LocalRoomSource();
      addTearDown(rooms.dispose);
      rooms.addRoom(_draft('ops', 2));
      final List<String> opened = <String>[];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              child: AgentRosterView(
                source: roster,
                rooms: rooms,
                onOpenRoom: opened.add,
                onCreateRoom: () {},
                onOpenRooms: () {},
                onSelect: (_, _) {},
                now: () => DateTime(2026, 9, 13, 12),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Rooms'), findsOneWidget);
      expect(find.text('ops'), findsOneWidget);
      // The bigger room slot buys its width back from the gap: both rows start
      // their name on the same x.
      expect(
        tester.getTopLeft(find.text('ops')).dx,
        moreOrLessEquals(tester.getTopLeft(find.text('Amber')).dx, epsilon: 0.5),
      );
      expect(find.text('Control Rooms'), findsOneWidget);
      expect(find.text('New room'), findsOneWidget);

      await tester.tap(find.text('ops'));
      await tester.pumpAndSettle();
      expect(opened, <String>[rooms.rooms.single.id]);
    });

    testWidgets('no rooms means no Rooms label', (tester) async {
      final LocalAgentRosterSource roster = LocalAgentRosterSource();
      addTearDown(roster.dispose);
      roster.addAgent(name: 'Amber');
      final LocalRoomSource rooms = LocalRoomSource();
      addTearDown(rooms.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              child: AgentRosterView(
                source: roster,
                rooms: rooms,
                onOpenRoom: (_) {},
                onSelect: (_, _) {},
                now: () => DateTime(2026, 9, 13, 12),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Rooms'), findsNothing);
      expect(find.text('Amber'), findsOneWidget);
    });
  });
}
