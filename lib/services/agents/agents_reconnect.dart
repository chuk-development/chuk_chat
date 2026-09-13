/// Agents reconnect handshake — authenticated resume with no pairing code.
///
/// Dart twin of `common/agents_crypto/src/agents_crypto/reconnect.py`. Once a
/// first pairing (§15) has completed, **both** sides persist a trust record:
/// their own long-term Ed25519 device identity, the peer's `device_id` +
/// approved Ed25519 public key, the stable `channel_id` and the established
/// channel key. A reconnect must not ask the human for a code again — but it
/// must still be safe against an imposter that holds neither long-term private
/// key.
///
/// This is that reconnect: a **mutual signed-nonce challenge**. Each side proves
/// possession of its persisted long-term Ed25519 private key over a transcript
/// binding both fresh nonces and the channel id, and verifies the peer's proof
/// against the *stored* approved public key. No pairing code, no SAS, no
/// ephemeral ECDH — the channel key is the one already stored from pairing, and
/// it plugs into [AgentsFrameSealer] / [AgentsFrameOpener] exactly as after a
/// fresh pairing.
///
/// ## Byte-exact cross-language contract (must match the Python twin)
///
/// Roles keep the §15 naming: **initiator** = the host (executor), **joiner** =
/// the app (controller).
///
///  * `RT = N_i ‖ N_j` — 64 bytes, initiator nonce first, on both sides.
///  * `proof_i = Ed25519.sign(RECONNECT_I_LABEL ‖ channel_id ‖ RT)` (host).
///  * `proof_j = Ed25519.sign(RECONNECT_J_LABEL ‖ channel_id ‖ RT)` (app).
///  * The label differs per role (no reflection); `RT` binds both nonces (no
///    cross-session replay); `channel_id` binds the pairing. Each side verifies
///    the peer's proof against the STORED approved public key, so an imposter
///    without the peer's private key cannot forge a verifying proof → abort.
///
/// Message flow (three messages, hand-carried through the relay):
///   1. initiator → `reconnect-hello`    : channel_id, device_id, N_i
///   2. joiner    → `reconnect-response` : device_id, N_j, proof_j
///   3. initiator → `reconnect-confirm`  : proof_i
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'package:chuk_chat/services/agents/agents_device_keys.dart';

/// Which side of the reconnect a session drives. Same naming as §15 pairing.
enum AgentsReconnectRole {
  /// The host (executor).
  initiator,

  /// The app (controller).
  joiner,
}

/// Ordered lifecycle. Any use after [authenticated] / [aborted] is refused.
enum AgentsReconnectState {
  created,
  helloSent, // initiator only
  responseSent, // joiner only
  authenticated,
  aborted,
}

/// Why a reconnect step was refused. Every value is a hard stop.
enum AgentsReconnectRejection {
  wrongState,
  malformed,
  channelMismatch,
  wrongPeer,
  badSignature,
}

/// Thrown whenever a reconnect step is refused, carrying a machine-readable
/// [rejection]. A failure moves the session to [AgentsReconnectState.aborted].
class AgentsReconnectException implements Exception {
  AgentsReconnectException(this.rejection, [this.detail]);

  final AgentsReconnectRejection rejection;
  final String? detail;

  @override
  String toString() => detail == null
      ? 'AgentsReconnectException(${rejection.name})'
      : 'AgentsReconnectException(${rejection.name}: $detail)';
}

/// Byte-exact protocol constants + pure helpers, shared by both roles and the
/// cross-language vector test.
class AgentsReconnectCrypto {
  const AgentsReconnectCrypto._();

  /// Ed25519 proof label prefixes. One per signing role.
  static const String proofILabel = 'cowork/reconnect/proof-i'; // host
  static const String proofJLabel = 'cowork/reconnect/proof-j'; // app

  /// Reconnect nonce length in bytes.
  static const int nonceLength = 32;

  static final Ed25519 _ed25519 = Ed25519();

  static Ed25519 get ed25519 => _ed25519;

