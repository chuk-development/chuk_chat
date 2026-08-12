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
import 'package:cowork/services/executor_provisioning.dart';
import 'package:cowork/services/websocket_connector.dart' as ws_connector;

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

/// Production connector: a real (optionally certificate-pinned) WebSocket.
Future<RelaySocket> defaultRelaySocketConnector(Uri url) async {
  final channel = await ws_connector.connectWebSocket(url);
  return _WebSocketRelaySocket(channel);
}

class _WebSocketRelaySocket implements RelaySocket {
  _WebSocketRelaySocket(this._channel);

  final dynamic _channel; // WebSocketChannel

  @override
  Stream<dynamic> get incoming => _channel.stream as Stream<dynamic>;

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

/// A tool-call line (rendered as a chip).
class CoworkRelayTool extends CoworkRelayInbound {
  const CoworkRelayTool(this.name, {this.status, this.raw = const {}});
  final String name;
  final String? status;
  final Map<String, dynamic> raw;
}

/// The run finished.
class CoworkRelayDone extends CoworkRelayInbound {
  const CoworkRelayDone();
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

  /// Hands the executor the account token over the sealed channel.
  Future<void> provisionAccount(AccountSession session);

  /// Seals and sends a task prompt.
  Future<void> sendTask(String prompt);

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
  Completer<void>? _pairingDone;
  CoworkFrameSealer? _sealer;
  CoworkFrameOpener? _opener;
  bool _disposed = false;

  @override
  ValueListenable<CoworkRelayState> get state => _state;

  @override
  Stream<CoworkRelayInbound> get inbound => _inbound.stream;

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
  Future<void> provisionAccount(AccountSession session) {
    final peerDeviceId = _pairing?.peerDeviceId;
    if (peerDeviceId == null) {
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
  Future<void> sendTask(String prompt) =>
      _sendFramePayload(<String, dynamic>{'type': 'task', 'prompt': prompt});

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
      _handlePairing(env).catchError(_failPairing);
    }
  }

  Future<void> _handlePairing(Map<String, dynamic> env) async {
    final pairing = _pairing;
    if (pairing == null) return;
    final step = env['step'];
    final data = env['data'];
    if (step is! String || data is! Map) return;
    final msg = data.cast<String, dynamic>();

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
      case 'tool':
        final name = '${payload['name'] ?? payload['tool'] ?? 'tool'}';
        final status = payload['status'];
        _inbound.add(
          CoworkRelayTool(
            name,
            status: status is String ? status : null,
            raw: payload,
          ),
        );
      case 'done':
        _inbound.add(const CoworkRelayDone());
      case 'error':
        _inbound.add(
          CoworkRelayRunError('${payload['message'] ?? 'Unknown error'}'),
        );
      default:
        break;
    }
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
