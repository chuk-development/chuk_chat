// The heal path: a paired host whose account session died parks on a channel
// derived from the pairing's channel key; a reconnect that finds its host
// offline claims that channel once, and the host is reachable again with no
// new pairing. Also the host session: the app's own refresh token never
// reaches the host, and a `host_session_request` is answered with a session
// minted for the host alone.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:chuk_chat/services/account_session.dart';
import 'package:chuk_chat/services/agents/agents_cloud_relay.dart';
import 'package:chuk_chat/services/agents/agents_device_keys.dart';
import 'package:chuk_chat/services/agents/agents_heal_channel.dart';
import 'package:chuk_chat/services/agents/agents_host_session.dart';
import 'package:chuk_chat/services/agents/agents_pairing_store.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/executor_provisioning.dart';

class _Session implements AccountSessionSource {
  _Session(this._current);
  final AccountSession? _current;
  @override
  AccountSession? current() => _current;
  @override
  Future<AccountSession?> refresh() async => _current;
}

/// The relay as a reconnect sees it: `auth_ok`, then the presence snapshot it
/// always sends, then the answer to a claim.
class _Relay implements RelaySocket {
  _Relay({required this.online, this.claimCode});

  /// Executor ids the presence snapshot reports online.
  final List<String> online;

  /// Null: the claim succeeds for [hostId]. Else the refusal code.
  final String? claimCode;

  /// True: the relay never answers a claim.
  bool silentClaims = false;

  static const String hostId = 'host-relay-uuid';

  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
  final StreamController<dynamic> _toApp = StreamController<dynamic>.broadcast();
  bool closed = false;

  @override
  Stream<dynamic> get incoming => _toApp.stream;

  @override
  void send(String data) {
    final frame = jsonDecode(data) as Map<String, dynamic>;
    sent.add(frame);
    switch (frame['type']) {
      case 'auth':
        _deliver(<String, dynamic>{'type': 'auth_ok'});
        _deliver(<String, dynamic>{
          'type': 'cowork_presence',
          'executors': <Map<String, dynamic>>[
            for (final id in online) <String, dynamic>{'device_id': id, 'online': true},
          ],
        });
      case 'cowork_pair_claim':
        if (silentClaims) return;
        final code = claimCode;
        if (code != null) {
          _deliver(<String, dynamic>{
            'type': 'cowork_pair_error',
            'code': code,
            'req_id': frame['req_id'],
          });
          return;
        }
        _deliver(<String, dynamic>{
          'type': 'executor_status',
          'device_id': hostId,
          'online': true,
        });
        _deliver(<String, dynamic>{
          'type': 'cowork_pair_claimed',
          'device_id': hostId,
          'req_id': frame['req_id'],
        });
    }
  }

  void deliver(Map<String, dynamic> frame) => _deliver(frame);

  void _deliver(Map<String, dynamic> frame) {
    if (!_toApp.isClosed) _toApp.add(jsonEncode(frame));
  }

  @override
  Future<void> close() async {
    closed = true;
    if (!_toApp.isClosed) await _toApp.close();
  }
}

class _RecordingTransport implements ExecutorTransport {
  final List<Map<String, dynamic>> payloads = <Map<String, dynamic>>[];
  @override
  Future<void> sendAuthentication(
    ExecutorHandle target,
    Map<String, dynamic> payload,
  ) async {
    payloads.add(payload);
  }
}

