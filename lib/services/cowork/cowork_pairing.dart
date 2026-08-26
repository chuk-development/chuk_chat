/// CoWork secure pairing — SAS-authenticated X25519 with a hash commitment.
///
/// Dart twin of `common/cowork_crypto/src/cowork_crypto/pairing.py`. Implements
/// §15 of the platform plan: establish an E2E channel key **and** mutual device
/// trust between the desktop app (joiner) and the Python client (initiator)
/// using a short human code, such that even a malicious relay/backend cannot
/// MITM or spoof, and a stolen code cannot hijack the client.
///
/// The primitive is the ZRTP / Signal-safety-number pattern, built only from
/// X25519 + HKDF-SHA256 + SHA-256.
///
/// ## Byte-exact cross-language contract (must match the Python twin)
///
/// All multi-byte lengths are big-endian. All labels are ASCII, no terminator.
///
/// Roles
///   * **initiator** = the Python client. Ephemeral X25519 key `(a, A)`.
///   * **joiner**    = the desktop app.   Ephemeral X25519 key `(b, B)`.
///   * `A`/`B` are the 32-byte raw X25519 public keys.
///
/// Pairing code `PC = "{channel_id}-{digits}"` — the exact UTF-8 string.
///
/// * `commitment = SHA-256(COMMIT_LABEL ‖ A)` — 32 bytes.
/// * `K_raw = X25519(priv, peer_pub)` — 32 raw bytes, identical on both sides.
/// * `T = A ‖ B` — 64 bytes, **initiator public first**, on both sides.
/// * `channel_key = HKDF-SHA256(ikm=K_raw, salt="", info=CHANNEL_KEY_INFO, 32)`.
/// * `MAC_d/MAC_c = HKDF-SHA256(ikm=K_raw, salt="", info=CONFIRM_?_LABEL ‖ T ‖ PC, 32)`.
///   `PC` is folded in so the one-way-typed pairing code authenticates the
///   channel: a relaying attacker completing two ECDH legs knows every `K`/`T`
///   on the wire and could recompute a MAC over `T` alone, but never learns
///   `PC`, so both honest MACs are unforgeable without the shared code. Security
///   does not rest on a human comparing a SAS across two screens.
/// * `sas = HKDF-SHA256(ikm=K_raw, salt="", info=SAS_LABEL ‖ T ‖ PC, 8)` folded
///   to `digits` decimal characters — an OPTIONAL display value only, not a
///   security dependency ([confirmPeerSas] is optional, not in the happy path).
/// * Device key: `proof = Ed25519.sign(DEVICE_PROOF_LABEL ‖ T ‖ device_id)` and
///   `mac = HKDF(K_raw, info=LBL ‖ T ‖ ed_pub ‖ device_id ‖ PC, 32)`, LBL =
///   `DEVICE_D_LABEL` (joiner) or `DEVICE_C_LABEL` (initiator).
///
/// Every verification is constant-time. The session is single-use and expires;
/// any step after completion, abort, or expiry is refused. No usable channel key
/// is ever exposed unless both confirmation MACs verified.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart' as crypto;

import 'package:chuk_chat/services/cowork/cowork_approved_devices.dart';
import 'package:chuk_chat/services/cowork/cowork_device_keys.dart';

/// Which side of the ceremony a session drives.
enum CoworkPairingRole {
  /// The Python client.
  initiator,

  /// The desktop app.
  joiner,
}

/// Ordered lifecycle. Illegal transitions and any use after a terminal state
/// (`completed` / `aborted`) are refused.
enum CoworkPairingState {
  created,
  commitSent, // initiator only
  commitReceived, // joiner only
  pubkeySent, // joiner only
  keyEstablished, // K + SAS derived, MACs not yet checked
  confirmed, // both confirmation MACs verified
  completed, // peer device key approved
  aborted,
}

/// Why a pairing step was refused. Every value is a hard stop.
enum CoworkPairingRejection {
  wrongState,
  expired,
  consumed,
  malformed,
  channelMismatch,
  commitmentMismatch,
  sasMismatch,
  macMismatch,
  badDeviceProof,
}

