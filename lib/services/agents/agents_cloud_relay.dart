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
/// [_sendClaim], which is the one place the claim's shape is written. The
/// install flow, where the app mints the channel before the host exists,
/// repeats step 2 until the host has parked
/// ([AgentsCloudRelaySocket.waitForPairingClaim]).
///
/// The same claim heals a paired host whose account session died. Such a host
/// cannot open the relay with a token any more, so it parks on a *heal
/// channel* derived from the pairing's channel key (agents_heal_channel.dart).
/// When a reconnect finds its host offline, it claims that channel once. On
/// success the host is an ordinary executor of this account again and the
/// sealed session re-provisions it; on a refusal nothing changes.
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
import 'package:web_socket_channel/web_socket_channel.dart'
    show WebSocketChannelException;

import 'package:chuk_chat/services/account_session.dart';
import 'package:chuk_chat/services/agents/agents_pairing_uri.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/utils/io_helper.dart' show IOException;

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

/// The heal channel of a stored pairing, added to a reconnect address only for
/// the dial (never persisted). Key-derived material: never logged.
const String kAgentsHealChannelParam = 'cw_heal';

/// A dial address for the cloud relay, expressed as a [Uri] so it fits the
/// existing connector seam and so a stored trust record carries everything a
/// fresh phone needs to reconnect with no further input.
@immutable
class AgentsCloudRelayAddress {
  const AgentsCloudRelayAddress({
    required this.base,
    this.pairingChannel,
    this.targetDeviceId,
    this.healChannel,
  });

  /// The relay base, scheme + host + optional port, no path.
  final Uri base;

  /// The high-entropy pairing channel to claim. Set for a first pairing only.
  /// Key material: never logged.
  final String? pairingChannel;

  /// The host device this controller addresses. Known from the stored trust on
  /// every reconnect; learned from the claim on a first pairing.
  final String? targetDeviceId;

