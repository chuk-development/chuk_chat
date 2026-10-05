import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/account_session.dart';
import 'package:chuk_chat/services/agents/agent_mail_crypto.dart';
import 'package:chuk_chat/services/agents/agent_mail_key_handover.dart';
import 'package:chuk_chat/services/agents/agent_mail_service.dart';
import 'package:chuk_chat/services/agents/agents_chat_core.dart';
import 'package:chuk_chat/services/agents/agents_device_keys.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';

import '../../support/agent_mail_fake.dart';
import 'agents_relay_client_test.dart' show FakeExecutorHost, FakeRelaySocket;

/// The mail key goes to the host over the end-to-end channel
/// (docs/AGENT_MAIL.md §6.1): behind the account token on every provision,
/// and again after the app made a new key. Only in the Agents build.
void main() {
  late FakeAgentMailServer server;
  late AgentMailService service;
  late List<Map<String, dynamic>> sent;
  late bool channelUp;
  late AgentMailKeyHandover handover;
  Object? sendError;

  Future<void> record(Map<String, dynamic> payload) async {
    final Object? error = sendError;
    if (error != null) throw error;
    sent.add(payload);
  }

  AgentMailKeyHandover handoverFor(AgentMailService s) => AgentMailKeyHandover(
    service: s,
    channel: () => channelUp ? record : null,
  );

  setUp(() {
    debugAgentsChatCoreOverride = true;
    server = FakeAgentMailServer();
    service = server.service();
    sent = <Map<String, dynamic>>[];
    channelUp = false;
    sendError = null;
    handover = handoverFor(service);
  });

  tearDown(() {
    handover.stop();
    debugAgentsChatCoreOverride = null;
  });

  Future<AgentMailKeyPair> serverKey() =>
      AgentMailKeyPair.fromPrivateKey(kFakeMailPrivateKey);

  test('rides behind the account token over the sealed channel', () async {
    var ts = 1700000000000;
    final FakeRelaySocket socket = FakeRelaySocket();
    final FakeExecutorHost host = FakeExecutorHost(
      socket: socket,
      deviceId: 'host-laptop-1',
      channelId: 'chan1234',
      digits: '428913',
      signingKeyPair: await AgentsDeviceKeys.generate(),
      nowMs: () => ts,
    );
    await host.start();
    final AgentsRelayClient client = AgentsRelayClient(
      deviceId: 'app-desktop-1',
      signingKeyPair: await AgentsDeviceKeys.generate(),
      connector: (_) async => socket,
      nowMs: () => ts,
      mailKeyForwarder: handover.forwardTo,
    );
    await client.connect(
      hostUrl: Uri.parse('ws://127.0.0.1:8787'),
      pairingCode: 'chan1234-428913',
    );
    await host.paired.future;
    ts += 1;
    expect(
      host.received.where(
        (Map<String, dynamic> m) => m['type'] == 'agent_mail_key',
      ),
      isEmpty,
      reason: 'nothing before the account token',
    );

    await client.provisionAccount(
      const AccountSession(
        accessToken: 'access-1',
        refreshToken: 'refresh-1',
        userId: 'user-1',
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final List<String?> types = <String?>[
      for (final Map<String, dynamic> m in host.received) m['type'] as String?,
    ];
    expect(types, contains('agent_mail_key'));
    expect(
      types.indexOf('account_authentication'),
      lessThan(types.indexOf('agent_mail_key')),
    );
    final Map<String, dynamic> frame = host.received.singleWhere(
      (Map<String, dynamic> m) => m['type'] == 'agent_mail_key',
    );
    final AgentMailKeyPair key = await serverKey();
    expect(frame, <String, dynamic>{
      'type': 'agent_mail_key',
      'public_key': key.publicKeyBase64,
      'private_key': base64Encode(key.privateKey),
    });
    // Raw 32-byte keys, and the public one is derived from the private one.
    expect(base64Decode(frame['private_key'] as String), hasLength(32));
    final AgentMailKeyPair derived = await AgentMailKeyPair.fromPrivateKey(
      base64Decode(frame['private_key'] as String),
    );
    expect(derived.publicKeyBase64, frame['public_key']);

    // A re-provision (a token refresh) sends it again; the host keeps one.
    await client.provisionAccount(
      const AccountSession(
        accessToken: 'access-2',
        refreshToken: 'refresh-2',
        userId: 'user-1',
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(
      host.received.where(
        (Map<String, dynamic> m) => m['type'] == 'agent_mail_key',
      ),
      hasLength(2),
    );
    // The key was read once; the second time it came from memory.
    expect(server.calls, <String>['GET /key']);
    await client.dispose();
  });

  test('a mailbox without a key sends nothing and makes none', () async {
    final FakeAgentMailServer fresh = FakeAgentMailServer(hasKey: false);
    handover = handoverFor(fresh.service());
    await handover.handOver(record);
    expect(sent, isEmpty);
    expect(fresh.calls, <String>['GET /key']);
  });

  test('a key made while the channel is up goes at once', () async {
    final FakeAgentMailServer fresh = FakeAgentMailServer(hasKey: false);
    final AgentMailService freshService = fresh.service();
    handover = handoverFor(freshService)..start();
    channelUp = true;

    // The user opens the mailbox, which makes the key.
    await freshService.openMailbox();
    await pumpEventQueue();

    final AgentMailKeyPair made = freshService.cachedKey!;
    expect(sent, <Map<String, dynamic>>[agentMailKeyFrame(made)]);
    expect(
      fresh.bodiesOf('PUT', '/key').single['public_key'],
      sent.single['public_key'],
    );
  });

  test('a key made with no channel goes with the next provision', () async {
    final FakeAgentMailServer fresh = FakeAgentMailServer(hasKey: false);
    final AgentMailService freshService = fresh.service();
    handover = handoverFor(freshService)..start();
    await freshService.openMailbox();
    await pumpEventQueue();
    expect(sent, isEmpty);

    await handover.handOver(record);
    expect(sent, <Map<String, dynamic>>[
      agentMailKeyFrame(freshService.cachedKey!),
    ]);
  });

  test('a failed send is swallowed', () async {
    sendError = StateError('Not paired');
    await expectLater(handover.handOver(record), completes);
    expect(sent, isEmpty);
    sendError = null;
    await handover.handOver(record);
    expect(sent, hasLength(1));
  });

  test('a locked chuk key is swallowed too', () async {
    server.secretBox.locked = true;
    await expectLater(handover.handOver(record), completes);
    expect(sent, isEmpty);
  });

  test('not in the Agents build: nothing at all', () async {
    debugAgentsChatCoreOverride = false;
    handover.start();
    channelUp = true;
    await handover.handOver(record);
    expect(sent, isEmpty);
    expect(server.calls, isEmpty);
  });

  test('after stop a new key is not sent', () async {
    final FakeAgentMailServer fresh = FakeAgentMailServer(hasKey: false);
    final AgentMailService freshService = fresh.service();
    handover = handoverFor(freshService)
      ..start()
      ..stop();
    channelUp = true;
    await freshService.openMailbox();
    await pumpEventQueue();
    expect(sent, isEmpty);
  });
}