void main() {
  const AccountSession appSession = AccountSession(
    accessToken: 'app-access',
    refreshToken: 'app-refresh',
    userId: 'user-1',
    expiresAt: 1800000000,
  );

  group('the heal channel', () {
    test('matches the host derivation (shared vector)', () async {
      // Asserted with the same value in agents/host/tests/test_host_credential.py.
      final channel = await deriveAgentsHealChannel(
        List<int>.generate(32, (i) => i),
        '0123456789abcdef',
      );
      expect(channel, 'P6dK7KJxfD_xxCQuKe-OjUhdpol5n_UHLtRlMQPHnHk');
    });

    test('is 43 url-safe characters and depends on key and channel', () async {
      final key = Uint8List.fromList(List<int>.generate(32, (i) => i));
      final a = await deriveAgentsHealChannel(key, 'chan-a');
      expect(a.length, 43);
      expect(RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(a), isTrue);
      expect(await deriveAgentsHealChannel(key, 'chan-b'), isNot(a));
      expect(await deriveAgentsHealChannel(Uint8List(32), 'chan-a'), isNot(a));
    });

    test('refuses a malformed key or channel', () async {
      expect(
        () => deriveAgentsHealChannel(<int>[1, 2, 3], 'c'),
        throwsArgumentError,
      );
      expect(
        () => deriveAgentsHealChannel(Uint8List(32), ''),
        throwsArgumentError,
      );
    });
  });

  group('the dial address', () {
    test('carries the heal channel only to the dial, never to the server', () {
      final address = AgentsCloudRelayAddress(
        base: Uri.parse('wss://api.chuk.chat'),
        targetDeviceId: 'host-1',
        healChannel: 'HEAL',
      );
      expect(AgentsCloudRelayAddress.tryParse(address.toUri()), address);
      expect(address.dialUri.query, isEmpty);
      expect(address.toString(), isNot(contains('HEAL')));
    });
  });

  group('a reconnect', () {
    AgentsCloudRelayAddress address() => AgentsCloudRelayAddress(
      base: Uri.parse('wss://api.chuk.chat'),
      targetDeviceId: _Relay.hostId,
      healChannel: 'H' * 43,
    );

    test('claims the heal channel when its host is offline', () async {
      final relay = _Relay(online: const <String>[]);
      final socket = await AgentsCloudRelaySocket.connect(
        address: address(),
        deviceId: 'app-device',
        sessionSource: _Session(appSession),
        inner: (_) async => relay,
      );
      expect(relay.sent.map((f) => f['type']), <String>['auth', 'cowork_pair_claim']);
      expect(relay.sent[1]['pairing_channel'], 'H' * 43);
      expect(socket.targetDeviceId, _Relay.hostId);
      await socket.close();
    });

    test('does not claim when its host is online', () async {
      final relay = _Relay(online: const <String>[_Relay.hostId]);
      final socket = await AgentsCloudRelaySocket.connect(
        address: address(),
        deviceId: 'app-device',
        sessionSource: _Session(appSession),
        inner: (_) async => relay,
      );
      expect(relay.sent.map((f) => f['type']), <String>['auth']);
      await socket.close();
    });

    test('goes on as before when nothing is parked there', () async {
      final relay = _Relay(
        online: const <String>[],
        claimCode: 'pairing_channel_unknown',
      );
      final socket = await AgentsCloudRelaySocket.connect(
        address: address(),
        deviceId: 'app-device',
        sessionSource: _Session(appSession),
        inner: (_) async => relay,
      );
      // No exception, no pairing screen: the ordinary offline path.
      expect(socket.targetDeviceId, _Relay.hostId);
      expect(relay.closed, isFalse);
      await socket.close();
    });

    test('a claim the relay never answers does not hold up the reconnect or '
        'swallow a later error frame', () async {
      final relay = _Relay(online: const <String>[])..silentClaims = true;
      final watch = Stopwatch()..start();
      final socket = await AgentsCloudRelaySocket.connect(
        address: address(),
        deviceId: 'app-device',
        sessionSource: _Session(appSession),
        inner: (_) async => relay,
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
      final done = Completer<void>();
      socket.incoming.listen((_) {}, onDone: done.complete);
      // The stale claim waiter would have eaten this; now it closes the pipe.
      relay.deliver(<String, dynamic>{
        'type': 'cowork_error',
        'code': 'executor_offline',
        'target_device_id': _Relay.hostId,
      });
      await done.future.timeout(const Duration(seconds: 2));
      expect(relay.closed, isTrue);
    });

    test('the relay client adds the heal channel of its pairing', () async {
      final key = Uint8List.fromList(List<int>.generate(32, (i) => i));
      final expected = await deriveAgentsHealChannel(key, '0123456789abcdef');
      Uri? dialled;
      final client = AgentsRelayClient(
        deviceId: 'app-device',
        signingKeyPair: await _keyPair(),
        connector: (url) async {
          dialled = url;
          throw StateError('stop here');
        },
      );
      final pairing = await _pairing(
        key,
        Uri.parse('wss://api.chuk.chat/v2/relay/ws?cw_device=${_Relay.hostId}'),
      );
      await expectLater(
        client.reconnect(hostUrl: pairing.hostUrl, pairing: pairing),
        throwsStateError,
      );
      final parsed = AgentsCloudRelayAddress.tryParse(dialled!)!;
      expect(parsed.healChannel, expected);
      expect(parsed.targetDeviceId, _Relay.hostId);
      await client.dispose();
    });

    test('a local host URL is dialled unchanged', () async {
      Uri? dialled;
      final client = AgentsRelayClient(
        deviceId: 'app-device',
        signingKeyPair: await _keyPair(),
        connector: (url) async {
          dialled = url;
          throw StateError('stop here');
        },
      );
      final pairing = await _pairing(
        Uint8List(32),
        Uri.parse('ws://127.0.0.1:8787'),
      );
      await expectLater(
        client.reconnect(hostUrl: pairing.hostUrl, pairing: pairing),
        throwsStateError,
      );
      expect(dialled, Uri.parse('ws://127.0.0.1:8787'));
      await client.dispose();
    });
  });

  group('provisioning', () {
    test("never hands the host the app's refresh token", () async {
      final transport = _RecordingTransport();
      await ExecutorProvisioning(transport).provision(
        const ExecutorHandle(deviceId: 'host'),
        appSession,
      );
      final payload = transport.payloads.single;
      expect(payload['type'], 'account_authentication');
      expect(payload['access_token'], 'app-access');
      expect(payload.containsKey('refresh_token'), isFalse);
      expect(payload.containsKey('session_kind'), isFalse);
      expect(payload['expires_at'], 1800000000);
    });

    test('hands over a minted host session marked as the host\'s own', () async {
      final transport = _RecordingTransport();
      await ExecutorProvisioning(transport).provisionHostSession(
        const ExecutorHandle(deviceId: 'host'),
        const AgentsHostSession(
          accessToken: 'host-access',
          refreshToken: 'host-refresh',
          userId: 'user-1',
          expiresAt: 1800003600,
        ),
      );
      final payload = transport.payloads.single;
      expect(payload['session_kind'], 'host');
      expect(payload['refresh_token'], 'host-refresh');
      expect(payload['access_token'], 'host-access');
      expect(payload['user_id'], 'user-1');
      expect(payload['expires_at'], 1800003600);
    });
  });

  group('minting a host session', () {
    test('posts with the app bearer and reads the session', () async {
      http.Request? seen;
      final client = MockClient((request) async {
        seen = request;
        return http.Response(
          jsonEncode(<String, dynamic>{
            'access_token': 'host-access',
            'refresh_token': 'host-refresh',
            'user_id': 'user-1',
            'expires_at': 1800003600,
            'session_kind': 'host',
          }),
          200,
        );
      });
      final grant = await mintAgentsHostSession(
        appSession,
        client: client,
        baseUrl: 'https://api.example.test',
      );
      expect(seen!.method, 'POST');
      expect(seen!.url.toString(), 'https://api.example.test/v2/agents/host-session');
      expect(seen!.headers['Authorization'], 'Bearer app-access');
      expect(grant!.refreshToken, 'host-refresh');
      expect(grant.expiresAt, 1800003600);
      expect(grant.toString(), isNot(contains('host-refresh')));
    });

    test('is null on a refusal, a bad body, another user or no network', () async {
      Future<AgentsHostSession?> mint(MockClient client) => mintAgentsHostSession(
        appSession,
        client: client,
        baseUrl: 'https://api.example.test',
      );
      expect(await mint(MockClient((_) async => http.Response('{}', 429))), isNull);
      expect(await mint(MockClient((_) async => http.Response('nope', 200))), isNull);
      expect(
        await mint(
          MockClient(
            (_) async => http.Response(
              jsonEncode(<String, dynamic>{
                'access_token': 'a',
                'refresh_token': 'r',
                'user_id': 'someone-else',
              }),
              200,
            ),
          ),
        ),
        isNull,
      );
      expect(
        await mint(MockClient((_) async => throw http.ClientException('down'))),
        isNull,
      );
    });
  });
}

Future<SimpleKeyPair> _keyPair() => AgentsDeviceKeys.generate();

Future<AgentsStoredPairing> _pairing(Uint8List key, Uri hostUrl) async {
  final host = await AgentsDeviceKeys.generate();
  return AgentsStoredPairing(
    hostUrl: hostUrl,
    channelId: '0123456789abcdef',
    channelKey: key,
    peerDeviceId: 'cowork-host',
    peerPublicKey: await host.extractPublicKey(),
  );
}
