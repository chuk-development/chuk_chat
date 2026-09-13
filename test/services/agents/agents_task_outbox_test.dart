import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/agents/agents_task_outbox.dart';
import 'package:chuk_chat/services/offline_send_coordinator.dart';

/// Bead cowork-i7sd: "ob die Nachrichten im Backend ankommen, ist irgendwie
/// nicht klar". A prompt the socket would not take used to be gone — not
/// stored, not retried, not sent when the host came back.
void main() {
  late Map<String, String> disk;
  late DateTime clock;

  setUp(() {
    disk = <String, String>{};
    clock = DateTime.utc(2026, 9, 10, 12);
    AgentsTaskOutbox.resetForTest();
    AgentsTaskOutbox.now = () => clock;
    AgentsTaskOutbox.read = (key) async => disk[key];
    AgentsTaskOutbox.write = (key, value) async => disk[key] = value;
    AgentsTaskOutbox.delete = (key) async => disk.remove(key);
  });

  tearDown(() {
    AgentsTaskOutbox.read = null;
    AgentsTaskOutbox.write = null;
    AgentsTaskOutbox.delete = null;
    AgentsTaskOutbox.now = () => DateTime.now().toUtc();
  });

  test('a queued prompt survives a restart, verbatim and in order', () async {
    await AgentsTaskOutbox.enqueue(sessionKey: 't', prompt: 'erste');
    await AgentsTaskOutbox.enqueue(
      sessionKey: 't',
      prompt: 'zweite  ',
      modelId: 'm1',
      providerSlug: 'p1',
      reasoningEffort: 'none',
    );
    // A restart reads the same rows off disk.
    final tasks = await AgentsTaskOutbox.pendingFor('t');
    expect(tasks.map((t) => t.prompt).toList(), ['erste', 'zweite  ']);
    expect(tasks.last.modelId, 'm1');
    expect(tasks.last.providerSlug, 'p1');
    expect(tasks.last.reasoningEffort, 'none');
  });

  test('threads keep their own queues', () async {
    await AgentsTaskOutbox.enqueue(sessionKey: 'a', prompt: 'x');
    await AgentsTaskOutbox.enqueue(sessionKey: 'b', prompt: 'y');
    expect((await AgentsTaskOutbox.pendingFor('a')).single.prompt, 'x');
    expect((await AgentsTaskOutbox.pendingFor('b')).single.prompt, 'y');
  });

  test('a flush sends oldest first and empties the queue', () async {
    await AgentsTaskOutbox.enqueue(sessionKey: 't', prompt: 'eins');
    await AgentsTaskOutbox.enqueue(sessionKey: 't', prompt: 'zwei');
    final sent = <String>[];
    final count = await AgentsTaskOutbox.flush('t', (task) async {
      sent.add(task.prompt);
    });
    expect(count, 2);
    expect(sent, ['eins', 'zwei']);
    expect(await AgentsTaskOutbox.pendingFor('t'), isEmpty);
    expect(disk, isEmpty);
  });

  test('a flush that fails stops and keeps everything', () async {
    await AgentsTaskOutbox.enqueue(sessionKey: 't', prompt: 'eins');
    await AgentsTaskOutbox.enqueue(sessionKey: 't', prompt: 'zwei');
    final count = await AgentsTaskOutbox.flush('t', (task) async {
      throw StateError('Not paired');
    });
    expect(count, 0);
    final pending = await AgentsTaskOutbox.pendingFor('t');
    expect(pending.map((t) => t.prompt).toList(), ['eins', 'zwei']);
    expect(pending.first.attempts, 1);
    expect(pending.first.lastError, contains('Not paired'));
  });

  test('a prompt the host never takes is given up on, not looped', () async {
    await AgentsTaskOutbox.enqueue(sessionKey: 't', prompt: 'giftig');
    for (int i = 0; i < AgentsTaskOutbox.maxAttempts; i++) {
      await AgentsTaskOutbox.flush('t', (task) async => throw 'no');
      // Each failure earns a wait; the give-up cap is about attempts, not
      // about how often something asks for a flush.
      clock = clock.add(const Duration(minutes: 1));
    }
    expect(await AgentsTaskOutbox.pendingFor('t'), isEmpty);
  });

  test('an unreadable row is an empty queue, never a crash', () async {
    disk['$kTaskOutboxPrefix'
            't'] =
        'not json at all';
    expect(await AgentsTaskOutbox.pendingFor('t'), isEmpty);
    disk['$kTaskOutboxPrefix'
            't'] =
        '[{"nope": 1}]';
    expect(await AgentsTaskOutbox.pendingFor('t'), isEmpty);
  });

  test('a queue with no store still answers', () async {
    AgentsTaskOutbox.read = null;
    AgentsTaskOutbox.write = null;
    AgentsTaskOutbox.delete = null;
    // No SQLite in a plain unit test: the calls fail soft rather than throw.
    expect(await AgentsTaskOutbox.pendingFor('t'), isEmpty);
  });

  // ── the airplane-mode path ─────────────────────────────────────────────
  //
  // The imported send paths short-circuit on `NetworkStatusService.isOnline ==
  // false` BEFORE the relay is ever asked, and call
  // `OfflineSendCoordinator.enqueue`. That used to return '' and store
  // nothing: the prompt was gone with no trace. These two say it is not.

  test('a send with the device offline lands in the outbox with a real '
      'queueId', () async {
    final queueId = await OfflineSendCoordinator.enqueue(
      const OfflineSendPayload(
        chatId: 'thread-1',
        messageText: 'was kostet der spass',
        modelId: 'm1',
        providerSlug: 'p1',
        reasoningEffort: 'low',
        // Everything the host owns is dropped on purpose.
        systemPrompt: 'ignored',
        maxTokens: 512,
      ),
    );

    // Real, not ''. The bubble writes it into `queueId`, and the flush finds
    // the row by it again.
    expect(queueId, isNotEmpty);

    final pending = await AgentsTaskOutbox.pendingFor('thread-1');
    expect(pending.single.localId, queueId);
    expect(pending.single.prompt, 'was kostet der spass');
    expect(pending.single.modelId, 'm1');
    expect(pending.single.providerSlug, 'p1');
    expect(pending.single.reasoningEffort, 'low');
  });

  test('a prompt typed offline goes out on the next flush, once', () async {
    await OfflineSendCoordinator.enqueue(
      const OfflineSendPayload(
        chatId: 'thread-1',
        messageText: 'im flugmodus getippt',
        modelId: '',
        providerSlug: '',
      ),
    );
    // The device came back and the host paired.
    final sent = <String>[];
    expect(
      await AgentsTaskOutbox.flush('thread-1', (task) async {
        sent.add(task.prompt);
      }),
      1,
    );
    expect(sent, ['im flugmodus getippt']);
    // And it is not sent a second time on the next pairing.
    expect(await AgentsTaskOutbox.flush('thread-1', (_) async {}), 0);
    expect(await AgentsTaskOutbox.pendingFor('thread-1'), isEmpty);
  });

  // ── backoff ────────────────────────────────────────────────────────────

  test('a flush that fails backs off instead of hammering', () async {
    await AgentsTaskOutbox.enqueue(sessionKey: 't', prompt: 'eins');
    expect(await AgentsTaskOutbox.flush('t', (_) async => throw 'no host'), 0);
    final afterFirst = (await AgentsTaskOutbox.pendingFor('t')).single;
    expect(afterFirst.attempts, 1);
    expect(afterFirst.nextAttemptAt, isNotNull);
    expect(afterFirst.isDue(clock), isFalse);

    // A reconnect, a resume and a watchdog tick all land in the same second.
    // None of them may touch the host again yet.
    int tries = 0;
    for (int i = 0; i < 3; i++) {
      await AgentsTaskOutbox.flush('t', (_) async {
        tries++;
      });
    }
    expect(tries, 0);
    expect((await AgentsTaskOutbox.pendingFor('t')).single.attempts, 1);

    // Once the wait is over it is tried again.
    clock = clock.add(const Duration(seconds: 2));
    final sent = <String>[];
    expect(
      await AgentsTaskOutbox.flush('t', (task) async => sent.add(task.prompt)),
      1,
    );
    expect(sent, ['eins']);
  });

  test('the wait grows with every failure, up to the cap', () async {
    await AgentsTaskOutbox.enqueue(sessionKey: 't', prompt: 'giftig');
    final waits = <Duration>[];
    for (int i = 0; i < 3; i++) {
      await AgentsTaskOutbox.flush('t', (_) async => throw 'no');
      final task = (await AgentsTaskOutbox.pendingFor('t')).single;
      waits.add(task.nextAttemptAt!.difference(clock));
      clock = task.nextAttemptAt!;
    }
    expect(waits[1], greaterThan(waits[0]));
    expect(waits[2], greaterThan(waits[1]));
    expect(waits.last, lessThanOrEqualTo(const Duration(seconds: 11)));
  });

  test('a not-yet-due entry holds the ones behind it', () async {
    await AgentsTaskOutbox.enqueue(sessionKey: 't', prompt: 'eins');
    await AgentsTaskOutbox.enqueue(sessionKey: 't', prompt: 'zwei');
    await AgentsTaskOutbox.flush('t', (_) async => throw 'no');
    // 'eins' is waiting. 'zwei' must not overtake it — the thread would read
    // in the wrong order.
    final sent = <String>[];
    expect(
      await AgentsTaskOutbox.flush('t', (task) async => sent.add(task.prompt)),
      0,
    );
    expect(sent, isEmpty);
  });
}