  /// `RT = N_i ‖ N_j` — 64 bytes, initiator nonce first, always.
  static Uint8List transcript(List<int> nonceI, List<int> nonceJ) {
    if (nonceI.length != nonceLength || nonceJ.length != nonceLength) {
      throw ArgumentError('nonces must be 32 bytes each');
    }
    return Uint8List.fromList(<int>[...nonceI, ...nonceJ]);
  }

  /// The exact bytes a role signs: `label ‖ channel_id ‖ RT`.
  static Uint8List signedBytes(
    String label,
    String channelId,
    List<int> transcript,
  ) => Uint8List.fromList(<int>[
    ...utf8.encode(label),
    ...utf8.encode(channelId),
    ...transcript,
  ]);

  /// A fresh 32-byte nonce from the platform's secure RNG.
  static Uint8List randomNonce() {
    final rnd = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(nonceLength, (_) => rnd.nextInt(256)),
    );
  }
}

/// A single-use, code-free reconnect handshake state machine for one role.
///
/// Construct with [AgentsReconnect.initiator] (host) or [AgentsReconnect.joiner]
/// (app). Each side is seeded from its persisted trust record: its own
/// [SimpleKeyPair] device identity, the stored `channel_id`, and the peer's
/// `device_id` + approved Ed25519 public key. The channel key is not touched
/// here — the caller already holds it from storage and uses it once
/// [authenticated] is true.
class AgentsReconnect {
  AgentsReconnect._({
    required AgentsReconnectRole role,
    required String deviceId,
    required SimpleKeyPair deviceKeyPair,
    required String peerDeviceId,
    required SimplePublicKey peerPublicKey,
    required String channelId,
    required List<int> nonce,
  }) : _role = role,
       _deviceId = deviceId,
       _deviceKeyPair = deviceKeyPair,
       _peerDeviceId = peerDeviceId,
       _peerPublicKey = peerPublicKey,
       _channelId = channelId,
       _nonce = nonce;

  final AgentsReconnectRole _role;
  final String _deviceId;
  final SimpleKeyPair _deviceKeyPair;
  final String _peerDeviceId;
  final SimplePublicKey _peerPublicKey;
  final String _channelId;
  final List<int> _nonce;

  AgentsReconnectState _state = AgentsReconnectState.created;
  List<int>? _peerNonce;

  // --- constructors ----------------------------------------------------------

  /// Start a reconnect as the host — it sends the first `hello`.
  ///
  /// [nonce] is injectable only for deterministic vectors / tests; leave null in
  /// production so a fresh 32-byte nonce is drawn from the secure RNG.
  static AgentsReconnect initiator({
    required String deviceId,
    required SimpleKeyPair deviceKeyPair,
    required String peerDeviceId,
    required SimplePublicKey peerPublicKey,
    required String channelId,
    List<int>? nonce,
  }) => AgentsReconnect._(
    role: AgentsReconnectRole.initiator,
    deviceId: deviceId,
    deviceKeyPair: deviceKeyPair,
    peerDeviceId: peerDeviceId,
    peerPublicKey: peerPublicKey,
    channelId: channelId,
    nonce: _resolveNonce(nonce),
  );

  /// Join a reconnect as the app — it answers the host's `hello`.
  static AgentsReconnect joiner({
    required String deviceId,
    required SimpleKeyPair deviceKeyPair,
    required String peerDeviceId,
    required SimplePublicKey peerPublicKey,
    required String channelId,
    List<int>? nonce,
  }) => AgentsReconnect._(
    role: AgentsReconnectRole.joiner,
    deviceId: deviceId,
    deviceKeyPair: deviceKeyPair,
    peerDeviceId: peerDeviceId,
    peerPublicKey: peerPublicKey,
    channelId: channelId,
    nonce: _resolveNonce(nonce),
  );

  static List<int> _resolveNonce(List<int>? nonce) {
    if (nonce == null) return AgentsReconnectCrypto.randomNonce();
    if (nonce.length != AgentsReconnectCrypto.nonceLength) {
      throw ArgumentError.value(nonce.length, 'nonce', 'must be 32 bytes');
    }
    return nonce;
  }

