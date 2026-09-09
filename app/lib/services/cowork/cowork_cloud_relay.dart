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
/// [CoworkRelayClient] talks to a [RelaySocket] and nothing else. This file
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
///                "pairing_channel": "<c from the QR>"}     # first pairing only
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

import 'package:cowork/services/account_session.dart';
import 'package:cowork/services/cowork/cowork_pairing_uri.dart';
import 'package:cowork/services/cowork/cowork_relay_client.dart';

/// The endpoint path on the API server.
const String kCoworkRelayPath = '/v2/relay/ws';

/// Query markers that turn a relay base URL into a full dial address.
///
/// The [RelaySocketConnector] seam sees a [Uri] and nothing else, so the two
/// facts a cloud dial needs beyond the URL ride on it: which pairing channel to
/// claim (first pairing) or which host device to address (every time after).
/// They are stripped before the socket is opened, so the server never sees them
/// and they never reach an access log.
const String kCoworkPairChannelParam = 'cw_pair';
const String kCoworkTargetDeviceParam = 'cw_device';

/// A dial address for the cloud relay, expressed as a [Uri] so it fits the
/// existing connector seam and so a stored trust record carries everything a
/// fresh phone needs to reconnect with no further input.
@immutable
class CoworkCloudRelayAddress {
  const CoworkCloudRelayAddress({
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
  factory CoworkCloudRelayAddress.forInvite(CoworkPairingInvite invite) =>
      CoworkCloudRelayAddress(
        base: invite.relayBase,
        pairingChannel: invite.pairingChannel,
      );

  /// The address a paired app dials forever after: the relay, addressed to the
  /// host's device id. This is what belongs in a persisted trust record — it
  /// asks for no code, no channel claim and no user action.
  factory CoworkCloudRelayAddress.forHost({
    required Uri base,
    required String targetDeviceId,
  }) => CoworkCloudRelayAddress(base: base, targetDeviceId: targetDeviceId);

  /// The URL the client is handed. Markers included; see the constants above.
  Uri toUri() => base.replace(
    path: kCoworkRelayPath,
    queryParameters: <String, String>{
      if (pairingChannel != null && pairingChannel!.isNotEmpty)
        kCoworkPairChannelParam: pairingChannel!,
      if (targetDeviceId != null && targetDeviceId!.isNotEmpty)
        kCoworkTargetDeviceParam: targetDeviceId!,
    },
  );

  /// The URL actually opened: the markers removed, so nothing private and
  /// nothing meaningless to the server rides in the request line.
  Uri get dialUri => base.replace(path: kCoworkRelayPath);

  /// Reads an address back out of a URL, or null when [url] is not one of ours
  /// (a plain `ws://` host, a bare https link). A `wss://` URL on the relay path
  /// counts even with no markers — the caller then supplies the target itself.
  static CoworkCloudRelayAddress? tryParse(Uri url) {
    final scheme = url.scheme.toLowerCase();
    if (scheme != 'ws' && scheme != 'wss') return null;
    if (url.path != kCoworkRelayPath) return null;
    final channel = url.queryParameters[kCoworkPairChannelParam]?.trim();
    final device = url.queryParameters[kCoworkTargetDeviceParam]?.trim();
    return CoworkCloudRelayAddress(
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
        existing?.base ?? fallbackBase ?? Uri.parse(kDefaultCoworkRelayBase);
    return CoworkCloudRelayAddress.forHost(
      base: base,
      targetDeviceId: peerDeviceId,
    ).toUri();
  }

  @override
  bool operator ==(Object other) =>
      other is CoworkCloudRelayAddress &&
      other.base == base &&
      other.pairingChannel == pairingChannel &&
      other.targetDeviceId == targetDeviceId;

  @override
  int get hashCode => Object.hash(base, pairingChannel, targetDeviceId);

  /// The channel is key material, so it is not in here.
  @override
  String toString() =>
      'CoworkCloudRelayAddress($base, target: $targetDeviceId, '
      'pairing: ${pairingChannel == null ? 'no' : 'yes'})';
}

/// Raised when the relay refuses the handshake or the pairing claim. The
/// message is written for a person, because it is what the pairing screen shows.
class CoworkCloudRelayException implements Exception {
  const CoworkCloudRelayException(this.message, {this.code});

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
RelaySocketConnector coworkCloudRelayConnector({
  required String deviceId,
  required AccountSessionSource sessionSource,
  RelaySocketConnector inner = defaultRelaySocketConnector,
  Duration handshakeTimeout = const Duration(seconds: 20),
}) {
  return (Uri url) async {
    final address = CoworkCloudRelayAddress.tryParse(url);
    if (address == null) return inner(url);
    return CoworkCloudRelaySocket.connect(
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
class CoworkCloudRelaySocket implements RelaySocket {
  CoworkCloudRelaySocket._({
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

  static const Uuid _uuid = Uuid();

  final RelaySocket _transport;
  final String _deviceId;
  final CoworkCloudRelayAddress address;

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
  static Future<CoworkCloudRelaySocket> connect({
    required CoworkCloudRelayAddress address,
    required String deviceId,
    required AccountSessionSource sessionSource,
    RelaySocketConnector inner = defaultRelaySocketConnector,
    Duration handshakeTimeout = const Duration(seconds: 20),
  }) async {
    final session = await _resolveSession(sessionSource);
    final transport = await inner(address.dialUri);
    final socket = CoworkCloudRelaySocket._(
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
      throw const CoworkCloudRelayException(
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
      throw CoworkCloudRelayException(
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
      throw const CoworkCloudRelayException(
        'Your computer is not reachable right now. Make sure CoWork is '
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
  // Everything the app assumes about binding a pairing channel to the account
  // lives in this one method, on purpose: the backend half is being built in
  // parallel, so this is the single place to adjust if a field name or a reply
  // type turns out different.
  //
  // We send:
  //     {"type": "cowork_pair_claim", "pairing_channel": "<c from the QR>"}
  //
  // We accept as success any reply whose type starts with `cowork_pair_claim`
  // and is not an error, and we read the host's device id out of it under any
  // of `device_id` / `executor_device_id` / `target_device_id`, at the top
  // level or one level down under `executor`. Failing that, an
  // `executor_status` naming an online device answers the same question, which
  // is what the relay already broadcasts when an executor appears.
  //
  // We treat as failure: `cowork_error`, `error`, and any `…_error` /
  // `…_denied` claim reply. The user sees one plain sentence, never a code.
  Future<String?> _claimPairingChannel(
    String channel, {
    required Duration timeout,
  }) async {
    final answer = _expect((frame) {
      final type = '${frame['type']}';
      if (type.startsWith('cowork_pair_claim')) return true;
      if (type == 'cowork_error' || type == 'error') return true;
      if (type == 'executor_status' && frame['online'] == true) return true;
      return false;
    }, timeout);
    _transport.send(
      jsonEncode(<String, dynamic>{
        'type': 'cowork_pair_claim',
        'pairing_channel': channel,
      }),
    );

    final Map<String, dynamic> frame;
    try {
      frame = await answer;
    } on TimeoutException {
      throw const CoworkCloudRelayException(
        'That code did not work. Ask your computer for a new one and scan '
        'again.',
        code: 'claim_timeout',
      );
    }
    final type = '${frame['type']}';
    if (type == 'cowork_error' ||
        type == 'error' ||
        type.endsWith('_error') ||
        type.endsWith('_denied')) {
      throw CoworkCloudRelayException(
        'That code did not work. Ask your computer for a new one and scan '
        'again.',
        code: '${frame['code'] ?? type}',
      );
    }
    return _deviceIdFrom(frame);
  }

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
          debugPrint('[cowork-cloud] relay error: ${frame['code']}');
        }
      case 'ping':
        // A control frame, answered on the socket and never passed upward.
        _transport.send(jsonEncode(<String, dynamic>{'type': 'pong'}));
      case 'executor_status':
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
        const CoworkCloudRelayException(
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
      return 'This account cannot use CoWork yet.';
    }
    return 'Could not sign this device in. Check your connection and try '
        'again.';
  }
}
