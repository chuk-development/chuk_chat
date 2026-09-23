/// The cloud transport — the same relay client, a different pipe.
///
/// The app has always spoken ONE protocol to the host: a blind relay it joins by
/// channel, over which it runs the §15 pairing ceremony and then the §14 sealed
/// frames. That protocol does not change here. What changes is what carries it.
///
/// Assume there is never a direct connection between phone and host. The only
/// direct connection either side has is to the API server, so every byte goes
/// `app ⇄ api.chuk.chat ⇄ host` (docs/PLAN_2026-09-09_CLOUD_PAIRING_TRANSPORT.md).
/// The relay stays blind: it routes an opaque `payload` it can never read, and
/// the seal, the SAS and the commitment are what make that safe.
///
/// ## Where this sits
///
/// [AgentsRelayClient] talks to a [RelaySocket] and nothing else. This file
/// supplies a second implementation of that seam. Upward it looks exactly like
/// the local blind relay — it accepts and emits the same
/// `{"type":"join"|"pairing"|"frame",…}` envelopes — and downward it speaks the
/// API server's relay contract. Not one line of the ceremony, the seal or the
/// reconnect knows the difference, which is the whole design.
///
/// ## The wire, exactly
///
/// Dial `wss://api.chuk.chat/v2/relay/ws` (base configurable, that default),
/// then:
///
///     1. app -> {"type": "auth", "token": "<supabase jwt>",
///                 "role": "controller", "device_id": "<our uuid4>"}
///        relay -> {"type": "auth_ok"}
///               | {"type": "auth_error", "detail": ...} + close(1008)
///
///     2. app -> {"type": "cowork_pair_claim",
///                "pairing_channel": "<c from the QR>",
///                "req_id": "<uuid4 hex>"}                  # first pairing only
///        relay -> {"type": "executor_status", "device_id", "online": true}
///                 {"type": "cowork_pair_claimed", "device_id", "req_id"}
///               | {"type": "cowork_pair_error", "code", "req_id"}
///
///     3. app -> {"req_id": "<uuid4 hex>", "type": "cowork_relay",
///                "target_device_id": "<host device>",
///                "payload": "<the local-relay envelope, as a JSON string>"}
///        relay -> the same shape back, from the host, with no
///                 target_device_id (an executor addresses nobody).
///
/// Step 2 binds the scanned channel to the signed-in account; it lives in
/// [_claimPairingChannel], which is the one place the claim's shape is written.
///
/// The `payload` is opaque to the relay. It carries the local-relay envelope
/// verbatim — the `join`, the unsealed `pairing` steps of the ceremony, and the
/// sealed `frame`s — because the host feeds it straight back into the party it
/// already runs for the local relay. It is sent as a JSON **string**, which is
/// what the host sends too; a nested object is accepted on receive.
///
/// The `join` is load-bearing and must go first. The relay tells an executor
/// nothing about presence, so the host reads our `join` payload as "a controller
/// attached" and only then publishes its §15 commit. Send anything before it and
/// the ceremony silently never starts. Nothing here reorders sends: whatever the
/// client hands down while the handshake is still running is queued and flushed
/// in order, and `join` is the first thing the client ever sends.
///
/// ## The local path is untouched
///
/// A plain `ws://127.0.0.1:8787` address never reaches this file: the connector
/// hands it to [defaultRelaySocketConnector] as before. Same-machine
/// development keeps working with no flag and no account.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'package:chuk_chat/services/account_session.dart';
import 'package:chuk_chat/services/agents/agents_pairing_uri.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';

/// The endpoint path on the API server.
const String kAgentsRelayPath = '/v2/relay/ws';

/// Query markers that turn a relay base URL into a full dial address.
///
/// The [RelaySocketConnector] seam sees a [Uri] and nothing else, so the two
/// facts a cloud dial needs beyond the URL ride on it: which pairing channel to
/// claim (first pairing) or which host device to address (every time after).
/// They are stripped before the socket is opened, so the server never sees them
/// and they never reach an access log.
const String kAgentsPairChannelParam = 'cw_pair';
const String kAgentsTargetDeviceParam = 'cw_device';

/// A dial address for the cloud relay, expressed as a [Uri] so it fits the
/// existing connector seam and so a stored trust record carries everything a
/// fresh phone needs to reconnect with no further input.
@immutable
class AgentsCloudRelayAddress {
  const AgentsCloudRelayAddress({
    required this.base,
    this.pairingChannel,
    this.targetDeviceId,
  });

  /// The relay base, scheme + host + optional port, no path.
  final Uri base;

  /// The high-entropy pairing channel to claim. Set for a first pairing only.
  /// Key material: never logged.
  final String? pairingChannel;