  /// The heal channel to claim when [targetDeviceId] is offline. Set on a
  /// reconnect only. Key-derived material: never logged, never persisted.
  final String? healChannel;

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
      if (healChannel != null && healChannel!.isNotEmpty)
        kAgentsHealChannelParam: healChannel!,
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
    final heal = url.queryParameters[kAgentsHealChannelParam]?.trim();
    return AgentsCloudRelayAddress(
      base: Uri(
        scheme: scheme,
        host: url.host,
        port: url.hasPort ? url.port : null,
      ),
      pairingChannel: (channel == null || channel.isEmpty) ? null : channel,
      targetDeviceId: (device == null || device.isEmpty) ? null : device,
      healChannel: (heal == null || heal.isEmpty) ? null : heal,
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
      other.targetDeviceId == targetDeviceId &&
      other.healChannel == healChannel;

  @override
  int get hashCode =>
      Object.hash(base, pairingChannel, targetDeviceId, healChannel);

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

/// Stops a waiting claim ([AgentsCloudRelaySocket.waitForPairingClaim]): the
/// install page closed, or the user asked for a new command.
class AgentsClaimCancel {
  final Completer<void> _cancelled = Completer<void>();

  bool get isCancelled => _cancelled.isCompleted;

  /// Completes on [cancel]. Never fails.
  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
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
  static void resetClaimCache() {
    _claimedTargets.clear();
    for (final String key in List<String>.of(_handoffs.keys)) {
      _dropHandoff(key);
    }
  }

  /// Sockets that won a waiting claim and wait for the pairing to take them,
  /// keyed like [_claimedTargets]. At most one per key.
  static final Map<String, AgentsCloudRelaySocket> _handoffs =
      <String, AgentsCloudRelaySocket>{};
  static final Map<String, Timer> _handoffTimers = <String, Timer>{};

  /// How long a won claim's socket waits for the pairing before it is closed.
  static const Duration kClaimHandoffTimeout = Duration(seconds: 60);

  /// Whether a won claim's socket waits for the pairing. Tests only.
  @visibleForTesting
  static bool hasHandoff({required Uri base, required String pairingChannel}) =>
      _handoffs.containsKey('$base|$pairingChannel');

  /// Keeps [socket] for the pairing of [key]. It is closed and dropped when
  /// [cancel] fires (the page closed, a new command), when [timeout] passes
  /// unused, or when the connection goes away on its own.
  static void _parkHandoff(
    String key,
    AgentsCloudRelaySocket socket,
    AgentsClaimCancel cancel,
    Duration timeout,
  ) {
    _dropHandoff(key);
    _handoffs[key] = socket;
    _handoffTimers[key] = Timer(timeout, () => _dropHandoff(key, socket));
    unawaited(cancel.whenCancelled.then((_) => _dropHandoff(key, socket)));
    unawaited(socket._transportGone.future.then((_) {
      if (identical(_handoffs[key], socket)) {
        _handoffs.remove(key);
        _handoffTimers.remove(key)?.cancel();
      }
    }));
  }

  /// Closes and forgets the parked socket of [key]. With [only], only when
  /// that socket is still the one parked there: a socket the pairing has
  /// taken belongs to the pairing and is never closed from here.
  static void _dropHandoff(String key, [AgentsCloudRelaySocket? only]) {
    final AgentsCloudRelaySocket? parked = _handoffs[key];
    if (parked == null || (only != null && !identical(parked, only))) return;
    _handoffs.remove(key);
    _handoffTimers.remove(key)?.cancel();
    unawaited(parked.close());
  }

  /// Takes the parked socket of [key], or null when there is none or it is
  /// gone.
  static AgentsCloudRelaySocket? _takeHandoff(String key) {
    final AgentsCloudRelaySocket? parked = _handoffs.remove(key);
    _handoffTimers.remove(key)?.cancel();
    if (parked == null) return null;
    if (parked._closed || parked._transportGone.isCompleted) return null;
    return parked;
  }

  /// Records a claim as if the relay had answered it. Tests only.
  @visibleForTesting
  static void debugRememberClaim({
    required Uri base,
    required String pairingChannel,
    required String deviceId,
  }) => _claimedTargets['$base|$pairingChannel'] = deviceId;

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

  /// What the relay client reads. Frames that arrive while nobody listens
  /// yet are held in [_upBuffer] and handed to the first listener, in order.
  /// That is the ordinary case at pairing: the host publishes its §15 commit
  /// the moment the claim binds it, which is before the client has had the
  /// socket back and subscribed. A broadcast stream would drop that frame,
  /// and the ceremony would then wait for a commit that never comes again.
  late final StreamController<dynamic> _upward =
      StreamController<dynamic>.broadcast(onListen: _flushUp);
  final List<dynamic> _upBuffer = <dynamic>[];

  /// The transport ended while frames were still held for the first
  /// listener: the stream closes right after they are handed over.
  bool _closeUpAfterFlush = false;

  /// How many frames are held for a listener at most. A pairing needs one or
  /// two; this only bounds a socket that nobody ever reads.
  static const int _upBufferLimit = 256;

  StreamSubscription<dynamic>? _sub;

  /// Where relayed payloads are addressed. Set before the first send.
  String? _targetDeviceId;

  /// Envelopes the client handed us before the handshake finished. The client
  /// sends `join` the instant it has a socket, so this is the ordinary path,
  /// not an edge case.
  final List<String> _pending = <String>[];
  bool _ready = false;
  bool _closed = false;

  /// Completes when the transport is gone (done, failed or closed). The
  /// waiting claim races its pause against it, so a dropped socket is dialled
  /// again at once instead of after the next claim times out.
  final Completer<void> _transportGone = Completer<void>();

  void _markGone() {
    if (!_transportGone.isCompleted) _transportGone.complete();
  }

  /// The first presence snapshot the relay sends after `auth_ok`: the device
  /// ids of this account's executors that are online. It is sent
  /// unconditionally, so a reconnect can tell "host offline" from "not yet
  /// known" without a second round trip.
  final Completer<Set<String>> _presence = Completer<Set<String>>();

  /// How long a reconnect waits for that snapshot before it claims the heal
  /// channel anyway. The relay sends it right behind `auth_ok`.
  static const Duration _presenceWait = Duration(seconds: 3);

  /// How long a heal claim may take before the reconnect goes on without it.
  static const Duration _healClaimTimeout = Duration(seconds: 5);

  /// True while a reconnect is renewing a parked host through its heal
  /// channel. The shell shows a short neutral status for it; it says nothing
  /// about which host or channel.
  static ValueListenable<bool> get healInProgress => _healInProgress;
  static final ValueNotifier<bool> _healInProgress = ValueNotifier<bool>(false);

  /// Lets a widget test show the heal status without a relay.
  @visibleForTesting
  static set debugHealInProgress(bool value) => _healInProgress.value = value;

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
    final channel = address.pairingChannel;
    if (channel != null && channel.isNotEmpty) {
      // The install flow's waiting claim already holds a signed-in socket
      // that won this claim, and the host has already sent its §15 commit
      // down it. Pairing must go on over THAT socket: the host opens one
      // session per claim and ignores a second `join`.
      final handed = _takeHandoff('${address.base}|$channel');
      if (handed != null) return handed;
    }
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

  /// Listens on the transport and signs in as this account's controller.
  /// Throws [AgentsCloudRelayException] on a refusal.
  Future<void> _authenticate(AccountSession session, Duration timeout) async {
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
  }

  Future<void> _handshake(AccountSession session, Duration timeout) async {
    await _authenticate(session, timeout);

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
      final heal = address.healChannel;
      if (heal != null && heal.isNotEmpty && _targetDeviceId != null) {
        await _healIfOffline(heal);
      }
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
    final Map<String, dynamic> frame;
    try {
      frame = await _sendClaim(channel, timeout: timeout);
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

  /// Sends one claim for [channel] and hands back the relay's answer frame,
  /// whatever it says. The only place the claim frame is written. Throws
  /// [TimeoutException] when nothing answers within [timeout].
  Future<Map<String, dynamic>> _sendClaim(
    String channel, {
    required Duration timeout,
  }) {
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
    return answer;
  }

  // --- THE WAITING CLAIM ----------------------------------------------------
  // The install flow. The app mints the pairing channel itself and shows the
  // user a command; the host parks on that channel only when the command has
  // run, which can be many minutes later. Until then every claim is answered
  // `pairing_channel_unknown`. So this claims again on the same socket every
  // [retryEvery] until the relay answers `cowork_pair_claimed`, the deadline
  // passes, or the caller cancels.
  //
  // A socket that drops while it waits is dialled again with backoff, and the
  // wait goes on. Claims on an authenticated controller socket are not rate
  // limited by the relay, and a claim from the same account is idempotent.
  //
  // The learned host device id goes into the same claim cache the one-shot
  // claim fills. The pairing that follows dials the same pairing address and
  // finds it there, so it never claims a second time.

  /// Pair error codes that mean "try again later", not "this cannot work".
  static const Set<String> _claimRetryCodes = <String>{
    'pairing_channel_unknown',
    'claim_failed',
  };

  /// Waits until the host has parked on [pairingChannel], claims it for the
  /// signed-in account, and returns the host's device id.
  ///
  /// Returns null when [cancel] fires first. Throws
  /// [AgentsCloudRelayException] with code `claim_expired` at [deadline], and
  /// for a refusal that no retry can change (no session, a refused sign-in, a
  /// malformed channel). The channel is key material: it is never logged and
  /// never part of an error.
  static Future<String?> waitForPairingClaim({
    required Uri base,
    required String pairingChannel,
    required String deviceId,
    required AccountSessionSource sessionSource,
    required DateTime deadline,
    AgentsClaimCancel? cancel,
    RelaySocketConnector inner = defaultRelaySocketConnector,
    Duration retryEvery = const Duration(seconds: 3),
    Duration handshakeTimeout = const Duration(seconds: 20),
    List<Duration> reconnectBackoff = kClaimReconnectBackoff,
    DateTime Function()? now,
    Future<void> Function(Duration delay)? sleep,
    Duration handoffTimeout = kClaimHandoffTimeout,
  }) async {
    final AgentsClaimCancel token = cancel ?? AgentsClaimCancel();
    final DateTime Function() clock = now ?? DateTime.now;
    final Future<void> Function(Duration) wait =
        sleep ?? (Duration d) => Future<void>.delayed(d);
    final String cacheKey = '$base|$pairingChannel';
    final address = AgentsCloudRelayAddress(
      base: base,
      pairingChannel: pairingChannel,
    );

    /// Waits [delay], but never past the deadline, and wakes early on a
    /// cancel or on [gone].
    Future<void> pause(Duration delay, [Future<void>? gone]) async {
      final Duration left = deadline.difference(clock());
      final Duration step = left < delay ? left : delay;
      if (step <= Duration.zero) return;
      await Future.any(<Future<void>>[wait(step), token.whenCancelled, ?gone]);
    }

    bool over() => !clock().isBefore(deadline);

    var failures = 0;
    while (true) {
      if (token.isCancelled) return null;
      if (over()) throw _claimExpired;
      final String? known = _claimedTargets[cacheKey];
      if (known != null) return known;

      AgentsCloudRelaySocket? socket;
      var handedOff = false;
      try {
        final AccountSession session = await _resolveSession(sessionSource);
        if (token.isCancelled) return null;
        final RelaySocket transport = await inner(address.dialUri);
        socket = AgentsCloudRelaySocket._(
          transport: transport,
          deviceId: deviceId,
          address: address,
        );
        await socket._authenticate(session, handshakeTimeout);
        failures = 0;
        while (true) {
          if (token.isCancelled) return null;
          if (over()) throw _claimExpired;
          if (socket._transportGone.isCompleted) break;
          final Map<String, dynamic> frame;
          try {
            frame = await socket._sendClaim(
              pairingChannel,
              timeout: handshakeTimeout,
            );
          } on TimeoutException {
            // A claim nobody answered leaves its waiter armed; clear it so a
            // later answer is not taken for this one. Then dial again.
            socket._awaiting = null;
            socket._awaitingMatch = null;
            break;
          }
          final String type = '${frame['type']}';
          if (type == 'cowork_pair_claimed') {
            final String? device = _deviceIdFrom(frame);
            if (device == null) {
              // A claim answer with no device cannot be used, and a retry
              // gets the same answer.
              throw const AgentsCloudRelayException(
                _installClaimFailedText,
                code: 'claim_no_device',
              );
            }
            _claimedTargets[cacheKey] = device;
            // Keep this socket for the pairing: the host's commit is already
            // on its way down it (see [connect]).
            socket._targetDeviceId = device;
            socket._ready = true;
            _parkHandoff(cacheKey, socket, token, handoffTimeout);
            handedOff = true;
            if (kDebugMode) {
              debugPrint('[agents-cloud] install claim: computer linked');
            }
            return device;
          }
          final String code = '${frame['code'] ?? type}';
          if (type == 'cowork_pair_error' && !_claimRetryCodes.contains(code)) {
            throw AgentsCloudRelayException(
              _installClaimFailedText,
              code: code,
            );
          }
          // Not parked yet (or a passing relay error): wait and claim again.
          await pause(retryEvery, socket._transportGone.future);
        }
      } on AgentsCloudRelayException catch (error) {
        // The relay closed under us: a network matter, so dial again. Every
        // other refusal is final.
        if (error.code != 'closed') rethrow;
      } on TimeoutException {
        // No answer to the dial or the sign-in: dial again.
      } catch (error) {
        // Only a transport failure is worth another dial (offline, DNS, TLS,
        // a dropped connection). Anything else is a bug, and a bug must not
        // hide behind "waiting" for half an hour: it ends the wait, and the
        // page shows the failed state.
        if (!_isTransportFailure(error)) rethrow;
        if (kDebugMode) {
          debugPrint(
            '[agents-cloud] install claim: dial failed '
            '(${error.runtimeType}), retrying',
          );
        }
      } finally {
        if (!handedOff) await socket?.close();
      }
      if (token.isCancelled) return null;
      final Duration delay =
          reconnectBackoff[failures.clamp(0, reconnectBackoff.length - 1)];
      failures++;
      await pause(delay);
    }
  }

  /// True for a failure of the connection itself: an I/O error (socket,
  /// HTTP upgrade, TLS) or the WebSocket layer's wrapper around one.
  static bool _isTransportFailure(Object error) =>
      error is IOException || error is WebSocketChannelException;

  /// How long the waiting claim waits before it dials a dropped socket again.
  static const List<Duration> kClaimReconnectBackoff = <Duration>[
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 15),
  ];

  static const AgentsCloudRelayException _claimExpired =
      AgentsCloudRelayException(
        'This command has expired. Make a new command and run it again.',
        code: 'claim_expired',
      );

  static const String _installClaimFailedText =
      'Your computer could not be linked. Make a new command and run it '
      'again.';

  /// Claims the heal channel when the target host is not online.
  ///
  /// A host whose account session died parks on that channel and can reach
  /// nobody until a paired app claims it. The claim is the ordinary pairing
  /// claim, so the relay learns nothing new: it binds the parked socket to
  /// this account, and the host still has to pass the controller-session
  /// handshake before it acts on anything. Never throws: a refusal (the usual
  /// answer, when the host is simply off) leaves the reconnect as it was.
  Future<void> _healIfOffline(String heal) async {
    final target = _targetDeviceId;
    if (target == null) return;
    Set<String>? online;
    try {
      online = await _presence.future.timeout(_presenceWait);
    } on TimeoutException {
      online = null;
    }
    if (online != null && online.contains(target)) return;
    _healInProgress.value = true;
    try {
      // Short: the relay answers a claim at once, and a heal attempt must not
      // hold up an ordinary reconnect.
      final claimed = await _claimPairingChannel(
        heal,
        timeout: _healClaimTimeout,
      );
      if (kDebugMode) {
        debugPrint(
          claimed == target
              ? '[agents-cloud] renewed a parked host (heal channel)'
              : '[agents-cloud] heal claim answered for another device',
        );
      }
    } on AgentsCloudRelayException {
      // Not parked: the host is off, or healthy on another path.
    } on TimeoutException {
      // The relay did not answer the claim; the reconnect goes on as before.
    } finally {
      _healInProgress.value = false;
      // A claim that timed out leaves its waiter armed. The socket stays open
      // now, so a stale waiter would swallow a later error frame.
      _awaiting = null;
      _awaitingMatch = null;
    }
  }

  static Set<String> _onlineExecutors(Map<String, dynamic> frame) {
    final online = <String>{};
    final executors = frame['executors'];
    if (executors is! List) return online;
    for (final entry in executors) {
      if (entry is! Map) continue;
      final id = entry['device_id'];
      if (id is String && id.isNotEmpty && entry['online'] != false) {
        online.add(id);
      }
    }
    return online;
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
    _markGone();
    _pending.clear();
    await _sub?.cancel();
    _sub = null;
    await _transport.close();
    _upBuffer.clear();
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
        _emitUp(text);
      case 'cowork_error':
        // Routing failed (the host went offline mid-run, a bad target). There
        // is nothing to render and nothing the ceremony can do with it; the
        // client's own timeout and the reconnect watchdog are what recover.
        //
        // [close] is deliberately the whole response, and it must stay a
        // CLOSE and never a failure: it ends the upward stream, the relay
        // client turns that into `AgentsRelayPhase.closed` ("Disconnected"),
        // and the thread view's watchdog dials again and re-provisions the
        // account token on its own. A host restart therefore costs the user
        // nothing — no error to read, no button to press. Raising an error
        // here instead would park the view in a terminal state that only a
        // tap could leave.
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
        // Same contract as `cowork_error` above — a close, which the watchdog
        // answers with a fresh dial and a fresh `account_authentication`.
        if (_ready &&
            frame['device_id'] == _targetDeviceId &&
            frame['online'] == false) {
          unawaited(close());
        }
      case 'cowork_presence':
        if (!_presence.isCompleted) _presence.complete(_onlineExecutors(frame));
      case 'pong':
        break;
      default:
        break;
    }
  }

  void _onTransportError(Object error, StackTrace _) {
    _markGone();
    final waiting = _awaiting;
    _awaiting = null;
    _awaitingMatch = null;
    if (waiting != null && !waiting.isCompleted) waiting.completeError(error);
    if (!_upward.isClosed) _upward.addError(error);
  }

  void _onTransportDone() {
    _markGone();
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
    if (_upward.isClosed) return;
    if (!_upward.hasListener && _upBuffer.isNotEmpty) {
      // Keep the held frames for the listener that is about to come.
      _closeUpAfterFlush = true;
      return;
    }
    unawaited(_upward.close());
  }

  /// Passes one frame up, or holds it until the first listener arrives.
  void _emitUp(dynamic frame) {
    if (_upward.isClosed) return;
    if (_upward.hasListener) {
      _upward.add(frame);
      return;
    }
    if (_upBuffer.length < _upBufferLimit) _upBuffer.add(frame);
  }

  /// The first listener subscribed: hand it what arrived before it.
  void _flushUp() {
    if (_upward.isClosed) return;
    final List<dynamic> held = List<dynamic>.of(_upBuffer);
    _upBuffer.clear();
    for (final dynamic frame in held) {
      _upward.add(frame);
    }
    if (_closeUpAfterFlush) {
      _closeUpAfterFlush = false;
      unawaited(_upward.close());
    }
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
