import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/agents/agents_outbox_flusher.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_task_outbox.dart';

import '../../support/fake_relay_controller.dart';

/// The outbox goes out app-wide on the relay `paired` transition, not only
/// while a thread view is mounted.
void main() {
  late Map<String, String> disk;
  late ValueNotifier<AgentsRelayController?> link;
  late FakeRelayController controller;

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
    link = ValueNotifier<AgentsRelayController?>(null);
    controller = FakeRelayController();
  });

  tearDown(() {
    AgentsOutboxFlusher.stopForTest();
    AgentsTaskOutbox.read = null;
    AgentsTaskOutbox.write = null;
    AgentsTaskOutbox.delete = null;
    AgentsTaskOutbox.readKeys = null;
    link.dispose();
  });

  /// Lets the unawaited flush and its store round trips finish.
  Future<void> settle() async {
    for (int i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  void pair(FakeRelayController c) =>
      c.set(const AgentsRelayState(phase: AgentsRelayPhase.paired));

  test('every thread flushes on the transition into paired', () async {
    await AgentsTaskOutbox.enqueue(sessionKey: 'a', prompt: 'a1');
    await AgentsTaskOutbox.enqueue(sessionKey: 'b', prompt: 'b1');
    AgentsOutboxFlusher.startForTest(link);

    // A transport that is bound but not paired sends nothing.
    link.value = controller;
    await settle();
    expect(controller.tasks, isEmpty);

    pair(controller);
    await settle();
    expect(controller.tasks.toSet(), {'a1', 'b1'});
    expect(controller.taskSessionKeys.toSet(), {'a', 'b'});
    expect(await AgentsTaskOutbox.pendingFor('a'), isEmpty);
    expect(await AgentsTaskOutbox.pendingFor('b'), isEmpty);
  });

  test('a controller bound already paired flushes at once', () async {
    final task = await AgentsTaskOutbox.enqueue(sessionKey: 't', prompt: 'x');
    pair(controller);
    AgentsOutboxFlusher.startForTest(link);
    link.value = controller;
    await settle();
    expect(controller.tasks, ['x']);
    // It goes out under the id stored with the entry.
    expect(controller.taskIds, [task.taskId]);
  });

  test('a later reconnect flushes again', () async {
    AgentsOutboxFlusher.startForTest(link);
    link.value = controller;
    pair(controller);
    await settle();

    await AgentsTaskOutbox.enqueue(sessionKey: 't', prompt: 'offline');
    // The link drops and comes back.
    controller.set(const AgentsRelayState(phase: AgentsRelayPhase.closed));
    await settle();
    expect(controller.tasks, isEmpty);
    pair(controller);
    await settle();
    expect(controller.tasks, ['offline']);
  });

  test('a new transport is followed, the old one is let go', () async {
    AgentsOutboxFlusher.startForTest(link);
    link.value = controller;
    pair(controller);
    await settle();

    final FakeRelayController next = FakeRelayController();
    link.value = next;
    await AgentsTaskOutbox.enqueue(sessionKey: 't', prompt: 'neu');
    pair(next);
    await settle();
    expect(next.tasks, ['neu']);
    expect(controller.tasks, isEmpty);
  });

  test('the flusher and a view flushing at once send the prompt once, under '
      'one id', () async {
    final task = await AgentsTaskOutbox.enqueue(sessionKey: 't', prompt: 'x');
    pair(controller);
    AgentsOutboxFlusher.startForTest(link);
    link.value = controller;
    // What the view's own paired handler runs, in the same moment.
    await AgentsOutboxFlusher.flushAllVia(controller);
    await settle();
    expect(controller.tasks, ['x']);
    expect(controller.taskIds.toSet(), {task.taskId});
  });

  test('a sender with no link defers without counting an attempt', () async {
    await AgentsTaskOutbox.enqueue(sessionKey: 't', prompt: 'x');
    expect(await AgentsOutboxFlusher.flushAllVia(controller), 0);
    final task = (await AgentsTaskOutbox.pendingFor('t')).single;
    expect(task.attempts, 0);
    expect(controller.tasks, isEmpty);
  });
}
