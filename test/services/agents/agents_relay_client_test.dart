import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthChangeEvent, AuthState, Session, User;

import 'package:chuk_chat/services/account_session.dart';
import 'package:chuk_chat/services/session_refresh_scheduler.dart';
import 'package:chuk_chat/services/agents/agents_approved_devices.dart';
import 'package:chuk_chat/services/agents/agents_device_keys.dart';
import 'package:chuk_chat/services/agents/agents_frame.dart';
import 'package:chuk_chat/services/agents/agents_frame_codec.dart';
import 'package:chuk_chat/services/agents/agents_pairing.dart';
import 'package:chuk_chat/services/agents/agents_host_session.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/herenow/herenow_store.dart';
import 'package:chuk_chat/services/mcp/mcp_store.dart';

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

  final AgentsApprovedDevices approved = AgentsApprovedDevices.empty();
  late final AgentsPairing _initiator;

  AgentsFrameSealer? _sealer;
  AgentsFrameOpener? _opener;

  /// Payloads the host opened from the client (account_authentication, task…).
  final List<Map<String, dynamic>> received = <Map<String, dynamic>>[];

  final Completer<void> paired = Completer<void>();

  static String frameToWire(AgentsFrame f) =>
      base64.encode(utf8.encode(f.toJsonString()));
  static AgentsFrame frameFromWire(String w) =>
      AgentsFrame.fromJsonString(utf8.decode(base64.decode(w)));

  Future<void> start() async {
    _initiator = await AgentsPairing.initiator(
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
    _sealer = AgentsFrameSealer.withChannelKey(
      channelKey: channelKey,
      keyVersion: 1,
      deviceId: deviceId,
      signingKeyPair: signingKeyPair,
    );
    _opener = AgentsFrameOpener.withChannelKey(
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

/// A session source the test scripts: what `current()` returns and what a
/// `refresh()` mints, plus how often a refresh was asked for.
class _SessionSource implements AccountSessionSource {
  _SessionSource({required AccountSession current, AccountSession? refreshed})
      : _current = current,
        _refreshed = refreshed;

  AccountSession _current;
  final AccountSession? _refreshed;
  int refreshCalls = 0;

  @override
  AccountSession? current() => _current;

  @override
  Future<AccountSession?> refresh() async {
    refreshCalls++;
    final next = _refreshed;
    if (next != null) _current = next;
    return _current;
  }
}

void main() {
  const int ts = 1723478400000;
  int clock() => ts;

  Future<(AgentsRelayClient, FakeExecutorHost, FakeRelaySocket)> paired({
    String channelId = 'chan1234',
    String digits = '428913',
    String appDeviceId = 'app-desktop-1',
    String hostDeviceId = 'host-laptop-1',
    McpStore? mcpStore,
    HereNowStore? hereNowStore,
    AccountSessionSource? sessionSource,
    Stream<AuthState>? authChanges,
    Future<AccountSession?> Function(String)? sessionAdopter,
    SessionRefreshScheduler? scheduler,
    AgentsHostSessionMinter? hostSessionMinter,
  }) async {
    final socket = FakeRelaySocket();
    final host = FakeExecutorHost(
      socket: socket,
      deviceId: hostDeviceId,
      channelId: channelId,
      digits: digits,
      signingKeyPair: await AgentsDeviceKeys.generate(),
      nowMs: clock,
    );
    await host.start();

    final client = AgentsRelayClient(
      deviceId: appDeviceId,
      signingKeyPair: await AgentsDeviceKeys.generate(),
      connector: (_) async => socket,
      nowMs: clock,
      mcpStore: mcpStore,
      hereNowStore: hereNowStore,
      sessionSource: sessionSource,
      authChanges: authChanges,
      sessionAdopter: sessionAdopter,
      scheduler: scheduler,
      hostSessionMinter: hostSessionMinter,
    );

    await client.connect(
      hostUrl: Uri.parse('ws://127.0.0.1:8787'),
      pairingCode: '$channelId-$digits',
    );
    await host.paired.future;
    return (client, host, socket);
  }

  // --- token freshness (docs/WIRE_CONTRACT.md, cowork-c91) -------------------

  Session supabaseSession(String access, String refresh) => Session(
        accessToken: access,
        refreshToken: refresh,
        tokenType: 'bearer',
        expiresIn: 3600,
        user: const User(
          id: 'user-1',
          appMetadata: <String, dynamic>{},
          userMetadata: <String, dynamic>{},
          aud: 'authenticated',
          createdAt: '2026-01-01T00:00:00Z',
        ),
      );

  List<Map<String, dynamic>> authFrames(FakeExecutorHost host) => host.received
      .where((p) => p['type'] == 'account_authentication')
      .toList();

  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test('a Supabase token refresh re-provisions the host at once, and an '
      'unchanged token is not re-sent', () async {
    final auth = StreamController<AuthState>.broadcast();
    final (client, host, _) = await paired(authChanges: auth.stream);
    await client.provisionAccount(
      const AccountSession(
        accessToken: 'access-1',
        refreshToken: 'refresh-1',
        userId: 'user-1',
      ),
    );
    await settle();
    expect(authFrames(host).map((p) => p['access_token']), ['access-1']);

    // Supabase rotated the tokens: the host gets the new pair straight away.
    auth.add(AuthState(
      AuthChangeEvent.tokenRefreshed,
      supabaseSession('access-2', 'refresh-2'),
    ));
    await settle();
    final frames = authFrames(host);
    expect(frames.map((p) => p['access_token']), ['access-1', 'access-2']);
    // The app's refresh token never leaves the app (the host has its own).
    expect(frames.last.containsKey('refresh_token'), isFalse);
    expect(frames.last['user_id'], 'user-1');
    // `expires_at` comes from the JWT's exp claim; a fake token has none, so
    // the field is simply absent here (the reprovision test covers it).

    // The same token again is noise, not a new provision.
    auth.add(AuthState(
      AuthChangeEvent.tokenRefreshed,
      supabaseSession('access-2', 'refresh-2'),
    ));
    await settle();
    expect(authFrames(host).length, 2);

    await client.dispose();
    await auth.close();
  });

  test('a reprovision_request with an expired token is answered with a '
      'refreshed account_authentication', () async {
    final source = _SessionSource(
      current: const AccountSession(
        accessToken: 'access-1',
        refreshToken: 'refresh-1',
        userId: 'user-1',
      ),
      refreshed: const AccountSession(
        accessToken: 'access-3',
        refreshToken: 'refresh-3',
        userId: 'user-1',
        expiresAt: 1800000000,
      ),
    );
    final (client, host, _) = await paired(sessionSource: source);
    await client.provisionAccount(source.current()!);
    await settle();

    await host.emit(<String, dynamic>{
      'type': 'reprovision_request',
      'reason': 'token_expired',
    });
    await settle();

    final frames = authFrames(host);
    expect(frames.map((p) => p['access_token']), ['access-1', 'access-3']);
    expect(frames.last.containsKey('refresh_token'), isFalse);
    expect(frames.last['expires_at'], 1800000000);
    expect(source.refreshCalls, 1);
    // Never surfaced to the UI: nothing for the user to decide.
    await client.dispose();
  });

  test('a reprovision_request without a reason answers with the current '
      'session even when the token is unchanged', () async {
    final source = _SessionSource(
      current: const AccountSession(
        accessToken: 'access-1',
        refreshToken: 'refresh-1',
        userId: 'user-1',
      ),
    );
    final (client, host, _) = await paired(sessionSource: source);
    await client.provisionAccount(source.current()!);
    await settle();

    await host.emit(<String, dynamic>{'type': 'reprovision_request'});
    await settle();

    expect(authFrames(host).map((p) => p['access_token']),
        ['access-1', 'access-1']);
    expect(source.refreshCalls, 0);
    await client.dispose();
  });

  test('account_session_rotated is adopted through the session adopter and '
      'acked with the adopted pair', () async {
    final adoptedWith = <String>[];
    final source = _SessionSource(
      current: const AccountSession(
        accessToken: 'access-1',
        refreshToken: 'refresh-1',
        userId: 'user-1',
        expiresAt: 1700000000,
      ),
    );
    final (client, host, _) = await paired(
      sessionSource: source,
      sessionAdopter: (refresh) async {
        adoptedWith.add(refresh);
        return AccountSession(
          accessToken: 'access-live',
          refreshToken: 'refresh-live',
          userId: 'user-1',
          expiresAt: 1800003600,
        );
      },
    );
    await client.provisionAccount(source.current()!);
    await settle();

    await host.emit(<String, dynamic>{
      'type': 'account_session_rotated',
      'access_token': 'access-host',
      'refresh_token': 'refresh-host',
      'expires_at': 1800000000,
      'rotated_at': '2026-09-05T02:00:00Z',
    });
    await settle();

    expect(adoptedWith, ['refresh-host']);
    final frames = authFrames(host);
    expect(frames.map((p) => p['access_token']), ['access-1', 'access-live']);
    expect(frames.last.containsKey('refresh_token'), isFalse);
    await client.dispose();
  });

  test('account_session_rotated older than the app session keeps the app '
      'session and still acks', () async {
    var adopterCalls = 0;
    final source = _SessionSource(
      current: const AccountSession(
        accessToken: 'access-new',
        refreshToken: 'refresh-new',
        userId: 'user-1',
        expiresAt: 1900000000,
      ),
    );
    final (client, host, _) = await paired(
      sessionSource: source,
      sessionAdopter: (_) async {
        adopterCalls++;
        return null;
      },
    );
    await client.provisionAccount(source.current()!);
    await settle();

    await host.emit(<String, dynamic>{
      'type': 'account_session_rotated',
      'access_token': 'access-old',
      'refresh_token': 'refresh-old',
      'expires_at': 1800000000,
    });
    await settle();

    expect(adopterCalls, 0);
    expect(authFrames(host).map((p) => p['access_token']),
        ['access-new', 'access-new']);
    await client.dispose();
  });

  test('account_session_rotated with a failing adopter acks with the host '
      'pair itself', () async {
    final source = _SessionSource(
      current: const AccountSession(
        accessToken: 'access-1',
        refreshToken: 'refresh-1',
        userId: 'user-1',
      ),
    );
    final (client, host, _) = await paired(
      sessionSource: source,
      sessionAdopter: (_) async => throw StateError('no network'),
    );
    await client.provisionAccount(source.current()!);
    await settle();

    await host.emit(<String, dynamic>{
      'type': 'account_session_rotated',
      'access_token': 'access-host',
      'refresh_token': 'refresh-host',
      'expires_at': 1800000000,
    });
    await settle();

    final last = authFrames(host).last;
    expect(last['access_token'], 'access-host');
    expect(last.containsKey('refresh_token'), isFalse);
    expect(last['expires_at'], 1800000000);
    await client.dispose();
  });

  test('account_session_rotated with no session to name the user is not acked '
      'with an empty user_id (F5)', () async {
    // No session source at all: the app is between a dropped session and its
    // recovery. Whatever the host sends, the app cannot say whose token it is.
    final (client, host, _) = await paired();
    await settle();

    await host.emit(<String, dynamic>{
      'type': 'account_session_rotated',
      'access_token': 'access-host',
      'refresh_token': 'refresh-host',
      'expires_at': 1800000000,
    });
    await settle();

    // Silence, not a frame with `user_id: ""` (docs/WIRE_CONTRACT.md: the
    // user id must not change).
    expect(authFrames(host), isEmpty);
    await client.dispose();
  });

  test('a host_session_request is answered with a session minted for the '
      'host alone, once per burst', () async {
    final minted = <String>[];
    final source = _SessionSource(
      current: const AccountSession(
        accessToken: 'access-1',
        refreshToken: 'refresh-1',
        userId: 'user-1',
      ),
    );
    final (client, host, _) = await paired(
      sessionSource: source,
      hostSessionMinter: (session) async {
        minted.add(session.accessToken);
        return const AgentsHostSession(
          accessToken: 'host-access',
          refreshToken: 'host-refresh',
          userId: 'user-1',
          expiresAt: 1800003600,
        );
      },
    );
    await client.provisionAccount(source.current()!);
    await settle();

    await host.emit(<String, dynamic>{
      'type': 'host_session_request',
      'reason': 'provisioned_without_own_session',
    });
    await host.emit(<String, dynamic>{'type': 'host_session_request'});
    await settle();

    // Minted with the app's own bearer, once for the burst.
    expect(minted, ['access-1']);
    final hostFrames = authFrames(host)
        .where((p) => p['session_kind'] == 'host')
        .toList();
    expect(hostFrames, hasLength(1));
    expect(hostFrames.single['refresh_token'], 'host-refresh');
    expect(hostFrames.single['access_token'], 'host-access');
    expect(hostFrames.single['expires_at'], 1800003600);
    // The app's own refresh token went nowhere.
    expect(
      authFrames(host).any((p) => p['refresh_token'] == 'refresh-1'),
      isFalse,
    );
    await client.dispose();
  });

  test('a host session that cannot be minted sends nothing', () async {
    final source = _SessionSource(
      current: const AccountSession(
        accessToken: 'access-1',
        refreshToken: 'refresh-1',
        userId: 'user-1',
      ),
    );
    final (client, host, _) = await paired(
      sessionSource: source,
      hostSessionMinter: (_) async => null,
    );
    await client.provisionAccount(source.current()!);
    await settle();
    await host.emit(<String, dynamic>{'type': 'host_session_request'});
    await settle();
    expect(authFrames(host).where((p) => p['session_kind'] == 'host'), isEmpty);
    await client.dispose();
  });

  test('channelIdOf takes everything before the last dash', () {
    expect(AgentsRelayClient.channelIdOf('chan1234-428913'), 'chan1234');
    expect(AgentsRelayClient.channelIdOf('a-b-c-999'), 'a-b-c');
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
      signingKeyPair: await AgentsDeviceKeys.generate(),
      nowMs: clock,
    );
    await host.start();

    final client = AgentsRelayClient(
      deviceId: 'app-desktop-1',
      signingKeyPair: await AgentsDeviceKeys.generate(),
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

    expect(client.state.value.phase, AgentsRelayPhase.paired);
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
    expect(auth.containsKey('refresh_token'), isFalse);
    expect(auth['user_id'], 'user-1');

    await client.dispose();
  });

  test('a failed provision reports one error and releases waiting replay', () async {
    final (client, host, _) = await paired();
    addTearDown(() async {
      AgentsRelayClient.debugBeforeSeal = null;
      await client.dispose();
    });
    AgentsRelayClient.debugBeforeSeal = (payload) async {
      if (payload['type'] == 'account_authentication') {
        throw StateError('Socket closed during provisioning');
      }
    };
    final replay = client.requestReplay(sessionKey: 'thread-1');
    await expectLater(
      client.provisionAccount(const AccountSession(
        accessToken: 'access-1',
        refreshToken: 'refresh-1',
        userId: 'user-1',
      )),
      throwsStateError,
    );
    await replay;
    await settle();
    expect(host.received.where((m) => m['type'] == 'replay'), hasLength(1));
  });

  test('sendTask seals {type:task,prompt}; the host opens it', () async {
    final (client, host, _) = await paired();

    await client.sendTask('list the files');
    await Future<void>.delayed(Duration.zero);

    final task = host.received.singleWhere((m) => m['type'] == 'task');
    expect(task['prompt'], 'list the files');

    await client.dispose();
  });

  test('sendTask waits for the account provision, so a task never overtakes '
      'its own auth', () async {
    // This is how a message disappeared. Right after a reconnect the task
    // frame could reach the host BEFORE the `account_authentication` that says
    // whose task it is, and a host with no provisioned controller session
    // dropped it where it stood: no run, no log, no error frame. The app saw
    // the same nothing it sees for a frame that never left the phone.
    final (client, host, _) = await paired();

    final task = client.sendTask(
      'list the files',
      sessionKey: 'thread-1',
      taskId: 'task-abc',
    );
    await settle();
    // Held: the provision has not happened.
    expect(host.received.where((m) => m['type'] == 'task'), isEmpty);

    await client.provisionAccount(
      const AccountSession(
        accessToken: 'access-1',
        refreshToken: 'refresh-1',
        userId: 'user-1',
      ),
    );
    await task;
    await settle();

    final order = host.received
        .map((m) => m['type'])
        .where((t) => t == 'account_authentication' || t == 'task')
        .toList();
    expect(order, ['account_authentication', 'task']);
    final sent = host.received.singleWhere((m) => m['type'] == 'task');
    expect(sent['task_id'], 'task-abc');

    await client.dispose();
  });

  test('a task with no id leaves the key off the frame, and an ack comes back '
      'as a typed event', () async {
    // The id is optional on the wire, so a caller that has none and a host too
    // old to know the key both keep working exactly as before.
    final (client, host, _) = await paired();
    await client.provisionAccount(
      const AccountSession(
        accessToken: 'access-1',
        refreshToken: 'refresh-1',
        userId: 'user-1',
      ),
    );
    final acks = <AgentsRelayTaskAck>[];
    client.inbound.listen((event) {
      if (event is AgentsRelayTaskAck) acks.add(event);
    });

    await client.sendTask('list the files', sessionKey: 'thread-1');
    await settle();
    expect(
      host.received.singleWhere((m) => m['type'] == 'task'),
      isNot(contains('task_id')),
    );

    // `request_id` is what the contract calls the executor's id for the work.
    await host.emit(<String, dynamic>{
      'type': 'task_ack',
      'task_id': 'task-abc',
      'session_key': 'thread-1',
      'status': 'rejected',
      'reason': 'not_provisioned',
    });
    await settle();
    expect(acks.single.taskId, 'task-abc');
    expect(acks.single.isRejected, isTrue);
    expect(acks.single.isRetryable, isTrue);

    await client.dispose();
  });

  test('a replay waits for the account provision, so auth goes out first',
      () async {
    // The host logs "expected account_authentication, got 'replay'" when the
    // order is the other way round: the reattaching view asks for its
    // transcript before the token that says whose transcript it is. Holding the
    // replay costs nothing — it is the same round trip either way.
    final (client, host, _) = await paired();

    final replay = client.requestReplay(sessionKey: 'thread-1');
    await settle();
    // Nothing yet: the provision has not happened.
    expect(host.received.where((m) => m['type'] == 'replay'), isEmpty);

    await client.provisionAccount(
      const AccountSession(
        accessToken: 'access-1',
        refreshToken: 'refresh-1',
        userId: 'user-1',
      ),
    );
    await replay;
    await settle();

    final order = host.received
        .map((m) => m['type'])
        .where((t) => t == 'account_authentication' || t == 'replay')
        .toList();
    expect(order, ['account_authentication', 'replay']);

    await client.dispose();
  });

  test('the agent_list request waits for the account provision too, and the '
      'coworker frames carry the id and the name', () async {
    // Sent on pair, the list request used to reach the host before the token
    // ("expected account_authentication, got 'agent_list'") and was dropped;
    // nothing asked again until the next pairing, so the roster stayed
    // without the host's names (bead cowork-817, Host #6 finding).
    final (client, host, _) = await paired();

    final list = client.requestAgentList();
    await settle();
    expect(host.received.where((m) => m['type'] == 'agent_list'), isEmpty);

    await client.provisionAccount(
      const AccountSession(
        accessToken: 'access-1',
        refreshToken: 'refresh-1',
        userId: 'user-1',
      ),
    );
    await list;
    await client.createAgent('local:desk:1:7', 'Crypto Desk');
    await client.renameAgent('host:cowork-host', 'Laptop Bot');
    await settle();

    final order = host.received
        .map((m) => m['type'])
        .where((t) =>
            t == 'account_authentication' ||
            t == 'agent_list' ||
            t == 'agent_create' ||
            t == 'agent_rename')
        .toList();
    expect(order,
        ['account_authentication', 'agent_list', 'agent_create', 'agent_rename']);
    final create = host.received.firstWhere((m) => m['type'] == 'agent_create');
    expect(create, {
      'type': 'agent_create',
      'agent_id': 'local:desk:1:7',
      'name': 'Crypto Desk',
    });
    final rename = host.received.firstWhere((m) => m['type'] == 'agent_rename');
    expect(rename['agent_id'], 'host:cowork-host');
    expect(rename['name'], 'Laptop Bot');

    await client.dispose();
  });

  test('a retry says so on the frame, a normal send does not', () async {
    // Without the flag the host cannot tell a Retry from the reader asking the
    // same question again, so it stores a second user turn: the transcript
    // replays the question once per attempt and the model is handed a history
    // full of repeats (bead cowork-bkw).
    final (client, host, _) = await paired();

    await client.sendTask('why');
    await client.sendTask('why', regenerate: true);
    await Future<void>.delayed(Duration.zero);

    final tasks = host.received.where((m) => m['type'] == 'task').toList();
    expect(tasks, hasLength(2));
    expect(tasks.first.containsKey('regenerate'), isFalse);
    expect(tasks.last['regenerate'], isTrue);

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

  test('an approval_request frame surfaces as a AgentsRelayApprovalRequest',
      () async {
    final (client, host, _) = await paired();
    final events = <AgentsRelayInbound>[];
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

    final ask = events.whereType<AgentsRelayApprovalRequest>().single;
    expect(ask.approvalId, 'ap-1');
    expect(ask.name, 'My Page');
    expect(ask.fileCount, 2);
    expect(ask.totalBytes, 1024);
    expect(ask.public, isTrue);

    await sub.cancel();
    await client.dispose();
  });

  test('replayed file, subagent and approval frames carry replay, mid and '
      'the approval outcome (cowork-266)', () async {
    final (client, host, _) = await paired();
    final events = <AgentsRelayInbound>[];
    final sub = client.inbound.listen(events.add);

    await host.emit(<String, dynamic>{
      'type': 'file',
      'name': 'a.txt',
      'mime_type': 'text/plain',
      'size': 2,
      'data': base64.encode(<int>[104, 105]),
      'replay': true,
      'mid': 7,
    });
    await host.emit(<String, dynamic>{
      'type': 'subagent',
      'event': {'type': 'subagent_state', 'subagent_id': 'sa_1', 'state': 'succeeded'},
      'replay': true,
      'mid': 8,
    });
    await host.emit(<String, dynamic>{
      'type': 'approval_request',
      'approval_id': 'ap-1',
      'action': 'herenow_publish',
      'path': 'site',
      'name': 'My Page',
      'file_count': 1,
      'total_bytes': 5,
      'base_url': 'https://here.now',
      'public': true,
      'replay': true,
      'mid': 9,
      'decision': 'denied',
      'decision_reason': 'timeout',
      'decided_at': 12.5,
    });
    // A live frame of each kind stays unmarked.
    await host.emit(<String, dynamic>{
      'type': 'subagent',
      'event': {'type': 'subagent_state', 'subagent_id': 'sa_2', 'state': 'running'},
    });
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final file = events.whereType<AgentsRelayFile>().single;
    expect(file.replay, isTrue);
    expect(file.mid, 7);
    expect(file.isValid, isTrue);

    final subs = events.whereType<AgentsRelaySubagent>().toList();
    expect(subs[0].replay, isTrue);
    expect(subs[0].mid, 8);
    expect(subs[1].replay, isFalse);
    expect(subs[1].mid, isNull);

    final ask = events.whereType<AgentsRelayApprovalRequest>().single;
    expect(ask.replay, isTrue);
    expect(ask.mid, 9);
    expect(ask.isDecided, isTrue);
    expect(ask.isApproved, isFalse);
    expect(ask.decision, 'denied');
    expect(ask.decisionReason, 'timeout');

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

  test('a heartbeat frame opens and surfaces as proof of life', () async {
    final (client, host, _) = await paired();

    final events = <AgentsRelayInbound>[];
    final sub = client.inbound.listen(events.add);

    await host.emit(<String, dynamic>{
      'type': 'heartbeat',
      'run_id': 'run-7',
      'session_key': 'thread-1',
      'seq': 3,
      'elapsed': 31.4,
    });
    // A host too old to send the extra fields still says it is alive.
    await host.emit(<String, dynamic>{'type': 'heartbeat'});
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final beats = events.whereType<AgentsRelayHeartbeat>().toList();
    expect(beats, hasLength(2));
    expect(beats.first.runId, 'run-7');
    expect(beats.first.sessionKey, 'thread-1');
    expect(beats.first.seq, 3);
    expect(beats.first.elapsedSeconds, 31.4);
    expect(beats.last.seq, 0);
    expect(beats.last.runId, isNull);

    await sub.cancel();
    await client.dispose();
  });

  test('delta / tool / done frames from the host open and surface as events',
      () async {
    final (client, host, _) = await paired();

    final events = <AgentsRelayInbound>[];
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

    expect(events.whereType<AgentsRelayDelta>().map((e) => e.text).join(), 'Hello');
    final tool = events.whereType<AgentsRelayTool>().single;
    expect(tool.name, 'shell');
    expect(tool.status, 'running');
    expect(events.whereType<AgentsRelayDone>(), hasLength(1));

    await sub.cancel();
    await client.dispose();
  });

  test('a subagent_state frame surfaces; a subagent_output frame does not',
      () async {
    final (client, host, _) = await paired();
    final events = <AgentsRelayInbound>[];
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

    final subs = events.whereType<AgentsRelaySubagent>().toList();
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
    final events = <AgentsRelayInbound>[];
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

    final turns = events.whereType<AgentsRelayRoomTurn>().toList();
    expect(turns, hasLength(2));
    expect(turns.first.roomId, 'r1');
    expect(turns.first.round, 1);
    expect(turns.first.handle, 'amber');
    expect(turns.first.text, 'ship it');
    expect(turns.last.agentId, 'id-cobalt');

    final done = events.whereType<AgentsRelayRoomDone>().single;
    expect(done.roomId, 'r1');
    expect(done.reason, 'no_more_mentions');
    expect(done.messagesSent, 2);
    expect(done.rounds, 2);

    await sub.cancel();
    await client.dispose();
  });

  test('a malformed room_turn is dropped, not surfaced', () async {
    final (client, host, _) = await paired();
    final events = <AgentsRelayInbound>[];
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
    expect(events.whereType<AgentsRelayRoomTurn>(), isEmpty);

    await sub.cancel();
    await client.dispose();
  });

  test('a room_history frame surfaces its stored turns', () async {
    final (client, host, _) = await paired();
    final events = <AgentsRelayInbound>[];
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

    final hist = events.whereType<AgentsRelayRoomHistory>().single;
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

    final events = <AgentsRelayInbound>[];
    final sub = client.inbound.listen(events.add);

    // A frame signed by a device the client never approved.
    final rogueKey = await AgentsDeviceKeys.generate();
    final rogueSealer = AgentsFrameSealer.withChannelKey(
      channelKey: List<int>.filled(kAgentsChannelKeyLength, 7),
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
    expect(events.whereType<AgentsRelayDelta>().single.text, 'ok');

    await sub.cancel();
    await client.dispose();
  });

  // --- refresh scheduler hooks (bead cowork-2n1) ------------------------------

  test('tells the refresh scheduler when the host is attached, away and gone',
      () async {
    final scheduler = SessionRefreshScheduler(
      source: _SessionSource(
        current: const AccountSession(
          accessToken: 'a1',
          refreshToken: 'r1',
          userId: 'user-1',
        ),
      ),
    );
    expect(scheduler.hostAttached, isNull);

    final (client, _, socket) = await paired(scheduler: scheduler);
    expect(scheduler.hostAttached, isTrue);
    expect(scheduler.reconnectHost, isNotNull);

    // Attached: a reattach request is a no-op, the pairing stays.
    await scheduler.reconnectHost!();
    expect(client.state.value.phase, AgentsRelayPhase.paired);

    // The host drops: the scheduler must know before it spends a token.
    await socket.close();
    await pumpEventQueue();
    expect(client.state.value.phase, AgentsRelayPhase.closed);
    expect(scheduler.hostAttached, isFalse);
    expect(scheduler.reconnectHost, isNotNull);

    // Gone: the hooks are withdrawn, the scheduler refreshes on its own.
    await client.dispose();
    expect(scheduler.hostAttached, isNull);
    expect(scheduler.reconnectHost, isNull);
  });

  test('after a host drop the scheduler\'s reconnectHost dials again instead of '
      'refusing with "Already connected" (F4)', () async {
    final scheduler = SessionRefreshScheduler(
      source: _SessionSource(
        current: const AccountSession(
          accessToken: 'a1',
          refreshToken: 'r1',
          userId: 'user-1',
        ),
      ),
    );
    final first = FakeRelaySocket();
    final host = FakeExecutorHost(
      socket: first,
      deviceId: 'host-laptop-1',
      channelId: 'chan1234',
      digits: '428913',
      signingKeyPair: await AgentsDeviceKeys.generate(),
      nowMs: clock,
    );
    await host.start();
    var dials = 0;
    final client = AgentsRelayClient(
      deviceId: 'app-desktop-1',
      signingKeyPair: await AgentsDeviceKeys.generate(),
      // The first dial reaches the host; every later one gets a fresh, silent
      // socket — enough to prove the client let go of the dead one.
      connector: (_) async => ++dials == 1 ? first : FakeRelaySocket(),
      nowMs: clock,
      scheduler: scheduler,
    );
    await client.connect(
      hostUrl: Uri.parse('ws://127.0.0.1:8787'),
      pairingCode: 'chan1234-428913',
    );
    await host.paired.future;
    expect(dials, 1);

    // The host drops.
    await first.close();
    await pumpEventQueue();
    expect(client.state.value.phase, AgentsRelayPhase.closed);
    expect(scheduler.hostAttached, isFalse);

    // The scheduler asks for a re-attach: it must dial, not throw.
    Object? failure;
    unawaited(scheduler.reconnectHost!().catchError((Object e) {
      failure = e;
    }));
    await pumpEventQueue();
    expect(failure, isNull);
    expect(dials, 2);

    await client.dispose();
  });

  test('a disposed client does not withdraw a successor client\'s hooks',
      () async {
    final scheduler = SessionRefreshScheduler(
      source: _SessionSource(
        current: const AccountSession(
          accessToken: 'a1',
          refreshToken: 'r1',
          userId: 'user-1',
        ),
      ),
    );
    final (first, _, _) = await paired(scheduler: scheduler);
    final (second, _, _) = await paired(
      scheduler: scheduler,
      channelId: 'chan5678',
      digits: '112233',
    );
    expect(scheduler.hostAttached, isTrue);

    await first.dispose();
    expect(scheduler.hostAttached, isTrue);
    expect(scheduler.reconnectHost, isNotNull);

    await second.dispose();
    expect(scheduler.hostAttached, isNull);
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

    final client = AgentsRelayClient(
      deviceId: 'app-desktop-1',
      signingKeyPair: await AgentsDeviceKeys.generate(),
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
    expect(client.state.value.phase, AgentsRelayPhase.error);

    await client.dispose();
  });

  test('sendTask before pairing throws', () async {
    final client = AgentsRelayClient(
      deviceId: 'app-desktop-1',
      signingKeyPair: await AgentsDeviceKeys.generate(),
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

    final events = <AgentsRelayInbound>[];
    final sub = client.inbound.listen(events.add);

    final rfb = base64.encode(<int>[0, 1, 82, 70, 66, 255]); // arbitrary bytes
    await host.emit(<String, dynamic>{
      'type': 'browser_view', 'status': 'started', 'vnc_available': true,
    });
    await host.emit(<String, dynamic>{'type': 'browser_data', 'size': 6, 'data': rfb});
    await host.emit(<String, dynamic>{
      'type': 'browser_view',
      'status': 'error',
      'message': 'no browser open yet',
      'reason': 'no_display',
    });
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final views = events.whereType<AgentsRelayBrowserView>().toList();
    expect(views.map((e) => e.status), <String>['started', 'error']);
    expect(views.last.message, 'no browser open yet');
    expect(views.first.vncAvailable, isTrue);
    expect(views.last.vncAvailable, isFalse);
    // The machine-readable half of the message (bead cowork-qp5i); a host too
    // old to send it leaves it empty rather than absent.
    expect(views.last.reason, 'no_display');
    expect(views.first.reason, isEmpty);

    final data = events.whereType<AgentsRelayBrowserData>().single;
    expect(data.bytes, <int>[0, 1, 82, 70, 66, 255]);

    await sub.cancel();
    await client.dispose();
  });

  // Bead cowork-5eo6: without the key the executor resolves the PRIMARY
  // environment, which with one container per coworker is almost never the box
  // the browser is in — the view then reports no browser while one is running.
  test('browser_start names the thread whose box to look in', () async {
    final (client, host, _) = await paired();

    await client.startBrowserView(sessionKey: 'agent-7');
    await Future<void>.delayed(Duration.zero);

    final start =
        host.received.singleWhere((m) => m['type'] == 'browser_start');
    expect(start['session_key'], 'agent-7');
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
    // No key given, no key sent: the executor keeps its old behaviour.
    final bareStart =
        host.received.singleWhere((m) => m['type'] == 'browser_start');
    expect(bareStart.containsKey('session_key'), isFalse);
    final data = host.received.singleWhere((m) => m['type'] == 'browser_data');
    expect(base64.decode(data['data'] as String), <int>[9, 8, 7]);

    await client.dispose();
  });

  test('outbound frames stay in call order even when an earlier seal is slow',
      () async {
    // `seal` takes its seq synchronously; the send happens after an await. If
    // the first send is slower than the second, an unchained client would put
    // seq n+1 on the wire before seq n and the host would reject n (strictly
    // increasing seq). The FIFO chain must keep wire order == call order.
    final (client, host, _) = await paired();
    AgentsRelayClient.debugBeforeSeal = (payload) async {
      if (payload['type'] == 'browser_data' &&
          (payload['data'] as String).startsWith(base64.encode(<int>[1]))) {
        await Future<void>.delayed(const Duration(milliseconds: 60));
      }
    };
    try {
      final first = client.sendBrowserData(Uint8List.fromList(<int>[1, 1, 1]));
      final second = client.sendBrowserData(Uint8List.fromList(<int>[2, 2, 2]));
      await Future.wait(<Future<void>>[first, second]);
      await Future<void>.delayed(Duration.zero);
    } finally {
      AgentsRelayClient.debugBeforeSeal = null;
    }
    final datas = host.received
        .where((m) => m['type'] == 'browser_data')
        .map((m) => base64.decode(m['data'] as String).first)
        .toList();
    expect(datas, <int>[1, 2]); // both arrived (none rejected), in call order
    await client.dispose();
  });

  test('a failed send does not poison the send chain', () async {
    final (client, host, _) = await paired();
    var calls = 0;
    AgentsRelayClient.debugBeforeSeal = (payload) async {
      if (payload['type'] == 'browser_data' && ++calls == 1) {
        throw StateError('boom');
      }
    };
    try {
      await expectLater(
        client.sendBrowserData(Uint8List.fromList(<int>[7])),
        throwsA(isA<StateError>()),
      );
      await client.sendBrowserData(Uint8List.fromList(<int>[8]));
      await Future<void>.delayed(Duration.zero);
    } finally {
      AgentsRelayClient.debugBeforeSeal = null;
    }
    final datas = host.received
        .where((m) => m['type'] == 'browser_data')
        .map((m) => base64.decode(m['data'] as String).first)
        .toList();
    expect(datas, <int>[8]); // the failed one never hit the wire, the next did
    await client.dispose();
  });

  test('a run_command tool payload becomes arguments, result and a failure flag',
      () async {
    final (client, host, _) = await paired();
    final events = <AgentsRelayInbound>[];
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

    final tools = events.whereType<AgentsRelayTool>().toList();
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
    final events = <AgentsRelayInbound>[];
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

    final file = events.whereType<AgentsRelayFile>().single;
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
    final events = <AgentsRelayInbound>[];
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

    final files = events.whereType<AgentsRelayFile>().toList();
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
    final events = <AgentsRelayInbound>[];
    final sub = client.inbound.listen(events.add);

    await host.emit(<String, dynamic>{'type': 'reasoning', 'text': 'thinking…'});
    await host.emit(<String, dynamic>{
      'type': 'done',
      'final_answer': 'all set',
      'reason': 'interrupted',
      'iterations': 4,
    });
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(events.whereType<AgentsRelayReasoning>().single.text, 'thinking…');
    final done = events.whereType<AgentsRelayDone>().single;
    expect(done.reason, 'interrupted');
    expect(done.iterations, 4);
    expect(done.finalAnswer, 'all set');
    expect(done.wasStopped, isTrue);

    await sub.cancel();
    await client.dispose();
  });

  test('an mcp_credentials frame goes to the connector store, not to the UI',
      () async {
    // The host renews the OAuth tokens while the app is closed, and a provider
    // that rotates refresh tokens kills the device's copy in the act. The frame
    // is state to store, not something to render — the user did nothing and has
    // nothing to decide.
    final (client, host, _) = await paired();
    final events = <AgentsRelayInbound>[];
    final sub = client.inbound.listen(events.add);
    final applied = <Map<String, dynamic>>[];
    final original = AgentsRelayClient.mcpCredentialsSink;
    AgentsRelayClient.mcpCredentialsSink = (payload) async {
      applied.add(payload);
      return 1;
    };
    addTearDown(() => AgentsRelayClient.mcpCredentialsSink = original);

    await host.emit(<String, dynamic>{
      'type': 'mcp_credentials',
      'session_key': 'amber-otter-2',
      'id': 'notion',
      'name': 'Notion',
      'url': 'https://mcp.notion.example/mcp',
      'access_token': 'at-new',
      'oauth': <String, dynamic>{
        'refresh_token': 'rt-2',
        'token_endpoint': 'https://auth.notion.example/token',
        'client_id': 'cid-notion',
      },
      'rotated_at': '2026-09-05T09:00:00.000Z',
    });
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(applied, hasLength(1));
    expect(applied.single['id'], 'notion');
    expect((applied.single['oauth'] as Map)['refresh_token'], 'rt-2');
    expect(events, isEmpty);

    await sub.cancel();
    await client.dispose();
  });

  test('a run_state frame surfaces the host run in flight for the thread',
      () async {
    final (client, host, _) = await paired();
    final events = <AgentsRelayInbound>[];
    final sub = client.inbound.listen(events.add);

    await host.emit(<String, dynamic>{
      'type': 'run_state',
      'session_key': 'amber-otter-2',
      'state': 'running',
      'run_id': 'run-77',
      'started_at': 1723478400,
      'prompt': 'read the log',
    });
    await host.emit(<String, dynamic>{
      'type': 'run_state',
      'session_key': 'cobalt-fox-1',
      'state': 'idle',
    });
    // No session key names nothing to route to — dropped, not surfaced.
    await host.emit(<String, dynamic>{'type': 'run_state', 'state': 'running'});
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final states = events.whereType<AgentsRelayRunState>().toList();
    expect(states, hasLength(2));
    expect(states.first.sessionKey, 'amber-otter-2');
    expect(states.first.isRunning, isTrue);
    expect(states.first.runId, 'run-77');
    expect(states.first.startedAt, 1723478400);
    expect(states.first.prompt, 'read the log');
    expect(states.last.sessionKey, 'cobalt-fox-1');
    expect(states.last.isRunning, isFalse);
    expect(states.last.runId, isNull);

    await sub.cancel();
    await client.dispose();
  });

  test('done carries run_id and while_away; only reason "replay" is the '
      'history end', () async {
    final (client, host, _) = await paired();
    final events = <AgentsRelayInbound>[];
    final sub = client.inbound.listen(events.add);

    // A persisted run terminal replayed from the host: a real completion the
    // user never saw, NOT the end-of-history marker.
    await host.emit(<String, dynamic>{
      'type': 'done',
      'final_answer': 'the report is written',
      'reason': 'finished',
      'iterations': 3,
      'tokens_spent': 900,
      'replay': true,
      'run_id': 'run-42',
      'while_away': true,
    });
    // The marker that closes the replay stream.
    await host.emit(<String, dynamic>{
      'type': 'done',
      'reason': 'replay',
      'replay': true,
    });
    // A live run ending.
    await host.emit(<String, dynamic>{
      'type': 'done',
      'reason': 'finished',
      'run_id': 'run-43',
    });
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final dones = events.whereType<AgentsRelayDone>().toList();
    expect(dones, hasLength(3));

    expect(dones[0].runId, 'run-42');
    expect(dones[0].whileAway, isTrue);
    expect(dones[0].isReplay, isTrue);
    // The whole point of the helper: a replayed terminal is not the end marker.
    expect(dones[0].isHistoryEnd, isFalse);

    expect(dones[1].isHistoryEnd, isTrue);
    expect(dones[1].isReplay, isTrue);
    expect(dones[1].runId, isNull);
    expect(dones[1].whileAway, isFalse);

    expect(dones[2].runId, 'run-43');
    expect(dones[2].isReplay, isFalse);
    expect(dones[2].isHistoryEnd, isFalse);
    expect(dones[2].whileAway, isFalse);

    await sub.cancel();
    await client.dispose();
  });

  test('mid decodes on replayed delta, user and tool events', () async {
    final (client, host, _) = await paired();
    final events = <AgentsRelayInbound>[];
    final sub = client.inbound.listen(events.add);

    await host.emit(<String, dynamic>{
      'type': 'user',
      'text': 'read the log',
      'replay': true,
      'mid': 11,
    });
    await host.emit(<String, dynamic>{
      'type': 'delta',
      'text': 'reading…',
      'replay': true,
      'mid': 12,
    });
    await host.emit(<String, dynamic>{
      'type': 'tool',
      'name': 'run_command',
      'command': 'tail -n 5 log',
      'exit_code': 0,
      'replay': true,
      'mid': 13,
    });
    // A live event without a cursor keeps mid null — it is optional.
    await host.emit(<String, dynamic>{'type': 'delta', 'text': 'live'});
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(events.whereType<AgentsRelayUser>().single.mid, 11);
    final deltas = events.whereType<AgentsRelayDelta>().toList();
    expect(deltas.first.mid, 12);
    expect(deltas.last.mid, isNull);
    expect(events.whereType<AgentsRelayTool>().single.mid, 13);

    await sub.cancel();
    await client.dispose();
  });

  test('requestReplay sends after_id only when the cursor advanced', () async {
    final (client, host, _) = await paired();

    await client.requestReplay(sessionKey: 'amber-otter-2', afterId: 42);
    await client.requestReplay(sessionKey: 'cobalt-fox-1');
    await Future<void>.delayed(Duration.zero);

    final replays =
        host.received.where((m) => m['type'] == 'replay').toList();
    expect(replays, hasLength(2));
    expect(replays[0]['session_key'], 'amber-otter-2');
    expect(replays[0]['after_id'], 42);
    // A fresh thread asks for the whole history: no cursor on the frame, so an
    // old host sees exactly the frame it always saw — plus the page size, which
    // an old host ignores (Bead cowork-axx).
    expect(replays[1]['session_key'], 'cobalt-fox-1');
    expect(replays[1].containsKey('after_id'), isFalse);
    expect(replays[1]['limit'], kReplayPageSize);
    // A delta replay is never paged.
    expect(replays[0].containsKey('limit'), isFalse);

    await client.dispose();
  });

  test('requestReplay pages: before_id and limit ride the frame, the done '
      'brings has_more / oldest_mid back', () async {
    final (client, host, _) = await paired();
    final events = <AgentsRelayInbound>[];
    final sub = client.inbound.listen(events.add);

    await client.requestReplay(
        sessionKey: 'cobalt-fox-1', beforeId: 120, limit: 50);
    await Future<void>.delayed(Duration.zero);
    final page = host.received.singleWhere((m) => m['type'] == 'replay');
    expect(page['before_id'], 120);
    expect(page['limit'], 50);
    expect(page.containsKey('after_id'), isFalse);

    await host.emit(<String, dynamic>{
      'type': 'done',
      'reason': 'replay',
      'replay': true,
      'final_answer': null,
      'iterations': 0,
      'has_more': true,
      'oldest_mid': 71,
      'before_id': 120,
    });
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final done = events.whereType<AgentsRelayDone>().single;
    expect(done.isHistoryEnd, isTrue);
    expect(done.hasMore, isTrue);
    expect(done.oldestMid, 71);
    expect(done.pageBeforeId, 120);

    await sub.cancel();
    await client.dispose();
  });

  test('sendRunAck seals {type:run_ack,run_id}; the host opens it', () async {
    final (client, host, _) = await paired();

    await client.sendRunAck('run-42');
    await Future<void>.delayed(Duration.zero);

    final ack = host.received.singleWhere((m) => m['type'] == 'run_ack');
    expect(ack['run_id'], 'run-42');
    expect(ack.keys, containsAll(<String>['type', 'run_id']));

    await client.dispose();
  });

  // The model the user picked in the composer does not go to a hosted API: it
  // rides the task frame to the host as `model` / `provider` /
  // `reasoning_effort` (docs/WIRE_CONTRACT.md). The executor reads exactly
  // those three keys (agents/executor/tests/test_model_select.py covers that half);
  // these two cover this half, so the contract is closed on both sides.
  test('sendTask puts the picked model, provider and reasoning on the frame',
      () async {
    final (client, host, _) = await paired();

    await client.sendTask(
      'summarise the log',
      sessionKey: 'amber-otter-2',
      modelId: 'glm-5.3-flash',
      providerSlug: 'zhipu',
      reasoningEffort: 'low',
    );
    await Future<void>.delayed(Duration.zero);

    final task = host.received.singleWhere((m) => m['type'] == 'task');
    expect(task['prompt'], 'summarise the log');
    expect(task['session_key'], 'amber-otter-2');
    // The names are `model` and `provider`, NOT `model_id` / `provider_slug`:
    // the executor looks those three up by these exact keys.
    expect(task['model'], 'glm-5.3-flash');
    expect(task['provider'], 'zhipu');
    expect(task['reasoning_effort'], 'low');
    // Fast mode is a model plus a reasoning level, never its own flag.
    expect(task.containsKey('fast_mode'), isFalse);

    await client.dispose();
  });

  test('sendTask leaves the model keys off when the composer set none',
      () async {
    final (client, host, _) = await paired();

    // Nothing chosen, and the empty string is treated as nothing too — either
    // way the host keeps its own default instead of being pinned to ''.
    await client.sendTask('summarise the log');
    await client.sendTask(
      'summarise it again',
      modelId: '',
      providerSlug: '',
      reasoningEffort: '',
    );
    await Future<void>.delayed(Duration.zero);

    final tasks = host.received.where((m) => m['type'] == 'task').toList();
    expect(tasks, hasLength(2));
    for (final task in tasks) {
      expect(task.containsKey('model'), isFalse);
      expect(task.containsKey('provider'), isFalse);
      expect(task.containsKey('reasoning_effort'), isFalse);
    }

    await client.dispose();
  });

  // --- room policy: agent_to_agent (bead cowork-h46g) ------------------------

  test('createRoom leaves agent_to_agent off the frame when it is on',
      () async {
    final (client, host, _) = await paired();

    await client.createRoom('room-1', 'launch', const <Map<String, String>>[
      <String, String>{'agent_id': 'a', 'handle': 'amber'},
      <String, String>{'agent_id': 'b', 'handle': 'cobalt'},
    ]);
    await settle();

    final frame = host.received.singleWhere((m) => m['type'] == 'room_create');
    expect(frame['room_id'], 'room-1');
    expect(frame['name'], 'launch');
    // The key rides only when the policy is OFF, so a host that never heard of
    // it sees exactly the frame it has always seen.
    expect(frame.containsKey('agent_to_agent'), isFalse);

    await client.dispose();
  });

  test('createRoom carries agent_to_agent:false when the room turned it off',
      () async {
    final (client, host, _) = await paired();

    await client.createRoom(
      'room-2',
      'quiet',
      const <Map<String, String>>[
        <String, String>{'agent_id': 'a', 'handle': 'amber'},
        <String, String>{'agent_id': 'b', 'handle': 'cobalt'},
      ],
      agentToAgent: false,
    );
    await settle();

    final frame = host.received.singleWhere((m) => m['type'] == 'room_create');
    expect(frame['agent_to_agent'], false);

    await client.dispose();
  });

  test('setRoomAgentToAgent seals the room_set_agent_to_agent frame', () async {
    final (client, host, _) = await paired();

    await client.setRoomAgentToAgent('room-3', false);
    await client.setRoomAgentToAgent('room-3', true);
    await settle();

    final frames = host.received
        .where((m) => m['type'] == 'room_set_agent_to_agent')
        .toList();
    expect(frames, hasLength(2));
    expect(frames.first['room_id'], 'room-3');
    expect(frames.first['enabled'], false);
    expect(frames.last['enabled'], true);

    await client.dispose();
  });

  test('a room frame carries as many members as the room has', () async {
    // There is no member ceiling any more; the frame must not quietly cut one.
    final (client, host, _) = await paired();

    await client.createRoom('room-4', 'all hands', <Map<String, String>>[
      for (var i = 0; i < 12; i++)
        <String, String>{'agent_id': 'id$i', 'handle': 'h$i'},
    ]);
    await settle();

    final frame = host.received.singleWhere((m) => m['type'] == 'room_create');
    expect((frame['members'] as List<dynamic>), hasLength(12));

    await client.dispose();
  });
}
