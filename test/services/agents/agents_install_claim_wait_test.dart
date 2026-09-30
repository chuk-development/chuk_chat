// The waiting claim of the install flow: claim again until the computer has
// parked on the channel, dial again when the socket drops, stop at the
// deadline or on cancel.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/web_socket_channel.dart'
    show WebSocketChannelException;

import 'package:chuk_chat/services/account_session.dart';
import 'package:chuk_chat/services/agents/agents_cloud_relay.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';

/// One relay socket. It signs the app in, then answers each claim with the
/// next step of [script]:
///
///  * `unknown` — `pairing_channel_unknown` (the computer has not parked),
///  * `claimed` — the success pair, presence first,
///  * `invalid` — `invalid_pairing_channel` (final),
///  * `drop`    — no answer; the socket closes.
class _ClaimSocket implements RelaySocket {
  _ClaimSocket(this.script, {this.authOk = true, this.commitOnBind = false});

  final List<String> script;
  final bool authOk;

  /// Sends the host's commit right behind the claim answer, as the real host
  /// does on `cowork_pair_bound`.
  final bool commitOnBind;

  static const Map<String, dynamic> commit = <String, dynamic>{
    'type': 'pairing',
    'step': 'commit',
  };

  /// The local-relay envelopes the app sent to the host, unwrapped.
  List<Map<String, dynamic>> get relayed => <Map<String, dynamic>>[
    for (final Map<String, dynamic> f in sent)
      if (f['type'] == 'cowork_relay')
        jsonDecode(f['payload'] as String) as Map<String, dynamic>,
  ];
  int claims = 0;
  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
  bool closed = false;

  static const String hostDeviceId = 'host-device-9';

  final StreamController<dynamic> _toApp =
      StreamController<dynamic>.broadcast();

  @override
  Stream<dynamic> get incoming => _toApp.stream;

  @override
  void send(String data) {
    final Map<String, dynamic> frame = jsonDecode(data) as Map<String, dynamic>;
    sent.add(frame);
    switch (frame['type']) {
      case 'auth':
        _deliver(
          authOk
              ? <String, dynamic>{'type': 'auth_ok'}
              : <String, dynamic>{'type': 'auth_error', 'detail': 'Invalid'},
        );
      case 'cowork_pair_claim':
        final String step = claims < script.length ? script[claims] : 'unknown';
        claims++;
        switch (step) {
          case 'claimed':
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
            // The host is bound now, and it publishes its §15 commit at once,
            // before anybody on the app side has sent a `join`.
            if (commitOnBind) {
              _deliver(<String, dynamic>{
                'req_id': 'server1',
                'type': 'cowork_relay',
                'payload': jsonEncode(commit),
              });
            }
          case 'invalid':
            _deliver(<String, dynamic>{
              'type': 'cowork_pair_error',
              'code': 'invalid_pairing_channel',
              'req_id': frame['req_id'],
            });
          case 'drop':
            unawaited(close());
          default:
            _deliver(<String, dynamic>{
              'type': 'cowork_pair_error',
              'code': 'pairing_channel_unknown',
              'req_id': frame['req_id'],
            });
        }
    }
  }

  void _deliver(Map<String, dynamic> frame) {
    // Async, as a real socket is: the answer arrives after the send returns.
    scheduleMicrotask(() {
      if (!_toApp.isClosed) _toApp.add(jsonEncode(frame));
    });
  }

  @override
  Future<void> close() async {
    closed = true;
    if (!_toApp.isClosed) await _toApp.close();
  }
}

class _Session implements AccountSessionSource {
  const _Session([this._session = _signedIn]);

  static const AccountSession _signedIn = AccountSession(
    accessToken: 'jwt',
    refreshToken: 'r',
    userId: 'user-1',
  );

  final AccountSession? _session;

  @override
  AccountSession? current() => _session;

  @override
  Future<AccountSession?> refresh() async => _session;
}

