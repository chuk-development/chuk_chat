import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/models/agents_room.dart';
import 'package:chuk_chat/ui/expressive/agent_face.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';
import 'package:chuk_chat/widgets/messenger_typing_indicator.dart';
import 'package:chuk_chat/widgets/room_thread_view.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

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

  /// A coworker's turn goes through the chat's Markdown renderer, exactly like
  /// a one-to-one answer, so its words live in a RichText.
  Finder said(String text) => find.textContaining(text, findRichText: true);

  /// The bubbles the room drew, in order.
  List<MessageBubble> bubbles(WidgetTester tester) =>
      tester.widgetList<MessageBubble>(find.byType(MessageBubble)).toList();

  /// The faces beside the bubbles — not the ones in the member strip, which is
  /// a header and draws its own.
  Finder gutterFaces() => find.byWidgetPredicate(
    (Widget w) => w is ExpressiveFace && w.size == 28,
    description: 'a face in the bubble gutter',
  );

  testWidgets('shows the room name, the user message and each speaker', (
    tester,
  ) async {
    await pump(
      tester,
      turns: const <AgentsRoomTurn>[
        AgentsRoomTurn(
          round: 1,
          agentId: 'a',
          handle: 'amber',
          text: 'ship it',
        ),
        AgentsRoomTurn(
          round: 1,
          agentId: 'b',
          handle: 'cobalt',
          text: 'agreed',
        ),
      ],
      stop: AgentsRoomStop.noMoreMentions,
    );

    expect(find.text('launch'), findsOneWidget);
    expect(find.text('what is the plan?'), findsOneWidget);
    expect(find.text('@amber'), findsOneWidget);
    expect(said('ship it'), findsOneWidget);
    expect(find.text('@cobalt'), findsOneWidget);
    expect(said('agreed'), findsOneWidget);
  });

  testWidgets(
    'the room is drawn with the chat bubble, not a bubble of its own',
    (tester) async {
      await pump(
        tester,
        turns: const <AgentsRoomTurn>[
          AgentsRoomTurn(
            round: 1,
            agentId: 'a',
            handle: 'amber',
            text: 'ship it',
          ),
        ],
        stop: AgentsRoomStop.noMoreMentions,
      );

      // One bubble for the user's line, one for the turn — the same widget the
      // one-to-one thread uses, in its messenger mode.
      final List<MessageBubble> all = bubbles(tester);
      expect(all, hasLength(2));
      expect(all.every((MessageBubble b) => b.messengerMode), isTrue);
    },
  );

  testWidgets("the user's line is the user's own bubble", (tester) async {
    await pump(tester, turns: const <AgentsRoomTurn>[]);
    final MessageBubble mine = bubbles(tester).single;
    expect(mine.isUser, isTrue);
    expect(mine.message, 'what is the plan?');
    expect(mine.senderLabel, isNull, reason: 'the user needs no name tag');
  });

  testWidgets('two different members each get a face and a name', (
    tester,
  ) async {
    await pump(
      tester,
      turns: const <AgentsRoomTurn>[
        AgentsRoomTurn(round: 1, agentId: 'a', handle: 'amber', text: 'one'),
        AgentsRoomTurn(round: 1, agentId: 'b', handle: 'cobalt', text: 'two'),
      ],
    );

    expect(gutterFaces(), findsNWidgets(2));
    expect(find.text('@amber'), findsOneWidget);
    expect(find.text('@cobalt'), findsOneWidget);

    final List<MessageBubble> turns = bubbles(tester).sublist(1);
    expect(turns.map((MessageBubble b) => b.startsNewGroup), <bool>[
      true,
      true,
    ]);
    expect(turns.map((MessageBubble b) => b.endsGroup), <bool>[true, true]);
  });

  testWidgets('a run by one member shows its face and name once', (
    tester,
  ) async {
    await pump(
      tester,
      turns: const <AgentsRoomTurn>[
        AgentsRoomTurn(round: 1, agentId: 'a', handle: 'amber', text: 'one'),
        AgentsRoomTurn(round: 2, agentId: 'a', handle: 'amber', text: 'two'),
        AgentsRoomTurn(round: 3, agentId: 'a', handle: 'amber', text: 'three'),
      ],
    );

    // Three bubbles, one face, one name: a run is one group.
    expect(said('one'), findsOneWidget);
    expect(said('two'), findsOneWidget);
    expect(said('three'), findsOneWidget);
    expect(gutterFaces(), findsOneWidget);
    expect(find.text('@amber'), findsOneWidget);

    final List<MessageBubble> turns = bubbles(tester).sublist(1);
    expect(turns.map((MessageBubble b) => b.senderLabel != null), <bool>[
      true,
      false,
      false,
    ]);
    // First / middle / last, so the run's corners connect.
    expect(turns.map((MessageBubble b) => b.startsNewGroup), <bool>[
      true,
      false,
      false,
    ]);
    expect(turns.map((MessageBubble b) => b.endsGroup), <bool>[
      false,
      false,
      true,
    ]);
  });

  testWidgets('a member who speaks again after someone else opens a new run', (
    tester,
  ) async {
    await pump(
      tester,
      turns: const <AgentsRoomTurn>[
        AgentsRoomTurn(round: 1, agentId: 'a', handle: 'amber', text: 'one'),
        AgentsRoomTurn(round: 1, agentId: 'b', handle: 'cobalt', text: 'two'),
        AgentsRoomTurn(round: 2, agentId: 'a', handle: 'amber', text: 'three'),
      ],
    );

    // Amber is named twice, because the two runs are not the same run.
    expect(find.text('@amber'), findsNWidgets(2));
    expect(gutterFaces(), findsNWidgets(3));
  });

  testWidgets('the face lines up with the name, and the runs breathe', (
    tester,
  ) async {
    await pump(
      tester,
      turns: const <AgentsRoomTurn>[
        AgentsRoomTurn(round: 1, agentId: 'a', handle: 'amber', text: 'one'),
        AgentsRoomTurn(round: 1, agentId: 'a', handle: 'amber', text: 'two'),
        AgentsRoomTurn(round: 2, agentId: 'b', handle: 'cobalt', text: 'three'),
      ],
    );

    // The face opens the run at the same height as the handle over it.
    expect(
      tester.getRect(gutterFaces().first).top,
      tester.getRect(find.text('@amber')).top,
    );

    // A continuation adds only the in-run gap; a new run adds the between-run
    // gap plus its name. So the second step down the thread is the bigger one.
    final Rect first = tester.getRect(find.byType(MessageBubble).at(1));
    final Rect second = tester.getRect(find.byType(MessageBubble).at(2));
    final Rect third = tester.getRect(find.byType(MessageBubble).at(3));
    expect(second.height, lessThan(first.height));
    expect(third.height, greaterThan(second.height));
  });

  testWidgets('there is no round divider', (tester) async {
    // The round is how the host walks its loop, not something the reader needs
    // between two messages; the names already say who answered whom.
    await pump(
      tester,
      turns: const <AgentsRoomTurn>[
        AgentsRoomTurn(round: 1, agentId: 'a', handle: 'amber', text: 'x'),
        AgentsRoomTurn(round: 2, agentId: 'b', handle: 'cobalt', text: 'y'),
        AgentsRoomTurn(round: 3, agentId: 'c', handle: 'ash', text: 'z'),
      ],
      stop: AgentsRoomStop.roundsExhausted,
    );
    expect(find.textContaining('Round'), findsNothing);
    expect(find.byType(Divider), findsNothing);
  });

  testWidgets('the stop line names why it ended, for every reason', (
    tester,
  ) async {
    for (final AgentsRoomStop stop in AgentsRoomStop.values) {
      await pump(
        tester,
        turns: const <AgentsRoomTurn>[
          AgentsRoomTurn(round: 3, agentId: 'a', handle: 'amber', text: 'x'),
        ],
        stop: stop,
      );
      expect(find.text(stop.label), findsOneWidget, reason: '$stop');
      // A system line, not a rule across the thread.
      expect(find.byType(Divider), findsNothing, reason: '$stop');
    }
  });

  testWidgets('the agent-to-agent policy reads as a calm system line', (
    tester,
  ) async {
    // The room ended because a coworker's @mention was not followed: the policy
    // is off. The line is the only place the user learns that.
    await pump(
      tester,
      turns: const <AgentsRoomTurn>[
        AgentsRoomTurn(round: 1, agentId: 'a', handle: 'amber', text: 'x'),
      ],
      stop: AgentsRoomStop.agentToAgentOff,
    );
    final Finder line = find.text('Coworkers do not reply to each other here');
    expect(line, findsOneWidget);
    // Not an error: it is drawn in the quiet colour, like the other reasons.
    final ColorScheme scheme = Theme.of(tester.element(line)).colorScheme;
    expect(tester.widget<Text>(line).style?.color, scheme.onSurfaceVariant);
  });

  testWidgets('a failed turn says so in the error colour', (tester) async {
    await pump(
      tester,
      turns: const <AgentsRoomTurn>[
        AgentsRoomTurn(round: 1, agentId: 'a', handle: 'amber', text: 'x'),
      ],
      stop: AgentsRoomStop.turnFailed,
    );
    final Finder line = find.text("A coworker's turn failed");
    final ColorScheme scheme = Theme.of(tester.element(line)).colorScheme;
    expect(tester.widget<Text>(line).style?.color, scheme.error);
  });

  testWidgets('a running room shows the chat typing pill, no stop line', (
    tester,
  ) async {
    await pump(
      tester,
      turns: const <AgentsRoomTurn>[
        AgentsRoomTurn(round: 1, agentId: 'a', handle: 'amber', text: 'x'),
      ],
      running: true,
    );
    expect(find.byType(MessengerTypingIndicator), findsOneWidget);
    expect(find.textContaining('Reached'), findsNothing);
  });

  test('stop reasons parse from the wire and carry a label', () {
    expect(
      AgentsRoomStop.fromWire('rounds_exhausted'),
      AgentsRoomStop.roundsExhausted,
    );
    expect(
      AgentsRoomStop.fromWire('messages_exhausted'),
      AgentsRoomStop.messagesExhausted,
    );
    expect(AgentsRoomStop.fromWire('stopped'), AgentsRoomStop.stopped);
    expect(AgentsRoomStop.fromWire('turn_failed'), AgentsRoomStop.turnFailed);
    expect(
      AgentsRoomStop.fromWire('no_more_mentions'),
      AgentsRoomStop.noMoreMentions,
    );
    expect(AgentsRoomStop.fromWire('who knows'), isNull);
    expect(AgentsRoomStop.fromWire(null), isNull);
    expect(AgentsRoomStop.messagesExhausted.label, 'Reached the message limit');
  });

  testWidgets('the member strip shows each members handle', (tester) async {
    await pump(
      tester,
      turns: const <AgentsRoomTurn>[],
      members: const <AgentsRoomMember>[
        AgentsRoomMember(agentId: 'a', handle: 'amber'),
        AgentsRoomMember(agentId: 'b', handle: 'cobalt'),
      ],
    );
    expect(find.text('@amber'), findsOneWidget);
    expect(find.text('@cobalt'), findsOneWidget);
  });

  testWidgets('no member strip when there are no members', (tester) async {
    await pump(tester, turns: const <AgentsRoomTurn>[]);
    expect(find.textContaining('@'), findsNothing);
  });

  testWidgets('a narrow room at a big text scale does not overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
          child: Scaffold(
            body: RoomThreadView(
              roomName: 'launch week war room',
              userMessage: 'what is the plan for the launch on friday?',
              turns: const <AgentsRoomTurn>[
                AgentsRoomTurn(
                  round: 1,
                  agentId: 'a',
                  handle: 'amberlynnfitzgerald',
                  text: 'we ship on friday, after the smoke test passes',
                ),
              ],
              members: const <AgentsRoomMember>[
                AgentsRoomMember(agentId: 'a', handle: 'amberlynnfitzgerald'),
                AgentsRoomMember(agentId: 'b', handle: 'cobalt'),
              ],
              stop: AgentsRoomStop.noMoreMentions,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