/// Thrown whenever a pairing step is refused, carrying a machine-readable
/// [rejection]. Any failure past key establishment first moves the session to
/// [CoworkPairingState.aborted] and discards key material.
class CoworkPairingException implements Exception {
  CoworkPairingException(this.rejection, [this.detail]);

  final CoworkPairingRejection rejection;
  final String? detail;

  @override
  String toString() =>
      detail == null ? 'CoworkPairingException(${rejection.name})'
          : 'CoworkPairingException(${rejection.name}: $detail)';
}

/// Byte-exact protocol constants + pure crypto helpers, shared by both roles and
/// by the cross-language vector test.
class CoworkPairingCrypto {
  const CoworkPairingCrypto._();

  // Labels as UTF-8 bytes (kept as strings, encoded on use, to stay readable).
  static const String sasLabel = 'cowork/pairing/sas';
  static const String confirmDLabel = 'cowork/pairing/confirm-d';
  static const String confirmCLabel = 'cowork/pairing/confirm-c';
  static const String deviceDLabel = 'cowork/pairing/device-d';
  static const String deviceCLabel = 'cowork/pairing/device-c';
  static const String deviceProofLabel = 'cowork/pairing/device-proof';
  static const String commitLabel = 'cowork/pairing/commit-v1';

  /// HKDF `info` for the channel key — matches `channel_key.py`
  /// (`CHANNEL_KEY_INFO`) and `derive_channel_key`.
  static const String channelKeyInfo = 'chuk.cowork.channel-key.v1';

  static const int x25519PublicLength = 32;
  static const int commitmentLength = 32;
  static const int macLength = 32;
  static const int channelKeyLength = 32;

  /// Bytes drawn from HKDF before folding down into the decimal SAS.
  static const int sasHkdfBytes = 8;

  static const int defaultSasDigits = 6;

  /// Default pairing-code lifetime in milliseconds (~2 minutes, §15).
  static const int defaultExpiryMs = 120000;

  static final X25519 _x25519 = X25519();
  static final Ed25519 _ed25519 = Ed25519();
  static final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  static X25519 get x25519 => _x25519;
  static Ed25519 get ed25519 => _ed25519;

  /// HKDF-SHA256 with an empty salt (== RFC 5869 no-salt == Python `salt=None`)
  /// and the given `info`, returning `length` bytes.
  static Future<Uint8List> hkdf(
    List<int> ikm,
    List<int> info,
    int length,
  ) async {
    final kdf = length == 32 ? _hkdf : Hkdf(hmac: Hmac.sha256(), outputLength: length);
    final out = await kdf.deriveKey(
      secretKey: SecretKey(ikm),
      // Empty nonce = empty HKDF-Extract salt, matching the Python twin.
      nonce: const <int>[],
      info: info,
    );
    return Uint8List.fromList(await out.extractBytes());
  }

  /// `SHA-256(COMMIT_LABEL ‖ A)` — the initiator's binding commitment to its
  /// ephemeral public key `A`. 32 bytes.
  static Uint8List commitment(List<int> publicA) {
    if (publicA.length != x25519PublicLength) {
      throw ArgumentError.value(
        publicA.length,
        'publicA',
        'must be a 32-byte X25519 public key',
      );
    }
    final input = <int>[...utf8.encode(commitLabel), ...publicA];
    return Uint8List.fromList(crypto.sha256.convert(input).bytes);
  }

  /// `T = A ‖ B` — 64 bytes, initiator public first, always.
  static Uint8List transcript(List<int> publicA, List<int> publicB) {
    if (publicA.length != x25519PublicLength ||
        publicB.length != x25519PublicLength) {
      throw ArgumentError('public keys must be 32 raw X25519 bytes');
    }
    return Uint8List.fromList(<int>[...publicA, ...publicB]);
  }

  /// The decimal SAS both sides compute and a human compares out of band.
  static Future<String> deriveSas(
    List<int> kRaw,
    List<int> t,
    String pairingCode,
    int digits,
  ) async {
    final info = <int>[...utf8.encode(sasLabel), ...t, ...utf8.encode(pairingCode)];
    final out = await hkdf(kRaw, info, sasHkdfBytes);
    var value = BigInt.zero;
    for (final b in out) {
      value = (value << 8) | BigInt.from(b);
    }
    final modulus = BigInt.from(10).pow(digits);
    return (value % modulus).toString().padLeft(digits, '0');
  }

