/// CoWork relay client — the app's transport for a LOCAL run.
///
/// This is the controller (phone/desktop) side of the local relay protocol.
/// It opens one WebSocket to a local host, joins a channel, runs the pairing
/// **joiner** ceremony (§15: joiner = desktop) against the host initiator,
/// then seals/opens CoWork frames (§14) over the now-authenticated channel.
///
/// ## Wire protocol (must match the Python host byte for byte)
///
///  * Connect a WebSocket to `ws://<host>:<port>` (default `ws://127.0.0.1:8787`).
///  * First message: `{"type":"join","channel":"<channel_id>","role":"controller"}`.
///    `channel_id` is the part of the pairing code before the **last** `-`.
///  * Pairing envelope:
///    `{"type":"pairing","step":"commit|pubkey|reveal|confirm-d|confirm-c|
///    device-d|device-c","data":{...}}` — `data` is the exact map the Dart
///    pairing state machine produces/consumes. The joiner (this app) sends
///    `pubkey`, `confirm-d` and `device-d`; it consumes `commit`, `reveal`,
///    `confirm-c` and `device-c`.
///  * Sealed frame envelope: `{"type":"frame","frame":"<base64>"}` where the
///    base64 payload is the UTF-8 of [CoworkFrame.toJsonString]
///    ([_frameToWire] / [_frameFromWire]).
///
/// The transport is decoupled from any UI. The WebSocket is injected through a
/// [RelaySocket] seam and a [RelaySocketConnector], so the whole flow is
/// testable against a fake in-Dart executor without a real server.
library;

import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart' show SimpleKeyPair;
import 'package:flutter/foundation.dart';

import 'package:cowork/services/account_session.dart';
import 'package:cowork/services/cowork/cowork_approved_devices.dart';
import 'package:cowork/services/cowork/cowork_frame.dart';
import 'package:cowork/services/cowork/cowork_frame_codec.dart';
import 'package:cowork/services/cowork/cowork_pairing.dart';
import 'package:cowork/services/cowork/cowork_pairing_store.dart';
import 'package:cowork/services/cowork/cowork_reconnect.dart';
import 'package:cowork/services/executor_provisioning.dart';
import 'package:cowork/services/websocket_connector.dart' as ws_connector;
import 'package:web_socket_channel/web_socket_channel.dart';

/// A minimal duplex socket seam: an inbound stream of text frames and a way to
/// send text. Injected so the relay client can run against a fake in tests.
abstract interface class RelaySocket {
  /// Frames arriving from the peer. Each element is the raw String (or bytes)
  /// delivered by the underlying transport.
  Stream<dynamic> get incoming;

  /// Sends one text frame to the peer.
  void send(String data);

  /// Closes the socket.
  Future<void> close();
}

/// Opens a [RelaySocket] to [url]. Default is [defaultRelaySocketConnector];
/// tests inject one that returns a fake.
typedef RelaySocketConnector = Future<RelaySocket> Function(Uri url);

/// Production connector.
///
/// Certificate pinning is meaningful only for TLS (`wss://`) to our own
/// backend; the CoWork host runs on a plain `ws://` (localhost / LAN), which
/// has no certificate to pin. Using the pinned client for a plain `ws://`
/// breaks the connection in release builds (the socket drops mid-pairing), so
/// we branch: pinned connector for `wss://`, a plain WebSocket for `ws://`.
Future<RelaySocket> defaultRelaySocketConnector(Uri url) async {
  final WebSocketChannel channel = url.scheme == 'wss'
      ? await ws_connector.connectWebSocket(url)
      : WebSocketChannel.connect(url);
  await channel.ready;
  return _WebSocketRelaySocket(channel);
}

class _WebSocketRelaySocket implements RelaySocket {
  _WebSocketRelaySocket(this._channel);

  final WebSocketChannel _channel;

  @override
  Stream<dynamic> get incoming => _channel.stream;

  @override
  void send(String data) => _channel.sink.add(data);

  @override
  Future<void> close() async {
    await _channel.sink.close();
  }
}

/// Where the relay client is in its lifecycle. Drives the UI directly.
enum CoworkRelayPhase {
  /// Nothing connected yet.
  idle,

  /// Opening the socket.
  connecting,

  /// Socket open, running the pairing ceremony.
  pairing,

  /// Paired: channel key established, host device approved, frames flow.
  paired,

  /// A failure the user must see (connect refused, pairing aborted).
  error,

  /// The socket closed after having been paired.
  closed,
}

/// Immutable snapshot of the relay client state, exposed as a [ValueListenable].
@immutable
class CoworkRelayState {
  const CoworkRelayState({
    required this.phase,
    this.detail,
    this.sas,
    this.peerDeviceId,
  });

  final CoworkRelayPhase phase;

  /// Human-readable status or error message (safe to show).
  final String? detail;

  /// The short authentication string, for optional on-screen reassurance.
  final String? sas;

  /// The approved host device id, once paired.
  final String? peerDeviceId;

  bool get isPaired => phase == CoworkRelayPhase.paired;

