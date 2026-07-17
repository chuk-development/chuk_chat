/// CoWork wire frame: `{seq, ts, nonce, ciphertext, sig}`.
///
/// Every byte that crosses `api.chuk.chat` between a phone (controller) and a
/// laptop (executor) is wrapped in one of these. The relay is a **blind**
/// store-and-forward hop: it matches `device_id` to a socket and forwards the
/// blob verbatim. It can drop, delay or reorder frames; it can never read,
/// forge or replay one.
///
/// Layered defences, in the order `CoworkFrameOpener` applies them:
///  1. `sig` — per-device Ed25519 over `(header, nonce, ciphertext)`, checked
///     *before* decryption as a cheap fail-closed gate.
///  2. `seq` + `ts` — strictly monotonic sequence inside a freshness window,
///     so a captured frame cannot be re-sent.
///  3. `ciphertext` — AES-256-GCM under the account key, with the header as
///     additional authenticated data so a ciphertext cannot be transplanted
///     onto a different `(seq, ts, device_id, kv)`.
library;

import 'dart:convert';
import 'dart:typed_data';

/// Wire format version. Bump only for a breaking change to the frame layout.
const String kCoworkFrameVersion = '1';

/// AES-GCM nonce length in bytes.
const int kCoworkFrameNonceLength = 12;

/// Ed25519 signature length in bytes.
const int kCoworkFrameSignatureLength = 64;

/// AES-GCM authentication tag length in bytes, appended to [CoworkFrame.ciphertext].
const int kCoworkFrameMacLength = 16;

/// Domain separator mixed into every signature and AAD, so a CoWork signature
/// can never be replayed as a signature for some other chuk_chat protocol.
const String _kDomain = 'chuk.cowork.frame';

/// Why a frame was refused.
///
/// Every value is a hard reject: the payload never reaches the executor.
enum CoworkFrameRejection {
  /// Structurally invalid — missing field, wrong type, bad base64, bad length.
  malformed,

  /// `v` is not a frame version this build speaks.
  unsupportedVersion,

  /// `device_id` is not in this device's **local** approved set.
  ///
  /// The Supabase `cowork_devices` row is a UX convenience and a first-line
  /// filter; it is not end-to-end encrypted, so a compromised server can flip
  /// an approval flag at will. This rejection is the real boundary: the
  /// executor trusts only keys it recorded locally itself.
  deviceNotApproved,

  /// Ed25519 verification failed: forged, tampered, or signed by another device.
  badSignature,

  /// `kv` names an account key version this receiver does not hold.
  ///
  /// Not an attack vector on its own — `kv` is signed and bound into the AEAD,
  /// so only the peer itself can set it — but an authenticated field that is
  /// read and never checked is a trap. Today exactly one key version is held,
  /// so a mismatch means the two devices have drifted across a password
  /// rotation; rejecting here says so plainly instead of surfacing as a
  /// confusing [decryptionFailed].
  keyVersionMismatch,

  /// `ts` is outside the freshness window — stale replay or bad clock.
  timestampOutOfWindow,

  /// `seq` is not greater than the highest already accepted from this device.
  replayedSequence,

  /// AES-GCM authentication failed — wrong key, wrong header, or mangled bytes.
  decryptionFailed,
}

/// Thrown whenever a frame is refused. Carries a machine-readable [rejection]
/// so callers can count and audit rejects without parsing strings.
class CoworkFrameRejectedException implements Exception {
  const CoworkFrameRejectedException(this.rejection, [this.detail]);

  final CoworkFrameRejection rejection;

  /// Short, non-sensitive context. Never contains plaintext, keys or nonces.
  final String? detail;

  @override
  String toString() => detail == null
      ? 'CoworkFrameRejectedException(${rejection.name})'
      : 'CoworkFrameRejectedException(${rejection.name}: $detail)';
}

/// A sealed CoWork frame, as it travels over the relay.
class CoworkFrame {
  CoworkFrame({
    required this.deviceId,
    required this.seq,
    required this.ts,
    required this.nonce,
    required this.ciphertext,
    required this.sig,
    this.version = kCoworkFrameVersion,
    this.keyVersion = 1,
  });

  /// Frame format version (`v`).
  final String version;

  /// Account key version (`kv`) the [ciphertext] was sealed under — mirrors
  /// `EncryptionService.currentKeyVersion`, so a password rotation is legible
  /// without trial decryption.
  final int keyVersion;

  /// The signing device. The receiver checks this against its paired peer
  /// before spending a signature verification on the frame.
  final String deviceId;

  /// Strictly monotonic per sending device. `seq <= lastSeen` is dropped.
  final int seq;

  /// Milliseconds since the Unix epoch, UTC.
  final int ts;

  /// AES-GCM nonce, [kCoworkFrameNonceLength] random bytes, unique per frame.
  final Uint8List nonce;

  /// AES-GCM output: cipher text followed by the [kCoworkFrameMacLength]-byte tag.
  final Uint8List ciphertext;

  /// Ed25519 signature over [signedBytes].
  final Uint8List sig;

  /// The authenticated header: everything about the frame except the payload.
  ///
  /// Used verbatim as AES-GCM additional authenticated data, and as the prefix
  /// of [signedBytes]. Every field is length-prefixed, so no two distinct
  /// headers can ever serialise to the same bytes.
  Uint8List get headerBytes => buildHeaderBytes(
    version: version,
    keyVersion: keyVersion,
    deviceId: deviceId,
    seq: seq,
    ts: ts,
  );

