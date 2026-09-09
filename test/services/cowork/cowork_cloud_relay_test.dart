import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cowork/services/account_session.dart';
import 'package:cowork/services/cowork/cowork_approved_devices.dart';
import 'package:cowork/services/cowork/cowork_cloud_relay.dart';
import 'package:cowork/services/cowork/cowork_device_keys.dart';
import 'package:cowork/services/cowork/cowork_frame.dart';
import 'package:cowork/services/cowork/cowork_frame_codec.dart';
import 'package:cowork/services/cowork/cowork_pairing.dart';
import 'package:cowork/services/cowork/cowork_pairing_uri.dart';
import 'package:cowork/services/cowork/cowork_relay_client.dart';

/// A stand-in for `api.chuk.chat/v2/relay/ws`.
///
/// It is the socket the cloud transport actually opens, so everything the app
/// puts on the wire lands in [sent] verbatim — which is what makes the frame
/// shapes assertable. It answers the handshake and the claim, and it plays the
/// relay's routing: a `cowork_relay` frame from the app is unwrapped and handed
/// to the host side, and whatever the host answers is wrapped again.
class _FakeRelayServer implements RelaySocket {
  _FakeRelayServer({this.authOk = true, this.claimReply});

  final bool authOk;

  /// What the relay answers a `cowork_pair_claim` with. Null means the real
  /// success pair: an `executor_status` delta, then `cowork_pair_claimed`.
  final Map<String, dynamic>? claimReply;

  /// Every frame the app sent, decoded.
  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];

  /// Local-relay envelopes the app addressed to the host, unwrapped.
  final StreamController<Map<String, dynamic>> _toHost =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get toHost => _toHost.stream;

  final StreamController<dynamic> _toApp =
      StreamController<dynamic>.broadcast();
  bool closed = false;

  static const String hostDeviceId = 'host-device-uuid';

  @override
  Stream<dynamic> get incoming => _toApp.stream;

  @override
  void send(String data) {
    final frame = jsonDecode(data) as Map<String, dynamic>;
    sent.add(frame);
    switch (frame['type']) {
      case 'auth':
        _deliver(
          authOk
              ? <String, dynamic>{'type': 'auth_ok'}
              : <String, dynamic>{
                  'type': 'auth_error',
                  'detail': 'Invalid token',
                },
        );
      case 'cowork_pair_claim':
        final reply = claimReply;
        if (reply != null) {
          _deliver(<String, dynamic>{...reply, 'req_id': frame['req_id']});
          return;
        }
        // The real order: the presence delta first, then the answer.
        _deliver(<String, dynamic>{
          'type': 'executor_status',
          'device_id': hostDeviceId,
          'online': true,
        });
        _deliver(<String, dynamic>{
          'type': 'cowork_pair_claimed',
          'device_id': hostDeviceId,
          'req_id': frame['req_id'],
        });
      case 'cowork_relay':
        // The host receives a JSON string and decodes it, exactly as it does
        // for a frame off the loopback relay.
        final payload = frame['payload'];
        if (payload is String) {
          _toHost.add(jsonDecode(payload) as Map<String, dynamic>);
        }
    }
  }

  /// The host answers. An executor sends no target_device_id, and its payload
  /// is a JSON string like ours.
  void fromHost(Map<String, dynamic> envelope) {
    _deliver(<String, dynamic>{
      'req_id': 'server1',
      'type': 'cowork_relay',
      'payload': jsonEncode(envelope),
    });
  }

  void _deliver(Map<String, dynamic> frame) {
    if (!_toApp.isClosed) _toApp.add(jsonEncode(frame));
  }

  @override
  Future<void> close() async {
    closed = true;
    if (!_toApp.isClosed) await _toApp.close();
    if (!_toHost.isClosed) await _toHost.close();
  }
}

/// The §15 initiator, exactly as the host runs it, speaking the LOCAL relay
/// envelopes. It never learns that a cloud relay is in the middle — which is the
/// property this whole file exists to prove.
class _HostSide {
  _HostSide({
    required this.server,
    required this.channelId,
    required this.digits,
    required this.signingKeyPair,
    required this.deviceId,
  });

  final _FakeRelayServer server;
  final String channelId;
  final String digits;
  final SimpleKeyPair signingKeyPair;
  final String deviceId;

