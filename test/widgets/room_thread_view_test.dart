import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/agents_room.dart';
import 'package:chuk_chat/widgets/room_thread_view.dart';

void main() {
  Future<void> pump(
    WidgetTester tester, {
    required List<AgentsRoomTurn> turns,
    List<AgentsRoomMember> members = const <AgentsRoomMember>[],
    AgentsRoomStop? stop,
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
        AgentsRoomTurn(round: 1, agentId: 'a', handle: 'amber', text: 'ship it'),
        AgentsRoomTurn(round: 1, agentId: 'b', handle: 'cobalt', text: 'agreed'),
      ],
      stop: AgentsRoomStop.noMoreMentions,
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
        AgentsRoomTurn(round: 1, agentId: 'a', handle: 'amber', text: 'x'),
        AgentsRoomTurn(round: 2, agentId: 'b', handle: 'cobalt', text: 'y'),
      ],
      stop: AgentsRoomStop.noMoreMentions,
    );

    expect(find.text('Round 1'), findsOneWidget);
    expect(find.text('Round 2'), findsOneWidget);
  });

  testWidgets('a single round shows only one round divider', (tester) async {
    await pump(
      tester,
      turns: const [
        AgentsRoomTurn(round: 1, agentId: 'a', handle: 'amber', text: 'x'),
        AgentsRoomTurn(round: 1, agentId: 'b', handle: 'cobalt', text: 'y'),
      ],
      stop: AgentsRoomStop.noMoreMentions,
    );
    expect(find.text('Round 1'), findsOneWidget);
    expect(find.text('Round 2'), findsNothing);
  });

  testWidgets('the stop footer names why it ended', (tester) async {
    await pump(
      tester,
      turns: const [
        AgentsRoomTurn(round: 3, agentId: 'a', handle: 'amber', text: 'x'),
      ],
      stop: AgentsRoomStop.roundsExhausted,
    );
    expect(find.text('Reached the round limit'), findsOneWidget);
  });

  testWidgets('a running room shows the talking indicator, no footer',
      (tester) async {
    await pump(
      tester,
      turns: const [
        AgentsRoomTurn(round: 1, agentId: 'a', handle: 'amber', text: 'x'),
      ],
      running: true,
    );
    expect(find.text('the room is talking…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.textContaining('Reached'), findsNothing);
  });

  test('stop reasons parse from the wire and carry a label', () {
    expect(AgentsRoomStop.fromWire('rounds_exhausted'),
        AgentsRoomStop.roundsExhausted);
    expect(AgentsRoomStop.fromWire('messages_exhausted'),
        AgentsRoomStop.messagesExhausted);
    expect(AgentsRoomStop.fromWire('stopped'), AgentsRoomStop.stopped);
    expect(AgentsRoomStop.fromWire('turn_failed'), AgentsRoomStop.turnFailed);
    expect(AgentsRoomStop.fromWire('no_more_mentions'),
        AgentsRoomStop.noMoreMentions);
    expect(AgentsRoomStop.fromWire('who knows'), isNull);
    expect(AgentsRoomStop.fromWire(null), isNull);
    expect(AgentsRoomStop.messagesExhausted.label, 'Reached the message limit');
  });

  testWidgets('the member strip shows each members handle', (tester) async {
    await pump(
      tester,
      turns: const [],
      members: const [
        AgentsRoomMember(agentId: 'a', handle: 'amber'),
        AgentsRoomMember(agentId: 'b', handle: 'cobalt'),
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