  /// Exactly what the Ed25519 signature covers: header, nonce and ciphertext.
  Uint8List get signedBytes => buildSignedBytes(
    header: headerBytes,
    nonce: nonce,
    ciphertext: ciphertext,
  );

  static Uint8List buildHeaderBytes({
    required String version,
    required int keyVersion,
    required String deviceId,
    required int seq,
    required int ts,
  }) {
    final builder = BytesBuilder(copy: false);
    _addField(builder, utf8.encode(_kDomain));
    _addField(builder, utf8.encode(version));
    _addField(builder, utf8.encode('$keyVersion'));
    _addField(builder, utf8.encode(deviceId));
    _addField(builder, utf8.encode('$seq'));
    _addField(builder, utf8.encode('$ts'));
    return builder.toBytes();
  }

  static Uint8List buildSignedBytes({
    required Uint8List header,
    required Uint8List nonce,
    required Uint8List ciphertext,
  }) {
    final builder = BytesBuilder(copy: false);
    builder.add(header);
    _addField(builder, nonce);
    _addField(builder, ciphertext);
    return builder.toBytes();
  }

  /// Length-prefixed append: 4-byte big-endian length, then the bytes.
  ///
  /// `seq`/`ts` are written as their decimal text rather than a fixed 64-bit
  /// integer because `ByteData.setUint64` is unsupported on the web, and `ts`
  /// in milliseconds does not fit in 32 bits.
  static void _addField(BytesBuilder builder, List<int> value) {
    final length = ByteData(4)..setUint32(0, value.length);
    builder.add(length.buffer.asUint8List());
    builder.add(value);
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'v': version,
    'kv': keyVersion,
    'device_id': deviceId,
    'seq': seq,
    'ts': ts,
    'nonce': base64Encode(nonce),
    'ciphertext': base64Encode(ciphertext),
    'sig': base64Encode(sig),
  };

  String toJsonString() => jsonEncode(toJson());

  /// Parses a frame off the wire.
  ///
  /// Strict by construction: anything a relay or attacker could hand us that is
  /// not a well-formed frame throws [CoworkFrameRejection.malformed] rather
  /// than reaching the cryptographic layer with a surprising shape.
  factory CoworkFrame.fromJson(Map<String, dynamic> json) {
    final version = json['v'];
    if (version is! String || version.isEmpty) {
      throw const CoworkFrameRejectedException(
        CoworkFrameRejection.malformed,
        'v missing or not a string',
      );
    }
    if (version != kCoworkFrameVersion) {
      throw const CoworkFrameRejectedException(
        CoworkFrameRejection.unsupportedVersion,
      );
    }

    final keyVersion = json['kv'];
    if (keyVersion is! int || keyVersion < 1) {
      throw const CoworkFrameRejectedException(
        CoworkFrameRejection.malformed,
        'kv missing or not a positive int',
      );
    }

    final deviceId = json['device_id'];
    if (deviceId is! String || deviceId.isEmpty) {
      throw const CoworkFrameRejectedException(
        CoworkFrameRejection.malformed,
        'device_id missing or not a string',
      );
    }

    final seq = json['seq'];
    if (seq is! int || seq < 0) {
      throw const CoworkFrameRejectedException(
        CoworkFrameRejection.malformed,
        'seq missing or not a non-negative int',
      );
    }

    final ts = json['ts'];
    if (ts is! int) {
      throw const CoworkFrameRejectedException(
        CoworkFrameRejection.malformed,
        'ts missing or not an int',
      );
    }

    final nonce = _decodeBase64(json['nonce'], 'nonce');
    if (nonce.length != kCoworkFrameNonceLength) {
      throw const CoworkFrameRejectedException(
        CoworkFrameRejection.malformed,
        'nonce length',
      );
    }

    final ciphertext = _decodeBase64(json['ciphertext'], 'ciphertext');
    if (ciphertext.length < kCoworkFrameMacLength) {
      throw const CoworkFrameRejectedException(
        CoworkFrameRejection.malformed,
        'ciphertext shorter than the GCM tag',
      );
    }

    final sig = _decodeBase64(json['sig'], 'sig');
    if (sig.length != kCoworkFrameSignatureLength) {
      throw const CoworkFrameRejectedException(
        CoworkFrameRejection.malformed,
        'sig length',
      );
    }

    return CoworkFrame(
      version: version,
      keyVersion: keyVersion,
      deviceId: deviceId,
      seq: seq,
      ts: ts,
      nonce: nonce,
      ciphertext: ciphertext,
      sig: sig,
    );
  }

  /// Parses a frame from its JSON text. Invalid JSON is
  /// [CoworkFrameRejection.malformed], not a [FormatException] escaping into
  /// the relay read loop.
  factory CoworkFrame.fromJsonString(String source) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      throw const CoworkFrameRejectedException(
        CoworkFrameRejection.malformed,
        'not valid JSON',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw const CoworkFrameRejectedException(
        CoworkFrameRejection.malformed,
        'not a JSON object',
      );
    }
    return CoworkFrame.fromJson(decoded);
  }

  static Uint8List _decodeBase64(Object? value, String field) {
    if (value is! String) {
      throw CoworkFrameRejectedException(
        CoworkFrameRejection.malformed,
        '$field missing or not a string',
      );
    }
    try {
      return base64Decode(value);
    } on FormatException {
      throw CoworkFrameRejectedException(
        CoworkFrameRejection.malformed,
        '$field is not valid base64',
      );
    }
  }
}
