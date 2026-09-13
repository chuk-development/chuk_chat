import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/icon_finder.dart';

import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/models/agents_room.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/widgets/room_mention_picker.dart';
import 'package:chuk_chat/widgets/room_thread_page.dart';

void main() {
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
    expect(find.text('the room is talking…'), findsOneWidget);
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
    expect(find.text('ship it'), findsOneWidget);

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
    expect(find.text('Round 1'), findsOneWidget);
    expect(find.text('Round 2'), findsOneWidget);
    expect(find.text('@cobalt'), findsOneWidget);
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

    expect(find.text('the room is talking…'), findsNothing);
    expect(find.text('Reached the round limit'), findsOneWidget);
  });

  testWidgets('non-room events on the stream are ignored', (tester) async {
    final ctrl = await pump(tester);
    ctrl.add(const AgentsRelayDelta('agent-thread text'));
    ctrl.add(const AgentsRelayDone());
    await tester.pump();

    // Still running, no turns — the agent-thread events did not leak in.
    expect(find.text('the room is talking…'), findsOneWidget);
    expect(find.textContaining('agent-thread text'), findsNothing);
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
    expect(find.text('other room'), findsNothing);
    // A done for another room does not stop this one either.
    ctrl.add(const AgentsRelayRoomDone(roomId: 'r2', reason: 'stopped'));
    await tester.pump();
    expect(find.text('the room is talking…'), findsOneWidget);
  });

  testWidgets('an unknown stop reason leaves no footer but stops running', (
    tester,
  ) async {
    final ctrl = await pump(tester);
    ctrl.add(const AgentsRelayRoomDone(roomId: 'r1', reason: 'who_knows'));
    await tester.pump();
    // fromWire returns null -> no footer, and not running (no indicator).
    expect(find.text('the room is talking…'), findsNothing);
    expect(find.textContaining('Reached'), findsNothing);
  });

  testWidgets('no composer when onSend is null', (tester) async {
    await pump(tester);
    expect(findIcon(Icons.send), findsNothing);
  });

  testWidgets('the composer sends and resets the thread', (tester) async {
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
    expect(find.text('old turn'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'new question');
    await tester.tap(findIcon(Icons.send));
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
    await tester.tap(findIcon(Icons.send));
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
    expect(find.text('live turn'), findsOneWidget);

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
    expect(find.text('live turn'), findsNothing);
    expect(find.text('stored one'), findsOneWidget);
    expect(find.text('stored two'), findsOneWidget);
    expect(find.text('the room is talking…'), findsNothing);
  });

  testWidgets('an empty room_history leaves the page running and empty', (
    tester,
  ) async {
    final ctrl = await pump(tester);
    ctrl.add(const AgentsRelayRoomHistory(roomId: 'r1', turns: []));
    await tester.pump();
    expect(find.text('the room is talking…'), findsOneWidget);
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
    expect(find.text('other'), findsNothing);
  });

  testWidgets('a no_such_room done names the missing-room reason', (
    tester,
  ) async {
    final ctrl = await pump(tester);
    ctrl.add(const AgentsRelayRoomDone(roomId: 'r1', reason: 'no_such_room'));
    await tester.pump();
    expect(find.text('This room is not on your host yet'), findsOneWidget);
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
      find.text('Connection changed. Reopen the room to continue.'),
      findsOneWidget,
    );
    expect(find.text('the room is talking…'), findsNothing);
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

    // Enabled before the drop.
    expect(
      tester
          .widget<IconButton>(findWidgetWithIcon<IconButton>(Icons.send))
          .onPressed,
      isNotNull,
    );

    unawaited(ctrl.close());
    await tester.pump();

    // Disabled after: the send button is dead and typing hits nothing.
    expect(
      tester
          .widget<IconButton>(findWidgetWithIcon<IconButton>(Icons.send))
          .onPressed,
      isNull,
    );
    expect(find.text('Reopen the room to send'), findsOneWidget);
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
      expect(inPicker('3 coworkers'), findsOneWidget);

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
