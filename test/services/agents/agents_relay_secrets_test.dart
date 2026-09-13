
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/account_session.dart';
import 'package:chuk_chat/services/agents/agents_device_keys.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';

import 'agents_relay_client_test.dart' show FakeExecutorHost, FakeRelaySocket;

/// The secrets frames over the real sealed channel (docs/WIRE_CONTRACT.md,
/// "Secrets"): a `secret_request` from the host surfaces as a
/// [AgentsRelaySecretRequest]; `sendSecrets` seals the whole set with the
/// request id; the set is forwarded once after every provision.
void main() {
  var ts = 1700000000000;
  int clock() => ts;

  Future<(AgentsRelayClient, FakeExecutorHost, FakeRelaySocket)> paired({
    Future<void> Function()? secretsForwarder,
  }) async {
    final socket = FakeRelaySocket();
    final host = FakeExecutorHost(
      socket: socket,
      deviceId: 'host-laptop-1',
      channelId: 'chan1234',
      digits: '428913',
      signingKeyPair: await AgentsDeviceKeys.generate(),
      nowMs: clock,
    );
    await host.start();
    final client = AgentsRelayClient(
      deviceId: 'app-desktop-1',
      signingKeyPair: await AgentsDeviceKeys.generate(),
      connector: (_) async => socket,
      nowMs: clock,
      secretsForwarder: secretsForwarder,
    );
    await client.connect(
      hostUrl: Uri.parse('ws://127.0.0.1:8787'),
      pairingCode: 'chan1234-428913',
    );
    await host.paired.future;
    ts += 1;
    return (client, host, socket);
  }

  test('a secret_request frame surfaces with names, purpose and thread',
      () async {
    final (client, host, _) = await paired();
    final events = <AgentsRelayInbound>[];
    final sub = client.inbound.listen(events.add);

    await host.emit(<String, dynamic>{
      'type': 'secret_request',
      'request_id': 'sr-1',
      'session_key': 'thread-1',
      'names': ['PEXELS_API_KEY', 'PIXABAY_API_KEY', 7],
      'purpose': 'fetch stock photos',
    });
    // A request with nothing to ask is dropped, not surfaced.
    await host.emit(<String, dynamic>{
      'type': 'secret_request',
      'request_id': 'sr-empty',
      'names': <String>[],
    });
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final request = events.whereType<AgentsRelaySecretRequest>().single;
    expect(request.requestId, 'sr-1');
    expect(request.names, ['PEXELS_API_KEY', 'PIXABAY_API_KEY']);
    expect(request.purpose, 'fetch stock photos');
    expect(request.sessionKey, 'thread-1');

    await sub.cancel();
    await client.dispose();
  });

  test('sendSecrets seals {type:secrets} with the whole set, sorted, and the '
      'request id; the host opens it', () async {
    final (client, host, _) = await paired();

    await client.sendSecrets(
      values: {'Z_KEY': 'zzzzzzzzzz', 'A_KEY': 'aaaaaaaaaa'},
      revision: 3,
      requestId: 'sr-1',
    );
    await Future<void>.delayed(Duration.zero);

    final frame = host.received.singleWhere((m) => m['type'] == 'secrets');
    expect(frame['entries'], [
      {'name': 'A_KEY', 'value': 'aaaaaaaaaa'},
      {'name': 'Z_KEY', 'value': 'zzzzzzzzzz'},
    ]);
    expect(frame['revision'], 3);
    expect(frame['request_id'], 'sr-1');

    await client.sendSecrets(values: const {}, revision: 4);
    await Future<void>.delayed(Duration.zero);
    final cleared = host.received.where((m) => m['type'] == 'secrets').last;
    expect(cleared['entries'], isEmpty);
    expect(cleared.containsKey('request_id'), isFalse);

    await client.dispose();
  });

  test('the secrets forwarder runs once after every provision', () async {
    var forwards = 0;
    final (client, _, _) = await paired(
      secretsForwarder: () async => forwards++,
    );
    expect(forwards, 0);

    await client.provisionAccount(
      const AccountSession(
        accessToken: 'access-1',
        refreshToken: 'refresh-1',
        userId: 'user-1',
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(forwards, 1);

    await client.dispose();
  });

  test('fromPayload drops a request with no id', () {
    expect(
      AgentsRelaySecretRequest.fromPayload(<String, dynamic>{
        'type': 'secret_request',
        'names': ['A'],
      }),
      isNull,
    );
  });
}
