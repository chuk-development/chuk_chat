import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cowork/services/cowork/cowork_relay_client.dart';
import 'package:cowork/widgets/room_thread_page.dart';

void main() {
  Future<StreamController<CoworkRelayInbound>> pump(
    WidgetTester tester, {
    void Function(String)? onSend,
    VoidCallback? onReady,
  }) async {
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
            onSend: onSend,
            onReady: onReady,
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

  testWidgets('no composer when onSend is null', (tester) async {
    await pump(tester);
    expect(find.byIcon(Icons.send), findsNothing);
  });

  testWidgets('the composer sends and resets the thread', (tester) async {
    final sent = <String>[];
    final ctrl = await pump(tester, onSend: sent.add);

    // A turn from a prior exchange is on screen.
    ctrl.add(
      const CoworkRelayRoomTurn(
        roomId: 'r1',
        round: 1,
        agentId: 'a',
        handle: 'amber',
        text: 'old turn',
      ),
    );
    await tester.pump();
    expect(find.text('old turn'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'new question');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();

    expect(sent, ['new question']);
    // Sending resets: the old turn is gone, the sent message is the subject.
    expect(find.text('old turn'), findsNothing);
    expect(find.text('new question'), findsOneWidget);
  });

  testWidgets('an empty message does not send', (tester) async {
    final sent = <String>[];
    await pump(tester, onSend: sent.add);
    await tester.enterText(find.byType(TextField), '   ');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
    expect(sent, isEmpty);
  });

  testWidgets('onReady fires once the page is up', (tester) async {
    var ready = 0;
    await pump(tester, onReady: () => ready++);
    await tester.pump(); // let the post-frame callback run
    expect(ready, 1);
  });

  testWidgets('room_history replaces the thread and marks it not running',
      (tester) async {
    final ctrl = await pump(tester);
    ctrl.add(
      const CoworkRelayRoomTurn(
        roomId: 'r1',
        round: 1,
        agentId: 'a',
        handle: 'amber',
        text: 'live turn',
      ),
    );
    await tester.pump();
    expect(find.text('live turn'), findsOneWidget);

    ctrl.add(
      const CoworkRelayRoomHistory(
        roomId: 'r1',
        turns: [
          CoworkRelayRoomTurn(
            roomId: 'r1',
            round: 1,
            agentId: 'a',
            handle: 'amber',
            text: 'stored one',
          ),
          CoworkRelayRoomTurn(
            roomId: 'r1',
            round: 2,
            agentId: 'b',
            handle: 'cobalt',
            text: 'stored two',
          ),
        ],
      ),
    );
    await tester.pump();

    // The live turn is replaced by the stored history; the exchange is over.
    expect(find.text('live turn'), findsNothing);
    expect(find.text('stored one'), findsOneWidget);
    expect(find.text('stored two'), findsOneWidget);
    expect(find.text('the room is talking…'), findsNothing);
  });

  testWidgets('an empty room_history leaves the page running and empty',
      (tester) async {
    final ctrl = await pump(tester);
    ctrl.add(const CoworkRelayRoomHistory(roomId: 'r1', turns: []));
    await tester.pump();
    expect(find.text('the room is talking…'), findsOneWidget);
  });

  testWidgets('history for another room is ignored', (tester) async {
    final ctrl = await pump(tester);
    ctrl.add(
      const CoworkRelayRoomHistory(
        roomId: 'r2',
        turns: [
          CoworkRelayRoomTurn(
            roomId: 'r2',
            round: 1,
            agentId: 'z',
            handle: 'zed',
            text: 'other',
          ),
        ],
      ),
    );
    await tester.pump();
    expect(find.text('other'), findsNothing);
  });

  testWidgets('a no_such_room done names the missing-room reason',
      (tester) async {
    final ctrl = await pump(tester);
    ctrl.add(const CoworkRelayRoomDone(roomId: 'r1', reason: 'no_such_room'));
    await tester.pump();
    expect(find.text('This room is not on your host yet'), findsOneWidget);
  });
}
