// test/services/agents/agents_pending_failed_test.dart
//
// Bead chuk_chat-9hgx: an Agents task that went to the socket but was never
// confirmed by the host used to be DROPPED after three attempts. It is now
// kept as a failed outbox entry under the same task id, its bubble offers
// Retry, and a Retry is still the same task to the host. And a `task_ack`
// for any thread clears its record app-wide, so a task that did arrive is
// never shown as failed.
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/agents/agents_outbox_flusher.dart';
import 'package:chuk_chat/services/agents/agents_queued_marks.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_task_outbox.dart';

import '../../support/fake_relay_controller.dart';

void main() {
  late Map<String, String> disk;
  late List<Map<String, dynamic>> transcript;

  setUp(() {
    disk = <String, String>{};
    AgentsTaskOutbox.resetForTest();
    AgentsTaskOutbox.read = (key) async => disk[key];
    AgentsTaskOutbox.write = (key, value) async => disk[key] = value;
    AgentsTaskOutbox.delete = (key) async => disk.remove(key);
    AgentsTaskOutbox.readKeys = (prefix) async => <String>[
      for (final String key in disk.keys)
        if (key.startsWith(prefix)) key,
    ];
    transcript = <Map<String, dynamic>>[
      <String, dynamic>{'role': 'user', 'text': 'build it'},
    ];
    AgentsQueuedMarks.readRows = (_) => transcript;
    AgentsQueuedMarks.writeRows = (_, rows) async => transcript = rows;
  });

  tearDown(() {
    AgentsOutboxFlusher.stopForTest();
    AgentsTaskOutbox.read = null;
    AgentsTaskOutbox.write = null;
    AgentsTaskOutbox.delete = null;
    AgentsTaskOutbox.readKeys = null;
    AgentsQueuedMarks.readRows = null;
    AgentsQueuedMarks.writeRows = null;
  });

  Future<void> sendTimes(int n) async {
    for (var i = 0; i < n; i++) {
      await AgentsPendingTasks.record(
        sessionKey: 't',
        taskId: 'task-1',
        prompt: 'build it',
        modelId: 'm1',
      );
    }
  }

  test(
    'an unconfirmed task out of attempts is kept as failed, not dropped',
    () async {
      await sendTimes(AgentsPendingTasks.maxAttempts);

      expect(await AgentsPendingTasks.mayRetry('t', 'task-1'), isFalse);

      // Off the unacknowledged record ...
      expect(await AgentsPendingTasks.pendingFor('t'), isEmpty);
      // ... and into the outbox as failed, under the SAME task id.
      final entry = (await AgentsTaskOutbox.pendingFor('t')).single;
      expect(entry.failed, isTrue);
      expect(entry.taskId, 'task-1');
      expect(entry.prompt, 'build it');
      expect(entry.modelId, 'm1');
      expect(entry.lastError, AgentsPendingTasks.notConfirmedError);
      // The bubble offers Retry.
      expect(transcript.single['status'], 'failed');
      expect(transcript.single['queueId'], entry.localId);
      // Automatic flushes leave it alone until the user asks.
      expect(await AgentsTaskOutbox.anyDue(), isFalse);

      // Retry: the entry is due again and goes out under its old id.
      expect(await AgentsTaskOutbox.requeueByLocalId(entry.localId), isTrue);
      final c = FakeRelayController()
        ..set(const AgentsRelayState(phase: AgentsRelayPhase.paired));
      expect(
        await AgentsTaskOutbox.flush(
          't',
          (task) => AgentsOutboxFlusher.sendQueued(c, task),
        ),
        1,
      );
      expect(c.taskIds, ['task-1']);
    },
  );

  test('resend skips and keeps the exhausted task', () async {
    await sendTimes(AgentsPendingTasks.maxAttempts);
    final sent = <String>[];
    final n = await AgentsPendingTasks.resend('t', (task) async {
      sent.add(task.taskId);
    });
    expect(n, 0);
    expect(sent, isEmpty);
    expect((await AgentsTaskOutbox.pendingFor('t')).single.failed, isTrue);
  });

  test('a task with attempts left is resent, not kept as failed', () async {
    await sendTimes(1);
    final sent = <String>[];
    await AgentsPendingTasks.resend('t', (task) async => sent.add(task.taskId));
    expect(sent, ['task-1']);
    expect(await AgentsTaskOutbox.pendingFor('t'), isEmpty);
  });

  test('a task_ack for any thread clears that thread\'s record', () async {
    await sendTimes(1);
    await AgentsPendingTasks.record(
      sessionKey: 'other',
      taskId: 'task-2',
      prompt: 'x',
    );
    final link = ValueNotifier<AgentsRelayController?>(null);
    final c = FakeRelayController();
    AgentsOutboxFlusher.startForTest(link, inbound: c.inbound);

    c.emit(
      const AgentsRelayTaskAck(
        taskId: 'task-1',
        status: 'duplicate',
        sessionKey: 't',
      ),
    );
    // An old host leaves the session key off: found by the task id.
    c.emit(const AgentsRelayTaskAck(taskId: 'task-2', status: 'accepted'));
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(await AgentsPendingTasks.pendingFor('t'), isEmpty);
    expect(await AgentsPendingTasks.pendingFor('other'), isEmpty);
    link.dispose();
  });
}