  @override
  bool operator ==(Object other) =>
      other is CoworkRelayState &&
      other.phase == phase &&
      other.detail == detail &&
      other.sas == sas &&
      other.peerDeviceId == peerDeviceId;

  @override
  int get hashCode => Object.hash(phase, detail, sas, peerDeviceId);
}

/// A decoded, opened frame delivered from the executor into the thread.
sealed class CoworkRelayInbound {
  const CoworkRelayInbound();
}

/// An assistant text delta.
class CoworkRelayDelta extends CoworkRelayInbound {
  const CoworkRelayDelta(this.text);
  final String text;
}

/// A reasoning delta — the model's thinking, which is a separate channel from
/// the answer and is rendered separately (never folded into the reply text).
///
/// The executor strips `<think>` blocks today and does not forward them, so
/// nothing emits this yet on the real wire. It is dispatched from a
/// `{"type":"reasoning"}` payload the moment the runtime starts sending one.
class CoworkRelayReasoning extends CoworkRelayInbound {
  const CoworkRelayReasoning(this.text);
  final String text;
}

/// One tool call that ran, as reported by the executor.
///
/// The executor's `tool` payload carries `name`, `command`, `exit_code`,
/// `stdout`, `stderr` and `timed_out`. Those map onto a short argument form, a
/// short result form, the full detail for the expanded view, and success vs
/// failure. [duration] is only ever set when the host actually reports a
/// `duration_ms` — it is never guessed.
class CoworkRelayTool extends CoworkRelayInbound {
  const CoworkRelayTool(
    this.name, {
    this.status,
    this.arguments,
    this.result,
    this.detail,
    this.exitCode,
    this.timedOut = false,
    this.duration,
    this.failed = false,
    this.raw = const {},
  });

  /// Builds a tool line from a decoded `tool` payload.
  factory CoworkRelayTool.fromPayload(Map<String, dynamic> payload) {
    final name = '${payload['name'] ?? payload['tool'] ?? 'tool'}';
    final status = payload['status'];
    final exitCode = _asInt(payload['exit_code']);
    final timedOut = payload['timed_out'] == true;
    final stdout = _asText(payload['stdout']);
    final stderr = _asText(payload['stderr']);
    final arguments = _asText(payload['command']) ?? _asText(payload['arguments']);
    // Failure is read from the protocol, never from the text: a non-zero exit
    // code, a timeout, or an explicit error field.
    final failed =
        timedOut || (exitCode != null && exitCode != 0) || payload['error'] != null;
    final detailParts = <String>[
      if (stdout != null && stdout.isNotEmpty) stdout,
      if (stderr != null && stderr.isNotEmpty) stderr,
    ];
    final result = _asText(payload['error']) ??
        (stderr != null && stderr.isNotEmpty && failed ? stderr : stdout);
    return CoworkRelayTool(
      name,
      status: status is String ? status : null,
      arguments: arguments,
      result: result,
      detail: detailParts.isEmpty ? null : detailParts.join('\n'),
      exitCode: exitCode,
      timedOut: timedOut,
      duration: _asDuration(payload['duration_ms']),
      failed: failed,
      raw: payload,
    );
  }

  final String name;
  final String? status;

  /// Short form of what the tool was called with (for `run_command`: the
  /// command line).
  final String? arguments;

  /// Short form of what came back.
  final String? result;

  /// The full output, shown only when the line is expanded.
  final String? detail;

  final int? exitCode;
  final bool timedOut;

  /// Wall-clock duration, only when the host reported one.
  final Duration? duration;

  /// True when the protocol says the call failed (non-zero exit, timeout, or an
  /// explicit error).
  final bool failed;

  final Map<String, dynamic> raw;

  static String? _asText(Object? value) => value is String ? value : null;

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  static Duration? _asDuration(Object? value) {
    final ms = _asInt(value);
    if (ms == null || ms < 0) return null;
    return Duration(milliseconds: ms);
  }
}

/// A file the agent produced and pushed into the thread (§9,
/// `send_file_to_user`).
///
/// The base64 body is decoded exactly **once**, here in the transport, and only
/// the resulting bytes travel on. The encoded string is never kept, so a big
/// screenshot does not sit in memory twice. A body that does not decode, or
/// whose length contradicts the declared [declaredSize], arrives with
/// [bytes] null and [error] set, so the UI can show a failure card instead of
/// crashing.
class CoworkRelayFile extends CoworkRelayInbound {
  const CoworkRelayFile({
    required this.name,
    required this.mimeType,
    required this.declaredSize,
    this.bytes,
    this.error,
  });

  final String name;
  final String mimeType;
  final int? declaredSize;
  final Uint8List? bytes;
  final String? error;

  bool get isImage => mimeType.startsWith('image/');
  bool get isValid => bytes != null && error == null;
}

/// The run finished. The executor reports why, and how many rounds it took.
class CoworkRelayDone extends CoworkRelayInbound {
  const CoworkRelayDone({
    this.finalAnswer,
    this.reason,
    this.iterations,
    this.tokensSpent,
  });

  /// The loop's own final answer, when it sent one.
  final String? finalAnswer;