  /// The host device this controller addresses. Known from the stored trust on
  /// every reconnect; learned from the claim on a first pairing.
  final String? targetDeviceId;

  /// The address for a first pairing, built from a scanned or typed invite.
  factory AgentsCloudRelayAddress.forInvite(AgentsPairingInvite invite) =>
      AgentsCloudRelayAddress(
        base: invite.relayBase,
        pairingChannel: invite.pairingChannel,
      );

  /// The address a paired app dials forever after: the relay, addressed to the
  /// host's device id. This is what belongs in a persisted trust record — it
  /// asks for no code, no channel claim and no user action.
  factory AgentsCloudRelayAddress.forHost({
    required Uri base,
    required String targetDeviceId,
  }) => AgentsCloudRelayAddress(base: base, targetDeviceId: targetDeviceId);

  /// The URL the client is handed. Markers included; see the constants above.
  Uri toUri() => base.replace(
    path: kAgentsRelayPath,
    queryParameters: <String, String>{
      if (pairingChannel != null && pairingChannel!.isNotEmpty)
        kAgentsPairChannelParam: pairingChannel!,
      if (targetDeviceId != null && targetDeviceId!.isNotEmpty)
        kAgentsTargetDeviceParam: targetDeviceId!,
    },
  );

  /// The URL actually opened: the markers removed, so nothing private and
  /// nothing meaningless to the server rides in the request line.
  Uri get dialUri => base.replace(path: kAgentsRelayPath);

  /// Reads an address back out of a URL, or null when [url] is not one of ours
  /// (a plain `ws://` host, a bare https link). A `wss://` URL on the relay path
  /// counts even with no markers — the caller then supplies the target itself.
  static AgentsCloudRelayAddress? tryParse(Uri url) {
    final scheme = url.scheme.toLowerCase();
    if (scheme != 'ws' && scheme != 'wss') return null;
    if (url.path != kAgentsRelayPath) return null;
    final channel = url.queryParameters[kAgentsPairChannelParam]?.trim();
    final device = url.queryParameters[kAgentsTargetDeviceParam]?.trim();
    return AgentsCloudRelayAddress(
      base: Uri(
        scheme: scheme,
        host: url.host,
        port: url.hasPort ? url.port : null,
      ),
      pairingChannel: (channel == null || channel.isEmpty) ? null : channel,
      targetDeviceId: (device == null || device.isEmpty) ? null : device,
    );
  }

  /// The address a restored trust record should be dialled at.
  ///
  /// A record mirrored to Supabase is pulled back by a device that is, by
  /// definition, not the one that wrote it — a new phone, or a reinstall. A
  /// loopback or LAN address in it is therefore an address for somebody else's
  /// machine, and dialling it is the exact bug the phone had: it faithfully
  /// carried `ws://127.0.0.1:8787` and saw no coworker. Identity, not address —
  /// so the host device id is kept and the pipe becomes the relay.
  ///
  /// An address that already names the relay is returned untouched, whatever
  /// relay it names, so a self-hosted backend survives a reinstall.
  static Uri forRestoredTrust(
    Uri stored,
    String peerDeviceId, {
    Uri? fallbackBase,
  }) {
    final existing = tryParse(stored);
    if (existing != null && existing.targetDeviceId != null) return stored;
    final base =
        existing?.base ?? fallbackBase ?? Uri.parse(kDefaultAgentsRelayBase);
    return AgentsCloudRelayAddress.forHost(
      base: base,
      targetDeviceId: peerDeviceId,
    ).toUri();
  }

  @override
  bool operator ==(Object other) =>
      other is AgentsCloudRelayAddress &&
      other.base == base &&
      other.pairingChannel == pairingChannel &&
      other.targetDeviceId == targetDeviceId;

  @override
  int get hashCode => Object.hash(base, pairingChannel, targetDeviceId);

  /// The channel is key material, so it is not in here.
  @override
  String toString() =>
      'AgentsCloudRelayAddress($base, target: $targetDeviceId, '
      'pairing: ${pairingChannel == null ? 'no' : 'yes'})';
}

/// Raised when the relay refuses the handshake or the pairing claim. The
/// message is written for a person, because it is what the pairing screen shows.
class AgentsCloudRelayException implements Exception {
  const AgentsCloudRelayException(this.message, {this.code});

  final String message;

  /// The server's machine-readable code, when it sent one. Never shown.
  final String? code;

  @override
  String toString() => message;
}

