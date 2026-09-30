import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/platform_specific/chat/voice/voice_turn_queue.dart';

/// Stands in for a chat screen: each send appends a user row and an
/// assistant row, and reports the assistant row as the turn.
class _FakeChat {
  String? chatId = 'chat-1';
  bool busy = false;
  bool refuse = false;
  final List<String> sent = <String>[];
  int rows = 0;

  Future<void> send(String text, VoiceTurnStarted onStarted) async {
    if (refuse) return;
    sent.add(text);
    rows += 2;
    busy = true;
    onStarted(chatId!, rows - 1);
  }

  bool offline = false;

  VoiceTurnQueue queue({
    Duration maxWait = const Duration(seconds: 5),
    Duration turnTimeout = const Duration(seconds: 5),
  }) => VoiceTurnQueue(
    send: send,
    isBusy: () => busy,
    currentChatId: () => chatId,
    isOffline: () => offline,
    pollInterval: const Duration(milliseconds: 5),
    maxWait: maxWait,
    turnTimeout: turnTimeout,
  );
}

void main() {
  test('a task completes with the text its own row was finalized with', () async {
    final _FakeChat chat = _FakeChat();
    final VoiceTurnQueue queue = chat.queue();
    final Future<VoiceTurnOutcome> outcome = queue.enqueue('chat-1', 'task');
    await pumpEventQueue();
    expect(chat.sent, <String>['task']);

    // Another row finishing is not this task.
    expect(queue.complete('chat-1', 99, 'other'), isFalse);
    expect(queue.complete('chat-1', 1, 'the answer'), isTrue);
    chat.busy = false;

    final VoiceTurnOutcome result = await outcome;
    expect(result.ok, isTrue);
    expect(result.text, 'the answer');
    queue.dispose();
  });

  test('overlapping tasks run one turn at a time, results stay mapped', () async {
    final _FakeChat chat = _FakeChat();
    final VoiceTurnQueue queue = chat.queue();
    final Future<VoiceTurnOutcome> a = queue.enqueue('chat-1', 'a');
    final Future<VoiceTurnOutcome> b = queue.enqueue('chat-1', 'b');
    await pumpEventQueue();
    // b waits until a's turn is over.
    expect(chat.sent, <String>['a']);
    expect(queue.length, 2);

    queue.complete('chat-1', 1, 'answer a');
    chat.busy = false;
    await pumpEventQueue();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(chat.sent, <String>['a', 'b']);

    queue.complete('chat-1', 3, 'answer b');
    chat.busy = false;
    expect((await a).text, 'answer a');
    expect((await b).text, 'answer b');
    queue.dispose();
  });

  test('waits while the reader has a turn of their own in flight', () async {
    final _FakeChat chat = _FakeChat()..busy = true;
    final VoiceTurnQueue queue = chat.queue();
    final Future<VoiceTurnOutcome> outcome = queue.enqueue('chat-1', 'task');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(chat.sent, isEmpty);

    chat.busy = false;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(chat.sent, <String>['task']);
    queue.complete('chat-1', 1, 'done');
    expect((await outcome).ok, isTrue);
    queue.dispose();
  });

  test('a failure text from the pipeline reports failed', () async {
    final _FakeChat chat = _FakeChat();
    final VoiceTurnQueue queue = chat.queue();
    final Future<VoiceTurnOutcome> outcome = queue.enqueue('chat-1', 'task');
    await pumpEventQueue();
    queue.complete('chat-1', 1, 'Error: 502');
    expect((await outcome).ok, isFalse);
    queue.dispose();
  });

  test('a send that does not start reports failed', () async {
    final _FakeChat chat = _FakeChat()..refuse = true;
    final VoiceTurnQueue queue = chat.queue();
    final VoiceTurnOutcome outcome = await queue.enqueue('chat-1', 'task');
    expect(outcome.ok, isFalse);
    queue.dispose();
  });

  test('a task for a chat that is no longer on screen fails', () async {
    final _FakeChat chat = _FakeChat()..chatId = 'other-chat';
    final VoiceTurnQueue queue = chat.queue();
    final VoiceTurnOutcome outcome = await queue.enqueue('chat-1', 'task');
    expect(outcome.ok, isFalse);
    expect(chat.sent, isEmpty);
    queue.dispose();
  });

  test('an interrupted turn fails its task', () async {
    final _FakeChat chat = _FakeChat();
    final VoiceTurnQueue queue = chat.queue();
    final Future<VoiceTurnOutcome> outcome = queue.enqueue('chat-1', 'task');
    await pumpEventQueue();
    expect(queue.fail('chat-1', 1, 'stopped'), isTrue);
    final VoiceTurnOutcome result = await outcome;
    expect(result.ok, isFalse);
    expect(result.text, 'stopped');
    queue.dispose();
  });

  test('a turn that never ends times out', () async {
    final _FakeChat chat = _FakeChat();
    final VoiceTurnQueue queue = chat.queue(
      turnTimeout: const Duration(milliseconds: 30),
    );
    final VoiceTurnOutcome outcome = await queue.enqueue('chat-1', 'task');
    expect(outcome.ok, isFalse);
    // The late answer no longer belongs to anyone.
    expect(queue.complete('chat-1', 1, 'late'), isFalse);
    queue.dispose();
  });

  test('dispose fails waiting and running tasks, and takes no more', () async {
    final _FakeChat chat = _FakeChat();
    final VoiceTurnQueue queue = chat.queue();
    final Future<VoiceTurnOutcome> running = queue.enqueue('chat-1', 'a');
    final Future<VoiceTurnOutcome> waiting = queue.enqueue('chat-1', 'b');
    await pumpEventQueue();
    queue.dispose();
    expect((await running).ok, isFalse);
    expect((await waiting).ok, isFalse);
    expect((await queue.enqueue('chat-1', 'c')).ok, isFalse);
  });

  test('the turn timeout runs from the start, even if the send holds on', () async {
    final _FakeChat chat = _FakeChat();
    final Completer<void> never = Completer<void>();
    final VoiceTurnQueue queue = VoiceTurnQueue(
      send: (String text, VoiceTurnStarted onStarted) async {
        await chat.send(text, onStarted);
        await never.future; // a send that awaits the whole answer
      },
      isBusy: () => false,
      currentChatId: () => chat.chatId,
      pollInterval: const Duration(milliseconds: 5),
      turnTimeout: const Duration(milliseconds: 30),
    );
    final VoiceTurnOutcome outcome = await queue.enqueue('chat-1', 'task');
    expect(outcome.ok, isFalse);
    queue.dispose();
  });

  test('a send that holds on still reports its answer', () async {
    final _FakeChat chat = _FakeChat();
    final Completer<void> hold = Completer<void>();
    final VoiceTurnQueue queue = VoiceTurnQueue(
      send: (String text, VoiceTurnStarted onStarted) async {
        await chat.send(text, onStarted);
        await hold.future;
      },
      isBusy: () => false,
      currentChatId: () => chat.chatId,
      pollInterval: const Duration(milliseconds: 5),
    );
    final Future<VoiceTurnOutcome> outcome = queue.enqueue('chat-1', 'task');
    await pumpEventQueue();
    queue.complete('chat-1', 1, 'answer');
    expect((await outcome).text, 'answer');
    hold.complete();
    queue.dispose();
  });

  test('a hang-up cancels the tasks of that call that have not started', () async {
    final _FakeChat chat = _FakeChat();
    final VoiceTurnQueue queue = chat.queue();
    final Object callA = Object();
    final Object callB = Object();
    final Future<VoiceTurnOutcome> running = queue.enqueue(
      'chat-1',
      'a1',
      tag: callA,
    );
    await pumpEventQueue();
    expect(chat.sent, <String>['a1']);
    final Future<VoiceTurnOutcome> waitingA = queue.enqueue(
      'chat-1',
      'a2',
      tag: callA,
    );
    final Future<VoiceTurnOutcome> waitingB = queue.enqueue(
      'chat-1',
      'b1',
      tag: callB,
    );

    expect(queue.cancelPending(callA, 'The call ended.'), 1);
    final VoiceTurnOutcome cancelled = await waitingA;
    expect(cancelled.ok, isFalse);
    expect(cancelled.text, 'The call ended.');

    // The running task of call A still finishes; call B's task still runs.
    queue.complete('chat-1', 1, 'answer a1');
    chat.busy = false;
    expect((await running).text, 'answer a1');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(chat.sent, <String>['a1', 'b1']);
    queue.complete('chat-1', 3, 'answer b1');
    chat.busy = false;
    expect((await waitingB).text, 'answer b1');
    queue.dispose();
  });

  test('a send parked offline fails its task at once with "offline"', () async {
    final _FakeChat chat = _FakeChat()
      ..refuse = true
      ..offline = true;
    final VoiceTurnQueue queue = chat.queue();
    final VoiceTurnOutcome outcome = await queue
        .enqueue('chat-1', 'task')
        .timeout(const Duration(seconds: 1));
    expect(outcome.ok, isFalse);
    expect(outcome.text, kVoiceTaskOffline);
    queue.dispose();
  });
}
