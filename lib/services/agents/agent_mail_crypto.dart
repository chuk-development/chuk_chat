/// The seal format `chuk-agent-mail-v1` (docs/AGENT_MAIL.md §3.2).
///
/// The server seals every content field of a mail to the user's mail key, an
/// X25519 key pair the app makes. Only the app and the user's host hold the
/// private key, so only they can open what the server stores.
///
/// Sealing to a public key `R`:
///
///  1. a new ephemeral X25519 pair `e`, `E`;
///  2. `shared = X25519(e, R)`;
///  3. `key = HKDF-SHA256(shared, salt = E ‖ R, info = "chuk-agent-mail-v1")`;
///  4. `ct = AES-256-GCM(key, nonce, plaintext, aad = "chuk-agent-mail-v1")`,
///     the 16-byte tag at the end.
///
/// The text form is `{"v":1,"epk":b64(E),"n":b64(nonce),"ct":b64(ct)}`; the
/// binary form (attachments) is `"CAM1" ‖ E ‖ nonce ‖ ct`.
///
/// Nothing here logs, and no error message carries key or content bytes.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// The HKDF `info` and the AES-GCM `aad` of every seal.
const String kAgentMailSealLabel = 'chuk-agent-mail-v1';

/// The magic prefix of the binary form.
const List<int> kAgentMailBinaryMagic = <int>[0x43, 0x41, 0x4d, 0x31]; // CAM1

const int _keyLength = 32;
const int _nonceLength = 12;
const int _tagLength = 16;

final X25519 _x25519 = X25519();
final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
final AesGcm _aes = AesGcm.with256bits();
final List<int> _label = utf8.encode(kAgentMailSealLabel);

/// A seal that could not be opened: bad shape, wrong key, or tampered bytes.
/// The message names the step, never the bytes.
class AgentMailSealException implements Exception {
  const AgentMailSealException(this.reason);

  final String reason;

  @override
  String toString() => 'AgentMailSealException: $reason';
}

/// The user's mail key: the raw 32-byte X25519 private and public key.
class AgentMailKeyPair {
  AgentMailKeyPair({
    required List<int> privateKey,
    required List<int> publicKey,
  }) : privateKey = Uint8List.fromList(privateKey),
       publicKey = Uint8List.fromList(publicKey) {
    if (this.privateKey.length != _keyLength ||
        this.publicKey.length != _keyLength) {
      throw const AgentMailSealException('key length');
    }
  }

  final Uint8List privateKey;
  final Uint8List publicKey;

  String get publicKeyBase64 => base64Encode(publicKey);
  String get privateKeyBase64 => base64Encode(privateKey);

  /// A new random key pair.
  static Future<AgentMailKeyPair> generate() async =>
      _fromKeyPair(await _x25519.newKeyPair());

  /// The pair of a known raw private key (the public key is derived).
  static Future<AgentMailKeyPair> fromPrivateKey(List<int> privateKey) async {
    if (privateKey.length != _keyLength) {
      throw const AgentMailSealException('key length');
    }
    return _fromKeyPair(await _x25519.newKeyPairFromSeed(privateKey));
  }

  static Future<AgentMailKeyPair> _fromKeyPair(SimpleKeyPair pair) async {
    final SimpleKeyPairData data = await pair.extract();
    return AgentMailKeyPair(
      privateKey: data.bytes,
      publicKey: data.publicKey.bytes,
    );
  }

  /// True when [other] is the same key.
  bool sameAs(AgentMailKeyPair other) =>
      _equal(privateKey, other.privateKey) &&
      _equal(publicKey, other.publicKey);

