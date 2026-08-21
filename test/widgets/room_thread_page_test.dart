import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cowork/services/cowork/cowork_relay_client.dart';
import 'package:cowork/widgets/room_thread_page.dart';

void main() {
  Future<StreamController<CoworkRelayInbound>> pump(WidgetTester tester) async {
    final ctrl = StreamController<CoworkRelayInbound>.broadcast();
    addTearDown(ctrl.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RoomThreadPage(
            roomId: 'r1',
            roomName: 'launch',
            userMessage: 'what is the plan?',
            inbound: ctrl.stream,
          ),
        ),
      ),
    );
    await tester.pump();
    return ctrl;
  }

  testWidgets('starts running with no turns, then accumulates arrivals',
      (tester) async {
    final ctrl = await pump(tester);

    // Running from the start: no stop footer, a talking indicator.
    expect(find.text('the room is talking…'), findsOneWidget);
    expect(find.text('@amber'), findsNothing);

    ctrl.add(
      const CoworkRelayRoomTurn(
        roomId: 'r1',
        round: 1,
        agentId: 'a',
        handle: 'amber',
        text: 'ship it',
      ),
    );
    await tester.pump();
    expect(find.text('@amber'), findsOneWidget);
    expect(find.text('ship it'), findsOneWidget);

    ctrl.add(
      const CoworkRelayRoomTurn(
        roomId: 'r1',
        round: 2,
        agentId: 'b',
        handle: 'cobalt',
        text: 'agreed',
      ),
    );
    await tester.pump();
    expect(find.text('Round 1'), findsOneWidget);
    expect(find.text('Round 2'), findsOneWidget);
    expect(find.text('@cobalt'), findsOneWidget);
  });

  testWidgets('room_done stops the running state and names the reason',
      (tester) async {
    final ctrl = await pump(tester);
    ctrl.add(
      const CoworkRelayRoomTurn(
        roomId: 'r1',
        round: 1,
        agentId: 'a',
        handle: 'amber',
        text: 'x',
      ),
    );
    ctrl.add(const CoworkRelayRoomDone(roomId: 'r1', reason: 'rounds_exhausted'));
    await tester.pump();

    expect(find.text('the room is talking…'), findsNothing);
    expect(find.text('Reached the round limit'), findsOneWidget);
  });

  testWidgets('non-room events on the stream are ignored', (tester) async {
    final ctrl = await pump(tester);
    ctrl.add(const CoworkRelayDelta('agent-thread text'));
    ctrl.add(const CoworkRelayDone());
    await tester.pump();

    // Still running, no turns — the agent-thread events did not leak in.
    expect(find.text('the room is talking…'), findsOneWidget);
    expect(find.textContaining('agent-thread text'), findsNothing);
  });

  testWidgets('a turn for another room is ignored', (tester) async {
    final ctrl = await pump(tester); // this page is room r1
    ctrl.add(
      const CoworkRelayRoomTurn(
        roomId: 'r2',
        round: 1,
        agentId: 'z',
        handle: 'zed',
        text: 'other room',
      ),
    );
    await tester.pump();
    expect(find.text('@zed'), findsNothing);
    expect(find.text('other room'), findsNothing);
    // A done for another room does not stop this one either.
    ctrl.add(const CoworkRelayRoomDone(roomId: 'r2', reason: 'stopped'));
    await tester.pump();
    expect(find.text('the room is talking…'), findsOneWidget);
  });

  testWidgets('an unknown stop reason leaves no footer but stops running',
      (tester) async {
    final ctrl = await pump(tester);
    ctrl.add(const CoworkRelayRoomDone(roomId: 'r1', reason: 'who_knows'));
    await tester.pump();
    // fromWire returns null -> no footer, and not running (no indicator).
    expect(find.text('the room is talking…'), findsNothing);
    expect(find.textContaining('Reached'), findsNothing);
  });
}