  /// A key-confirmation MAC: `HKDF(K_raw, label ‖ T ‖ PC, 32)`.
  ///
  /// `PC` (the pairing code) is folded in so the one-way-typed, out-of-band
  /// human code authenticates the channel. A relaying attacker that completes
  /// two ECDH legs knows every `K` and `T` on the wire and could recompute a
  /// MAC over `T` alone for each leg; it never learns `PC`, so folding `PC` in
  /// makes both honest MACs unforgeable unless the peer holds the same code.
  /// This removes any dependency on a human comparing a SAS across two screens.
  static Future<Uint8List> deriveConfirmMac(
    List<int> kRaw,
    String label,
    List<int> t,
    String pairingCode,
  ) =>
      hkdf(
        kRaw,
        <int>[...utf8.encode(label), ...t, ...utf8.encode(pairingCode)],
        macLength,
      );

  static Future<Uint8List> deviceMac(
    List<int> kRaw,
    String label,
    List<int> t,
    List<int> edPub,
    String deviceId,
    String pairingCode,
  ) =>
      hkdf(
        kRaw,
        <int>[
          ...utf8.encode(label),
          ...t,
          ...edPub,
          ...utf8.encode(deviceId),
          ...utf8.encode(pairingCode),
        ],
        macLength,
      );

  static Uint8List deviceProofMessage(List<int> t, String deviceId) =>
      Uint8List.fromList(
        <int>[...utf8.encode(deviceProofLabel), ...t, ...utf8.encode(deviceId)],
      );

  /// The channel key that later seals frames (§14). Matches
  /// `derive_channel_key`: `HKDF(K_raw, info=channelKeyInfo, 32)`.
  static Future<Uint8List> deriveChannelKey(List<int> kRaw) =>
      hkdf(kRaw, utf8.encode(channelKeyInfo), channelKeyLength);

  /// Constant-time byte comparison. Returns false on a length mismatch without
  /// leaking where the difference is.
  static bool constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}

/// A single-use pairing session state machine for one role.
///
/// Construct with [CoworkPairing.initiator] (Python client) or
/// [CoworkPairing.joiner] (desktop app). Each message-handling method consumes a
/// JSON-serialisable `Map` and returns the next one to put on the wire (or
/// nothing). The wire messages are plain maps by design: they ride the real
/// relay later, but here they are passed hand to hand so they can be tested
/// directly.
class CoworkPairing {
  CoworkPairing._({
    required CoworkPairingRole role,
    required String deviceId,
    required SimpleKeyPair deviceKeyPair,
    required SimplePublicKey devicePublicKey,
    required SimpleKeyPair ephemeralKeyPair,
    required List<int> ephemeralPublic,
    required String channelId,
    required String pairingCode,
    required int sasDigits,
    required int expiresAtMs,
    required int Function() nowMs,
    required CoworkApprovedDevices approvedDevices,
  })  : _role = role,
        _deviceId = deviceId,
        _deviceKeyPair = deviceKeyPair,
        _devicePublicKey = devicePublicKey,
        _ephemeralKeyPair = ephemeralKeyPair,
        _ephemeralPublic = ephemeralPublic,
        _channelId = channelId,
        _pairingCode = pairingCode,
        _sasDigits = sasDigits,
        _expiresAtMs = expiresAtMs,
        _nowMs = nowMs,
        _approved = approvedDevices;

  final CoworkPairingRole _role;
  final String _deviceId;
  final SimpleKeyPair _deviceKeyPair;
  final SimplePublicKey _devicePublicKey;
  final SimpleKeyPair _ephemeralKeyPair;
  final List<int> _ephemeralPublic;
  final String _channelId;
  final String _pairingCode;
  final int _sasDigits;
  final int Function() _nowMs;
  final CoworkApprovedDevices _approved;

  int _expiresAtMs;
  CoworkPairingState _state = CoworkPairingState.created;

  List<int>? _peerPublic;
  List<int>? _commitment; // joiner: the received commitment
  List<int>? _kRaw;
  List<int>? _channelKey;
  String? _sas;
  String? _peerDeviceId;
  bool _sentDeviceKey = false;
  bool _approvedPeer = false;

  // --- constructors ----------------------------------------------------------