  // --- observable state ------------------------------------------------------

  AgentsReconnectRole get role => _role;

  AgentsReconnectState get state => _state;

  String get channelId => _channelId;

  String get peerDeviceId => _peerDeviceId;

  bool get authenticated => _state == AgentsReconnectState.authenticated;

  // --- guards ----------------------------------------------------------------

  void _require(AgentsReconnectState expected) {
    if (_state == AgentsReconnectState.authenticated ||
        _state == AgentsReconnectState.aborted) {
      throw AgentsReconnectException(
        AgentsReconnectRejection.wrongState,
        _state.name,
      );
    }
    if (_state != expected) {
      throw AgentsReconnectException(
        AgentsReconnectRejection.wrongState,
        'expected ${expected.name}, in ${_state.name}',
      );
    }
  }

  void _abort() {
    _state = AgentsReconnectState.aborted;
    _peerNonce = null;
  }

  List<int> _currentTranscript() {
    final peer = _peerNonce!;
    return _role == AgentsReconnectRole.initiator
        ? AgentsReconnectCrypto.transcript(_nonce, peer)
        : AgentsReconnectCrypto.transcript(peer, _nonce);
  }

  Future<Uint8List> _sign(String label) async {
    final message = AgentsReconnectCrypto.signedBytes(
      label,
      _channelId,
      _currentTranscript(),
    );
    final signature = await AgentsReconnectCrypto.ed25519.sign(
      message,
      keyPair: _deviceKeyPair,
    );
    return Uint8List.fromList(signature.bytes);
  }

  Future<void> _verifyPeer(String label, List<int> signature) async {
    final message = AgentsReconnectCrypto.signedBytes(
      label,
      _channelId,
      _currentTranscript(),
    );
    final valid = await AgentsReconnectCrypto.ed25519.verify(
      message,
      signature: Signature(signature, publicKey: _peerPublicKey),
    );
    if (!valid) {
      _abort();
      throw AgentsReconnectException(AgentsReconnectRejection.badSignature);
    }
  }

  void _checkPeerDevice(Object? wireDeviceId) {
    if (wireDeviceId is! String || wireDeviceId.isEmpty) {
      throw AgentsReconnectException(
        AgentsReconnectRejection.malformed,
        'device_id',
      );
    }
    if (!_constantTimeStringEquals(wireDeviceId, _peerDeviceId)) {
      _abort();
      throw AgentsReconnectException(AgentsReconnectRejection.wrongPeer);
    }
  }

  // --- initiator steps -------------------------------------------------------

  /// [initiator] Publish the challenge: our `device_id`, `channel_id` and fresh
  /// nonce `N_i`.
  Map<String, dynamic> createHello() {
    if (_role != AgentsReconnectRole.initiator) {
      throw AgentsReconnectException(
        AgentsReconnectRejection.wrongState,
        'initiator only',
      );
    }
    _require(AgentsReconnectState.created);
    final msg = <String, dynamic>{
      'type': 'reconnect-hello',
      'channel_id': _channelId,
      'device_id': _deviceId,
      'nonce': base64.encode(_nonce),
    };
    _state = AgentsReconnectState.helloSent;
    return msg;
  }

  /// [initiator] Verify the joiner's proof against the stored key, then sign our
  /// own proof and return the `confirm`.
  Future<Map<String, dynamic>> onResponse(Map<String, dynamic> msg) async {
    if (_role != AgentsReconnectRole.initiator) {
      throw AgentsReconnectException(
        AgentsReconnectRejection.wrongState,
        'initiator only',
      );
    }
    _require(AgentsReconnectState.helloSent);
    if (msg['type'] != 'reconnect-response') {
      throw AgentsReconnectException(
        AgentsReconnectRejection.malformed,
        'expected reconnect-response',
      );
    }
    _checkPeerDevice(msg['device_id']);
    final peerNonce = _decodeNonce(msg['nonce']);
    _peerNonce = peerNonce;
    final sigJ = _decodeBytes(msg['sig'], 'sig');
    await _verifyPeer(AgentsReconnectCrypto.proofJLabel, sigJ);
    final proofI = await _sign(AgentsReconnectCrypto.proofILabel);
    _state = AgentsReconnectState.authenticated;
    return <String, dynamic>{
      'type': 'reconnect-confirm',
      'sig': base64.encode(proofI),
    };
  }