  /// The termination reason the runtime reported (`finished`, `estop`,
  /// `interrupted`, …).
  final String? reason;

  /// How many rounds the loop ran.
  final int? iterations;

  /// Tokens the run spent (prompt + completion), for a cost readout. Null for a
  /// host too old to report it; zero when the backend sent no usage.
  final int? tokensSpent;

  /// True when the run ended because the kill switch fired, not because the
  /// agent finished. Read from the protocol's reason, never from text.
  bool get wasStopped => reason == 'estop' || reason == 'interrupted';
}

/// A child agent's lifecycle step (§7.6). Only state transitions surface here —
/// `queued` → `running` → `succeeded`/`failed`/`cancelled` — so the thread shows
/// the shape of a delegated fan-out without drowning in each child's own
/// streamed output. Built from a `subagent_state` event; a `subagent_output`
/// event (a child's delta/tool) is not turned into one of these.
class CoworkRelaySubagent extends CoworkRelayInbound {
  const CoworkRelaySubagent({
    required this.subagentId,
    required this.title,
    required this.state,
    this.result,
    this.error,
    this.tokensSpent,
  });

  /// The child's stable id (`sa_…`).
  final String subagentId;

  /// The child's title, as the parent named it. May be empty.
  final String title;

  /// The lifecycle state string the runtime reported: `queued`, `running`,
  /// `succeeded`, `failed`, `cancelled`. Read from the protocol, never guessed.
  final String state;

  /// The child's final result, on success. Null until then.
  final String? result;

  /// The child's error text, on failure. Null otherwise.
  final String? error;

  /// Tokens (prompt + completion) the child spent. Null when the runtime did
  /// not report any (a child that reported no usage omits it).
  final int? tokensSpent;

  /// True once the child has reached a terminal state.
  bool get isTerminal =>
      state == 'succeeded' || state == 'failed' || state == 'cancelled';
}

/// One member's turn in a group room (§16.1). Streamed live as the room talks.
class CoworkRelayRoomTurn extends CoworkRelayInbound {
  const CoworkRelayRoomTurn({
    required this.roomId,
    required this.round,
    required this.agentId,
    required this.handle,
    required this.text,
  });

  /// Which room this turn belongs to, so the app routes it to the right open
  /// room when several run at once.
  final String roomId;

  final int round;
  final String agentId;
  final String handle;
  final String text;
}

/// A group-room exchange ended. [reason] is a raw stop string from the host
/// (`no_more_mentions` / `rounds_exhausted` / `messages_exhausted` / `stopped` /
/// `turn_failed`); the UI maps it through `CoworkRoomStop.fromWire`.
class CoworkRelayRoomDone extends CoworkRelayInbound {
  const CoworkRelayRoomDone({
    required this.roomId,
    required this.reason,
    this.messagesSent,
    this.rounds,
  });

  /// Which room ended.
  final String roomId;

  final String reason;
  final int? messagesSent;
  final int? rounds;
}

/// A room's stored transcript, replayed on request (§16.1). Replaces whatever
/// the page currently shows for [roomId] with [turns].
class CoworkRelayRoomHistory extends CoworkRelayInbound {
  const CoworkRelayRoomHistory({required this.roomId, required this.turns});

  final String roomId;
  final List<CoworkRelayRoomTurn> turns;
}

/// The executor reported an error.
class CoworkRelayRunError extends CoworkRelayInbound {
  const CoworkRelayRunError(this.message);
  final String message;
}

/// Read-only surface the UI depends on, so widget tests can drive a fake
/// without a socket or a real pairing ceremony.
abstract interface class CoworkRelayController {
  /// Current lifecycle state; rebuild the UI when it changes.
  ValueListenable<CoworkRelayState> get state;

  /// Opened frames from the executor (deltas, tools, done, error).
  Stream<CoworkRelayInbound> get inbound;

  /// Connects, joins [pairingCode]'s channel, and runs the joiner ceremony
  /// against [hostUrl]. Throws (and moves to [CoworkRelayPhase.error]) on any
  /// pairing failure.
  Future<void> connect({required Uri hostUrl, required String pairingCode});

  /// Reconnects to an already-paired host with NO code, running the mutual
  /// signed-nonce reconnect handshake against the host and resuming the sealed
  /// channel from the stored channel key. Throws (and moves to
  /// [CoworkRelayPhase.error]) if the handshake fails (e.g. an imposter host).
  Future<void> reconnect({
    required Uri hostUrl,
    required CoworkStoredPairing pairing,
  });

  /// The trust established by the last successful [connect] / [reconnect], for
  /// the caller to persist. Null until paired.
  CoworkStoredPairing? get establishedTrust;

  /// Hands the executor the account token over the sealed channel.
  Future<void> provisionAccount(AccountSession session);

  /// Seals and sends a task prompt. [sessionKey] selects the thread on the
  /// executor side: one agent, many threads (§4). The executor resumes the
  /// append-only session that key routes to.
  Future<void> sendTask(String prompt, {String sessionKey});