/// Builds the app's production connector: cloud for `…/v2/relay/ws`, the plain
/// local socket for everything else.
///
/// [sessionSource] supplies the Supabase access token the relay authenticates
/// with. [inner] opens the underlying WebSocket and defaults to
/// [defaultRelaySocketConnector], which already pins `wss://` to our own
/// certificate (lib/utils/certificate_pinning.dart) and leaves `ws://` plain.
RelaySocketConnector agentsCloudRelayConnector({
  required String deviceId,
  required AccountSessionSource sessionSource,
  RelaySocketConnector inner = defaultRelaySocketConnector,
  Duration handshakeTimeout = const Duration(seconds: 20),
}) {
  return (Uri url) async {
    final address = AgentsCloudRelayAddress.tryParse(url);
    if (address == null) return inner(url);
    return AgentsCloudRelaySocket.connect(
      address: address,
      deviceId: deviceId,
      sessionSource: sessionSource,
      inner: inner,
      handshakeTimeout: handshakeTimeout,
    );
  };
}

/// A [RelaySocket] that speaks the cloud relay downward and the local blind
/// relay upward.
class AgentsCloudRelaySocket implements RelaySocket {
  AgentsCloudRelaySocket._({
    required RelaySocket transport,
    required String deviceId,
    required this.address,
  }) : _transport = transport,
       _deviceId = deviceId;

  /// Host device ids learned by claiming a pairing channel, keyed by
  /// `<relay base>|<pairing channel>`.
  ///
  /// A claim is for the moment of pairing. Anything that re-dials the same
  /// pairing address afterwards — the token scheduler's re-attach, a dropped
  /// socket before the trust record has been rewritten — must not claim a
  /// second time, so the target it learned is remembered for the life of the
  /// process. The persisted trust record holds the reconnect form of the
  /// address, so a later launch never comes back through here at all.
  static final Map<String, String> _claimedTargets = <String, String>{};

  /// Clears the learned targets. Tests only.
  @visibleForTesting
  static void resetClaimCache() => _claimedTargets.clear();

  /// The host device id a claim on [pairingChannel] returned, or null when this
  /// process has not claimed it. The claim is the only source of that id, so
  /// this is what a caller persists in the trust record after a first pairing.
  static String? learnedTarget({
    required Uri base,
    required String pairingChannel,
  }) => _claimedTargets['$base|$pairingChannel'];

  static const Uuid _uuid = Uuid();

  final RelaySocket _transport;
  final String _deviceId;
  final AgentsCloudRelayAddress address;

  final StreamController<dynamic> _upward =
      StreamController<dynamic>.broadcast();
  StreamSubscription<dynamic>? _sub;

  /// Where relayed payloads are addressed. Set before the first send.
  String? _targetDeviceId;

  /// Envelopes the client handed us before the handshake finished. The client
  /// sends `join` the instant it has a socket, so this is the ordinary path,
  /// not an edge case.
  final List<String> _pending = <String>[];
  bool _ready = false;
  bool _closed = false;

  /// One-shot waiters for a handshake / claim answer.
  Completer<Map<String, dynamic>>? _awaiting;
  bool Function(Map<String, dynamic> frame)? _awaitingMatch;

  /// Opens the socket, authenticates, claims the pairing channel when the
  /// address carries one, and hands back a ready transport.
  static Future<AgentsCloudRelaySocket> connect({
    required AgentsCloudRelayAddress address,
    required String deviceId,
    required AccountSessionSource sessionSource,
    RelaySocketConnector inner = defaultRelaySocketConnector,
    Duration handshakeTimeout = const Duration(seconds: 20),
  }) async {
    final session = await _resolveSession(sessionSource);
    final transport = await inner(address.dialUri);
    final socket = AgentsCloudRelaySocket._(
      transport: transport,
      deviceId: deviceId,
      address: address,
    );
    try {
      await socket._handshake(session, handshakeTimeout);
    } catch (_) {
      await socket.close();
      rethrow;
    }
    return socket;
  }

  static Future<AccountSession> _resolveSession(
    AccountSessionSource source,
  ) async {
    AccountSession? session;
    try {
      session = await source.refresh();
    } catch (_) {
      session = null;
    }
    session ??= source.current();
    if (session == null || session.accessToken.isEmpty) {
      throw const AgentsCloudRelayException(
        'Sign in first, then this device can reach your computer.',
        code: 'no_session',
      );
    }
    return session;
  }

