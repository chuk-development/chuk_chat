// Busy sends (idea 67): queue vs steer, the dock's queue, steers the tool
// loop takes, steers it does not take, stop, chat switch, double Esc.

import 'dart:convert';

import 'package:chuk_chat/models/chat_stream_event.dart' show NativeToolCall;
import 'package:chuk_chat/services/composer/composer_follow_ups.dart';
import 'package:chuk_chat/services/composer/follow_up_queue.dart';
import 'package:chuk_chat/services/tool_call_handler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SteerInbox.debugClear();
    ComposerBusySetting.debugReset();
  });

  group('busySendKind', () {
    test('Enter follows the setting, Ctrl+Enter does the other', () {
      expect(
        busySendKind(
          BusySendMode.queue,
          alternate: false,
          steerAvailable: true,
        ),
        FollowUpKind.queued,
      );
      expect(
        busySendKind(BusySendMode.queue, alternate: true, steerAvailable: true),
        FollowUpKind.steer,
      );
      expect(
        busySendKind(
          BusySendMode.steer,
          alternate: false,
          steerAvailable: true,
        ),
        FollowUpKind.steer,
      );
      expect(
        busySendKind(BusySendMode.steer, alternate: true, steerAvailable: true),
        FollowUpKind.queued,
      );
    });

    test('without steer (an Agents thread) every busy send queues', () {
      for (final mode in BusySendMode.values) {
        for (final alt in <bool>[false, true]) {
          expect(
            busySendKind(mode, alternate: alt, steerAvailable: false),
            FollowUpKind.queued,
          );
        }
      }
    });
  });

  test('the setting persists', () async {
    await ComposerBusySetting.set(BusySendMode.steer);
    ComposerBusySetting.debugReset();
    expect(ComposerBusySetting.mode.value, BusySendMode.queue);
    await ComposerBusySetting.load();
    expect(ComposerBusySetting.mode.value, BusySendMode.steer);
  });

  group('ComposerFollowUps', () {
    late Map<String, List<String>> parked;
    late String? chat;
    late bool agents;

    ComposerFollowUps make() => ComposerFollowUps(
      chatId: () => chat,
      park: (String id, List<String> texts) async => parked[id] = texts,
      loadParked: (String id) async => parked[id] ?? const <String>[],
      isAgentsThread: (_) => agents,
    );

    setUp(() {
      parked = <String, List<String>>{};
      chat = 'chat-1';
      agents = false;
    });

    test('a burst queues in order and is parked', () {
      final f = make();
      f.enqueue('first');
      f.enqueue('second');
      expect(f.queue.texts, <String>['first', 'second']);
      expect(parked['chat-1'], <String>['first', 'second']);
      expect(f.takeNext()!.text, 'first');
      expect(parked['chat-1'], <String>['second']);
      f.dispose();
    });

    test('a steer goes to the inbox; the tool loop taking it removes it '
        'from the dock', () {
      final f = make();
      final kind = f.enqueue('use metric units', alternate: true);
      expect(kind, FollowUpKind.steer);
      expect(f.queue.items.single.kind, FollowUpKind.steer);
      final taken = SteerInbox.take('chat-1');
      expect(taken.single.text, 'use metric units');
      expect(f.queue.isEmpty, isTrue, reason: 'delivered steers leave');
      f.dispose();
    });

    test('a steer the turn did not take is sent after the reply', () {
      final f = make();
      f.enqueue('also check B', alternate: true);
      f.enqueue('queued after');
      f.onTurnEnded();
      expect(SteerInbox.take('chat-1'), isEmpty);
      expect(
        f.queue.items.map((i) => (i.text, i.kind)).toList(),
        <(String, FollowUpKind)>[
          ('also check B', FollowUpKind.queued),
          ('queued after', FollowUpKind.queued),
        ],
      );
      expect(f.takeNext()!.text, 'also check B');
      f.dispose();
    });

    test('send now as steer moves a queued message into the turn', () {
      final f = make();
      f.enqueue('later');
      final id = f.queue.items.single.id;
      f.steerNow(id);
      expect(f.queue.items.single.kind, FollowUpKind.steer);
      expect(SteerInbox.isPending('chat-1', id), isTrue);
      f.edit(id, 'later, edited');
      expect(SteerInbox.take('chat-1').single.text, 'later, edited');
      f.dispose();
    });

    test('an Agents thread never steers', () {
      agents = true;
      final f = make();
      expect(f.steerAvailable, isFalse);
      expect(f.enqueue('x', alternate: true), FollowUpKind.queued);
      f.steerNow(f.queue.items.single.id);
      expect(f.queue.items.single.kind, FollowUpKind.queued);
      expect(SteerInbox.take('chat-1'), isEmpty);
      f.dispose();
    });

    test('stop puts everything back as one text and withdraws steers', () {
      final f = make();
      f.enqueue('a');
      f.enqueue('b', alternate: true);
      expect(f.drainToText(), 'a\n\nb');
      expect(f.queue.isEmpty, isTrue);
      expect(SteerInbox.take('chat-1'), isEmpty);
      expect(parked['chat-1'], isEmpty);
      f.dispose();
    });

    test('leaving a chat parks its queue there and restores it on return',
        () async {
      final f = make();
      f.enqueue('for chat one');
      f.enqueue('steer one', alternate: true);
      f.leaveChat('chat-1');
      chat = 'chat-2';
      expect(f.queue.isEmpty, isTrue, reason: 'never into the next chat');
      expect(SteerInbox.take('chat-1'), isEmpty);
      chat = 'chat-1';
      expect(await f.restoreParked('chat-1'), isTrue);
      expect(f.queue.texts, <String>['for chat one', 'steer one']);
      f.dispose();
    });

    test('remove drops the message and its steer', () {
      final f = make();
      f.enqueue('x', alternate: true);
      f.remove(f.queue.items.single.id);
      expect(f.queue.isEmpty, isTrue);
      expect(SteerInbox.take('chat-1'), isEmpty);
      f.dispose();
    });
  });

  test('double Esc fires within 500 ms only', () {
    DateTime now = DateTime(2026, 11, 5, 12);
    final d = DoubleEscapeDetector(clock: () => now);
    expect(d.press(), isFalse);
    now = now.add(const Duration(milliseconds: 600));
    expect(d.press(), isFalse, reason: 'too slow: starts over');
    now = now.add(const Duration(milliseconds: 400));
    expect(d.press(), isTrue);
    now = now.add(const Duration(milliseconds: 100));
    expect(d.press(), isFalse, reason: 'a third press starts a new pair');
  });

  group('tool loop', () {
    ToolLoopSession newSession(ToolCallHandler handler) =>
        handler.createSession(
          initialUserMessage: 'what is 2+2',
          history: const [],
          accessToken: 'test-token',
          toolCallingEnabled: true,
          discoveryMode: false,
          nativeToolCalling: true,
          discoveryContextKey: 'chat-steer',
        );

    test('a steer joins the next pass as a user message after the round',
        () async {
      final handler = ToolCallHandler();
      final session = newSession(handler);
      SteerInbox.post(
        'chat-steer',
        const SteerEntry(id: 's1', text: 'answer in German'),
      );
      SteerInbox.post(
        'other-chat',
        const SteerEntry(id: 's2', text: 'not mine'),
      );
      final result = await handler.processAssistantResponse(
        session: session,
        content: '',
        reasoning: '',
        nativeToolCalls: <NativeToolCall>[
          NativeToolCall(
            id: 'c-1',
            name: 'calculate',
            arguments: jsonEncode(<String, String>{'expression': '2+2'}),
          ),
        ],
      );
      expect(result.shouldContinue, isTrue);
      final history = result.nextStep!.history;
      final int toolAt = history.lastIndexWhere((m) => m['role'] == 'tool');
      final Map<String, dynamic> last = history.last;
      expect(history.indexOf(last), greaterThan(toolAt));
      expect(last['role'], 'user');
      expect(last['content'], SteerInbox.messageFor('answer in German'));
      expect(SteerInbox.take('chat-steer'), isEmpty, reason: 'taken once');
      expect(SteerInbox.take('other-chat').single.text, 'not mine');
    });
  });
}