void main() {
  const String channel =
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
  final Uri base = Uri.parse('wss://api.chuk.chat');

  late DateTime clock;
  late List<Duration> sleeps;
  late List<_ClaimSocket> sockets;
  late List<Uri> dials;

  /// What a dial throws once the scripted sockets are used up: the network
  /// is down.
  late Object Function() offline;

  setUp(() {
    AgentsCloudRelaySocket.resetClaimCache();
    clock = DateTime.utc(2026, 9, 29, 12);
    sleeps = <Duration>[];
    sockets = <_ClaimSocket>[];
    dials = <Uri>[];
    offline = () => const SocketException('Network is unreachable');
  });

  /// A connector that hands out one scripted socket per dial.
  RelaySocketConnector connector(List<_ClaimSocket> scripted) {
    return (Uri url) async {
      dials.add(url);
      if (sockets.length >= scripted.length) {
        throw offline();
      }
      final _ClaimSocket socket = scripted[sockets.length];
      sockets.add(socket);
      return socket;
    };
  }

  /// The fake clock moves only when the waiter sleeps.
  Future<void> fakeSleep(Duration d) async {
    sleeps.add(d);
    clock = clock.add(d);
  }

  Future<String?> wait(
    List<_ClaimSocket> scripted, {
    Duration lifetime = const Duration(minutes: 30),
    AgentsClaimCancel? cancel,
    AccountSessionSource session = const _Session(),
  }) {
    return AgentsCloudRelaySocket.waitForPairingClaim(
      base: base,
      pairingChannel: channel,
      deviceId: 'app-device-1',
      sessionSource: session,
      deadline: clock.add(lifetime),
      cancel: cancel,
      inner: connector(scripted),
      now: () => clock,
      sleep: fakeSleep,
    );
  }

  test('unknown x N, then claimed: one socket, a claim every 3 s', () async {
    final _ClaimSocket socket = _ClaimSocket(<String>[
      'unknown',
      'unknown',
      'unknown',
      'unknown',
      'claimed',
    ]);
    final String? device = await wait(<_ClaimSocket>[socket]);

    expect(device, _ClaimSocket.hostDeviceId);
    expect(dials, hasLength(1));
    expect(socket.claims, 5);
    expect(sleeps, List<Duration>.filled(4, const Duration(seconds: 3)));
    // The claim shape, exactly: the channel, a req id, nothing else.
    final Map<String, dynamic> claim = socket.sent.firstWhere(
      (Map<String, dynamic> f) => f['type'] == 'cowork_pair_claim',
    );
    expect(claim.keys.toSet(), <String>{'type', 'pairing_channel', 'req_id'});
    expect(claim['pairing_channel'], channel);
    // Signed in as this account's controller first.
    expect(socket.sent.first['type'], 'auth');
    expect(socket.sent.first['role'], 'controller');
    // The dial address carries no marker and no channel.
    expect(dials.single.toString(), 'wss://api.chuk.chat/v2/relay/ws');
    expect(
      socket.closed,
      isFalse,
      reason: 'the socket that won the claim is kept for the pairing',
    );
    expect(
      AgentsCloudRelaySocket.hasHandoff(base: base, pairingChannel: channel),
      isTrue,
    );
    // The pairing that follows finds the claim and never claims again.
    expect(
      AgentsCloudRelaySocket.learnedTarget(base: base, pairingChannel: channel),
      _ClaimSocket.hostDeviceId,
    );
  });

  test('a dropped socket is dialled again with backoff, and the wait goes '
      'on', () async {
    final _ClaimSocket first = _ClaimSocket(<String>['unknown', 'drop']);
    final _ClaimSocket second = _ClaimSocket(<String>['unknown', 'claimed']);
    final String? device = await wait(<_ClaimSocket>[first, second]);

    expect(device, _ClaimSocket.hostDeviceId);
    expect(dials, hasLength(2));
    expect(first.claims, 2);
    expect(second.claims, 2);
    expect(sleeps, contains(AgentsCloudRelaySocket.kClaimReconnectBackoff[0]));
  });

  test('a dial that fails is retried with a growing backoff', () async {
    // Two dials fail (no socket to hand out), then... still none: the
    // deadline ends it. The pauses follow the backoff table.
    await expectLater(
      wait(<_ClaimSocket>[], lifetime: const Duration(seconds: 10)),
      throwsA(
        isA<AgentsCloudRelayException>().having(
          (AgentsCloudRelayException e) => e.code,
          'code',
          'claim_expired',
        ),
      ),
    );
    expect(dials.length, greaterThanOrEqualTo(3));
    expect(sleeps.first, const Duration(seconds: 1));
    expect(sleeps[1], const Duration(seconds: 2));
  });

  test('a WebSocket-layer failure is a network failure too: retried', () async {
    var failed = 0;
    offline = () {
      failed++;
      return WebSocketChannelException('upgrade refused');
    };
    final _ClaimSocket socket = _ClaimSocket(<String>['claimed']);
    // Two failed dials first, then the socket.
    final List<_ClaimSocket> scripted = <_ClaimSocket>[socket];
    var dial = 0;
    final String? device = await AgentsCloudRelaySocket.waitForPairingClaim(
      base: base,
      pairingChannel: channel,
      deviceId: 'app-device-1',
      sessionSource: const _Session(),
      deadline: clock.add(const Duration(minutes: 30)),
      inner: (Uri url) async {
        dial++;
        if (dial <= 2) throw offline();
        return scripted.single;
      },
      now: () => clock,
      sleep: fakeSleep,
    );
    expect(device, _ClaimSocket.hostDeviceId);
    expect(failed, 2);
    expect(dial, 3);
  });

  test('a bug is not a network failure: it ends the wait at once', () async {
    offline = () => StateError('a bug, not the network');
    await expectLater(wait(<_ClaimSocket>[]), throwsA(isA<StateError>()));
    expect(dials, hasLength(1), reason: 'no second dial');
    expect(sleeps, isEmpty, reason: 'no backoff, no waiting');
  });

  test('the deadline ends the wait with claim_expired', () async {
    final _ClaimSocket socket = _ClaimSocket(<String>[]);
    await expectLater(
      wait(<_ClaimSocket>[socket], lifetime: const Duration(seconds: 10)),
      throwsA(
        isA<AgentsCloudRelayException>().having(
          (AgentsCloudRelayException e) => e.code,
          'code',
          'claim_expired',
        ),
      ),
    );
    // 3 + 3 + 3 + 1: the last pause is cut at the deadline.
    expect(socket.claims, 4);
    expect(sleeps.last, const Duration(seconds: 1));
    expect(socket.closed, isTrue);
  });

  test('cancel stops the wait and returns null', () async {
    final AgentsClaimCancel cancel = AgentsClaimCancel();
    final _ClaimSocket socket = _ClaimSocket(<String>[]);
    // A sleep that never ends: only the cancel can wake the pause.
    final Future<String?> result = AgentsCloudRelaySocket.waitForPairingClaim(
      base: base,
      pairingChannel: channel,
      deviceId: 'app-device-1',
      sessionSource: const _Session(),
      deadline: clock.add(const Duration(minutes: 30)),
      cancel: cancel,
      inner: connector(<_ClaimSocket>[socket]),
      now: () => clock,
      sleep: (Duration d) => Completer<void>().future,
    );
    await pumpEventQueue();
    expect(socket.claims, 1);
    cancel.cancel();
    expect(await result, isNull);
    expect(socket.claims, 1, reason: 'no claim after the cancel');
    expect(socket.closed, isTrue);
  });

  test('a final refusal is not retried', () async {
    final _ClaimSocket socket = _ClaimSocket(<String>['invalid']);
    await expectLater(
      wait(<_ClaimSocket>[socket]),
      throwsA(
        isA<AgentsCloudRelayException>().having(
          (AgentsCloudRelayException e) => e.code,
          'code',
          'invalid_pairing_channel',
        ),
      ),
    );
    expect(socket.claims, 1);
  });

  test('a refused sign-in is final', () async {
    final _ClaimSocket socket = _ClaimSocket(<String>[], authOk: false);
    await expectLater(
      wait(<_ClaimSocket>[socket]),
      throwsA(
        isA<AgentsCloudRelayException>().having(
          (AgentsCloudRelayException e) => e.code,
          'code',
          'auth_error',
        ),
      ),
    );
    expect(socket.claims, 0);
  });

  test('no session: final, and nothing is dialled', () async {
    await expectLater(
      wait(<_ClaimSocket>[], session: const _Session(null)),
      throwsA(
        isA<AgentsCloudRelayException>().having(
          (AgentsCloudRelayException e) => e.code,
          'code',
          'no_session',
        ),
      ),
    );
    expect(dials, isEmpty);
  });

  test('no error text carries the channel', () async {
    final _ClaimSocket socket = _ClaimSocket(<String>['invalid']);
    try {
      await wait(<_ClaimSocket>[socket]);
      fail('expected a refusal');
    } on AgentsCloudRelayException catch (error) {
      expect(error.message, isNot(contains(channel)));
      expect(error.toString(), isNot(contains(channel)));
    }
  });

  group('handoff and held frames', () {
    final AgentsCloudRelayAddress pairingAddress = AgentsCloudRelayAddress(
      base: base,
      pairingChannel: channel,
    );

    test('the pairing takes the socket that won the claim: no second dial, '
        'no second claim, and the early commit is delivered', () async {
      final _ClaimSocket socket = _ClaimSocket(<String>[
        'unknown',
        'claimed',
      ], commitOnBind: true);
      final String? device = await wait(<_ClaimSocket>[socket]);
      expect(device, _ClaimSocket.hostDeviceId);
      // The commit has arrived; nobody listens yet.
      await pumpEventQueue();

      final AgentsCloudRelaySocket paired =
          await AgentsCloudRelaySocket.connect(
            address: pairingAddress,
            deviceId: 'app-device-1',
            sessionSource: const _Session(),
            inner: connector(<_ClaimSocket>[socket]),
          );
      expect(dials, hasLength(1), reason: 'no second dial');
      expect(socket.claims, 2, reason: 'no second claim');
      expect(paired.targetDeviceId, _ClaimSocket.hostDeviceId);
      expect(
        AgentsCloudRelaySocket.hasHandoff(base: base, pairingChannel: channel),
        isFalse,
      );

      // The relay client subscribes only now, and still gets the commit.
      final List<dynamic> up = <dynamic>[];
      paired.incoming.listen(up.add);
      await pumpEventQueue();
      expect(up, hasLength(1));
      expect(jsonDecode(up.single as String), _ClaimSocket.commit);

      // Its `join` goes to the host over the same socket.
      paired.send(jsonEncode(<String, dynamic>{'type': 'join'}));
      expect(socket.relayed.single['type'], 'join');
      expect(socket.sent.last['target_device_id'], _ClaimSocket.hostDeviceId);
      await paired.close();
    });

    test('cancel drops and closes the kept socket', () async {
      final AgentsClaimCancel cancel = AgentsClaimCancel();
      final _ClaimSocket socket = _ClaimSocket(<String>['claimed']);
      await wait(<_ClaimSocket>[socket], cancel: cancel);
      expect(
        AgentsCloudRelaySocket.hasHandoff(base: base, pairingChannel: channel),
        isTrue,
      );
      cancel.cancel();
      await pumpEventQueue();
      expect(
        AgentsCloudRelaySocket.hasHandoff(base: base, pairingChannel: channel),
        isFalse,
      );
      expect(socket.closed, isTrue);
    });

    test('an unused kept socket is closed after the timeout; the pairing '
        'then dials again, still without a second claim', () async {
      final _ClaimSocket first = _ClaimSocket(<String>['claimed']);
      await AgentsCloudRelaySocket.waitForPairingClaim(
        base: base,
        pairingChannel: channel,
        deviceId: 'app-device-1',
        sessionSource: const _Session(),
        deadline: clock.add(const Duration(minutes: 30)),
        inner: connector(<_ClaimSocket>[first]),
        now: () => clock,
        sleep: fakeSleep,
        handoffTimeout: const Duration(milliseconds: 10),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(first.closed, isTrue);
      expect(
        AgentsCloudRelaySocket.hasHandoff(base: base, pairingChannel: channel),
        isFalse,
      );

      final _ClaimSocket second = _ClaimSocket(<String>[]);
      final AgentsCloudRelaySocket paired =
          await AgentsCloudRelaySocket.connect(
            address: pairingAddress,
            deviceId: 'app-device-1',
            sessionSource: const _Session(),
            inner: connector(<_ClaimSocket>[first, second]),
          );
      expect(dials, hasLength(2));
      expect(second.claims, 0, reason: 'the claim is remembered');
      expect(paired.targetDeviceId, _ClaimSocket.hostDeviceId);
      await paired.close();
    });

    test('a kept socket that dropped is not handed out', () async {
      final _ClaimSocket first = _ClaimSocket(<String>['claimed']);
      await wait(<_ClaimSocket>[first]);
      await first.close();
      await pumpEventQueue();
      expect(
        AgentsCloudRelaySocket.hasHandoff(base: base, pairingChannel: channel),
        isFalse,
      );
      final _ClaimSocket second = _ClaimSocket(<String>[]);
      final AgentsCloudRelaySocket paired =
          await AgentsCloudRelaySocket.connect(
            address: pairingAddress,
            deviceId: 'app-device-1',
            sessionSource: const _Session(),
            inner: connector(<_ClaimSocket>[first, second]),
          );
      expect(dials, hasLength(2));
      await paired.close();
    });

    test('the scan path: a commit that arrives inside the handshake, before '
        'the client listens, is delivered', () async {
      final _ClaimSocket socket = _ClaimSocket(<String>[
        'claimed',
      ], commitOnBind: true);
      final AgentsCloudRelaySocket paired =
          await AgentsCloudRelaySocket.connect(
            address: pairingAddress,
            deviceId: 'app-device-1',
            sessionSource: const _Session(),
            inner: connector(<_ClaimSocket>[socket]),
          );
      expect(socket.claims, 1);
      await pumpEventQueue();

      final List<dynamic> up = <dynamic>[];
      paired.incoming.listen(up.add);
      await pumpEventQueue();
      expect(up.map((dynamic f) => jsonDecode(f as String)), <dynamic>[
        _ClaimSocket.commit,
      ]);
      // Once a listener exists, frames flow straight through as before.
      await paired.close();
    });
  });
}
