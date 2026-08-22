import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cowork/models/cowork_room.dart';
import 'package:cowork/widgets/room_thread_view.dart';

void main() {
  Future<void> pump(
    WidgetTester tester, {
    required List<CoworkRoomTurn> turns,
    List<CoworkRoomMember> members = const <CoworkRoomMember>[],
    CoworkRoomStop? stop,
    bool running = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RoomThreadView(
            roomName: 'launch',
            userMessage: 'what is the plan?',
            turns: turns,
            members: members,
            stop: stop,
            running: running,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('shows the room name, the user message and each speaker',
      (tester) async {
    await pump(
      tester,
      turns: const [
        CoworkRoomTurn(round: 1, agentId: 'a', handle: 'amber', text: 'ship it'),
        CoworkRoomTurn(round: 1, agentId: 'b', handle: 'cobalt', text: 'agreed'),
      ],
      stop: CoworkRoomStop.noMoreMentions,
    );

    expect(find.text('launch'), findsOneWidget);
    expect(find.text('what is the plan?'), findsOneWidget);
    expect(find.text('@amber'), findsOneWidget);
    expect(find.text('ship it'), findsOneWidget);
    expect(find.text('@cobalt'), findsOneWidget);
  });

  testWidgets('groups turns by round with a divider per round', (tester) async {
    await pump(
      tester,
      turns: const [
        CoworkRoomTurn(round: 1, agentId: 'a', handle: 'amber', text: 'x'),
        CoworkRoomTurn(round: 2, agentId: 'b', handle: 'cobalt', text: 'y'),
      ],
      stop: CoworkRoomStop.noMoreMentions,
    );

    expect(find.text('Round 1'), findsOneWidget);
    expect(find.text('Round 2'), findsOneWidget);
  });

  testWidgets('a single round shows only one round divider', (tester) async {
    await pump(
      tester,
      turns: const [
        CoworkRoomTurn(round: 1, agentId: 'a', handle: 'amber', text: 'x'),
        CoworkRoomTurn(round: 1, agentId: 'b', handle: 'cobalt', text: 'y'),
      ],
      stop: CoworkRoomStop.noMoreMentions,
    );
    expect(find.text('Round 1'), findsOneWidget);
    expect(find.text('Round 2'), findsNothing);
  });

  testWidgets('the stop footer names why it ended', (tester) async {
    await pump(
      tester,
      turns: const [
        CoworkRoomTurn(round: 3, agentId: 'a', handle: 'amber', text: 'x'),
      ],
      stop: CoworkRoomStop.roundsExhausted,
    );
    expect(find.text('Reached the round limit'), findsOneWidget);
  });

  testWidgets('a running room shows the talking indicator, no footer',
      (tester) async {
    await pump(
      tester,
      turns: const [
        CoworkRoomTurn(round: 1, agentId: 'a', handle: 'amber', text: 'x'),
      ],
      running: true,
    );
    expect(find.text('the room is talking…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.textContaining('Reached'), findsNothing);
  });

  test('stop reasons parse from the wire and carry a label', () {
    expect(CoworkRoomStop.fromWire('rounds_exhausted'),
        CoworkRoomStop.roundsExhausted);
    expect(CoworkRoomStop.fromWire('messages_exhausted'),
        CoworkRoomStop.messagesExhausted);
    expect(CoworkRoomStop.fromWire('stopped'), CoworkRoomStop.stopped);
    expect(CoworkRoomStop.fromWire('turn_failed'), CoworkRoomStop.turnFailed);
    expect(CoworkRoomStop.fromWire('no_more_mentions'),
        CoworkRoomStop.noMoreMentions);
    expect(CoworkRoomStop.fromWire('who knows'), isNull);
    expect(CoworkRoomStop.fromWire(null), isNull);
    expect(CoworkRoomStop.messagesExhausted.label, 'Reached the message limit');
  });

  testWidgets('the member strip shows each members handle', (tester) async {
    await pump(
      tester,
      turns: const [],
      members: const [
        CoworkRoomMember(agentId: 'a', handle: 'amber'),
        CoworkRoomMember(agentId: 'b', handle: 'cobalt'),
      ],
    );
    expect(find.text('@amber'), findsOneWidget);
    expect(find.text('@cobalt'), findsOneWidget);
  });

  testWidgets('no member strip when there are no members', (tester) async {
    await pump(tester, turns: const []);
    expect(find.textContaining('@'), findsNothing);
  });
}
