import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cowork/services/account_session.dart';
import 'package:cowork/services/cowork/cowork_approved_devices.dart';
import 'package:cowork/services/cowork/cowork_device_keys.dart';
import 'package:cowork/services/cowork/cowork_frame.dart';
import 'package:cowork/services/cowork/cowork_frame_codec.dart';
import 'package:cowork/services/cowork/cowork_pairing.dart';
import 'package:cowork/services/cowork/cowork_relay_client.dart';
import 'package:cowork/services/herenow/herenow_store.dart';
import 'package:cowork/services/mcp/mcp_store.dart';

/// A stand-in [McpStore] whose forward payloads are canned, so a task-frame
/// test needs no SharedPreferences and no secure storage. Overriding
/// [forwardPayloads] is enough — the base constructor's secret store is never
/// touched.
class FakeMcpStore extends McpStore {
  FakeMcpStore(this._payloads);

  final List<Map<String, dynamic>> _payloads;

  @override
  Future<List<Map<String, dynamic>>> forwardPayloads() async => _payloads;
}

/// A stand-in [HereNowStore] whose forward payload is canned, so a task-frame
/// test needs no SharedPreferences. Null [_payload] models a disabled connector.
class FakeHereNowStore extends HereNowStore {
  FakeHereNowStore(this._payload);

  final Map<String, dynamic>? _payload;