  late final CoworkPairing _initiator;
  CoworkFrameSealer? _sealer;
  CoworkFrameOpener? _opener;

  /// Payloads the host opened out of the app's sealed frames.
  final List<Map<String, dynamic>> opened = <Map<String, dynamic>>[];
  final Completer<void> paired = Completer<void>();

  Future<void> start() async {
    _initiator = await CoworkPairing.initiator(
      deviceId: deviceId,
      deviceKeyPair: signingKeyPair,
      channelId: channelId,
      digits: digits,
      approvedDevices: CoworkApprovedDevices.empty(),
    );
    server.toHost.listen(_onEnvelope);
  }

  void _send(String step, Map<String, dynamic> data) => server.fromHost(
    <String, dynamic>{'type': 'pairing', 'step': step, 'data': data},
  );

  Future<void> _onEnvelope(Map<String, dynamic> env) async {
    switch (env['type']) {
      case 'join':
        _send('commit', _initiator.createCommit());
      case 'pairing':
        final step = env['step'] as String;
        final data = (env['data'] as Map).cast<String, dynamic>();
        switch (step) {
          case 'pubkey':
            _send('reveal', await _initiator.onPubkey(data));
          case 'confirm-d':
            _send('confirm-c', await _initiator.onConfirmD(data));
            _send('device-c', await _initiator.createDeviceKey());
          case 'device-d':
            await _initiator.onPeerDeviceKey(data);
            _establishCodec();
            if (!paired.isCompleted) paired.complete();
        }
      case 'frame':
        final frame = CoworkFrame.fromJsonString(
          utf8.decode(base64.decode(env['frame'] as String)),
        );
        opened.add(
          jsonDecode(utf8.decode(await _opener!.open(frame)))
              as Map<String, dynamic>,
        );
    }
  }

  void _establishCodec() {
    _sealer = CoworkFrameSealer.withChannelKey(
      channelKey: _initiator.channelKey,
      keyVersion: 1,
      deviceId: deviceId,
      signingKeyPair: signingKeyPair,
    );
    _opener = CoworkFrameOpener.withChannelKey(
      channelKey: _initiator.channelKey,
      keyVersion: 1,
      approvedDevices: _initiator.approvedDevices,
    );
  }

  Future<void> emit(Map<String, dynamic> payload) async {
    final frame = await _sealer!.seal(utf8.encode(jsonEncode(payload)));
    server.fromHost(<String, dynamic>{
      'type': 'frame',
      'frame': base64.encode(utf8.encode(frame.toJsonString())),
    });
  }
}

class _Session implements AccountSessionSource {
  _Session(this._session);
  final AccountSession? _session;

  @override
  AccountSession? current() => _session;

  @override
  Future<AccountSession?> refresh() async => _session;
}