  Future<void> _handshake(AccountSession session, Duration timeout) async {
    _sub = _transport.incoming.listen(
      _onTransportFrame,
      onError: _onTransportError,
      onDone: _onTransportDone,
      cancelOnError: false,
    );

    final auth = _expect(
      (frame) => frame['type'] == 'auth_ok' || frame['type'] == 'auth_error',
      timeout,
    );
    _transport.send(
      jsonEncode(<String, dynamic>{
        'type': 'auth',
        'token': session.accessToken,
        'role': 'controller',
        'device_id': _deviceId,
      }),
    );
    final authFrame = await auth;
    if (authFrame['type'] != 'auth_ok') {
      throw AgentsCloudRelayException(
        _authErrorText('${authFrame['detail'] ?? ''}'),
        code: 'auth_error',
      );
    }

    final channel = address.pairingChannel;
    if (channel != null && channel.isNotEmpty) {
      final cacheKey = '${address.base}|$channel';
      final known = _claimedTargets[cacheKey];
      _targetDeviceId =
          known ?? await _claimPairingChannel(channel, timeout: timeout);
      final learned = _targetDeviceId;
      if (learned != null) _claimedTargets[cacheKey] = learned;
    } else {
      _targetDeviceId = address.targetDeviceId;
    }
    if (_targetDeviceId == null || _targetDeviceId!.isEmpty) {
      throw const AgentsCloudRelayException(
        'Your computer is not reachable right now. Make sure Agents is '
        'running on it, then try again.',
        code: 'no_target',
      );
    }

    _ready = true;
    for (final queued in _pending) {
      _forward(queued);
    }
    _pending.clear();
  }

  // --- THE CLAIM ------------------------------------------------------------
  // Binding the scanned pairing channel to the signed-in account, and the only
  // place the claim's shape lives.
  //
  //     app   -> {"type": "cowork_pair_claim",
  //               "pairing_channel": "<c from the QR>", "req_id": "<hex>"}
  //     relay -> {"type": "executor_status", "device_id", "online": true}
  //              {"type": "cowork_pair_claimed", "device_id", "req_id"}
  //            | {"type": "cowork_pair_error", "code", "req_id"}
  //
  // `cowork_pair_claimed` carries the host's `device_id`, and that is the ONLY
  // place this app ever learns it. Every later frame is addressed to it, and it
  // is what the trust record remembers, so a reconnect needs no claim at all.
  //
  // The `executor_status` that arrives first is not the answer — it is a
  // presence delta that happens to name the same device. Waiting for the
  // claimed/error pair keeps "the relay agreed" and "an executor showed up"
  // distinct, which matters when the claim is refused after all.
  //
  // An unclaimed channel expires after five minutes, and the refusal for an
  // expired one, an unknown one and one another account holds is deliberately
  // the same code. So the user gets one plain sentence and one instruction:
  // ask the computer for a fresh code. Re-claiming from the same account is
  // idempotent, so a retry after a dropped socket is safe.
  Future<String?> _claimPairingChannel(
    String channel, {
    required Duration timeout,
  }) async {
    final reqId = _uuid.v4().replaceAll('-', '');
    final answer = _expect((frame) {
      final type = '${frame['type']}';
      return type == 'cowork_pair_claimed' ||
          type == 'cowork_pair_error' ||
          type == 'cowork_error' ||
          type == 'error';
    }, timeout);
    _transport.send(
      jsonEncode(<String, dynamic>{
        'type': 'cowork_pair_claim',
        'pairing_channel': channel,
        'req_id': reqId,
      }),
    );

    final Map<String, dynamic> frame;
    try {
      frame = await answer;
    } on TimeoutException {
      throw const AgentsCloudRelayException(
        _staleCodeText,
        code: 'claim_timeout',
      );
    }
    if ('${frame['type']}' != 'cowork_pair_claimed') {
      throw AgentsCloudRelayException(
        _staleCodeText,
        code: '${frame['code'] ?? frame['type']}',
      );
    }
    return _deviceIdFrom(frame);
  }

  /// The one sentence every claim refusal gets. The server refuses an expired
  /// channel, an unknown one and one another account holds with the same code
  /// on purpose, so there is nothing more specific to say — and the recovery is
  /// the same in all three cases.
  static const String _staleCodeText =
      'That code is not valid any more. Ask your computer for a new one.';

  static String? _deviceIdFrom(Map<String, dynamic> frame) {
    for (final key in const <String>[
      'device_id',
      'executor_device_id',
      'target_device_id',
    ]) {
      final value = frame[key];
      if (value is String && value.isNotEmpty) return value;
    }
    final executor = frame['executor'];
    if (executor is Map) {
      final value = executor['device_id'];
      if (value is String && value.isNotEmpty) return value;
    }
    return null;
  }

  /// The host device this socket ended up addressing. Read after a successful
  /// pairing to build the reconnect-form address for the trust record.
  String? get targetDeviceId => _targetDeviceId;