  /// Seals and sends a group-room task (§16.1): the host looks [roomId]'s
  /// members up and drives them, streaming `room_turn` / `room_done` back.
  Future<void> sendRoomTask(String roomId, String message);

  /// Asks the host to replay [roomId]'s stored transcript; the host answers with
  /// a `room_history` event (§16.1).
  Future<void> requestRoomHistory(String roomId);

  /// Asks the executor to abort the run in [sessionKey] — the controller side of
  /// the two-tier kill switch (§7.1).
  ///
  /// The stop **names its target**, and the thread key is the name the app has:
  /// it chose it when it sent the task, and it knows it before the first event of
  /// the run comes back. A stop that named nothing would have to mean "abort
  /// whatever is running", which loses an invisible race — the run the user meant
  /// can finish while the frame is in flight, and the next task in that thread
  /// would be the one that died.
  ///
  /// The UI must not treat this as "stopped": it is a request. The run is only
  /// over when a `done` or `error` event arrives.
  Future<void> requestStop({String sessionKey});

  /// Tears the client down.
  Future<void> dispose();
}

/// The real transport. Also an [ExecutorTransport]: [provisionAccount] shapes
/// the payload through [ExecutorProvisioning], which calls back into
/// [sendAuthentication] to seal and send it over this WebSocket.
class CoworkRelayClient implements CoworkRelayController, ExecutorTransport {
  CoworkRelayClient({
    required String deviceId,
    required SimpleKeyPair signingKeyPair,
    RelaySocketConnector connector = defaultRelaySocketConnector,
    CoworkApprovedDevices? approvedDevices,
    int keyVersion = 1,
    int Function()? nowMs,
    Duration pairingTimeout = const Duration(seconds: 30),
  })  : _deviceId = deviceId,
        _signingKeyPair = signingKeyPair,
        _connector = connector,
        _approvedDevices = approvedDevices ?? CoworkApprovedDevices.empty(),
        _keyVersion = keyVersion,
        _nowMs = nowMs,
        _pairingTimeout = pairingTimeout;

  final String _deviceId;
  final SimpleKeyPair _signingKeyPair;
  final RelaySocketConnector _connector;
  final CoworkApprovedDevices _approvedDevices;
  final int _keyVersion;
  final int Function()? _nowMs;
  final Duration _pairingTimeout;

  final ValueNotifier<CoworkRelayState> _state =
      ValueNotifier<CoworkRelayState>(
    const CoworkRelayState(phase: CoworkRelayPhase.idle),
  );
  final StreamController<CoworkRelayInbound> _inbound =
      StreamController<CoworkRelayInbound>.broadcast();

  RelaySocket? _socket;
  StreamSubscription<dynamic>? _sub;
  CoworkPairing? _pairing;
  CoworkReconnect? _reconnect;
  CoworkStoredPairing? _establishedTrust;

  /// The authenticated host device, set by BOTH the first pairing and a code-free
  /// reconnect. Reading it off `_pairing` alone was a bug: after a reconnect
  /// there is no pairing session, so provisioning threw "Cannot provision before
  /// pairing completes" and every auto-reconnect died before serving a task.
  String? _peerDeviceId;
  Completer<void>? _pairingDone;

  /// Serialises inbound pairing steps so awaited transitions never overlap.
  Future<void> _pairingQueue = Future<void>.value();
  CoworkFrameSealer? _sealer;
  CoworkFrameOpener? _opener;
  bool _disposed = false;

  @override
  ValueListenable<CoworkRelayState> get state => _state;

  @override
  Stream<CoworkRelayInbound> get inbound => _inbound.stream;

  @override
  CoworkStoredPairing? get establishedTrust => _establishedTrust;

  /// The channel id is everything before the last '-' in the pairing code.
  static String channelIdOf(String pairingCode) {
    final dash = pairingCode.lastIndexOf('-');
    if (dash <= 0 || dash >= pairingCode.length - 1) {
      throw const FormatException('Malformed pairing code');
    }
    return pairingCode.substring(0, dash);
  }

