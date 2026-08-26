import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/account_session.dart';
import 'package:chuk_chat/services/cowork/cowork_approved_devices.dart';
import 'package:chuk_chat/services/cowork/cowork_device_keys.dart';
import 'package:chuk_chat/services/cowork/cowork_frame.dart';
import 'package:chuk_chat/services/cowork/cowork_frame_codec.dart';
import 'package:chuk_chat/services/cowork/cowork_pairing_store.dart';
import 'package:chuk_chat/services/cowork/cowork_reconnect.dart';
import 'package:chuk_chat/services/cowork/cowork_relay_client.dart';

/// A fake duplex socket (client send captured on [outbound]; host writes via
/// [deliver]).
class FakeRelaySocket implements RelaySocket {
  final StreamController<dynamic> _incoming =
      StreamController<dynamic>.broadcast();
  final StreamController<String> _outbound = StreamController<String>.broadcast();

  @override
  Stream<dynamic> get incoming => _incoming.stream;

  Stream<String> get outbound => _outbound.stream;

  @override
  void send(String data) {
    if (!_outbound.isClosed) _outbound.add(data);
  }

  void deliver(String data) {
    if (!_incoming.isClosed) _incoming.add(data);
  }

  @override
  Future<void> close() async {
    if (!_incoming.isClosed) await _incoming.close();
    if (!_outbound.isClosed) await _outbound.close();
  }
}

/// A fake host that plays the reconnect INITIATOR: on join it sends a signed
/// reconnect-hello, verifies the app's response against the app's stored key,
/// confirms, then seals frames the app must open. Proves the whole code-free
/// reconnect + sealed-task flow end to end in Dart.
class FakeReconnectHost {
  FakeReconnectHost({
    required this.socket,
    required this.hostDeviceId,
    required this.hostKeyPair,
    required this.appDeviceId,
    required this.appPublicKey,
    required this.channelId,
    required this.channelKey,
  });

  final FakeRelaySocket socket;
  final String hostDeviceId;
  final SimpleKeyPair hostKeyPair;
  final String appDeviceId;
  final SimplePublicKey appPublicKey;
  final String channelId;
  final Uint8List channelKey;

  late final CoworkReconnect _initiator;
  CoworkFrameSealer? _sealer;
  CoworkFrameOpener? _opener;
  final List<Map<String, dynamic>> received = <Map<String, dynamic>>[];
  final Completer<void> authenticated = Completer<void>();

  Future<void> start() async {
    _initiator = CoworkReconnect.initiator(
      deviceId: hostDeviceId,
      deviceKeyPair: hostKeyPair,
      peerDeviceId: appDeviceId,
      peerPublicKey: appPublicKey,
      channelId: channelId,
    );
    socket.outbound.listen(_onEnvelope);
  }

  void _sendPairing(String step, Map<String, dynamic> data) {
    socket.deliver(
      jsonEncode(<String, dynamic>{'type': 'pairing', 'step': step, 'data': data}),
    );
  }

  Future<void> _onEnvelope(String raw) async {
    final env = jsonDecode(raw) as Map<String, dynamic>;
    switch (env['type']) {
      case 'join':
        _sendPairing('reconnect-hello', _initiator.createHello());
      case 'pairing':
        final step = env['step'] as String;
        final data = (env['data'] as Map).cast<String, dynamic>();
        if (step == 'reconnect-response') {
          _sendPairing('reconnect-confirm', await _initiator.onResponse(data));
          _establishCodec();
          if (!authenticated.isCompleted) authenticated.complete();
        }
      case 'frame':
        final frame = CoworkFrame.fromJsonString(
          utf8.decode(base64.decode(env['frame'] as String)),
        );
        received.add(
          jsonDecode(utf8.decode(await _opener!.open(frame)))
              as Map<String, dynamic>,
        );
    }
  }

  void _establishCodec() {
    final approved = CoworkApprovedDevices.empty()
      ..approve(appDeviceId, appPublicKey);
    _sealer = CoworkFrameSealer.withChannelKey(
      channelKey: channelKey,
      keyVersion: 1,
      deviceId: hostDeviceId,
      signingKeyPair: hostKeyPair,
    );
    _opener = CoworkFrameOpener.withChannelKey(
      channelKey: channelKey,
      keyVersion: 1,
      approvedDevices: approved,
    );
  }

  Future<void> emit(Map<String, dynamic> payload) async {
    final frame = await _sealer!.seal(utf8.encode(jsonEncode(payload)));
    socket.deliver(
      jsonEncode(<String, dynamic>{
        'type': 'frame',
        'frame': base64.encode(utf8.encode(frame.toJsonString())),
      }),
    );
  }
}