  // --- the RelaySocket seam --------------------------------------------------

  @override
  Stream<dynamic> get incoming => _upward.stream;

  @override
  void send(String data) {
    if (_closed) return;
    if (!_ready) {
      _pending.add(data);
      return;
    }
    _forward(data);
  }

  void _forward(String data) {
    final target = _targetDeviceId;
    if (target == null || target.isEmpty) return;
    // The payload is the local-relay envelope, VERBATIM and as a JSON *string*
    // — exactly the text the loopback relay would have carried. The host
    // tolerates an object on receive but sends the string form, so this sends
    // the string form too and the two halves stay symmetric.
    _transport.send(
      jsonEncode(<String, dynamic>{
        'req_id': _uuid.v4().replaceAll('-', ''),
        'type': 'cowork_relay',
        'target_device_id': target,
        'payload': data,
      }),
    );
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _ready = false;
    _pending.clear();
    await _sub?.cancel();
    _sub = null;
    await _transport.close();
    if (!_upward.isClosed) await _upward.close();
  }

  // --- inbound ---------------------------------------------------------------

  void _onTransportFrame(dynamic raw) {
    final Map<String, dynamic> frame;
    try {
      final decoded = jsonDecode(
        raw is String ? raw : utf8.decode(raw as List<int>),
      );
      if (decoded is! Map<String, dynamic>) return;
      frame = decoded;
    } catch (_) {
      return; // A malformed relay frame is dropped, never fatal.
    }

    final waiting = _awaiting;
    final match = _awaitingMatch;
    if (waiting != null && match != null && match(frame)) {
      _awaiting = null;
      _awaitingMatch = null;
      if (!waiting.isCompleted) waiting.complete(frame);
      return;
    }

    switch (frame['type']) {
      case 'cowork_relay':
        final payload = frame['payload'];
        if (payload == null) return;
        // Upward it must look exactly like the local relay: one JSON text
        // frame carrying the envelope.
        final text = payload is String ? payload : jsonEncode(payload);
        if (!_upward.isClosed) _upward.add(text);
      case 'cowork_error':
        // Routing failed (the host went offline mid-run, a bad target). There
        // is nothing to render and nothing the ceremony can do with it; the
        // client's own timeout and the reconnect watchdog are what recover.
        if (kDebugMode) {
          debugPrint('[agents-cloud] relay error: ${frame['code']}');
        }
        if (frame['code'] == 'executor_offline' &&
            frame['target_device_id'] == _targetDeviceId) {
          unawaited(close());
        }
      case 'ping':
        // A control frame, answered on the socket and never passed upward.
        _transport.send(jsonEncode(<String, dynamic>{'type': 'pong'}));
      case 'executor_status':
        // The API socket may still be healthy while the host restarted. The
        // old traffic keys are no longer usable: tell the reconnect supervisor
        // this connection is down instead of leaving a green but dead client.
        if (_ready &&
            frame['device_id'] == _targetDeviceId &&
            frame['online'] == false) {
          unawaited(close());
        }
      case 'cowork_presence':
      case 'pong':
        break;
      default:
        break;
    }
  }

  void _onTransportError(Object error, StackTrace _) {
    final waiting = _awaiting;
    _awaiting = null;
    _awaitingMatch = null;
    if (waiting != null && !waiting.isCompleted) waiting.completeError(error);
    if (!_upward.isClosed) _upward.addError(error);
  }

  void _onTransportDone() {
    final waiting = _awaiting;
    _awaiting = null;
    _awaitingMatch = null;
    if (waiting != null && !waiting.isCompleted) {
      waiting.completeError(
        const AgentsCloudRelayException(
          'The connection closed before your computer answered.',
          code: 'closed',
        ),
      );
    }
    _ready = false;
    if (!_upward.isClosed) unawaited(_upward.close());
  }

  Future<Map<String, dynamic>> _expect(
    bool Function(Map<String, dynamic> frame) match,
    Duration timeout,
  ) {
    final completer = Completer<Map<String, dynamic>>();
    _awaiting = completer;
    _awaitingMatch = match;
    return completer.future.timeout(timeout);
  }

  /// Turns the relay's reason into one plain sentence. The detail strings are
  /// fixed server-side constants, never user content.
  static String _authErrorText(String detail) {
    final lower = detail.toLowerCase();
    if (lower.contains('token') || lower.contains('expired')) {
      return 'Your sign-in expired. Sign in again and this device reconnects '
          'on its own.';
    }
    if (lower.contains('not enabled')) {
      return 'This account cannot use Agents yet.';
    }
    return 'Could not sign this device in. Check your connection and try '
        'again.';
  }
}