  @override
  Future<void> connect({
    required Uri hostUrl,
    required String pairingCode,
  }) async {
    if (_disposed) throw StateError('CoworkRelayClient is disposed');
    if (_socket != null) throw StateError('Already connected');

    final String channelId;
    try {
      channelId = channelIdOf(pairingCode);
    } on FormatException catch (e) {
      _fail('Invalid pairing code');
      throw StateError(e.message);
    }

    _set(const CoworkRelayState(phase: CoworkRelayPhase.connecting));

    final RelaySocket socket;
    try {
      socket = await _connector(hostUrl);
    } catch (e) {
      _fail('Could not reach host: $e');
      rethrow;
    }
    _socket = socket;
    if (kDebugMode) {
      debugPrint('[cowork-relay] socket connected to $hostUrl');
    }

    // 1. Build the joiner BEFORE listening, so the first inbound envelope
    //    (the host's commit) can never race an unset pairing session.
    _pairing = await CoworkPairing.joiner(
      deviceId: _deviceId,
      deviceKeyPair: _signingKeyPair,
      pairingCode: pairingCode,
      approvedDevices: _approvedDevices,
      nowMs: _nowMs,
    );

    final done = Completer<void>();
    _pairingDone = done;
    _sub = socket.incoming.listen(
      _onData,
      onError: (Object e, StackTrace _) => _failPairing(e),
      onDone: _onSocketDone,
      cancelOnError: false,
    );

    // 2. Join the channel as the controller. The host initiator drives the
    //    ceremony from here; _handlePairing reacts to each envelope it sends.
    socket.send(
      jsonEncode(<String, dynamic>{
        'type': 'join',
        'channel': channelId,
        'role': 'controller',
      }),
    );
    _set(
      const CoworkRelayState(
        phase: CoworkRelayPhase.pairing,
        detail: 'Pairing with host…',
      ),
    );

    try {
      await done.future.timeout(_pairingTimeout);
    } catch (e) {
      _fail(_pairingErrorText(e));
      await _closeSocket();
      rethrow;
    }

    // 3. Paired: repoint the frame codec at the fresh channel key (§14).
    final pairing = _pairing!;
    final channelKey = pairing.channelKey;
    _sealer = CoworkFrameSealer.withChannelKey(
      channelKey: channelKey,
      keyVersion: _keyVersion,
      deviceId: _deviceId,
      signingKeyPair: _signingKeyPair,
    );
    _opener = CoworkFrameOpener.withChannelKey(
      channelKey: channelKey,
      keyVersion: _keyVersion,
      approvedDevices: pairing.approvedDevices,
    );
    // Capture the trust the caller persists so the next launch reconnects with
    // no code: the host's device key + the established channel key.
    final peerDeviceId = pairing.peerDeviceId;
    _peerDeviceId = peerDeviceId;
    final peerPublicKey =
        peerDeviceId == null ? null : pairing.approvedDevices.lookup(peerDeviceId);
    if (peerDeviceId != null && peerPublicKey != null) {
      _establishedTrust = CoworkStoredPairing(
        hostUrl: hostUrl,
        channelId: channelId,
        channelKey: channelKey,
        peerDeviceId: peerDeviceId,
        peerPublicKey: peerPublicKey,
      );
    }
    _set(
      CoworkRelayState(
        phase: CoworkRelayPhase.paired,
        sas: pairing.sas,
        peerDeviceId: pairing.peerDeviceId,
        detail: 'Paired',
      ),
    );
  }

  @override
  Future<void> reconnect({
    required Uri hostUrl,
    required CoworkStoredPairing pairing,
  }) async {
    if (_disposed) throw StateError('CoworkRelayClient is disposed');
    if (_socket != null) throw StateError('Already connected');

    _set(const CoworkRelayState(phase: CoworkRelayPhase.connecting));

    final RelaySocket socket;
    try {
      socket = await _connector(hostUrl);
    } catch (e) {
      _fail('Could not reach host: $e');
      rethrow;
    }
    _socket = socket;
    if (kDebugMode) {
      debugPrint('[cowork-relay] reconnecting to $hostUrl (no code)');
    }

    // Build the reconnect joiner BEFORE listening so the host's reconnect-hello
    // can never race an unset session.
    _reconnect = CoworkReconnect.joiner(
      deviceId: _deviceId,
      deviceKeyPair: _signingKeyPair,
      peerDeviceId: pairing.peerDeviceId,
      peerPublicKey: pairing.peerPublicKey,
      channelId: pairing.channelId,
    );

    final done = Completer<void>();
    _pairingDone = done;
    _sub = socket.incoming.listen(
      _onData,
      onError: (Object e, StackTrace _) => _failPairing(e),
      onDone: _onSocketDone,
      cancelOnError: false,
    );

    socket.send(
      jsonEncode(<String, dynamic>{
        'type': 'join',
        'channel': pairing.channelId,
        'role': 'controller',
      }),
    );
    _set(
      const CoworkRelayState(
        phase: CoworkRelayPhase.pairing,
        detail: 'Reconnecting…',
      ),
    );

    try {
      await done.future.timeout(_pairingTimeout);
    } catch (e) {
      _fail(_pairingErrorText(e));
      await _closeSocket();
      rethrow;
    }

    // Authenticated: resume the sealed channel from the STORED channel key.
    final approved = CoworkApprovedDevices.empty()
      ..approve(pairing.peerDeviceId, pairing.peerPublicKey);
    _sealer = CoworkFrameSealer.withChannelKey(
      channelKey: pairing.channelKey,
      keyVersion: _keyVersion,
      deviceId: _deviceId,
      signingKeyPair: _signingKeyPair,
    );
    _opener = CoworkFrameOpener.withChannelKey(
      channelKey: pairing.channelKey,
      keyVersion: _keyVersion,
      approvedDevices: approved,
    );
    _establishedTrust = pairing;
    _peerDeviceId = pairing.peerDeviceId;
    _set(
      CoworkRelayState(
        phase: CoworkRelayPhase.paired,
        peerDeviceId: pairing.peerDeviceId,
        detail: 'Reconnected',
      ),
    );
  }