  @override
  Future<Map<String, dynamic>?> forwardPayload() async => _payload;
}

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
    McpStore? mcpStore,
    HereNowStore? hereNowStore,
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
      mcpStore: mcpStore,
      hereNowStore: hereNowStore,
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

  test('sendTask forwards mcp_servers when the store has connections', () async {
    final servers = <Map<String, dynamic>>[
      <String, dynamic>{
        'name': 'github',
        'url': 'https://mcp.github.example/sse',
        'auth': 'appSession',
      },
      <String, dynamic>{
        'name': 'notion',
        'url': 'https://mcp.notion.example/sse',
        'auth': 'oauth',
        'access_token': 'tok-123',
      },
    ];
    final (client, host, _) = await paired(mcpStore: FakeMcpStore(servers));

    await client.sendTask('list the files');
    await Future<void>.delayed(Duration.zero);

    final task = host.received.singleWhere((m) => m['type'] == 'task');
    expect(task['mcp_servers'], servers);

    await client.dispose();
  });

  test('sendTask omits mcp_servers when the store is empty', () async {
    final (client, host, _) =
        await paired(mcpStore: FakeMcpStore(const <Map<String, dynamic>>[]));

    await client.sendTask('list the files');
    await Future<void>.delayed(Duration.zero);

    final task = host.received.singleWhere((m) => m['type'] == 'task');
    expect(task.containsKey('mcp_servers'), isFalse);

    await client.dispose();
  });

  test('sendTask with no store attached omits mcp_servers', () async {
    final (client, host, _) = await paired();

    await client.sendTask('list the files');
    await Future<void>.delayed(Duration.zero);

    final task = host.received.singleWhere((m) => m['type'] == 'task');
    expect(task.containsKey('mcp_servers'), isFalse);

    await client.dispose();
  });

  test('sendTask forwards herenow when the connector is enabled', () async {
    final (client, host, _) = await paired(
      hereNowStore: FakeHereNowStore(
        <String, dynamic>{'enabled': true, 'approval': 'ask'},
      ),
    );

    await client.sendTask('publish the report');
    await Future<void>.delayed(Duration.zero);

    final task = host.received.singleWhere((m) => m['type'] == 'task');
    expect(task['herenow'], <String, dynamic>{'enabled': true, 'approval': 'ask'});

    await client.dispose();
  });

  test('sendTask omits herenow when the connector is disabled', () async {
    final (client, host, _) = await paired(hereNowStore: FakeHereNowStore(null));

    await client.sendTask('publish the report');
    await Future<void>.delayed(Duration.zero);

    final task = host.received.singleWhere((m) => m['type'] == 'task');
    expect(task.containsKey('herenow'), isFalse);

    await client.dispose();
  });

  test('an approval_request frame surfaces as a CoworkRelayApprovalRequest',
      () async {
    final (client, host, _) = await paired();
    final events = <CoworkRelayInbound>[];
    final sub = client.inbound.listen(events.add);

    await host.emit(<String, dynamic>{
      'type': 'approval_request',
      'approval_id': 'ap-1',
      'action': 'herenow_publish',
      'path': 'site',
      'name': 'My Page',
      'file_count': 2,
      'total_bytes': 1024,
      'base_url': 'https://here.now',
      'public': true,
    });
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final ask = events.whereType<CoworkRelayApprovalRequest>().single;
    expect(ask.approvalId, 'ap-1');
    expect(ask.name, 'My Page');
    expect(ask.fileCount, 2);
    expect(ask.totalBytes, 1024);
    expect(ask.public, isTrue);

    await sub.cancel();
    await client.dispose();
  });

  test('sendApprovalDecision seals {type:approval_decision}; the host opens it',
      () async {
    final (client, host, _) = await paired();

    await client.sendApprovalDecision(approvalId: 'ap-1', approved: true);
    await Future<void>.delayed(Duration.zero);

    final decision =
        host.received.singleWhere((m) => m['type'] == 'approval_decision');
    expect(decision['approval_id'], 'ap-1');
    expect(decision['approved'], true);

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

  test('a subagent_state frame surfaces; a subagent_output frame does not',
      () async {
    final (client, host, _) = await paired();
    final events = <CoworkRelayInbound>[];
    final sub = client.inbound.listen(events.add);

    await host.emit(<String, dynamic>{
      'type': 'subagent',
      'event': <String, dynamic>{
        'type': 'subagent_state',
        'subagent_id': 'sa_1',
        'title': 'writer',
        'state': 'running',
      },
    });
    // An output delta from the child carries no lifecycle transition — dropped.
    await host.emit(<String, dynamic>{
      'type': 'subagent',
      'event': <String, dynamic>{
        'type': 'subagent_output',
        'subagent_id': 'sa_1',
        'title': 'writer',
        'payload': <String, dynamic>{'type': 'delta', 'text': 'x'},
      },
    });
    await host.emit(<String, dynamic>{
      'type': 'subagent',
      'event': <String, dynamic>{
        'type': 'subagent_state',
        'subagent_id': 'sa_1',
        'title': 'writer',
        'state': 'succeeded',
        'result': 'the summary',
        'tokens_spent': 4321,
      },
    });
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final subs = events.whereType<CoworkRelaySubagent>().toList();
    expect(subs, hasLength(2));
    expect(subs.first.state, 'running');
    expect(subs.first.tokensSpent, isNull);
    expect(subs.last.state, 'succeeded');
    expect(subs.last.result, 'the summary');
    expect(subs.last.tokensSpent, 4321);
    expect(subs.last.isTerminal, isTrue);

    await sub.cancel();
    await client.dispose();
  });

  test('room_turn and room_done frames surface as room events', () async {
    final (client, host, _) = await paired();
    final events = <CoworkRelayInbound>[];
    final sub = client.inbound.listen(events.add);

    await host.emit(<String, dynamic>{
      'type': 'room_turn',
      'room_id': 'r1',
      'round': 1,
      'agent_id': 'id-amber',
      'handle': 'amber',
      'text': 'ship it',
    });
    await host.emit(<String, dynamic>{
      'type': 'room_turn',
      'room_id': 'r1',
      'round': 2,
      'agent_id': 'id-cobalt',
      'handle': 'cobalt',
      'text': 'agreed',
    });
    await host.emit(<String, dynamic>{
      'type': 'room_done',
      'room_id': 'r1',
      'reason': 'no_more_mentions',
      'messages_sent': 2,
      'rounds': 2,
    });
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final turns = events.whereType<CoworkRelayRoomTurn>().toList();
    expect(turns, hasLength(2));
    expect(turns.first.roomId, 'r1');
    expect(turns.first.round, 1);
    expect(turns.first.handle, 'amber');
    expect(turns.first.text, 'ship it');
    expect(turns.last.agentId, 'id-cobalt');

    final done = events.whereType<CoworkRelayRoomDone>().single;
    expect(done.roomId, 'r1');
    expect(done.reason, 'no_more_mentions');
    expect(done.messagesSent, 2);
    expect(done.rounds, 2);

    await sub.cancel();
    await client.dispose();
  });

  test('a malformed room_turn is dropped, not surfaced', () async {
    final (client, host, _) = await paired();
    final events = <CoworkRelayInbound>[];
    final sub = client.inbound.listen(events.add);

    // Missing room_id -> dropped.
    await host.emit(<String, dynamic>{
      'type': 'room_turn',
      'round': 1,
      'agent_id': 'id-amber',
      'handle': 'amber',
      'text': 'x',
    });
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(events.whereType<CoworkRelayRoomTurn>(), isEmpty);

    await sub.cancel();
    await client.dispose();
  });

  test('a room_history frame surfaces its stored turns', () async {
    final (client, host, _) = await paired();
    final events = <CoworkRelayInbound>[];
    final sub = client.inbound.listen(events.add);

    await host.emit(<String, dynamic>{
      'type': 'room_history',
      'room_id': 'r1',
      'turns': <dynamic>[
        <String, dynamic>{
          'round': 1,
          'agent_id': 'id-amber',
          'handle': 'amber',
          'text': 'stored',
        },
        <String, dynamic>{'bad': 'turn'}, // skipped, not fatal
      ],
    });
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final hist = events.whereType<CoworkRelayRoomHistory>().single;
    expect(hist.roomId, 'r1');
    expect(hist.turns, hasLength(1));
    expect(hist.turns.first.handle, 'amber');
    expect(hist.turns.first.roomId, 'r1');

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

  test('sendTask carries the session_key so an agent can hold many threads',
      () async {
    final (client, host, _) = await paired();

    await client.sendTask('read the log', sessionKey: 'amber-otter-2');
    await Future<void>.delayed(Duration.zero);

    final task = host.received.singleWhere((m) => m['type'] == 'task');
    expect(task['prompt'], 'read the log');
    expect(task['session_key'], 'amber-otter-2');

    await client.dispose();
  });

  test('requestStop seals {type:stop} naming the thread it aborts', () async {
    final (client, host, _) = await paired();

    await client.sendTask('read the log', sessionKey: 'amber-otter-2');
    await client.requestStop(sessionKey: 'amber-otter-2');
    await Future<void>.delayed(Duration.zero);

    final stop = host.received.singleWhere((m) => m['type'] == 'stop');
    // The executor drops a stop that names no run, so the session key is the
    // whole point of the frame: it is what the run is matched by.
    expect(stop['session_key'], 'amber-otter-2');
    expect(stop.keys, containsAll(<String>['type', 'session_key']));

    await client.dispose();
  });

  test('requestStop defaults to the default thread', () async {
    final (client, host, _) = await paired();

    await client.requestStop();
    await Future<void>.delayed(Duration.zero);

    final stop = host.received.singleWhere((m) => m['type'] == 'stop');
    expect(stop['session_key'], 'default');

    await client.dispose();
  });

  test('browser_data and browser_view frames surface as browser events (§9.1)',
      () async {
    final (client, host, _) = await paired();

    final events = <CoworkRelayInbound>[];
    final sub = client.inbound.listen(events.add);

    final rfb = base64.encode(<int>[0, 1, 82, 70, 66, 255]); // arbitrary bytes
    await host.emit(<String, dynamic>{'type': 'browser_view', 'status': 'started'});
    await host.emit(<String, dynamic>{'type': 'browser_data', 'size': 6, 'data': rfb});
    await host.emit(<String, dynamic>{
      'type': 'browser_view',
      'status': 'error',
      'message': 'no browser open yet',
    });
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final views = events.whereType<CoworkRelayBrowserView>().toList();
    expect(views.map((e) => e.status), <String>['started', 'error']);
    expect(views.last.message, 'no browser open yet');

    final data = events.whereType<CoworkRelayBrowserData>().single;
    expect(data.bytes, <int>[0, 1, 82, 70, 66, 255]);

    await sub.cancel();
    await client.dispose();
  });

  test('start/stop/sendBrowserData seal the browser control frames (§9.1)',
      () async {
    final (client, host, _) = await paired();

    await client.startBrowserView();
    await client.sendBrowserData(Uint8List.fromList(<int>[9, 8, 7]));
    await client.stopBrowserView();
    await Future<void>.delayed(Duration.zero);

    expect(host.received.any((m) => m['type'] == 'browser_start'), isTrue);
    expect(host.received.any((m) => m['type'] == 'browser_stop'), isTrue);
    final data = host.received.singleWhere((m) => m['type'] == 'browser_data');
    expect(base64.decode(data['data'] as String), <int>[9, 8, 7]);

    await client.dispose();
  });

  test('a run_command tool payload becomes arguments, result and a failure flag',
      () async {
    final (client, host, _) = await paired();
    final events = <CoworkRelayInbound>[];
    final sub = client.inbound.listen(events.add);

    await host.emit(<String, dynamic>{
      'type': 'tool',
      'name': 'run_command',
      'command': 'ls /nope',
      'exit_code': 2,
      'stdout': '',
      'stderr': 'ls: /nope: No such file or directory',
      'timed_out': false,
      'duration_ms': 1500,
    });
    await host.emit(<String, dynamic>{
      'type': 'tool',
      'name': 'run_command',
      'command': 'echo hi',
      'exit_code': 0,
      'stdout': 'hi\n',
      'stderr': '',
      'timed_out': false,
    });
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final tools = events.whereType<CoworkRelayTool>().toList();
    expect(tools, hasLength(2));
    expect(tools[0].failed, isTrue);
    expect(tools[0].exitCode, 2);
    expect(tools[0].arguments, 'ls /nope');
    expect(tools[0].result, contains('No such file'));
    expect(tools[0].duration, const Duration(milliseconds: 1500));
    expect(tools[1].failed, isFalse);
    expect(tools[1].result, 'hi\n');
    // A host that reports no duration must not get an invented one.
    expect(tools[1].duration, isNull);

    await sub.cancel();
    await client.dispose();
  });

  test('a file event is decoded once into bytes', () async {
    final (client, host, _) = await paired();
    final events = <CoworkRelayInbound>[];
    final sub = client.inbound.listen(events.add);

    final body = utf8.encode('name,value\na,1\n');
    await host.emit(<String, dynamic>{
      'type': 'file',
      'name': 'report.csv',
      'mime_type': 'text/csv',
      'size': body.length,
      'data': base64.encode(body),
    });
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final file = events.whereType<CoworkRelayFile>().single;
    expect(file.name, 'report.csv');
    expect(file.mimeType, 'text/csv');
    expect(file.isValid, isTrue);
    expect(file.isImage, isFalse);
    expect(utf8.decode(file.bytes!), 'name,value\na,1\n');

    await sub.cancel();
    await client.dispose();
  });

  test('a file event with a broken body arrives as an error, never a crash',
      () async {
    final (client, host, _) = await paired();
    final events = <CoworkRelayInbound>[];
    final sub = client.inbound.listen(events.add);

    await host.emit(<String, dynamic>{
      'type': 'file',
      'name': 'shot.png',
      'mime_type': 'image/png',
      'size': 12,
      'data': 'not base64 at all !!',
    });
    await host.emit(<String, dynamic>{
      'type': 'file',
      'name': 'short.bin',
      'mime_type': 'application/octet-stream',
      'size': 999,
      'data': base64.encode(<int>[1, 2, 3]),
    });
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final files = events.whereType<CoworkRelayFile>().toList();
    expect(files, hasLength(2));
    expect(files[0].isValid, isFalse);
    expect(files[0].bytes, isNull);
    expect(files[0].error, contains('base64'));
    // A body that contradicts the declared size is refused too.
    expect(files[1].isValid, isFalse);
    expect(files[1].error, contains('declared size'));

    await sub.cancel();
    await client.dispose();
  });

  test('reasoning is its own event, and done carries the runtime reason',
      () async {
    final (client, host, _) = await paired();
    final events = <CoworkRelayInbound>[];
    final sub = client.inbound.listen(events.add);

    await host.emit(<String, dynamic>{'type': 'reasoning', 'text': 'thinking…'});
    await host.emit(<String, dynamic>{
      'type': 'done',
      'final_answer': 'all set',
      'reason': 'interrupted',
      'iterations': 4,
    });
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(events.whereType<CoworkRelayReasoning>().single.text, 'thinking…');
    final done = events.whereType<CoworkRelayDone>().single;
    expect(done.reason, 'interrupted');
    expect(done.iterations, 4);
    expect(done.finalAnswer, 'all set');
    expect(done.wasStopped, isTrue);

    await sub.cancel();
    await client.dispose();
  });
}