  /// Start a pairing session as the Python client (initiator). Generates the
  /// ephemeral `(a, A)` and the single-use pairing code, and fixes the expiry.
  ///
  /// [ephemeralKeyPair], [channelId] and [digits] are injectable only for
  /// deterministic vectors / tests; leave them null in production.
  static Future<CoworkPairing> initiator({
    required String deviceId,
    required SimpleKeyPair deviceKeyPair,
    int sasDigits = CoworkPairingCrypto.defaultSasDigits,
    int expiryMs = CoworkPairingCrypto.defaultExpiryMs,
    int Function()? nowMs,
    CoworkApprovedDevices? approvedDevices,
    SimpleKeyPair? ephemeralKeyPair,
    String? channelId,
    String? digits,
  }) async {
    if (sasDigits < 1) {
      throw ArgumentError.value(sasDigits, 'sasDigits', 'must be >= 1');
    }
    final now = nowMs ?? _wallClock;
    final resolvedChannelId = channelId ?? _randomChannelId();
    if (resolvedChannelId.contains('-')) {
      throw ArgumentError.value(
        resolvedChannelId,
        'channelId',
        "must not contain '-'",
      );
    }
    final resolvedDigits = digits ?? _randomDigits(sasDigits);
    if (resolvedDigits.length != sasDigits || !_isAllDigits(resolvedDigits)) {
      throw ArgumentError.value(
        resolvedDigits,
        'digits',
        'must be exactly sasDigits decimal characters',
      );
    }
    final ephemeral =
        ephemeralKeyPair ?? await CoworkPairingCrypto.x25519.newKeyPair();
    final ephemeralPublic = (await ephemeral.extractPublicKey()).bytes;
    final devicePublicKey = await deviceKeyPair.extractPublicKey();
    return CoworkPairing._(
      role: CoworkPairingRole.initiator,
      deviceId: deviceId,
      deviceKeyPair: deviceKeyPair,
      devicePublicKey: devicePublicKey,
      ephemeralKeyPair: ephemeral,
      ephemeralPublic: ephemeralPublic,
      channelId: resolvedChannelId,
      pairingCode: '$resolvedChannelId-$resolvedDigits',
      sasDigits: sasDigits,
      expiresAtMs: now() + expiryMs,
      nowMs: now,
      approvedDevices: approvedDevices ?? CoworkApprovedDevices.empty(),
    );
  }

  /// Join a pairing session as the desktop app, from the human-entered pairing
  /// code. The expiry is carried in the initiator's commit and adopted in
  /// [onCommit].
  static Future<CoworkPairing> joiner({
    required String deviceId,
    required SimpleKeyPair deviceKeyPair,
    required String pairingCode,
    int Function()? nowMs,
    CoworkApprovedDevices? approvedDevices,
    SimpleKeyPair? ephemeralKeyPair,
  }) async {
    final dash = pairingCode.lastIndexOf('-');
    if (dash <= 0 || dash >= pairingCode.length - 1) {
      throw CoworkPairingException(
        CoworkPairingRejection.malformed,
        'pairing code',
      );
    }
    final channelId = pairingCode.substring(0, dash);
    final digits = pairingCode.substring(dash + 1);
    if (!_isAllDigits(digits)) {
      throw CoworkPairingException(
        CoworkPairingRejection.malformed,
        'pairing code',
      );
    }
    final now = nowMs ?? _wallClock;
    final ephemeral =
        ephemeralKeyPair ?? await CoworkPairingCrypto.x25519.newKeyPair();
    final ephemeralPublic = (await ephemeral.extractPublicKey()).bytes;
    final devicePublicKey = await deviceKeyPair.extractPublicKey();
    return CoworkPairing._(
      role: CoworkPairingRole.joiner,
      deviceId: deviceId,
      deviceKeyPair: deviceKeyPair,
      devicePublicKey: devicePublicKey,
      ephemeralKeyPair: ephemeral,
      ephemeralPublic: ephemeralPublic,
      channelId: channelId,
      pairingCode: pairingCode,
      sasDigits: digits.length,
      expiresAtMs: 0, // set from the commit
      nowMs: now,
      approvedDevices: approvedDevices ?? CoworkApprovedDevices.empty(),
    );
  }

  // --- observable state ------------------------------------------------------