  @override
  Future<void> provisionAccount(AccountSession session) {
    // Works after a first pairing AND after a code-free reconnect.
    final peerDeviceId = _peerDeviceId;
    if (peerDeviceId == null || !_state.value.isPaired) {
      throw StateError('Cannot provision before pairing completes');
    }
    // Route the token through ExecutorProvisioning, which shapes the payload
    // and calls back into sendAuthentication over this sealed transport.
    return ExecutorProvisioning(this)
        .provision(ExecutorHandle(deviceId: peerDeviceId, label: 'host'), session);
  }

  @override
  Future<void> sendAuthentication(
    ExecutorHandle target,
    Map<String, dynamic> payload,
  ) =>
      _sendFramePayload(payload);

  @override
  Future<void> sendTask(String prompt, {String sessionKey = 'default'}) =>
      _sendFramePayload(<String, dynamic>{
        'type': 'task',
        'prompt': prompt,
        'session_key': sessionKey,
      });

  @override
  Future<void> sendRoomTask(String roomId, String message) =>
      _sendFramePayload(<String, dynamic>{
        'type': 'room_task',
        'room_id': roomId,
        'message': message,
      });

  @override
  Future<void> requestRoomHistory(String roomId) =>
      _sendFramePayload(<String, dynamic>{
        'type': 'room_history_request',
        'room_id': roomId,
      });