void main() {
  test('reconnect: no code, mutual auth, then sealed tasks + results flow',
      () async {
    const hostDeviceId = 'cowork-host';
    const appDeviceId = 'app-desktop-1';
    const channelId = 'cowork00deadbeef';
    final channelKey =
        Uint8List.fromList(List<int>.generate(32, (i) => (i * 5 + 1) & 0xff));

    final hostKeyPair = await CoworkDeviceKeys.generate();
    final hostPub = await hostKeyPair.extractPublicKey();
    final appKeyPair = await CoworkDeviceKeys.generate();
    final appPub = await appKeyPair.extractPublicKey();

    final socket = FakeRelaySocket();
    final host = FakeReconnectHost(
      socket: socket,
      hostDeviceId: hostDeviceId,
      hostKeyPair: hostKeyPair,
      appDeviceId: appDeviceId,
      appPublicKey: appPub,
      channelId: channelId,
      channelKey: channelKey,
    );
    await host.start();

    final client = CoworkRelayClient(
      deviceId: appDeviceId,
      signingKeyPair: appKeyPair,
      connector: (_) async => socket,
    );

    final stored = CoworkStoredPairing(
      hostUrl: Uri.parse('ws://127.0.0.1:8787'),
      channelId: channelId,
      channelKey: channelKey,
      peerDeviceId: hostDeviceId,
      peerPublicKey: hostPub,
    );

    await client.reconnect(
      hostUrl: stored.hostUrl,
      pairing: stored,
    );
    await host.authenticated.future;

    expect(client.state.value.phase, CoworkRelayPhase.paired);
    expect(client.state.value.peerDeviceId, hostDeviceId);
    expect(client.establishedTrust, isNotNull);

    // Provisioning must work after a code-free reconnect too. It used to read
    // the peer device id off the (now absent) pairing session and threw
    // "Cannot provision before pairing completes", which killed every
    // auto-reconnect before a single task could run.
    await client.provisionAccount(
      const AccountSession(
        accessToken: 'access-1',
        refreshToken: 'refresh-1',
        userId: 'user-1',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(
      host.received.where((m) => m['type'] == 'account_authentication'),
      hasLength(1),
      reason: 'the account token must reach the host after a reconnect',
    );

    // A task the app seals opens on the host over the resumed channel.
    await client.sendTask('do the thing');
    await Future<void>.delayed(Duration.zero);
    final task = host.received.singleWhere((m) => m['type'] == 'task');
    expect(task['prompt'], 'do the thing');

    // A result the host seals opens on the app.
    final events = <CoworkRelayInbound>[];
    final sub = client.inbound.listen(events.add);
    await host.emit(<String, dynamic>{'type': 'delta', 'text': 'hi'});
    await host.emit(<String, dynamic>{'type': 'done'});
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(events.whereType<CoworkRelayDelta>().single.text, 'hi');
    expect(events.whereType<CoworkRelayDone>(), hasLength(1));

    await sub.cancel();
    await client.dispose();
  });

  test('reconnect against an imposter host (wrong key) fails, no channel',
      () async {
    const hostDeviceId = 'cowork-host';
    const appDeviceId = 'app-desktop-1';
    const channelId = 'cowork00deadbeef';
    final channelKey = Uint8List(32);

    // The app stored the REAL host key, but the host on the wire signs with a
    // different (imposter) key.
    final realHostPub =
        await (await CoworkDeviceKeys.generate()).extractPublicKey();
    final imposterKeyPair = await CoworkDeviceKeys.generate();
    final appKeyPair = await CoworkDeviceKeys.generate();
    final appPub = await appKeyPair.extractPublicKey();

    final socket = FakeRelaySocket();
    final host = FakeReconnectHost(
      socket: socket,
      hostDeviceId: hostDeviceId,
      hostKeyPair: imposterKeyPair, // not the stored key
      appDeviceId: appDeviceId,
      appPublicKey: appPub,
      channelId: channelId,
      channelKey: channelKey,
    );
    await host.start();

    final client = CoworkRelayClient(
      deviceId: appDeviceId,
      signingKeyPair: appKeyPair,
      connector: (_) async => socket,
      pairingTimeout: const Duration(seconds: 2),
    );

    final stored = CoworkStoredPairing(
      hostUrl: Uri.parse('ws://127.0.0.1:8787'),
      channelId: channelId,
      channelKey: channelKey,
      peerDeviceId: hostDeviceId,
      peerPublicKey: realHostPub, // app trusts the real key
    );

    await expectLater(
      client.reconnect(hostUrl: stored.hostUrl, pairing: stored),
      throwsA(anything),
    );
    expect(client.state.value.phase, CoworkRelayPhase.error);

    await client.dispose();
  });
}