  CoworkPairingRole get role => _role;

  CoworkPairingState get state => _state;

  /// The full `PC` — initiator displays it, joiner echoes it.
  String get pairingCode => _pairingCode;

  String get channelId => _channelId;

  /// The short authentication string, available once `K` is derived. Compared
  /// out of band by the human; exposing it before confirmation is the point.
  String get sas {
    final value = _sas;
    if (value == null) {
      throw CoworkPairingException(
        CoworkPairingRejection.wrongState,
        'SAS not derived yet',
      );
    }
    return value;
  }

  CoworkApprovedDevices get approvedDevices => _approved;

  String? get peerDeviceId => _peerDeviceId;

  /// The 32-byte CoWork channel key — **only** after both confirmation MACs
  /// verified. Before that, or after an abort, this throws: no usable channel
  /// key is ever committed on a mismatch.
  Uint8List get channelKey {
    final key = _channelKey;
    if ((_state == CoworkPairingState.confirmed ||
            _state == CoworkPairingState.completed) &&
        key != null) {
      return Uint8List.fromList(key);
    }
    throw CoworkPairingException(
      CoworkPairingRejection.wrongState,
      'channel key is not available until both MACs verify',
    );
  }

  // --- guards ----------------------------------------------------------------

  void _require(CoworkPairingState expected) {
    if (_state == CoworkPairingState.completed ||
        _state == CoworkPairingState.aborted) {
      throw CoworkPairingException(CoworkPairingRejection.consumed, _state.name);
    }
    if (_state != expected) {
      throw CoworkPairingException(
        CoworkPairingRejection.wrongState,
        'expected ${expected.name}, in ${_state.name}',
      );
    }
  }

  void _checkNotExpired() {
    if (_expiresAtMs != 0 && _nowMs() > _expiresAtMs) {
      _abort();
      throw CoworkPairingException(CoworkPairingRejection.expired);
    }
  }

  void _abort() {
    _state = CoworkPairingState.aborted;
    // Discard all key material so nothing usable survives a failed ceremony.
    _kRaw = null;
    _channelKey = null;
  }

  // --- initiator steps -------------------------------------------------------

  /// [initiator] Publish the commitment `H(A)` and the routing id.
  Map<String, dynamic> createCommit() {
    if (_role != CoworkPairingRole.initiator) {
      throw CoworkPairingException(
        CoworkPairingRejection.wrongState,
        'initiator only',
      );
    }
    _require(CoworkPairingState.created);
    _checkNotExpired();
    final msg = <String, dynamic>{
      'type': 'commit',
      'channel_id': _channelId,
      'commitment': base64.encode(CoworkPairingCrypto.commitment(_ephemeralPublic)),
      'expires_at': _expiresAtMs,
      'sas_digits': _sasDigits,
    };
    _state = CoworkPairingState.commitSent;
    return msg;
  }

  /// [initiator] Receive the joiner's `B`, derive `K` and the SAS, and reveal
  /// `A`.
  Future<Map<String, dynamic>> onPubkey(Map<String, dynamic> msg) async {
    if (_role != CoworkPairingRole.initiator) {
      throw CoworkPairingException(
        CoworkPairingRejection.wrongState,
        'initiator only',
      );
    }
    _require(CoworkPairingState.commitSent);
    _checkNotExpired();
    if (msg['type'] != 'pubkey') {
      throw CoworkPairingException(
        CoworkPairingRejection.malformed,
        'expected pubkey',
      );
    }
    final peerB = _decodeKey(msg['pubkey'], 'pubkey');
    _peerPublic = peerB;
    await _establishKey(publicA: _ephemeralPublic, publicB: peerB);
    _state = CoworkPairingState.keyEstablished;
    return <String, dynamic>{
      'type': 'reveal',
      'pubkey': base64.encode(_ephemeralPublic),
    };
  }