  // --- joiner steps ----------------------------------------------------------

  /// [joiner] Adopt the initiator's nonce, sign our proof, and answer with our
  /// nonce `N_j` + proof.
  Future<Map<String, dynamic>> onHello(Map<String, dynamic> msg) async {
    if (_role != AgentsReconnectRole.joiner) {
      throw AgentsReconnectException(
        AgentsReconnectRejection.wrongState,
        'joiner only',
      );
    }
    _require(AgentsReconnectState.created);
    if (msg['type'] != 'reconnect-hello') {
      throw AgentsReconnectException(
        AgentsReconnectRejection.malformed,
        'expected reconnect-hello',
      );
    }
    if (msg['channel_id'] != _channelId) {
      throw AgentsReconnectException(AgentsReconnectRejection.channelMismatch);
    }
    _checkPeerDevice(msg['device_id']);
    final peerNonce = _decodeNonce(msg['nonce']);
    _peerNonce = peerNonce;
    final proofJ = await _sign(AgentsReconnectCrypto.proofJLabel);
    _state = AgentsReconnectState.responseSent;
    return <String, dynamic>{
      'type': 'reconnect-response',
      'device_id': _deviceId,
      'nonce': base64.encode(_nonce),
      'sig': base64.encode(proofJ),
    };
  }

  /// [joiner] Verify the initiator's proof against the stored key. On success
  /// the reconnect is authenticated and the stored channel key resumes the E2E
  /// channel.
  Future<void> onConfirm(Map<String, dynamic> msg) async {
    if (_role != AgentsReconnectRole.joiner) {
      throw AgentsReconnectException(
        AgentsReconnectRejection.wrongState,
        'joiner only',
      );
    }
    _require(AgentsReconnectState.responseSent);
    if (msg['type'] != 'reconnect-confirm') {
      throw AgentsReconnectException(
        AgentsReconnectRejection.malformed,
        'expected reconnect-confirm',
      );
    }
    final sigI = _decodeBytes(msg['sig'], 'sig');
    await _verifyPeer(AgentsReconnectCrypto.proofILabel, sigI);
    _state = AgentsReconnectState.authenticated;
  }

  // --- internals -------------------------------------------------------------

  List<int> _decodeNonce(Object? value) {
    final raw = _decodeBytes(value, 'nonce');
    if (raw.length != AgentsReconnectCrypto.nonceLength) {
      throw AgentsReconnectException(
        AgentsReconnectRejection.malformed,
        'nonce length',
      );
    }
    return raw;
  }

  static List<int> _decodeBytes(Object? value, String field) {
    if (value is! String) {
      throw AgentsReconnectException(
        AgentsReconnectRejection.malformed,
        '$field missing or not a string',
      );
    }
    try {
      return base64.decode(value);
    } on FormatException {
      throw AgentsReconnectException(
        AgentsReconnectRejection.malformed,
        '$field is not valid base64',
      );
    }
  }

  static bool _constantTimeStringEquals(String a, String b) {
    final ba = utf8.encode(a);
    final bb = utf8.encode(b);
    if (ba.length != bb.length) return false;
    var diff = 0;
    for (var i = 0; i < ba.length; i++) {
      diff |= ba[i] ^ bb[i];
    }
    return diff == 0;
  }
}

/// Parses a peer public key stored in a trust record. Delegates the length +
/// type checks to [AgentsDeviceKeys.publicKeyFromBase64].
SimplePublicKey agentsReconnectPeerKeyFromBase64(String encoded) =>
    AgentsDeviceKeys.publicKeyFromBase64(encoded);
