import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/agents/agents_task_outbox.dart';
import 'package:chuk_chat/services/offline_outbox_cipher.dart';
import 'package:chuk_chat/services/offline_send_coordinator.dart';
import 'package:chuk_chat/services/storage/chat_origin.dart';

/// Bead cowork-i7sd: "ob die Nachrichten im Backend ankommen, ist irgendwie
/// nicht klar". A prompt the socket would not take used to be gone — not
/// stored, not retried, not sent when the host came back.
void main() {
  // These tests model the Agents build: Agents threads take the Agents
  // store and queue (ChatOrigin). Tests run with FEATURE_AGENTS off.
  ChatOrigin.agentsEnabled = true;
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
    AgentsTaskOutbox.readKeys = null;
    AgentsTaskOutbox.now = () => DateTime.now().toUtc();
    OutboxCipher.reset();
  });

  /// The key listing reads the same disk the rows live on.
  void listDisk() {
    AgentsTaskOutbox.readKeys = (prefix) async => <String>[
      for (final String key in disk.keys)
        if (key.startsWith(prefix)) key,
    ];
  }

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

  test('two flushes of one thread in the same moment send the prompt once',
      () async {
    await AgentsTaskOutbox.enqueue(sessionKey: 't', prompt: 'einmal');
    final sent = <String>[];
    final Completer<void> release = Completer<void>();
    final Future<int> first = AgentsTaskOutbox.flush('t', (task) async {
      sent.add(task.prompt);
      await release.future; // the first flush is still in flight …
    });
    final Future<int> second = AgentsTaskOutbox.flush('t', (task) async {
      sent.add(task.prompt);
    });
    release.complete();
    final counts = await Future.wait(<Future<int>>[first, second]);
    expect(counts, <int>[1, 0]);
    expect(sent, <String>['einmal']);
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

  test('a prompt the host never takes is marked failed and KEPT, not looped',
      () async {
    await AgentsTaskOutbox.enqueue(sessionKey: 't', prompt: 'giftig');
    for (int i = 0; i < AgentsTaskOutbox.maxAttempts; i++) {
      await AgentsTaskOutbox.flush('t', (task) async => throw 'no');
      // Each failure earns a wait; the give-up cap is about attempts, not
      // about how often something asks for a flush.
      clock = clock.add(const Duration(minutes: 1));
    }
    // Nothing typed is ever lost: the entry is still there, with its error.
    final kept = (await AgentsTaskOutbox.pendingFor('t')).single;
    expect(kept.prompt, 'giftig');
    expect(kept.failed, isTrue);
    expect(kept.lastError, contains('no'));
    expect(kept.attempts, AgentsTaskOutbox.maxAttempts);

    // Automatic flushes leave it alone, and it is not "due" any more.
    listDisk();
    int tries = 0;
    expect(await AgentsTaskOutbox.flush('t', (_) async => tries++), 0);
    expect(await AgentsTaskOutbox.flushAll((_) async => tries++), 0);
    expect(tries, 0);
    expect(await AgentsTaskOutbox.anyDue(), isFalse);
  });

  test('a failed entry does not hold the prompts behind it', () async {
    await AgentsTaskOutbox.enqueue(sessionKey: 't', prompt: 'giftig');
    for (int i = 0; i < AgentsTaskOutbox.maxAttempts; i++) {
      await AgentsTaskOutbox.flush('t', (task) async => throw 'no');
      clock = clock.add(const Duration(minutes: 1));
    }
    await AgentsTaskOutbox.enqueue(sessionKey: 't', prompt: 'danach');
    final sent = <String>[];
    expect(
      await AgentsTaskOutbox.flush('t', (task) async => sent.add(task.prompt)),
      1,
    );
    expect(sent, ['danach']);
    expect((await AgentsTaskOutbox.pendingFor('t')).single.prompt, 'giftig');
  });

  test('a send with no link stops the flush without counting an attempt',
      () async {
    await AgentsTaskOutbox.enqueue(sessionKey: 't', prompt: 'eins');
    for (int i = 0; i < AgentsTaskOutbox.maxAttempts + 2; i++) {
      expect(
        await AgentsTaskOutbox.flush(
          't',
          (_) async => throw const OutboxSendDeferred(),
        ),
        0,
      );
    }
    final task = (await AgentsTaskOutbox.pendingFor('t')).single;
    expect(task.attempts, 0);
    expect(task.failed, isFalse);
    expect(task.isDue(clock), isTrue);
  });

  // ── requeue / discard ─────────────────────────────────────────────────

  Future<OutboxTask> failedEntry(String sessionKey, String prompt) async {
    final task = await AgentsTaskOutbox.enqueue(
      sessionKey: sessionKey,
      prompt: prompt,
    );
    for (int i = 0; i < AgentsTaskOutbox.maxAttempts; i++) {
      await AgentsTaskOutbox.markAttempt(sessionKey, task.localId, 'nope');
    }
    return task;
  }

  test('requeueByLocalId puts a failed entry back, in any thread', () async {
    listDisk();
    await AgentsTaskOutbox.enqueue(sessionKey: 'a', prompt: 'other');
    final task = await failedEntry('b', 'zurueck');
    expect((await AgentsTaskOutbox.findByLocalId(task.localId))!.failed, true);

    expect(await AgentsTaskOutbox.requeueByLocalId(task.localId), isTrue);
    final back = (await AgentsTaskOutbox.findByLocalId(task.localId))!;
    expect(back.failed, isFalse);
    expect(back.attempts, 0);
    expect(back.nextAttemptAt, isNull);
    expect(back.isDue(clock), isTrue);
    // Same entry, same wire id.
    expect(back.taskId, task.taskId);

    final sent = <String>[];
    await AgentsTaskOutbox.flush('b', (t) async => sent.add(t.prompt));
    expect(sent, ['zurueck']);

    expect(await AgentsTaskOutbox.requeueByLocalId('no-such-id'), isFalse);
  });

  test('requeueFailed takes back every failed entry of one thread', () async {
    await failedEntry('t', 'eins');
    await failedEntry('t', 'zwei');
    expect(await AgentsTaskOutbox.requeueFailed('t'), 2);
    final tasks = await AgentsTaskOutbox.pendingFor('t');
    expect(tasks.every((t) => !t.failed && t.attempts == 0), isTrue);
  });

  test('discardByLocalId removes exactly that entry', () async {
    listDisk();
    final keep = await AgentsTaskOutbox.enqueue(sessionKey: 't', prompt: 'a');
    final drop = await failedEntry('t', 'b');
    expect(await AgentsTaskOutbox.discardByLocalId(drop.localId), isTrue);
    final left = await AgentsTaskOutbox.pendingFor('t');
    expect(left.map((t) => t.localId), [keep.localId]);
    expect(await AgentsTaskOutbox.discardByLocalId(drop.localId), isFalse);
    expect(await AgentsTaskOutbox.findByLocalId(drop.localId), isNull);
  });

  test('two prompts queued in the same microsecond are two entries', () async {
    final a = await AgentsTaskOutbox.enqueue(sessionKey: 't', prompt: 'a');
    final b = await AgentsTaskOutbox.enqueue(sessionKey: 't', prompt: 'b');
    expect(a.localId, isNot(b.localId));
    expect(a.taskId, isNot(b.taskId));
  });

  test('wipeAll deletes every queued and every unacknowledged row', () async {
    listDisk();
    await AgentsTaskOutbox.enqueue(sessionKey: 'a', prompt: 'x');
    await AgentsTaskOutbox.enqueue(sessionKey: 'b', prompt: 'y');
    await AgentsPendingTasks.record(
      sessionKey: 'a',
      taskId: 't1',
      prompt: 'z',
    );
    disk['unrelated'] = 'keep';
    await AgentsTaskOutbox.wipeAll();
    expect(disk.keys, ['unrelated']);
  });

  // ── task id ───────────────────────────────────────────────────────────

  test('the task id is minted at enqueue and stable across flushes', () async {
    final queued = await AgentsTaskOutbox.enqueue(sessionKey: 't', prompt: 'x');
    expect(queued.taskId, isNotEmpty);
    expect(queued.taskId.length, lessThanOrEqualTo(64));

    final ids = <String>[];
    // First flush: the socket refuses after the frame may have left.
    await AgentsTaskOutbox.flush('t', (task) async {
      ids.add(task.taskId);
      throw StateError('socket died');
    });
    clock = clock.add(const Duration(minutes: 1));
    // Second flush (after a "restart": everything comes off disk).
    await AgentsTaskOutbox.flush('t', (task) async => ids.add(task.taskId));
    expect(ids, [queued.taskId, queued.taskId]);
  });

  test('a caller-given task id is kept', () async {
    final queued = await AgentsTaskOutbox.enqueue(
      sessionKey: 't',
      prompt: 'x',
      taskId: 'tabc-1',
    );
    expect(queued.taskId, 'tabc-1');
    expect((await AgentsTaskOutbox.pendingFor('t')).single.taskId, 'tabc-1');
  });

  // ── encryption at rest ────────────────────────────────────────────────

  test('a queued prompt is sealed at rest', () async {
    OutboxCipher.useFake(userId: 'u1');
    await AgentsTaskOutbox.enqueue(sessionKey: 't', prompt: 'geheimer text');
    final raw = disk['${kTaskOutboxPrefix}t']!;
    expect(raw, isNot(contains('geheimer text')));
    expect(raw, contains('sealed'));
    // And it reads back.
    expect(
      (await AgentsTaskOutbox.pendingFor('t')).single.prompt,
      'geheimer text',
    );
  });

  test('an unacknowledged task record is sealed at rest too', () async {
    OutboxCipher.useFake(userId: 'u1');
    await AgentsPendingTasks.record(
      sessionKey: 't',
      taskId: 'id1',
      prompt: 'auch geheim',
    );
    expect(disk['${kPendingTaskPrefix}t'], isNot(contains('auch geheim')));
    expect(
      (await AgentsPendingTasks.pendingFor('t')).single.prompt,
      'auch geheim',
    );
  });

  test('a legacy plaintext row still loads, and is sealed on the next write',
      () async {
    disk['${kTaskOutboxPrefix}t'] =
        '[{"localId":"q1","sessionKey":"t","prompt":"alt",'
        '"createdAt":"2026-09-01T00:00:00.000Z","attempts":2}]';
    OutboxCipher.useFake(userId: 'u1');
    final old = (await AgentsTaskOutbox.pendingFor('t')).single;
    expect(old.prompt, 'alt');
    expect(old.attempts, 2);
    expect(old.failed, isFalse);
    // No stored id: the one the old flush derived, so it stays one task.
    expect(old.taskId, 'o-q1');

    await AgentsTaskOutbox.enqueue(sessionKey: 't', prompt: 'neu');
    expect(disk['${kTaskOutboxPrefix}t'], isNot(contains('alt')));
    final both = await AgentsTaskOutbox.pendingFor('t');
    expect(both.map((t) => t.prompt), ['alt', 'neu']);
  });

  test('with no key the row stays plaintext and is sealed once a key exists',
      () async {
    OutboxCipher.useFake(userId: 'u1', withKey: false);
    await AgentsTaskOutbox.enqueue(sessionKey: 't', prompt: 'vor dem key');
    expect(disk['${kTaskOutboxPrefix}t'], contains('vor dem key'));

    OutboxCipher.useFake(userId: 'u1');
    await AgentsTaskOutbox.enqueue(sessionKey: 't', prompt: 'mit key');
    final raw = disk['${kTaskOutboxPrefix}t']!;
    expect(raw, isNot(contains('vor dem key')));
    expect(raw, isNot(contains('mit key')));
    expect(
      (await AgentsTaskOutbox.pendingFor('t')).map((t) => t.prompt),
      ['vor dem key', 'mit key'],
    );
  });

  test('a sealed row that cannot be opened is kept and not flushed', () async {
    OutboxCipher.useFake(userId: 'u1');
    await AgentsTaskOutbox.enqueue(sessionKey: 't', prompt: 'versiegelt');
    final sealedRaw = disk['${kTaskOutboxPrefix}t']!;

    // The key is gone (signed out, not loaded yet).
    OutboxCipher.useFake(userId: 'u1', withKey: false);
    listDisk();
    int tries = 0;
    expect(await AgentsTaskOutbox.flushAll((_) async => tries++), 0);
    expect(tries, 0);
    expect(await AgentsTaskOutbox.anyDue(), isFalse);
    expect(disk['${kTaskOutboxPrefix}t'], sealedRaw);

    // A prompt typed now must not overwrite it either.
    await AgentsTaskOutbox.enqueue(sessionKey: 't', prompt: 'spaeter');
    final String blob = (jsonDecode(sealedRaw) as Map)['sealed'] as String;
    final Map<String, Object?> after =
        jsonDecode(disk['${kTaskOutboxPrefix}t']!) as Map<String, Object?>;
    expect(after['locked'], [blob]);

    // The key comes back: both are there, oldest first, and both go out.
    OutboxCipher.useFake(userId: 'u1');
    final sent = <String>[];
    expect(await AgentsTaskOutbox.flushAll((t) async => sent.add(t.prompt)), 2);
    expect(sent, ['versiegelt', 'spaeter']);
    expect(disk, isEmpty);
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

  test('flushAll sends every thread queue, each into its own thread', () async {
    await AgentsTaskOutbox.enqueue(sessionKey: 'a', prompt: 'a1');
    await AgentsTaskOutbox.enqueue(sessionKey: 'a', prompt: 'a2');
    await AgentsTaskOutbox.enqueue(sessionKey: 'b', prompt: 'b1');
    // The key listing reads the same disk the rows live on.
    AgentsTaskOutbox.readKeys = (prefix) async => <String>[
      for (final String key in disk.keys)
        if (key.startsWith(prefix)) key,
    ];

    final sent = <String, List<String>>{};
    final count = await AgentsTaskOutbox.flushAll((task) async {
      (sent[task.sessionKey] ??= <String>[]).add(task.prompt);
    });

    expect(count, 3);
    expect(sent['a'], ['a1', 'a2']);
    expect(sent['b'], ['b1']);
    expect(await AgentsTaskOutbox.pendingFor('a'), isEmpty);
    expect(await AgentsTaskOutbox.pendingFor('b'), isEmpty);
  });

  test('flushAll keeps going when one thread queue is unreadable', () async {
    await AgentsTaskOutbox.enqueue(sessionKey: 'good', prompt: 'g1');
    disk['$kTaskOutboxPrefix' 'bad'] = 'not json at all';
    AgentsTaskOutbox.readKeys = (prefix) async => <String>[
      '$kTaskOutboxPrefix' 'bad',
      '$kTaskOutboxPrefix' 'good',
    ];

    final sent = <String>[];
    final count = await AgentsTaskOutbox.flushAll((task) async {
      sent.add(task.prompt);
    });

    // The unreadable row is an empty queue, and 'good' still went out.
    expect(count, 1);
    expect(sent, ['g1']);
  });

  test('flushAll with no key listing sends nothing and does not throw',
      () async {
    await AgentsTaskOutbox.enqueue(sessionKey: 't', prompt: 'x');
    AgentsTaskOutbox.readKeys = (prefix) => throw StateError('no store');
    final count = await AgentsTaskOutbox.flushAll((task) async {});
    expect(count, 0);
    // The queue is untouched.
    expect((await AgentsTaskOutbox.pendingFor('t')).single.prompt, 'x');
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