  /// [initiator] Verify the joiner's `MAC_d` (constant-time) and send `MAC_c`.
  Future<Map<String, dynamic>> onConfirmD(Map<String, dynamic> msg) async {
    if (_role != CoworkPairingRole.initiator) {
      throw CoworkPairingException(
        CoworkPairingRejection.wrongState,
        'initiator only',
      );
    }
    _require(CoworkPairingState.keyEstablished);
    _checkNotExpired();
    if (msg['type'] != 'confirm-d') {
      throw CoworkPairingException(
        CoworkPairingRejection.malformed,
        'expected confirm-d',
      );
    }
    await _verifyConfirm(msg, CoworkPairingCrypto.confirmDLabel);
    _state = CoworkPairingState.confirmed;
    final mac = await CoworkPairingCrypto.deriveConfirmMac(
      _kRaw!,
      CoworkPairingCrypto.confirmCLabel,
      _currentTranscript(),
      _pairingCode,
    );
    return <String, dynamic>{'type': 'confirm-c', 'mac': base64.encode(mac)};
  }

  // --- joiner steps ----------------------------------------------------------

  /// [joiner] Store the commitment and adopt the initiator's expiry.
  void onCommit(Map<String, dynamic> msg) {
    if (_role != CoworkPairingRole.joiner) {
      throw CoworkPairingException(
        CoworkPairingRejection.wrongState,
        'joiner only',
      );
    }
    _require(CoworkPairingState.created);
    if (msg['type'] != 'commit') {
      throw CoworkPairingException(
        CoworkPairingRejection.malformed,
        'expected commit',
      );
    }
    if (msg['channel_id'] != _channelId) {
      throw CoworkPairingException(CoworkPairingRejection.channelMismatch);
    }
    final received = _decodeBytes(msg['commitment'], 'commitment');
    if (received.length != CoworkPairingCrypto.commitmentLength) {
      throw CoworkPairingException(
        CoworkPairingRejection.malformed,
        'commitment length',
      );
    }
    final expiresAt = msg['expires_at'];
    if (expiresAt is! int) {
      throw CoworkPairingException(
        CoworkPairingRejection.malformed,
        'expires_at',
      );
    }
    _expiresAtMs = expiresAt;
    _checkNotExpired();
    _commitment = received;
    _state = CoworkPairingState.commitReceived;
  }

  /// [joiner] Send ephemeral `B`.
  Map<String, dynamic> createPubkey() {
    if (_role != CoworkPairingRole.joiner) {
      throw CoworkPairingException(
        CoworkPairingRejection.wrongState,
        'joiner only',
      );
    }
    _require(CoworkPairingState.commitReceived);
    _checkNotExpired();
    _state = CoworkPairingState.pubkeySent;
    return <String, dynamic>{
      'type': 'pubkey',
      'pubkey': base64.encode(_ephemeralPublic),
    };
  }

  /// [joiner] Receive `A`, check `H(A) == commitment` (constant-time), derive
  /// `K` + SAS, and send `MAC_d`.
  Future<Map<String, dynamic>> onReveal(Map<String, dynamic> msg) async {
    if (_role != CoworkPairingRole.joiner) {
      throw CoworkPairingException(
        CoworkPairingRejection.wrongState,
        'joiner only',
      );
    }
    _require(CoworkPairingState.pubkeySent);
    _checkNotExpired();
    if (msg['type'] != 'reveal') {
      throw CoworkPairingException(
        CoworkPairingRejection.malformed,
        'expected reveal',
      );
    }
    final peerA = _decodeKey(msg['pubkey'], 'pubkey');
    if (!CoworkPairingCrypto.constantTimeEquals(
      CoworkPairingCrypto.commitment(peerA),
      _commitment!,
    )) {
      _abort();
      throw CoworkPairingException(CoworkPairingRejection.commitmentMismatch);
    }
    _peerPublic = peerA;
    await _establishKey(publicA: peerA, publicB: _ephemeralPublic);
    _state = CoworkPairingState.keyEstablished;
    final mac = await CoworkPairingCrypto.deriveConfirmMac(
      _kRaw!,
      CoworkPairingCrypto.confirmDLabel,
      _currentTranscript(),
      _pairingCode,
    );
    return <String, dynamic>{'type': 'confirm-d', 'mac': base64.encode(mac)};
  }