  static bool _equal(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    int diff = 0;
    for (int i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}

Future<SecretKey> _messageKey({
  required SimpleKeyPair ephemeralOrRecipient,
  required List<int> remotePublicKey,
  required List<int> ephemeralPublic,
  required List<int> recipientPublic,
}) async {
  final SecretKey shared = await _x25519.sharedSecretKey(
    keyPair: ephemeralOrRecipient,
    remotePublicKey: SimplePublicKey(remotePublicKey, type: KeyPairType.x25519),
  );
  return _hkdf.deriveKey(
    secretKey: shared,
    nonce: <int>[...ephemeralPublic, ...recipientPublic],
    info: _label,
  );
}

/// The parts of one seal: `E`, the nonce, and `ct ‖ tag`.
typedef _Sealed = ({Uint8List epk, Uint8List nonce, Uint8List ct});

Future<_Sealed> _seal(
  List<int> plaintext,
  List<int> recipientPublicKey, {
  List<int>? ephemeralPrivateKey,
  List<int>? nonce,
}) async {
  if (recipientPublicKey.length != _keyLength) {
    throw const AgentMailSealException('key length');
  }
  final SimpleKeyPair ephemeral = ephemeralPrivateKey == null
      ? await _x25519.newKeyPair()
      : await _x25519.newKeyPairFromSeed(ephemeralPrivateKey);
  final List<int> epk = (await ephemeral.extractPublicKey()).bytes;
  final SecretKey key = await _messageKey(
    ephemeralOrRecipient: ephemeral,
    remotePublicKey: recipientPublicKey,
    ephemeralPublic: epk,
    recipientPublic: recipientPublicKey,
  );
  final SecretBox box = await _aes.encrypt(
    plaintext,
    secretKey: key,
    nonce: nonce ?? _aes.newNonce(),
    aad: _label,
  );
  if (box.nonce.length != _nonceLength) {
    throw const AgentMailSealException('nonce length');
  }
  return (
    epk: Uint8List.fromList(epk),
    nonce: Uint8List.fromList(box.nonce),
    ct: Uint8List.fromList(<int>[...box.cipherText, ...box.mac.bytes]),
  );
}

Future<Uint8List> _open(
  List<int> epk,
  List<int> nonce,
  List<int> ct,
  AgentMailKeyPair key,
) async {
  if (epk.length != _keyLength) {
    throw const AgentMailSealException('ephemeral key length');
  }
  if (nonce.length != _nonceLength) {
    throw const AgentMailSealException('nonce length');
  }
  if (ct.length < _tagLength) {
    throw const AgentMailSealException('ciphertext length');
  }
  final SimpleKeyPair recipient = SimpleKeyPairData(
    key.privateKey,
    publicKey: SimplePublicKey(key.publicKey, type: KeyPairType.x25519),
    type: KeyPairType.x25519,
  );
  final SecretKey secret = await _messageKey(
    ephemeralOrRecipient: recipient,
    remotePublicKey: epk,
    ephemeralPublic: epk,
    recipientPublic: key.publicKey,
  );
  final int split = ct.length - _tagLength;
  try {
    return Uint8List.fromList(
      await _aes.decrypt(
        SecretBox(
          ct.sublist(0, split),
          nonce: nonce,
          mac: Mac(ct.sublist(split)),
        ),
        secretKey: secret,
        aad: _label,
      ),
    );
  } on SecretBoxAuthenticationError {
    throw const AgentMailSealException('authentication failed');
  }
}

/// Seals [plaintext] (UTF-8) to [recipientPublicKey] in the text form.
///
/// [ephemeralPrivateKey] and [nonce] are for the test vector only; leave them
/// null, and both are fresh random values.
Future<String> sealAgentMailText(
  String plaintext,
  List<int> recipientPublicKey, {
  List<int>? ephemeralPrivateKey,
  List<int>? nonce,
}) async {
  final _Sealed s = await _seal(
    utf8.encode(plaintext),
    recipientPublicKey,
    ephemeralPrivateKey: ephemeralPrivateKey,
    nonce: nonce,
  );
  return jsonEncode(<String, Object>{
    'v': 1,
    'epk': base64Encode(s.epk),
    'n': base64Encode(s.nonce),
    'ct': base64Encode(s.ct),
  });
}

/// Seals [plaintext] to [recipientPublicKey] in the binary form.
Future<Uint8List> sealAgentMailBytes(
  List<int> plaintext,
  List<int> recipientPublicKey, {
  List<int>? ephemeralPrivateKey,
  List<int>? nonce,
}) async {
  final _Sealed s = await _seal(
    plaintext,
    recipientPublicKey,
    ephemeralPrivateKey: ephemeralPrivateKey,
    nonce: nonce,
  );
  return Uint8List.fromList(<int>[
    ...kAgentMailBinaryMagic,
    ...s.epk,
    ...s.nonce,
    ...s.ct,
  ]);
}

/// Opens a text-form seal. [envelope] is the JSON object as the server sends
/// it in a field, or the same object as a JSON string.
Future<String> unsealAgentMailText(
  Object? envelope,
  AgentMailKeyPair key,
) async {
  Object? value = envelope;
  if (value is String) {
    try {
      value = jsonDecode(value);
    } on FormatException {
      throw const AgentMailSealException('envelope is not JSON');
    }
  }
  if (value is! Map) throw const AgentMailSealException('no envelope');
  if (value['v'] != 1) throw const AgentMailSealException('unknown version');
  final Object? epk = value['epk'];
  final Object? n = value['n'];
  final Object? ct = value['ct'];
  if (epk is! String || n is! String || ct is! String) {
    throw const AgentMailSealException('envelope fields');
  }
  final List<int> plain;
  try {
    plain = await _open(
      base64Decode(epk),
      base64Decode(n),
      base64Decode(ct),
      key,
    );
  } on FormatException {
    throw const AgentMailSealException('envelope base64');
  }
  try {
    return utf8.decode(plain);
  } on FormatException {
    throw const AgentMailSealException('plaintext is not UTF-8');
  }
}

/// Opens a text-form seal whose plaintext is a JSON object.
Future<Map<String, dynamic>> unsealAgentMailJson(
  Object? envelope,
  AgentMailKeyPair key,
) async {
  final String text = await unsealAgentMailText(envelope, key);
  final Object? data;
  try {
    data = jsonDecode(text);
  } on FormatException {
    throw const AgentMailSealException('document is not JSON');
  }
  if (data is! Map<String, dynamic>) {
    throw const AgentMailSealException('document is not an object');
  }
  return data;
}

/// Opens a binary-form seal (an attachment object).
Future<Uint8List> unsealAgentMailBytes(
  List<int> blob,
  AgentMailKeyPair key,
) async {
  const int head = 4 + _keyLength + _nonceLength;
  if (blob.length < head + _tagLength) {
    throw const AgentMailSealException('object too short');
  }
  for (int i = 0; i < kAgentMailBinaryMagic.length; i++) {
    if (blob[i] != kAgentMailBinaryMagic[i]) {
      throw const AgentMailSealException('not a sealed object');
    }
  }
  return _open(
    blob.sublist(4, 4 + _keyLength),
    blob.sublist(4 + _keyLength, head),
    blob.sublist(head),
    key,
  );
}
