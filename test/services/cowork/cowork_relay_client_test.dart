import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/account_session.dart';
import 'package:chuk_chat/services/cowork/cowork_approved_devices.dart';
import 'package:chuk_chat/services/cowork/cowork_device_keys.dart';
import 'package:chuk_chat/services/cowork/cowork_frame.dart';
import 'package:chuk_chat/services/cowork/cowork_frame_codec.dart';
import 'package:chuk_chat/services/cowork/cowork_pairing.dart';
import 'package:chuk_chat/services/cowork/cowork_relay_client.dart';

/// A fake duplex socket. `send()` from the client is captured on [outbound];
/// the test host writes to the client via [deliver].
class FakeRelaySocket implements RelaySocket {
  final StreamController<dynamic> _incoming =
      StreamController<dynamic>.broadcast();
  final StreamController<String> _outbound = StreamController<String>.broadcast();
  bool closed = false;

  @override
  Stream<dynamic> get incoming => _incoming.stream;

  /// Envelopes the client sent (join, pairing steps, frames).
  Stream<String> get outbound => _outbound.stream;

  @override
  void send(String data) {
    if (_outbound.isClosed) return;
    _outbound.add(data);
  }

  /// Push an envelope down to the client.
  void deliver(String data) {
    if (!_incoming.isClosed) _incoming.add(data);
  }

  @override
  Future<void> close() async {
    closed = true;
    if (!_incoming.isClosed) await _incoming.close();
    if (!_outbound.isClosed) await _outbound.close();
  }
}

/// The in-Dart executor: it plays the pairing INITIATOR and, once paired, seals
/// frames the client must open and opens frames the client sealed. This proves
/// the whole join → pair → provision → task → stream flow with no real server.
class FakeExecutorHost {
  FakeExecutorHost({
    required this.socket,
    required this.deviceId,
    required this.channelId,
    required this.digits,
    required this.signingKeyPair,
    required this.nowMs,
  });

  final FakeRelaySocket socket;
  final String deviceId;
  final String channelId;
  final String digits;
  final SimpleKeyPair signingKeyPair;
  final int Function() nowMs;

  final CoworkApprovedDevices approved = CoworkApprovedDevices.empty();
  late final CoworkPairing _initiator;

  CoworkFrameSealer? _sealer;
  CoworkFrameOpener? _opener;

  /// Payloads the host opened from the client (account_authentication, task…).
  final List<Map<String, dynamic>> received = <Map<String, dynamic>>[];

  final Completer<void> paired = Completer<void>();

  static String frameToWire(CoworkFrame f) =>
      base64.encode(utf8.encode(f.toJsonString()));
  static CoworkFrame frameFromWire(String w) =>
      CoworkFrame.fromJsonString(utf8.decode(base64.decode(w)));

  Future<void> start() async {
    _initiator = await CoworkPairing.initiator(
      deviceId: deviceId,
      deviceKeyPair: signingKeyPair,
      nowMs: nowMs,
      channelId: channelId,
      digits: digits,
      approvedDevices: approved,
    );
    socket.outbound.listen(_onClientEnvelope);
  }

  void _sendPairing(String step, Map<String, dynamic> data) {
    socket.deliver(
      jsonEncode(<String, dynamic>{'type': 'pairing', 'step': step, 'data': data}),
    );
  }

  Future<void> _onClientEnvelope(String raw) async {
    final env = jsonDecode(raw) as Map<String, dynamic>;
    switch (env['type']) {
      case 'join':
        // Client joined; drive the ceremony by publishing the commitment.
        _sendPairing('commit', _initiator.createCommit());
      case 'pairing':
        await _onPairing(env);
      case 'frame':
        await _onFrame(env);
    }
  }

  Future<void> _onPairing(Map<String, dynamic> env) async {
    final step = env['step'] as String;
    final data = (env['data'] as Map).cast<String, dynamic>();
    switch (step) {
      case 'pubkey':
        _sendPairing('reveal', await _initiator.onPubkey(data));
      case 'confirm-d':
        _sendPairing('confirm-c', await _initiator.onConfirmD(data));
        // Reveal the host device key (device-c).
        _sendPairing('device-c', await _initiator.createDeviceKey());
      case 'device-d':
        await _initiator.onPeerDeviceKey(data);
        _establishCodec();
        if (!paired.isCompleted) paired.complete();
    }
  }