  /// [joiner] Verify the initiator's `MAC_c` (constant-time).
  Future<void> onConfirmC(Map<String, dynamic> msg) async {
    if (_role != CoworkPairingRole.joiner) {
      throw CoworkPairingException(
        CoworkPairingRejection.wrongState,
        'joiner only',
      );
    }
    _require(CoworkPairingState.keyEstablished);
    _checkNotExpired();
    if (msg['type'] != 'confirm-c') {
      throw CoworkPairingException(
        CoworkPairingRejection.malformed,
        'expected confirm-c',
      );
    }
    await _verifyConfirm(msg, CoworkPairingCrypto.confirmCLabel);
    _state = CoworkPairingState.confirmed;
  }

  // --- shared: SAS out-of-band comparison ------------------------------------

  /// **Optional** constant-time compare of the peer's SAS with ours, for UIs
  /// that want to display a matching short string for reassurance. It is not
  /// required for security and not part of the happy path: the confirmation
  /// MACs already fold `PC` in, so a wrong code or a relaying MITM is caught
  /// there and aborts before this is ever called.
  void confirmPeerSas(String peerSas) {
    final ours = _sas;
    if (ours == null) {
      throw CoworkPairingException(
        CoworkPairingRejection.wrongState,
        'SAS not derived yet',
      );
    }
    if (!CoworkPairingCrypto.constantTimeEquals(
      utf8.encode(peerSas),
      utf8.encode(ours),
    )) {
      _abort();
      throw CoworkPairingException(CoworkPairingRejection.sasMismatch);
    }
  }

  // --- shared: device-key approval exchange ----------------------------------

  /// Reveal our own Ed25519 device public key, authenticated under `K`.
  /// Callable once the confirmation MACs verified ([CoworkPairingState.confirmed]).
  Future<Map<String, dynamic>> createDeviceKey() async {
    _require(CoworkPairingState.confirmed);
    _checkNotExpired();
    if (_sentDeviceKey) {
      throw CoworkPairingException(
        CoworkPairingRejection.wrongState,
        'device key already sent',
      );
    }
    _sentDeviceKey = true;
    final t = _currentTranscript();
    final edPub = _devicePublicKey.bytes;
    final label = _role == CoworkPairingRole.joiner
        ? CoworkPairingCrypto.deviceDLabel
        : CoworkPairingCrypto.deviceCLabel;
    final signature = await CoworkPairingCrypto.ed25519.sign(
      CoworkPairingCrypto.deviceProofMessage(t, _deviceId),
      keyPair: _deviceKeyPair,
    );
    final mac = await CoworkPairingCrypto.deviceMac(
      _kRaw!,
      label,
      t,
      edPub,
      _deviceId,
      _pairingCode,
    );
    final result = <String, dynamic>{
      'type': 'device-key',
      'device_id': _deviceId,
      'ed25519_pub': base64.encode(edPub),
      'proof': base64.encode(signature.bytes),
      'mac': base64.encode(mac),
    };
    _maybeComplete();
    return result;
  }

  /// Verify the peer's device-key message under `K` and its self-signature,
  /// then locally approve it (§8 default-deny). Completes the session once both
  /// directions of the exchange are done.
  Future<void> onPeerDeviceKey(Map<String, dynamic> msg) async {
    _require(CoworkPairingState.confirmed);
    _checkNotExpired();
    if (msg['type'] != 'device-key') {
      throw CoworkPairingException(
        CoworkPairingRejection.malformed,
        'expected device-key',
      );
    }
    final peerDeviceId = msg['device_id'];
    if (peerDeviceId is! String || peerDeviceId.isEmpty) {
      throw CoworkPairingException(
        CoworkPairingRejection.malformed,
        'device_id',
      );
    }
    final edPubRaw = _decodeBytes(msg['ed25519_pub'], 'ed25519_pub');
    if (edPubRaw.length != CoworkDeviceKeys.publicKeyLength) {
      throw CoworkPairingException(
        CoworkPairingRejection.malformed,
        'ed25519_pub length',
      );
    }
    final proof = _decodeBytes(msg['proof'], 'proof');
    final mac = _decodeBytes(msg['mac'], 'mac');

    final t = _currentTranscript();
    // The peer's role is the opposite of ours, so its label is too.
    final label = _role == CoworkPairingRole.joiner
        ? CoworkPairingCrypto.deviceCLabel
        : CoworkPairingCrypto.deviceDLabel;
    final expectedMac = await CoworkPairingCrypto.deviceMac(
      _kRaw!,
      label,
      t,
      edPubRaw,
      peerDeviceId,
      _pairingCode,
    );
    if (!CoworkPairingCrypto.constantTimeEquals(mac, expectedMac)) {
      _abort();
      throw CoworkPairingException(CoworkPairingRejection.macMismatch);
    }

    final peerEd = SimplePublicKey(edPubRaw, type: KeyPairType.ed25519);
    final validSignature = await CoworkPairingCrypto.ed25519.verify(
      CoworkPairingCrypto.deviceProofMessage(t, peerDeviceId),
      signature: Signature(proof, publicKey: peerEd),
    );
    if (!validSignature) {
      _abort();
      throw CoworkPairingException(CoworkPairingRejection.badDeviceProof);
    }

    _approved.approve(peerDeviceId, peerEd);
    _peerDeviceId = peerDeviceId;
    _approvedPeer = true;
    _maybeComplete();
  }