  @override
  Future<void> requestStop({String sessionKey = 'default'}) =>
      _sendFramePayload(<String, dynamic>{
        'type': 'stop',
        // The executor matches this against the session key of the run it is
        // working on. A bare `{"type":"stop"}` — what this used to send — named
        // no run at all, so nothing could act on it.
        'session_key': sessionKey,
      });

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _sub?.cancel();
    await _socket?.close();
    _socket = null;
    if (!_inbound.isClosed) await _inbound.close();
    _state.dispose();
  }

  // --- internals -------------------------------------------------------------

  void _onData(dynamic raw) {
    final Map<String, dynamic> env;
    try {
      final decoded = jsonDecode(raw is String ? raw : utf8.decode(raw as List<int>));
      if (decoded is! Map<String, dynamic>) return;
      env = decoded;
    } catch (_) {
      return; // A malformed frame from the relay is dropped, never fatal.
    }

    final type = env['type'];
    if (type == 'frame') {
      unawaited(_handleFrame(env));
      return;
    }
    if (type == 'pairing' && !(_state.value.isPaired)) {
      // Serialise pairing steps. The host sends confirm-c and device-c
      // back-to-back; handling them concurrently would run onPeerDeviceKey
      // (device-c) before the awaited onConfirmC (confirm-c) has transitioned
      // the state to `confirmed`, throwing wrongState. Chain each step after
      // the previous one completes.
      _pairingQueue = _pairingQueue
          .then((_) => _reconnect != null
              ? _handleReconnect(env)
              : _handlePairing(env))
          .catchError(_failPairing);
    }
  }

  Future<void> _handleReconnect(Map<String, dynamic> env) async {
    final reconnect = _reconnect;
    if (reconnect == null) return;
    final step = env['step'];
    final data = env['data'];
    if (step is! String || data is! Map) return;
    final msg = data.cast<String, dynamic>();
    if (kDebugMode) debugPrint('[cowork-relay] recv reconnect step=$step');

    switch (step) {
      case 'reconnect-hello':
        _sendPairing('reconnect-response', await reconnect.onHello(msg));
      case 'reconnect-confirm':
        await reconnect.onConfirm(msg);
        if (reconnect.authenticated) {
          final done = _pairingDone;
          if (done != null && !done.isCompleted) done.complete();
        }
      default:
        break;
    }
  }

  Future<void> _handlePairing(Map<String, dynamic> env) async {
    final pairing = _pairing;
    if (pairing == null) return;
    final step = env['step'];
    final data = env['data'];
    if (step is! String || data is! Map) return;
    final msg = data.cast<String, dynamic>();
    if (kDebugMode) debugPrint('[cowork-relay] recv pairing step=$step');

    switch (step) {
      case 'commit':
        pairing.onCommit(msg);
        _sendPairing('pubkey', pairing.createPubkey());
      case 'reveal':
        _sendPairing('confirm-d', await pairing.onReveal(msg));
      case 'confirm-c':
        await pairing.onConfirmC(msg);
        // Reveal our own device key (device-d). The host reveals device-c.
        _sendPairing('device-d', await pairing.createDeviceKey());
        _maybeCompletePairing();
      case 'device-c':
        await pairing.onPeerDeviceKey(msg);
        _maybeCompletePairing();
      default:
        // Unknown pairing step: ignore rather than abort.
        break;
    }
  }

  void _maybeCompletePairing() {
    if (_pairing?.state == CoworkPairingState.completed) {
      final done = _pairingDone;
      if (done != null && !done.isCompleted) done.complete();
    }
  }

  void _sendPairing(String step, Map<String, dynamic> data) {
    if (kDebugMode) debugPrint('[cowork-relay] send pairing step=$step');
    _socket?.send(
      jsonEncode(<String, dynamic>{
        'type': 'pairing',
        'step': step,
        'data': data,
      }),
    );
  }

  Future<void> _handleFrame(Map<String, dynamic> env) async {
    final opener = _opener;
    if (opener == null) return;
    final wire = env['frame'];
    if (wire is! String) return;

    final CoworkFrame frame;
    try {
      frame = _frameFromWire(wire);
    } catch (_) {
      return; // Malformed / not a frame — drop.
    }

    final Uint8List plaintext;
    try {
      plaintext = await opener.open(frame);
    } on CoworkFrameRejectedException {
      return; // Hostile or replayed frame — drop silently, never render.
    }

    final Map<String, dynamic> payload;
    try {
      final decoded = jsonDecode(utf8.decode(plaintext));
      if (decoded is! Map<String, dynamic>) return;
      payload = decoded;
    } catch (_) {
      return;
    }
    _dispatch(payload);
  }

  void _dispatch(Map<String, dynamic> payload) {
    if (_inbound.isClosed) return;
    switch (payload['type']) {
      case 'delta':
        final text =
            payload['text'] ?? payload['delta'] ?? payload['content'] ?? '';
        _inbound.add(CoworkRelayDelta('$text'));
      case 'reasoning':
        final text = payload['text'] ?? payload['reasoning'] ?? '';
        _inbound.add(CoworkRelayReasoning('$text'));
      case 'tool':
        _inbound.add(CoworkRelayTool.fromPayload(payload));
      case 'file':
        _inbound.add(_fileFromPayload(payload));
      case 'done':
        final iterations = payload['iterations'];
        final finalAnswer = payload['final_answer'];
        final reason = payload['reason'];
        final tokens = payload['tokens_spent'] ?? payload['tokensSpent'];
        _inbound.add(
          CoworkRelayDone(
            finalAnswer: finalAnswer is String ? finalAnswer : null,
            reason: reason is String ? reason : null,
            iterations: iterations is int
                ? iterations
                : (iterations is num ? iterations.toInt() : null),
            tokensSpent: tokens is int
                ? tokens
                : (tokens is num ? tokens.toInt() : null),
          ),
        );
      case 'error':
        _inbound.add(
          CoworkRelayRunError('${payload['message'] ?? 'Unknown error'}'),
        );
      case 'subagent':
        final sub = _subagentFromPayload(payload);
        if (sub != null) _inbound.add(sub);
      case 'room_turn':
        final turn = _roomTurnFromPayload(payload);
        if (turn != null) _inbound.add(turn);
      case 'room_history':
        final hist = _roomHistoryFromPayload(payload);
        if (hist != null) _inbound.add(hist);
      case 'room_done':
        final roomId = payload['room_id'];
        final reason = payload['reason'];
        if (roomId is String && reason is String) {
          _inbound.add(
            CoworkRelayRoomDone(
              roomId: roomId,
              reason: reason,
              messagesSent: CoworkRelayTool._asInt(payload['messages_sent']),
              rounds: CoworkRelayTool._asInt(payload['rounds']),
            ),
          );
        }
      default:
        break;
    }
  }

  /// Turns a `subagent` frame into a [CoworkRelaySubagent], or null when the
  /// wrapped event is not a `subagent_state` (a `subagent_output` delta carries
  /// no lifecycle transition to show). Malformed frames are dropped, not thrown,
  /// so a bad child event never breaks the socket read loop.
  static CoworkRelaySubagent? _subagentFromPayload(Map<String, dynamic> payload) {
    final event = payload['event'];
    if (event is! Map) return null;
    if (event['type'] != 'subagent_state') return null;
    final id = event['subagent_id'];
    final state = event['state'];
    if (id is! String || state is! String) return null;
    final rawTitle = event['title'];
    final rawResult = event['result'];
    final rawError = event['error'];
    final rawTokens = event['tokens_spent'] ?? event['tokensSpent'];
    return CoworkRelaySubagent(
      subagentId: id,
      title: rawTitle is String ? rawTitle : '',
      state: state,
      result: rawResult is String ? rawResult : null,
      error: rawError is String ? rawError : null,
      tokensSpent: rawTokens is int
          ? rawTokens
          : (rawTokens is num ? rawTokens.toInt() : null),
    );
  }

  /// Turns a `room_turn` frame into a [CoworkRelayRoomTurn], or null when a
  /// field is missing or the wrong type. Dropped, never thrown.
  static CoworkRelayRoomTurn? _roomTurnFromPayload(Map<String, dynamic> payload) {
    final roomId = payload['room_id'];
    final agentId = payload['agent_id'];
    final handle = payload['handle'];
    final text = payload['text'];
    final round = CoworkRelayTool._asInt(payload['round']);
    if (roomId is! String ||
        agentId is! String ||
        handle is! String ||
        round == null) {
      return null;
    }
    return CoworkRelayRoomTurn(
      roomId: roomId,
      round: round,
      agentId: agentId,
      handle: handle,
      text: text is String ? text : '',
    );
  }

  /// Turns a `room_history` frame into a [CoworkRelayRoomHistory], or null when
  /// malformed. Each turn is parsed like a live `room_turn`; a bad turn in the
  /// list is skipped, not fatal.
  static CoworkRelayRoomHistory? _roomHistoryFromPayload(
    Map<String, dynamic> payload,
  ) {
    final roomId = payload['room_id'];
    final rawTurns = payload['turns'];
    if (roomId is! String || rawTurns is! List) return null;
    final turns = <CoworkRelayRoomTurn>[];
    for (final raw in rawTurns) {
      if (raw is! Map) continue;
      final round = CoworkRelayTool._asInt(raw['round']);
      final agentId = raw['agent_id'];
      final handle = raw['handle'];
      final text = raw['text'];
      if (round == null || agentId is! String || handle is! String) continue;
      turns.add(
        CoworkRelayRoomTurn(
          roomId: roomId,
          round: round,
          agentId: agentId,
          handle: handle,
          text: text is String ? text : '',
        ),
      );
    }
    return CoworkRelayRoomHistory(roomId: roomId, turns: turns);
  }

  /// Turns a `file` payload into a [CoworkRelayFile], decoding the base64 body
  /// exactly once and never keeping the encoded copy. A body that does not
  /// decode, is empty, or contradicts the declared size comes back as an error
  /// card instead of throwing into the socket read loop.
  static CoworkRelayFile _fileFromPayload(Map<String, dynamic> payload) {
    final rawName = payload['name'];
    final name = rawName is String && rawName.trim().isNotEmpty
        ? rawName.trim()
        : 'unnamed file';
    final rawMime = payload['mime_type'] ?? payload['mimeType'];
    final mimeType = rawMime is String && rawMime.isNotEmpty
        ? rawMime
        : 'application/octet-stream';
    final rawSize = payload['size'];
    final declaredSize = rawSize is int
        ? rawSize
        : (rawSize is num ? rawSize.toInt() : null);
    final data = payload['data'];
    if (data is! String || data.isEmpty) {
      return CoworkRelayFile(
        name: name,
        mimeType: mimeType,
        declaredSize: declaredSize,
        error: 'The file arrived without a body.',
      );
    }
    Uint8List bytes;
    try {
      bytes = base64.decode(data);
    } on FormatException {
      return CoworkRelayFile(
        name: name,
        mimeType: mimeType,
        declaredSize: declaredSize,
        error: 'The file body is not valid base64.',
      );
    }
    if (bytes.isEmpty) {
      return CoworkRelayFile(
        name: name,
        mimeType: mimeType,
        declaredSize: declaredSize,
        error: 'The file is empty.',
      );
    }
    if (declaredSize != null && declaredSize != bytes.length) {
      return CoworkRelayFile(
        name: name,
        mimeType: mimeType,
        declaredSize: declaredSize,
        error: 'The file body does not match the declared size '
            '($declaredSize bytes declared, ${bytes.length} received).',
      );
    }
    return CoworkRelayFile(
      name: name,
      mimeType: mimeType,
      declaredSize: declaredSize,
      bytes: bytes,
    );
  }

  Future<void> _sendFramePayload(Map<String, dynamic> payload) async {
    final sealer = _sealer;
    final socket = _socket;
    if (sealer == null || socket == null || !_state.value.isPaired) {
      throw StateError('Not paired');
    }
    final frame = await sealer.seal(utf8.encode(jsonEncode(payload)));
    socket.send(
      jsonEncode(<String, dynamic>{'type': 'frame', 'frame': _frameToWire(frame)}),
    );
  }

  void _onSocketDone() {
    if (kDebugMode) {
      debugPrint('[cowork-relay] socket closed (paired=${_state.value.isPaired})');
    }
    final done = _pairingDone;
    if (done != null && !done.isCompleted) {
      done.completeError(StateError('Host closed the connection during pairing'));
      return;
    }
    if (_state.value.isPaired) {
      _set(
        const CoworkRelayState(
          phase: CoworkRelayPhase.closed,
          detail: 'Disconnected',
        ),
      );
    }
  }

  void _failPairing(Object error) {
    if (kDebugMode) debugPrint('[cowork-relay] PAIRING FAILED: $error');
    final done = _pairingDone;
    if (done != null && !done.isCompleted) done.completeError(error);
  }

  void _fail(String detail) {
    _set(CoworkRelayState(phase: CoworkRelayPhase.error, detail: detail));
  }

  Future<void> _closeSocket() async {
    await _sub?.cancel();
    _sub = null;
    await _socket?.close();
    _socket = null;
  }

  void _set(CoworkRelayState next) {
    if (_disposed) return;
    _state.value = next;
  }

  static String _pairingErrorText(Object error) {
    if (error is TimeoutException) return 'Pairing timed out';
    if (error is CoworkPairingException) {
      return 'Pairing failed (${error.rejection.name})';
    }
    return 'Pairing failed';
  }

  /// A sealed frame as it rides the relay: base64 of the frame's JSON text.
  static String _frameToWire(CoworkFrame frame) =>
      base64.encode(utf8.encode(frame.toJsonString()));

  static CoworkFrame _frameFromWire(String wire) =>
      CoworkFrame.fromJsonString(utf8.decode(base64.decode(wire)));
}
