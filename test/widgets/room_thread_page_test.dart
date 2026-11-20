import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:shared_preferences/shared_preferences.dart';

import '../support/icon_finder.dart';

import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/models/agents_room.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/widgets/chat_composer_box.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';
import 'package:chuk_chat/widgets/messenger_typing_indicator.dart';
import 'package:chuk_chat/widgets/room_mention_picker.dart';
import 'package:chuk_chat/widgets/room_thread_page.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  /// The room is still talking: the chat's own typing pill, as in a one-to-one
  /// thread. There is no worded status line any more.
  Finder talking() => find.byType(MessengerTypingIndicator);

  /// An agent's turn goes through the chat's Markdown renderer, so its words
  /// live in a RichText.
  Finder said(String text) => find.textContaining(text, findRichText: true);

  /// The composer's send target — the chat's, so it is the north arrow.
  Finder sendButton() => findIcon(Icons.north_rounded);

  Future<StreamController<AgentsRelayInbound>> pump(
    WidgetTester tester, {
    void Function(String)? onSend,
    VoidCallback? onReady,
  }) async {
    final ctrl = StreamController<AgentsRelayInbound>.broadcast();
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

  testWidgets('starts running with no turns, then accumulates arrivals', (
    tester,
  ) async {
    final ctrl = await pump(tester);

    // Running from the start: no stop footer, a talking indicator.
    expect(talking(), findsOneWidget);
    expect(find.text('@amber'), findsNothing);

    ctrl.add(
      const AgentsRelayRoomTurn(
        roomId: 'r1',
        round: 1,
        agentId: 'a',
        handle: 'amber',
        text: 'ship it',
      ),
    );
    await tester.pump();
    expect(find.text('@amber'), findsOneWidget);
    expect(said('ship it'), findsOneWidget);

    ctrl.add(
      const AgentsRelayRoomTurn(
        roomId: 'r1',
        round: 2,
        agentId: 'b',
        handle: 'cobalt',
        text: 'agreed',
      ),
    );
    await tester.pump();
    expect(said('agreed'), findsOneWidget);
    expect(find.text('@cobalt'), findsOneWidget);
    // The round is the host's loop counter, not a line in the transcript.
    expect(find.textContaining('Round'), findsNothing);
  });

  testWidgets('room_done stops the running state and names the reason', (
    tester,
  ) async {
    final ctrl = await pump(tester);
    ctrl.add(
      const AgentsRelayRoomTurn(
        roomId: 'r1',
        round: 1,
        agentId: 'a',
        handle: 'amber',
        text: 'x',
      ),
    );
    ctrl.add(
      const AgentsRelayRoomDone(roomId: 'r1', reason: 'rounds_exhausted'),
    );
    await tester.pump();

    expect(talking(), findsNothing);
    expect(find.text('Reached the round limit'), findsOneWidget);
  });

  testWidgets('non-room events on the stream are ignored', (tester) async {
    final ctrl = await pump(tester);
    ctrl.add(const AgentsRelayDelta('agent-thread text'));
    ctrl.add(const AgentsRelayDone());
    await tester.pump();

    // Still running, no turns — the agent-thread events did not leak in.
    expect(talking(), findsOneWidget);
    expect(said('agent-thread text'), findsNothing);
  });

  testWidgets('a turn for another room is ignored', (tester) async {
    final ctrl = await pump(tester); // this page is room r1
    ctrl.add(
      const AgentsRelayRoomTurn(
        roomId: 'r2',
        round: 1,
        agentId: 'z',
        handle: 'zed',
        text: 'other room',
      ),
    );
    await tester.pump();
    expect(find.text('@zed'), findsNothing);
    expect(said('other room'), findsNothing);
    // A done for another room does not stop this one either.
    ctrl.add(const AgentsRelayRoomDone(roomId: 'r2', reason: 'stopped'));
    await tester.pump();
    expect(talking(), findsOneWidget);
  });

  testWidgets('an unknown stop reason leaves no footer but stops running', (
    tester,
  ) async {
    final ctrl = await pump(tester);
    ctrl.add(const AgentsRelayRoomDone(roomId: 'r1', reason: 'who_knows'));
    await tester.pump();
    // fromWire returns null -> no footer, and not running (no indicator).
    expect(talking(), findsNothing);
    expect(find.textContaining('Reached'), findsNothing);
  });

  group('an empty room', () {
    Future<StreamController<AgentsRelayInbound>> pumpEmpty(
      WidgetTester tester, {
      void Function(String)? onSend,
    }) async {
      final ctrl = StreamController<AgentsRelayInbound>.broadcast();
      addTearDown(ctrl.close);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RoomThreadPage(
              roomId: 'r1',
              roomName: 'launch',
              emptyHint: 'Message the room to start.',
              inbound: ctrl.stream,
              onSend: onSend,
            ),
          ),
        ),
      );
      await tester.pump();
      return ctrl;
    }

    testWidgets('shows a quiet line, no bubble and no typing dots', (
      tester,
    ) async {
      await pumpEmpty(tester, onSend: (_) {});
      expect(
        find.byKey(const ValueKey<String>('room-empty-hint')),
        findsOneWidget,
      );
      expect(find.text('Message the room to start.'), findsOneWidget);
      expect(find.byType(MessageBubble), findsNothing);
      expect(talking(), findsNothing);
    });

    testWidgets('a send replaces the line with the message and the dots', (
      tester,
    ) async {
      await pumpEmpty(tester, onSend: (_) {});
      await tester.enterText(find.byType(TextField), 'kick off');
      await tester.tap(sendButton());
      await tester.pump();
      expect(
        find.byKey(const ValueKey<String>('room-empty-hint')),
        findsNothing,
      );
      expect(find.text('kick off'), findsOneWidget);
      expect(talking(), findsOneWidget);
    });

    testWidgets('a live turn hides the line and shows the room talking', (
      tester,
    ) async {
      final ctrl = await pumpEmpty(tester);
      ctrl.add(
        const AgentsRelayRoomTurn(
          roomId: 'r1',
          round: 1,
          agentId: 'a',
          handle: 'amber',
          text: 'first',
        ),
      );
      // The event lands after the first frame; the second draws it.
      await tester.pump();
      await tester.pump();
      expect(
        find.byKey(const ValueKey<String>('room-empty-hint')),
        findsNothing,
      );
      expect(talking(), findsOneWidget);
    });
  });

  testWidgets('no composer when onSend is null', (tester) async {
    await pump(tester);
    expect(sendButton(), findsNothing);
  });

  testWidgets('the composer sends and keeps the conversation', (tester) async {
    final sent = <String>[];
    final ctrl = await pump(tester, onSend: sent.add);

    // A turn from a prior exchange is on screen.
    ctrl.add(
      const AgentsRelayRoomTurn(
        roomId: 'r1',
        round: 1,
        agentId: 'a',
        handle: 'amber',
        text: 'old turn',
      ),
    );
    await tester.pump();
    expect(said('old turn'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'new question');
    await tester.tap(sendButton());
    await tester.pump();

    expect(sent, ['new question']);
    // A group reads like a group chat: the earlier turn stays, the new line
    // follows it.
    expect(said('old turn'), findsOneWidget);
    expect(find.text('new question'), findsOneWidget);
  });

  testWidgets('the composer is the chat composer, not a bare field', (
    tester,
  ) async {
    await pump(tester, onSend: (_) {});
    expect(find.byType(ChatComposerBox), findsOneWidget);
    expect(find.byType(ChatComposerField), findsOneWidget);
    // One field, inside the chat's box — no second text surface.
    expect(find.byType(TextField), findsOneWidget);
    expect(
      find.descendant(of: find.byType(ChatComposerBox), matching: sendButton()),
      findsOneWidget,
    );
  });

  testWidgets('shift+enter writes a newline and sends nothing', (tester) async {
    final sent = <String>[];
    await pump(tester, onSend: sent.add);
    await tester.enterText(find.byType(TextField), 'first line');
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();

    expect(sent, isEmpty, reason: 'shift+enter is a newline, not a send');
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      startsWith('first line'),
    );
  });

  testWidgets('an empty message does not send', (tester) async {
    final sent = <String>[];
    await pump(tester, onSend: sent.add);
    await tester.enterText(find.byType(TextField), '   ');
    await tester.tap(sendButton());
    await tester.pump();
    expect(sent, isEmpty);
  });

  testWidgets('onReady fires once the page is up', (tester) async {
    var ready = 0;
    await pump(tester, onReady: () => ready++);
    await tester.pump(); // let the post-frame callback run
    expect(ready, 1);
  });

  testWidgets('room_history replaces the thread and marks it not running', (
    tester,
  ) async {
    final ctrl = await pump(tester);
    ctrl.add(
      const AgentsRelayRoomTurn(
        roomId: 'r1',
        round: 1,
        agentId: 'a',
        handle: 'amber',
        text: 'live turn',
      ),
    );
    await tester.pump();
    expect(said('live turn'), findsOneWidget);

    ctrl.add(
      const AgentsRelayRoomHistory(
        roomId: 'r1',
        turns: [
          AgentsRelayRoomTurn(
            roomId: 'r1',
            round: 1,
            agentId: 'a',
            handle: 'amber',
            text: 'stored one',
          ),
          AgentsRelayRoomTurn(
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
    expect(said('live turn'), findsNothing);
    expect(said('stored one'), findsOneWidget);
    expect(said('stored two'), findsOneWidget);
    expect(talking(), findsNothing);
  });

  testWidgets('an empty room_history leaves the page running and empty', (
    tester,
  ) async {
    final ctrl = await pump(tester);
    ctrl.add(const AgentsRelayRoomHistory(roomId: 'r1', turns: []));
    await tester.pump();
    expect(talking(), findsOneWidget);
  });

  testWidgets('history for another room is ignored', (tester) async {
    final ctrl = await pump(tester);
    ctrl.add(
      const AgentsRelayRoomHistory(
        roomId: 'r2',
        turns: [
          AgentsRelayRoomTurn(
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
    expect(said('other'), findsNothing);
  });

  testWidgets('a no_such_room done names the missing-room reason', (
    tester,
  ) async {
    final ctrl = await pump(tester);
    ctrl.add(const AgentsRelayRoomDone(roomId: 'r1', reason: 'no_such_room'));
    await tester.pump();
    expect(find.text('This group is not on your computer yet'), findsOneWidget);
  });

  testWidgets('when the inbound stream closes, a reconnect banner appears', (
    tester,
  ) async {
    final ctrl = StreamController<AgentsRelayInbound>.broadcast(sync: true);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RoomThreadPage(
            roomId: 'r1',
            roomName: 'launch',
            userMessage: 'hi',
            inbound: ctrl.stream,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining('Connection changed'), findsNothing);

    unawaited(ctrl.close()); // the transport was rebuilt on reconnect
    await tester.pump();

    expect(
      find.text('Connection changed. Reopen the group to continue.'),
      findsOneWidget,
    );
    expect(talking(), findsNothing);
  });

  testWidgets('the composer is disabled after the stream closes', (
    tester,
  ) async {
    final ctrl = StreamController<AgentsRelayInbound>.broadcast(sync: true);
    final sent = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RoomThreadPage(
            roomId: 'r1',
            roomName: 'launch',
            userMessage: 'hi',
            inbound: ctrl.stream,
            onSend: sent.add,
          ),
        ),
      ),
    );
    await tester.pump();

    // Enabled before the drop: the field takes text and send fires.
    expect(
      tester.widget<ChatComposerField>(find.byType(ChatComposerField)).enabled,
      isTrue,
    );

    unawaited(ctrl.close());
    await tester.pump();

    // Disabled after: the field is dead and the send target does nothing.
    expect(
      tester.widget<ChatComposerField>(find.byType(ChatComposerField)).enabled,
      isFalse,
    );
    await tester.tap(sendButton());
    await tester.pump();
    expect(sent, isEmpty);
    expect(find.text('Reopen the group to send'), findsOneWidget);
  });

  testWidgets('following the rebind, a new controller re-subscribes the room', (
    tester,
  ) async {
    final first = _FakeController();
    final notifier = ValueNotifier<AgentsRelayController?>(first);
    addTearDown(notifier.dispose);
    addTearDown(first.close);
    var readyCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RoomThreadPage(
            roomId: 'r1',
            roomName: 'launch',
            userMessage: 'hi',
            inbound: first.inbound,
            rebind: notifier,
            onReady: () => readyCalls++,
          ),
        ),
      ),
    );
    await tester.pump();

    first.emit(
      const AgentsRelayRoomTurn(
        roomId: 'r1',
        round: 1,
        agentId: 'a',
        handle: 'amber',
        text: 'on first',
      ),
    );
    await tester.pump();
    expect(find.text('on first'), findsOneWidget);

    // Reconnect: a new controller arrives. The page follows it.
    final second = _FakeController();
    addTearDown(second.close);
    notifier.value = second;
    await tester.pump();

    // onReady re-ran on the swap (re-create + re-request history).
    expect(readyCalls, greaterThanOrEqualTo(1));
    // A turn on the NEW controller renders -> we re-subscribed.
    second.emit(
      const AgentsRelayRoomTurn(
        roomId: 'r1',
        round: 1,
        agentId: 'b',
        handle: 'cobalt',
        text: 'on second',
      ),
    );
    await tester.pump();
    expect(find.text('on second'), findsOneWidget);
    // No dead-room banner: the rebind recovered it.
    expect(find.textContaining('Connection changed'), findsNothing);
  });

  group('the @mention picker', () {
    const List<AgentsRoomMember> trio = <AgentsRoomMember>[
      AgentsRoomMember(agentId: 'a', handle: 'amber'),
      AgentsRoomMember(agentId: 'b', handle: 'cobalt'),
      AgentsRoomMember(agentId: 'c', handle: 'ash'),
    ];

    /// The page with a room behind it. Returns what the composer sent, so a
    /// test can say "and nothing was sent" without a second fixture.
    Future<List<String>> pumpRoom(
      WidgetTester tester, {
      List<AgentsRoomMember> members = trio,
      List<AgentsAgent> agents = const <AgentsAgent>[],
    }) async {
      final ctrl = StreamController<AgentsRelayInbound>.broadcast();
      addTearDown(ctrl.close);
      final sent = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RoomThreadPage(
              roomId: 'r1',
              roomName: 'launch',
              userMessage: 'what is the plan?',
              inbound: ctrl.stream,
              members: members,
              agents: agents,
              onSend: sent.add,
            ),
          ),
        ),
      );
      await tester.pump();
      return sent;
    }

    /// Only what the picker draws — the header strip prints `@handle` too.
    Finder inPicker(String text) => find.descendant(
      of: find.byType(RoomMentionPicker),
      matching: find.text(text),
    );

    String composerText(WidgetTester tester) =>
        tester.widget<TextField>(find.byType(TextField)).controller!.text;

    testWidgets('an @ opens it on the whole room; a letter filters it', (
      tester,
    ) async {
      await pumpRoom(tester);
      expect(find.byType(RoomMentionPicker), findsNothing);

      await tester.enterText(find.byType(TextField), '@');
      await tester.pump();
      expect(find.byType(RoomMentionPicker), findsOneWidget);
      expect(inPicker('@all'), findsOneWidget);
      expect(inPicker('@amber'), findsOneWidget);
      expect(inPicker('@cobalt'), findsOneWidget);
      expect(inPicker('@ash'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '@am');
      await tester.pump();
      expect(inPicker('@amber'), findsOneWidget);
      expect(inPicker('@cobalt'), findsNothing);
      expect(inPicker('@ash'), findsNothing);
      expect(inPicker('@all'), findsNothing);

      // Nothing matches any more -> the picker closes rather than showing air.
      await tester.enterText(find.byType(TextField), '@amz');
      await tester.pump();
      expect(find.byType(RoomMentionPicker), findsNothing);
    });

    testWidgets('a name matches too, and the row shows name, handle, role', (
      tester,
    ) async {
      await pumpRoom(
        tester,
        agents: <AgentsAgent>[
          const AgentsAgent(
            id: 'b',
            name: 'Cobalt',
            role: 'release manager',
            threads: [],
          ),
        ],
      );
      await tester.enterText(find.byType(TextField), '@Cob');
      await tester.pump();
      expect(inPicker('Cobalt'), findsOneWidget);
      expect(inPicker('@cobalt'), findsOneWidget);
      expect(inPicker('release manager'), findsOneWidget);
    });

    testWidgets('an @ inside a word never opens it', (tester) async {
      await pumpRoom(tester);
      await tester.enterText(find.byType(TextField), 'write to amber@ex');
      await tester.pump();
      expect(find.byType(RoomMentionPicker), findsNothing);
    });

    testWidgets('a room with no members never opens it', (tester) async {
      await pumpRoom(tester, members: const <AgentsRoomMember>[]);
      await tester.enterText(find.byType(TextField), '@');
      await tester.pump();
      expect(find.byType(RoomMentionPicker), findsNothing);
    });

    testWidgets('escape closes it, and it stays closed inside that token', (
      tester,
    ) async {
      await pumpRoom(tester);
      await tester.enterText(find.byType(TextField), '@am');
      await tester.pump();
      expect(find.byType(RoomMentionPicker), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byType(RoomMentionPicker), findsNothing);

      // Still the same token: it does not spring back on the next letter.
      await tester.enterText(find.byType(TextField), '@amb');
      await tester.pump();
      expect(find.byType(RoomMentionPicker), findsNothing);

      // A new token opens it again.
      await tester.enterText(find.byType(TextField), '@amb @co');
      await tester.pump();
      expect(inPicker('@cobalt'), findsOneWidget);
    });

    testWidgets('a tap outside closes it', (tester) async {
      await pumpRoom(tester);
      await tester.enterText(find.byType(TextField), '@am');
      await tester.pump();
      expect(find.byType(RoomMentionPicker), findsOneWidget);

      await tester.tapAt(const Offset(200, 60)); // up in the thread
      await tester.pump();
      expect(find.byType(RoomMentionPicker), findsNothing);
    });

    testWidgets('enter accepts the highlighted row and sends nothing', (
      tester,
    ) async {
      final sent = await pumpRoom(tester);
      await tester.enterText(find.byType(TextField), 'hey @am');
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(composerText(tester), 'hey @amber ');
      expect(sent, isEmpty, reason: 'enter must not send while it is open');
      expect(find.byType(RoomMentionPicker), findsNothing);
    });

    testWidgets('enter with the picker closed sends', (tester) async {
      final sent = await pumpRoom(tester);
      await tester.enterText(find.byType(TextField), 'hey @amber what now');
      await tester.pump();
      expect(find.byType(RoomMentionPicker), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(sent, <String>['hey @amber what now']);
      expect(composerText(tester), isEmpty);
    });

    testWidgets('the arrows walk the list and tab accepts', (tester) async {
      final sent = await pumpRoom(tester);
      await tester.enterText(find.byType(TextField), '@');
      await tester.pump();

      // all -> amber -> cobalt, then back up to amber.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();

      expect(composerText(tester), '@amber ');
      expect(sent, isEmpty);
    });

    testWidgets('@all is offered and inserted', (tester) async {
      await pumpRoom(tester);
      await tester.enterText(find.byType(TextField), 'so @al');
      await tester.pump();
      expect(inPicker('Everyone'), findsOneWidget);
      expect(inPicker('3 agents'), findsOneWidget);

      await tester.tap(inPicker('Everyone'));
      await tester.pump();
      expect(composerText(tester), 'so @all ');
    });

    testWidgets('a tap on a row writes the handle mid-sentence', (
      tester,
    ) async {
      await pumpRoom(tester);
      await tester.enterText(find.byType(TextField), 'hey @co can you look');
      // The caret lands at the end after enterText, so put it back in the token.
      final TextEditingController c = tester
          .widget<TextField>(find.byType(TextField))
          .controller!;
      c.selection = const TextSelection.collapsed(offset: 7);
      await tester.pump();
      expect(find.byType(RoomMentionPicker), findsOneWidget);

      await tester.tap(inPicker('@cobalt'));
      await tester.pump();
      expect(c.text, 'hey @cobalt can you look');
      expect(c.selection.baseOffset, 12);
    });

    testWidgets('a long room stays bounded, filters, and follows the arrows', (
      tester,
    ) async {
      final List<AgentsRoomMember> many = <AgentsRoomMember>[
        for (int i = 0; i < 15; i++)
          AgentsRoomMember(agentId: 'a$i', handle: 'agent-$i'),
      ];
      await pumpRoom(tester, members: many);

      await tester.enterText(find.byType(TextField), '@');
      await tester.pump();
      final Rect box = tester.getRect(find.byType(RoomMentionPicker));
      expect(box.height, lessThanOrEqualTo(248));
      // It does not eat the thread above it.
      expect(
        box.height,
        lessThan(tester.getSize(find.byType(Scaffold)).height),
      );

      // Arrow past the visible rows: the highlighted one is scrolled into view.
      for (int i = 0; i < 9; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      }
      // One frame for the keys, one for the post-frame reveal.
      await tester.pump();
      await tester.pump();
      final Rect row = tester.getRect(inPicker('@agent-8'));
      expect(row.top, greaterThanOrEqualTo(box.top - 0.5));
      expect(row.bottom, lessThanOrEqualTo(box.bottom + 0.5));
      // …and that is the row enter takes.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(composerText(tester), '@agent-8 ');

      // Typing narrows the long list to one row.
      await tester.enterText(find.byType(TextField), '@agent-12');
      await tester.pump();
      expect(inPicker('@agent-12'), findsOneWidget);
      expect(inPicker('@agent-1'), findsNothing);
    });
  });

  group('a group reads like a group chat', () {
    // A broadcast stream delivers after the frame; the second pump draws it.
    Future<void> land(WidgetTester tester) async {
      await tester.pump();
      await tester.pump();
    }

    Future<StreamController<AgentsRelayInbound>> pumpGroup(
      WidgetTester tester, {
      void Function(String)? onSend,
      VoidCallback? onStop,
      List<AgentsAgent> agents = const <AgentsAgent>[],
    }) async {
      final ctrl = StreamController<AgentsRelayInbound>.broadcast();
      addTearDown(ctrl.close);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RoomThreadPage(
              roomId: 'r1',
              roomName: 'launch',
              inbound: ctrl.stream,
              members: const <AgentsRoomMember>[
                AgentsRoomMember(agentId: 'a', handle: 'amber'),
                AgentsRoomMember(agentId: 'b', handle: 'cobalt'),
              ],
              agents: agents,
              onSend: onSend,
              onStop: onStop,
            ),
          ),
        ),
      );
      await land(tester);
      return ctrl;
    }

    AgentsRelayRoomTurn turn(String agentId, String handle, String text) =>
        AgentsRelayRoomTurn(
          roomId: 'r1',
          round: 1,
          agentId: agentId,
          handle: handle,
          text: text,
        );

    testWidgets('two exchanges keep both user lines and every turn, in order', (
      tester,
    ) async {
      final ctrl = await pumpGroup(tester, onSend: (_) {});

      await tester.enterText(find.byType(TextField), 'first question');
      await tester.tap(sendButton());
      await land(tester);
      ctrl.add(turn('a', 'amber', 'first answer'));
      ctrl.add(
        const AgentsRelayRoomDone(roomId: 'r1', reason: 'no_more_mentions'),
      );
      await land(tester);

      await tester.enterText(find.byType(TextField), 'second question');
      await tester.tap(sendButton());
      await land(tester);
      ctrl.add(turn('b', 'cobalt', 'second answer'));
      await land(tester);

      expect(find.text('first question'), findsOneWidget);
      expect(said('first answer'), findsOneWidget);
      expect(find.text('second question'), findsOneWidget);
      expect(said('second answer'), findsOneWidget);
      // Top to bottom, the way they happened.
      final double y1 = tester.getTopLeft(find.text('first question')).dy;
      final double y2 = tester.getTopLeft(said('first answer')).dy;
      final double y3 = tester.getTopLeft(find.text('second question')).dy;
      final double y4 = tester.getTopLeft(said('second answer')).dy;
      expect(y1 < y2 && y2 < y3 && y3 < y4, isTrue);
    });

    testWidgets('history replays the whole conversation, user lines too', (
      tester,
    ) async {
      final ctrl = await pumpGroup(tester);
      ctrl.add(
        const AgentsRelayRoomHistory(
          roomId: 'r1',
          turns: [
            AgentsRelayRoomTurn(
              roomId: 'r1',
              round: 0,
              agentId: '',
              handle: '',
              text: 'what is the plan?',
              kind: 'user',
            ),
            AgentsRelayRoomTurn(
              roomId: 'r1',
              round: 1,
              agentId: 'a',
              handle: 'amber',
              text: 'we ship friday',
            ),
            AgentsRelayRoomTurn(
              roomId: 'r1',
              round: 0,
              agentId: '',
              handle: '',
              text: 'and the post?',
              kind: 'user',
            ),
          ],
        ),
      );
      await land(tester);

      final List<MessageBubble> bubbles = tester
          .widgetList<MessageBubble>(find.byType(MessageBubble))
          .toList();
      expect(bubbles.map((b) => b.isUser), [true, false, true]);
      expect(find.text('what is the plan?'), findsOneWidget);
      expect(find.text('and the post?'), findsOneWidget);
      expect(talking(), findsNothing);
    });

    testWidgets('a member is named by its roster name; an auto pick says so', (
      tester,
    ) async {
      final ctrl = await pumpGroup(
        tester,
        agents: const <AgentsAgent>[
          AgentsAgent(id: 'a', name: 'Amber', threads: <AgentsThreadInfo>[]),
        ],
      );
      ctrl.add(
        const AgentsRelayRoomTurn(
          roomId: 'r1',
          round: 1,
          agentId: 'a',
          handle: 'amber',
          text: 'picked',
          routedMode: 'auto',
          routedConfidence: 0.94,
        ),
      );
      ctrl.add(
        const AgentsRelayRoomTurn(
          roomId: 'r1',
          round: 1,
          agentId: 'b',
          handle: 'cobalt',
          text: 'unsure pick',
          routedMode: 'auto',
          routedFallback: true,
        ),
      );
      await land(tester);

      expect(find.text('Amber'), findsOneWidget);
      expect(find.text('@cobalt'), findsWidgets);
      expect(find.text('Picked by auto · 94%'), findsOneWidget);
      expect(find.text('Picked by auto (fallback)'), findsOneWidget);
    });

    testWidgets('a handoff is one quiet line with an icon, not a bubble', (
      tester,
    ) async {
      final ctrl = await pumpGroup(tester);
      ctrl.add(
        const AgentsRelayRoomTurn(
          roomId: 'r1',
          round: 1,
          agentId: 'a',
          handle: 'amber',
          text: 'write the post',
          kind: 'handoff',
          toAgentId: 'b',
          toHandle: 'cobalt',
        ),
      );
      await land(tester);

      final Finder line = find.byKey(const ValueKey<String>('room-handoff'));
      expect(line, findsOneWidget);
      expect(find.byType(MessageBubble), findsNothing);
      expect(
        find.descendant(
          of: line,
          matching: find.text('@cobalt: write the post'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: line,
          matching: findIcon(Icons.arrow_forward_rounded),
        ),
        findsOneWidget,
      );
    });

    testWidgets('room_working shows who is working until its turn lands', (
      tester,
    ) async {
      final ctrl = await pumpGroup(tester);
      ctrl.add(
        const AgentsRelayRoomWorking(
          roomId: 'r1',
          agentId: 'b',
          handle: 'cobalt',
        ),
      );
      await land(tester);
      final Finder row = find.byKey(const ValueKey<String>('room-working'));
      expect(row, findsOneWidget);
      expect(find.text('@cobalt is working…'), findsOneWidget);
      // Not a turn: no bubble for it.
      expect(find.byType(MessageBubble), findsNothing);

      ctrl.add(turn('b', 'cobalt', 'done'));
      await land(tester);
      expect(row, findsNothing);
      expect(said('done'), findsOneWidget);
      // Still running: the plain typing pill stands in.
      expect(talking(), findsOneWidget);
    });

    testWidgets('Stop replaces Send while the group runs and calls onStop', (
      tester,
    ) async {
      var stops = 0;
      final ctrl = await pumpGroup(
        tester,
        onSend: (_) {},
        onStop: () => stops++,
      );
      expect(findIcon(Icons.stop_rounded), findsNothing);
      expect(sendButton(), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'go');
      await tester.tap(sendButton());
      await land(tester);
      expect(sendButton(), findsNothing);
      await tester.tap(findIcon(Icons.stop_rounded));
      await land(tester);
      expect(stops, 1);

      ctrl.add(const AgentsRelayRoomDone(roomId: 'r1', reason: 'stopped'));
      await land(tester);
      expect(findIcon(Icons.stop_rounded), findsNothing);
      expect(sendButton(), findsOneWidget);
      expect(find.text('Stopped'), findsOneWidget);
    });

    testWidgets('no_addressee names how to address the group', (tester) async {
      final ctrl = await pumpGroup(tester);
      ctrl.add(const AgentsRelayRoomDone(roomId: 'r1', reason: 'no_addressee'));
      await land(tester);
      expect(
        find.text('Nobody was mentioned. Write @name or @all.'),
        findsOneWidget,
      );
    });

    testWidgets('the room_list frame is not taken for a history', (
      tester,
    ) async {
      final ctrl = await pumpGroup(tester);
      ctrl.add(turn('a', 'amber', 'kept'));
      ctrl.add(const AgentsRelayRoomList(rooms: <AgentsRelayRoomListEntry>[]));
      await land(tester);
      expect(said('kept'), findsOneWidget);
    });
  });
}

/// A minimal AgentsRelayController for the rebind test: only [inbound] is real;
/// every other member is a no-op via noSuchMethod.
class _FakeController implements AgentsRelayController {
  final StreamController<AgentsRelayInbound> _c =
      StreamController<AgentsRelayInbound>.broadcast(sync: true);

  @override
  Stream<AgentsRelayInbound> get inbound => _c.stream;

  void emit(AgentsRelayInbound e) => _c.add(e);
  Future<void> close() => _c.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