  void _maybeComplete() {
    if (_sentDeviceKey && _approvedPeer) {
      _state = CoworkPairingState.completed;
    }
  }

  // --- internals -------------------------------------------------------------

  List<int> _currentTranscript() {
    final peer = _peerPublic!;
    return _role == CoworkPairingRole.initiator
        ? CoworkPairingCrypto.transcript(_ephemeralPublic, peer)
        : CoworkPairingCrypto.transcript(peer, _ephemeralPublic);
  }

  Future<void> _establishKey({
    required List<int> publicA,
    required List<int> publicB,
  }) async {
    final peerPublic = SimplePublicKey(
      _peerPublic!,
      type: KeyPairType.x25519,
    );
    final shared = await CoworkPairingCrypto.x25519.sharedSecretKey(
      keyPair: _ephemeralKeyPair,
      remotePublicKey: peerPublic,
    );
    final kRaw = await shared.extractBytes();
    _kRaw = kRaw;
    _channelKey = await CoworkPairingCrypto.deriveChannelKey(kRaw);
    final t = CoworkPairingCrypto.transcript(publicA, publicB);
    _sas = await CoworkPairingCrypto.deriveSas(kRaw, t, _pairingCode, _sasDigits);
  }

  Future<void> _verifyConfirm(Map<String, dynamic> msg, String label) async {
    final mac = _decodeBytes(msg['mac'], 'mac');
    final expected = await CoworkPairingCrypto.deriveConfirmMac(
      _kRaw!,
      label,
      _currentTranscript(),
      _pairingCode,
    );
    if (!CoworkPairingCrypto.constantTimeEquals(mac, expected)) {
      _abort();
      throw CoworkPairingException(CoworkPairingRejection.macMismatch);
    }
  }

  List<int> _decodeKey(Object? value, String field) {
    final raw = _decodeBytes(value, field);
    if (raw.length != CoworkPairingCrypto.x25519PublicLength) {
      throw CoworkPairingException(
        CoworkPairingRejection.malformed,
        '$field length',
      );
    }
    return raw;
  }

  static List<int> _decodeBytes(Object? value, String field) {
    if (value is! String) {
      throw CoworkPairingException(
        CoworkPairingRejection.malformed,
        '$field missing or not a string',
      );
    }
    try {
      return base64.decode(value);
    } on FormatException {
      throw CoworkPairingException(
        CoworkPairingRejection.malformed,
        '$field is not valid base64',
      );
    }
  }
}

int _wallClock() => DateTime.now().millisecondsSinceEpoch;

String _randomChannelId() {
  // 8 bytes of hex, no '-', from the secure RNG the cryptography package uses.
  final rnd = SecretKeyData.random(length: 8).bytes;
  return rnd.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

String _randomDigits(int n) {
  // Rejection sampling for an unbiased 0-9 draw (bytes 250-255 would bias the
  // low digits under a plain `% 10`), matching Python's `secrets.randbelow(10)`.
  final out = StringBuffer();
  while (out.length < n) {
    for (final b in SecretKeyData.random(length: n).bytes) {
      if (b >= 250) continue;
      out.write(b % 10);
      if (out.length == n) break;
    }
  }
  return out.toString();
}

bool _isAllDigits(String s) {
  if (s.isEmpty) return false;
  for (final unit in s.codeUnits) {
    if (unit < 0x30 || unit > 0x39) return false;
  }
  return true;
}