  void _establishCodec() {
    final channelKey = _initiator.channelKey;
    _sealer = CoworkFrameSealer.withChannelKey(
      channelKey: channelKey,
      keyVersion: 1,
      deviceId: deviceId,
      signingKeyPair: signingKeyPair,
    );
    _opener = CoworkFrameOpener.withChannelKey(
      channelKey: channelKey,
      keyVersion: 1,
      approvedDevices: _initiator.approvedDevices,
    );
  }

  Future<void> _onFrame(Map<String, dynamic> env) async {
    final frame = frameFromWire(env['frame'] as String);
    final plain = await _opener!.open(frame);
    received.add(jsonDecode(utf8.decode(plain)) as Map<String, dynamic>);
  }

  /// Seal a payload and push it to the client (delta / tool / done / error).
  Future<void> emit(Map<String, dynamic> payload) async {
    final frame = await _sealer!.seal(utf8.encode(jsonEncode(payload)));
    socket.deliver(
      jsonEncode(<String, dynamic>{'type': 'frame', 'frame': frameToWire(frame)}),
    );
  }
}

void main() {
  const int ts = 1723478400000;
  int clock() => ts;

  Future<(CoworkRelayClient, FakeExecutorHost, FakeRelaySocket)> paired({
    String channelId = 'chan1234',
    String digits = '428913',
    String appDeviceId = 'app-desktop-1',
    String hostDeviceId = 'host-laptop-1',
  }) async {
    final socket = FakeRelaySocket();
    final host = FakeExecutorHost(
      socket: socket,
      deviceId: hostDeviceId,
      channelId: channelId,
      digits: digits,
      signingKeyPair: await CoworkDeviceKeys.generate(),
      nowMs: clock,
    );
    await host.start();

    final client = CoworkRelayClient(
      deviceId: appDeviceId,
      signingKeyPair: await CoworkDeviceKeys.generate(),
      connector: (_) async => socket,
      nowMs: clock,
    );

    await client.connect(
      hostUrl: Uri.parse('ws://127.0.0.1:8787'),
      pairingCode: '$channelId-$digits',
    );
    await host.paired.future;
    return (client, host, socket);
  }

  test('channelIdOf takes everything before the last dash', () {
    expect(CoworkRelayClient.channelIdOf('chan1234-428913'), 'chan1234');
    expect(CoworkRelayClient.channelIdOf('a-b-c-999'), 'a-b-c');
  });

  test('join → pair: the client joins, runs the joiner ceremony, and ends '
      'paired with the host device approved', () async {
    final socket = FakeRelaySocket();
    final joinEnvelopes = <Map<String, dynamic>>[];
    socket.outbound.listen((raw) {
      final env = jsonDecode(raw) as Map<String, dynamic>;
      if (env['type'] == 'join') joinEnvelopes.add(env);
    });

    final host = FakeExecutorHost(
      socket: socket,
      deviceId: 'host-laptop-1',
      channelId: 'chan1234',
      digits: '428913',
      signingKeyPair: await CoworkDeviceKeys.generate(),
      nowMs: clock,
    );
    await host.start();

    final client = CoworkRelayClient(
      deviceId: 'app-desktop-1',
      signingKeyPair: await CoworkDeviceKeys.generate(),
      connector: (_) async => socket,
      nowMs: clock,
    );

    await client.connect(
      hostUrl: Uri.parse('ws://127.0.0.1:8787'),
      pairingCode: 'chan1234-428913',
    );
    await host.paired.future;

    expect(joinEnvelopes, hasLength(1));
    expect(joinEnvelopes.single['channel'], 'chan1234');
    expect(joinEnvelopes.single['role'], 'controller');

    expect(client.state.value.phase, CoworkRelayPhase.paired);
    expect(client.state.value.peerDeviceId, 'host-laptop-1');
    expect(client.state.value.sas, isA<String>());
    // Both sides recorded the other device locally.
    expect(host.approved.isApproved('app-desktop-1'), isTrue);

    await client.dispose();
  });

  test('provisionAccount seals the account token; the host opens it', () async {
    final (client, host, _) = await paired();

    await client.provisionAccount(
      const AccountSession(
        accessToken: 'access-xyz',
        refreshToken: 'refresh-xyz',
        userId: 'user-1',
      ),
    );
    // Let the sealed frame reach the host and decrypt.
    await Future<void>.delayed(Duration.zero);

    final auth = host.received.singleWhere(
      (m) => m['type'] == 'account_authentication',
    );
    expect(auth['access_token'], 'access-xyz');
    expect(auth['refresh_token'], 'refresh-xyz');
    expect(auth['user_id'], 'user-1');

    await client.dispose();
  });

  test('sendTask seals {type:task,prompt}; the host opens it', () async {
    final (client, host, _) = await paired();

    await client.sendTask('list the files');
    await Future<void>.delayed(Duration.zero);

    final task = host.received.singleWhere((m) => m['type'] == 'task');
    expect(task['prompt'], 'list the files');

    await client.dispose();
  });

  test('delta / tool / done frames from the host open and surface as events',
      () async {
    final (client, host, _) = await paired();

    final events = <CoworkRelayInbound>[];
    final sub = client.inbound.listen(events.add);

    await host.emit(<String, dynamic>{'type': 'delta', 'text': 'Hel'});
    await host.emit(<String, dynamic>{'type': 'delta', 'text': 'lo'});
    await host.emit(<String, dynamic>{
      'type': 'tool',
      'name': 'shell',
      'status': 'running',
    });
    await host.emit(<String, dynamic>{'type': 'done'});
    // Drain the delivery + decrypt microtasks.
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(events.whereType<CoworkRelayDelta>().map((e) => e.text).join(), 'Hello');
    final tool = events.whereType<CoworkRelayTool>().single;
    expect(tool.name, 'shell');
    expect(tool.status, 'running');
    expect(events.whereType<CoworkRelayDone>(), hasLength(1));

    await sub.cancel();
    await client.dispose();
  });

  test('a hostile frame from an unapproved device is dropped, not rendered',
      () async {
    final (client, host, socket) = await paired();

    final events = <CoworkRelayInbound>[];
    final sub = client.inbound.listen(events.add);

    // A frame signed by a device the client never approved.
    final rogueKey = await CoworkDeviceKeys.generate();
    final rogueSealer = CoworkFrameSealer.withChannelKey(
      channelKey: List<int>.filled(kCoworkChannelKeyLength, 7),
      keyVersion: 1,
      deviceId: 'rogue',
      signingKeyPair: rogueKey,
    );
    final frame = await rogueSealer.seal(utf8.encode(jsonEncode({'type': 'delta', 'text': 'x'})));
    socket.deliver(
      jsonEncode({'type': 'frame', 'frame': FakeExecutorHost.frameToWire(frame)}),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(events, isEmpty);
    // The genuine host still works after the drop.
    await host.emit(<String, dynamic>{'type': 'delta', 'text': 'ok'});
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(events.whereType<CoworkRelayDelta>().single.text, 'ok');

    await sub.cancel();
    await client.dispose();
  });

  test('the host closing the socket mid-pairing surfaces an error', () async {
    final socket = FakeRelaySocket();
    // A host that only sends commit, then closes — pairing never completes.
    socket.outbound.listen((raw) async {
      final env = jsonDecode(raw) as Map<String, dynamic>;
      if (env['type'] == 'join') {
        await socket.close();
      }
    });

    final client = CoworkRelayClient(
      deviceId: 'app-desktop-1',
      signingKeyPair: await CoworkDeviceKeys.generate(),
      connector: (_) async => socket,
      nowMs: clock,
    );

    await expectLater(
      client.connect(
        hostUrl: Uri.parse('ws://127.0.0.1:8787'),
        pairingCode: 'chan1234-428913',
      ),
      throwsA(isA<Object>()),
    );
    expect(client.state.value.phase, CoworkRelayPhase.error);

    await client.dispose();
  });

  test('sendTask before pairing throws', () async {
    final client = CoworkRelayClient(
      deviceId: 'app-desktop-1',
      signingKeyPair: await CoworkDeviceKeys.generate(),
      connector: (_) async => FakeRelaySocket(),
    );
    await expectLater(client.sendTask('hi'), throwsStateError);
    await client.dispose();
  });
}
