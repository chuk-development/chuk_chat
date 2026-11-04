// test/services/agents/agents_background_link_test.dart
//
// Bead chuk_chat-16de: queued Agents prompts go out also when no thread view
// was ever opened. The background link opens a relay link when work waits
// and none is bound, the app-wide flusher sends the queue on `paired`, the
// link closes again when nothing is left, and it steps back the moment a
// thread view binds its own controller.

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/account_session.dart';
import 'package:chuk_chat/services/agents/agents_background_link.dart';
import 'package:chuk_chat/services/agents/agents_outbox_flusher.dart';
import 'package:chuk_chat/services/agents/agents_pairing_store.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_task_outbox.dart';

import '../../support/fake_relay_controller.dart';

final AgentsStoredPairing _pairing = AgentsStoredPairing(
  hostUrl: Uri.parse('wss://relay.example/v2/relay/ws'),
  channelId: 'ch',
  channelKey: Uint8List(32),
  peerDeviceId: 'host-1',
  peerPublicKey: SimplePublicKey(List<int>.filled(32, 1), type: KeyPairType.ed25519),
);

const AccountSession _session = AccountSession(
  accessToken: 'a',
  refreshToken: 'r',
  userId: 'u1',
);

void main() {
  late Map<String, String> disk;
  late ValueNotifier<AgentsRelayController?> slot;
  late List<FakeRelayController> built;

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
    slot = ValueNotifier<AgentsRelayController?>(null);
    built = <FakeRelayController>[];
  });

  tearDown(() {
    AgentsBackgroundLink.stopForTest();
    AgentsOutboxFlusher.stopForTest();
    AgentsTaskOutbox.read = null;
    AgentsTaskOutbox.write = null;
    AgentsTaskOutbox.delete = null;
    AgentsTaskOutbox.readKeys = null;
  });

  Future<void> settle() async {
    for (var i = 0; i < 30; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  AgentsBackgroundLink start({
    AgentsStoredPairing? pairing,
    bool noPairing = false,
    AccountSession? session = _session,
    bool reconnectFails = false,
  }) => AgentsBackgroundLink.startForTest(
    slot: slot,
    build: () async {
      final c = FakeRelayController()..reconnectFails = reconnectFails;
      built.add(c);
      return c;
    },
    // [noPairing]: no pairing stored on this device.
    loadPairing: () async => noPairing ? null : (pairing ?? _pairing),
    session: () => session,
    hasWork: AgentsBackgroundLink.hasQueuedWork,
  );

  test('a queued prompt goes out with no thread view, then the link closes',
      () async {
    await AgentsTaskOutbox.enqueue(sessionKey: 'thread-a', prompt: 'hello');
    AgentsOutboxFlusher.startForTest(slot);
    final link = start();

    await link.check();
    await settle();

    expect(built, hasLength(1));
    final c = built.single;
    expect(c.reconnectCalls, 1);
    expect(c.provisioned, isTrue);
    expect(c.tasks, ['hello']);
    expect(c.taskSessionKeys, ['thread-a']);
    expect(await AgentsTaskOutbox.pendingFor('thread-a'), isEmpty);

    // The host has not acknowledged it yet: the link stays up.
    await link.check();
    expect(identical(slot.value, c), isTrue);

    // Acknowledged: nothing left, the link closes.
    await AgentsPendingTasks.clear('thread-a', c.taskIds.single!);
    await link.check();
    expect(slot.value, isNull);
    expect(AgentsBackgroundLink.ownController, isNull);
  });

  test('nothing is opened without work, a session or a pairing', () async {
    final link = start();
    await link.check();
    expect(built, isEmpty);

    await AgentsTaskOutbox.enqueue(sessionKey: 't', prompt: 'x');
    AgentsBackgroundLink.stopForTest();
    final noSession = start(session: null);
    await noSession.check();
    expect(built, isEmpty);

    // Work and a session, but no pairing stored on this device.
    AgentsBackgroundLink.stopForTest();
    final noPairing = start(noPairing: true);
    await noPairing.check();
    expect(built, isEmpty);
    expect(slot.value, isNull);
  });

  test('a link of its own that died is dropped and built anew', () async {
    await AgentsTaskOutbox.enqueue(sessionKey: 't', prompt: 'x');
    final link = start(reconnectFails: true);
    await link.check();
    // The reconnect failed through its state (error), with no throw.
    final first = built.single;
    expect(identical(slot.value, first), isTrue);

    await link.check();
    expect(built, hasLength(2));
    expect(AgentsBackgroundLink.owns(first), isFalse);
    expect(identical(slot.value, built.last), isTrue);

    // A socket that closed after pairing is replaced the same way.
    built.last.set(const AgentsRelayState(phase: AgentsRelayPhase.closed));
    await link.check();
    expect(built, hasLength(3));
    expect(built[2].reconnectCalls, 1);
    expect(identical(slot.value, built[2]), isTrue);
  });

  test('a bound thread view link is left alone', () async {
    await AgentsTaskOutbox.enqueue(sessionKey: 't', prompt: 'x');
    final view = FakeRelayController();
    slot.value = view;
    final link = start();
    await link.check();
    expect(built, isEmpty);
    expect(identical(slot.value, view), isTrue);
  });

  test('a thread view that binds later takes over', () async {
    await AgentsTaskOutbox.enqueue(sessionKey: 't', prompt: 'x');
    final link = start();
    await link.check();
    expect(AgentsBackgroundLink.owns(built.single), isTrue);

    final view = FakeRelayController();
    slot.value = view;
    expect(AgentsBackgroundLink.ownController, isNull);
    expect(AgentsBackgroundLink.owns(built.single), isFalse);
    expect(identical(slot.value, view), isTrue);
  });

  test('unacknowledged tasks are re-sent over the background link',
      () async {
    await AgentsPendingTasks.record(
      sessionKey: 'thread-b',
      taskId: 'task-9',
      prompt: 'did this arrive?',
    );
    AgentsOutboxFlusher.startForTest(slot);
    final link = start();
    await link.check();
    await settle();
    expect(built.single.taskIds, ['task-9']);
    expect(built.single.tasks, ['did this arrive?']);
  });
}