void main() {
  const String channel = 'k7m2p9q4w8r3t6y1u5i0o2a7s4d9f3g6h1j8k5l2z7x4c9v6b3';
  const String digits = '428913';
  const String appDeviceId = 'app-device-uuid';

  final AccountSessionSource signedIn = _Session(
    const AccountSession(
      accessToken: 'jwt-1',
      refreshToken: 'refresh-1',
      userId: 'user-1',
    ),
  );

  setUp(CoworkCloudRelaySocket.resetClaimCache);

  CoworkPairingInvite invite({String? relay}) => CoworkPairingInvite.tryParse(
    'cowork://pair?c=$channel&k=$digits${relay == null ? '' : '&r=$relay'}',
  )!;

  group('the dial address', () {
    test(
      'carries the pairing channel, then the host, and survives a parse',
      () {
        final pairing = CoworkCloudRelayAddress.forInvite(invite());
        expect(pairing.dialUri, Uri.parse('wss://api.chuk.chat/v2/relay/ws'));
        expect(CoworkCloudRelayAddress.tryParse(pairing.toUri()), pairing);

        final reconnect = CoworkCloudRelayAddress.forHost(
          base: Uri.parse('wss://api.chuk.chat'),
          targetDeviceId: 'host-1',
        );
        expect(CoworkCloudRelayAddress.tryParse(reconnect.toUri()), reconnect);
        // The markers never reach the server.
        expect(reconnect.dialUri.query, isEmpty);
      },
    );

    test('a restored trust is repointed from a loopback to the relay', () {
      // What the phone used to be handed: another machine's own address.
      expect(
        CoworkCloudRelayAddress.forRestoredTrust(
          Uri.parse('ws://127.0.0.1:8787'),
          'host-1',
        ),
        Uri.parse('wss://api.chuk.chat/v2/relay/ws?cw_device=host-1'),
      );
      // An address that already names a relay is left exactly as it is, so a
      // self-hosted backend survives a reinstall.
      final selfHosted = Uri.parse(
        'wss://relay.example.test/v2/relay/ws?cw_device=host-1',
      );
      expect(
        CoworkCloudRelayAddress.forRestoredTrust(selfHosted, 'host-1'),
        selfHosted,
      );
    });

    test('a local host URL is not a cloud address', () {
      expect(
        CoworkCloudRelayAddress.tryParse(Uri.parse('ws://127.0.0.1:8787')),
        isNull,
      );
    });
  });

  group('the handshake', () {
    test(
      'authenticates as the controller and claims the scanned channel',
      () async {
        final server = _FakeRelayServer();
        final socket = await CoworkCloudRelaySocket.connect(
          address: CoworkCloudRelayAddress.forInvite(invite()),
          deviceId: appDeviceId,
          sessionSource: signedIn,
          inner: (_) async => server,
        );

        expect(server.sent[0], <String, dynamic>{
          'type': 'auth',
          'token': 'jwt-1',
          'role': 'controller',
          'device_id': appDeviceId,
        });
        expect(server.sent[1]['type'], 'cowork_pair_claim');
        expect(server.sent[1]['pairing_channel'], channel);
        expect(server.sent[1]['req_id'], isA<String>());
        // The claim's answer is the only place the host's device id comes from.
        expect(socket.targetDeviceId, _FakeRelayServer.hostDeviceId);
        expect(
          CoworkCloudRelaySocket.learnedTarget(
            base: Uri.parse('wss://api.chuk.chat'),
            pairingChannel: channel,
          ),
          _FakeRelayServer.hostDeviceId,
        );
        await socket.close();
      },
    );

    test('a typed code carries its own channel and claims it', () async {
      // §15 defines the pairing code as channel id + digits, so the typed
      // fallback needs nothing the QR has (bead cowork-b75, resolved).
      final typed = CoworkPairingInvite.tryParse('$channel-$digits')!;
      expect(typed.pairingChannel, channel);

      final server = _FakeRelayServer();
      final socket = await CoworkCloudRelaySocket.connect(
        address: CoworkCloudRelayAddress.forInvite(typed),
        deviceId: appDeviceId,
        sessionSource: signedIn,
        inner: (_) async => server,
      );

      expect(server.sent[1]['type'], 'cowork_pair_claim');
      expect(server.sent[1]['pairing_channel'], channel);
      await socket.close();
    });

    test('a reconnect dials the relay and never claims again', () async {
      final server = _FakeRelayServer();
      final socket = await CoworkCloudRelaySocket.connect(
        address: CoworkCloudRelayAddress.forHost(
          base: Uri.parse('wss://api.chuk.chat'),
          targetDeviceId: 'host-1',
        ),
        deviceId: appDeviceId,
        sessionSource: signedIn,
        inner: (_) async => server,
      );

      expect(server.sent.map((f) => f['type']), <String>['auth']);
      expect(socket.targetDeviceId, 'host-1');
      await socket.close();
    });

    test('a refused sign-in is one plain sentence, not a code', () async {
      final server = _FakeRelayServer(authOk: false);
      await expectLater(
        CoworkCloudRelaySocket.connect(
          address: CoworkCloudRelayAddress.forInvite(invite()),
          deviceId: appDeviceId,
          sessionSource: signedIn,
          inner: (_) async => server,
        ),
        throwsA(
          isA<CoworkCloudRelayException>().having(
            (e) => e.message,
            'message',
            contains('Sign in again'),
          ),
        ),
      );
      expect(server.closed, isTrue);
    });

    test('a refused claim is one plain sentence, not a code', () async {
      // The server refuses an expired channel, an unknown one and one another
      // account holds with the same code, on purpose.
      final server = _FakeRelayServer(
        claimReply: const <String, dynamic>{
          'type': 'cowork_pair_error',
          'code': 'pairing_channel_unknown',
        },
      );
      await expectLater(
        CoworkCloudRelaySocket.connect(
          address: CoworkCloudRelayAddress.forInvite(invite()),
          deviceId: appDeviceId,
          sessionSource: signedIn,
          inner: (_) async => server,
        ),
        throwsA(
          isA<CoworkCloudRelayException>().having(
            (e) => e.message,
            'message',
            allOf(contains('not valid any more'), isNot(contains(channel))),
          ),
        ),
      );
    });

    test('signed out never opens a socket', () async {
      var opened = false;
      await expectLater(
        CoworkCloudRelaySocket.connect(
          address: CoworkCloudRelayAddress.forInvite(invite()),
          deviceId: appDeviceId,
          sessionSource: _Session(null),
          inner: (_) async {
            opened = true;
            return _FakeRelayServer();
          },
        ),
        throwsA(isA<CoworkCloudRelayException>()),
      );
      expect(opened, isFalse);
    });
  });

  group('the connector', () {
    test('leaves a local ws:// dial to the plain socket', () async {
      final plain = _FakeRelayServer();
      Uri? asked;
      final connector = coworkCloudRelayConnector(
        deviceId: appDeviceId,
        sessionSource: signedIn,
        inner: (url) async {
          asked = url;
          return plain;
        },
      );

      final socket = await connector(Uri.parse('ws://127.0.0.1:8787'));

      expect(identical(socket, plain), isTrue);
      expect(asked, Uri.parse('ws://127.0.0.1:8787'));
      // No handshake: the local blind relay has none.
      expect(plain.sent, isEmpty);
    });
  });

  group('the whole ceremony over the cloud pipe', () {
    test('pairs, then seals and opens frames in both directions', () async {
      final server = _FakeRelayServer();
      final host = _HostSide(
        server: server,
        channelId: channel,
        digits: digits,
        deviceId: _FakeRelayServer.hostDeviceId,
        signingKeyPair: await CoworkDeviceKeys.generate(),
      );
      await host.start();

      final client = CoworkRelayClient(
        deviceId: appDeviceId,
        signingKeyPair: await CoworkDeviceKeys.generate(),
        connector: coworkCloudRelayConnector(
          deviceId: appDeviceId,
          sessionSource: signedIn,
          inner: (_) async => server,
        ),
      );
      addTearDown(client.dispose);

      final address = CoworkCloudRelayAddress.forInvite(invite());
      await client.connect(
        hostUrl: address.toUri(),
        pairingCode: invite().pairingCode,
      );
      await host.paired.future;

      expect(client.state.value.phase, CoworkRelayPhase.paired);
      expect(
        client.establishedTrust?.peerDeviceId,
        _FakeRelayServer.hostDeviceId,
      );

      // Every app frame rode as an opaque payload addressed to the host.
      final relayed = server.sent
          .where((f) => f['type'] == 'cowork_relay')
          .toList();
      expect(relayed, isNotEmpty);
      for (final frame in relayed) {
        expect(frame['target_device_id'], _FakeRelayServer.hostDeviceId);
        expect(frame['req_id'], isA<String>());
        // A JSON string, not a nested object: the host's contract.
        expect(frame['payload'], isA<String>());
      }
      // The join goes FIRST. The relay tells the executor nothing about
      // presence, so this payload is the host's only signal that a controller
      // attached — anything ahead of it and the ceremony never starts.
      expect(jsonDecode(relayed.first['payload'] as String), <String, dynamic>{
        'type': 'join',
        'channel': channel,
        'role': 'controller',
      });

      // App → host: a sealed task frame, wrapped and unwrapped, opens.
      await client.sendTask('write the report', sessionKey: 'default');
      await Future<void>.delayed(Duration.zero);
      expect(host.opened.last, containsPair('prompt', 'write the report'));

      // Host → app: a sealed delta, wrapped and unwrapped, opens.
      final inbound = client.inbound.first;
      await host.emit(<String, dynamic>{'type': 'delta', 'text': 'on it'});
      final event = await inbound.timeout(const Duration(seconds: 5));
      expect(event, isA<CoworkRelayDelta>());
      expect((event as CoworkRelayDelta).text, 'on it');
    });
  });
}
