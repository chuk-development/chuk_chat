import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

/// The math of device pairing, shared by the device (MCP, chuk_chat) and the
/// approving app so both sides run one implementation.
///
/// * Pairing code: the first 50 bits of SHA-256(device public key) in
///   Crockford base32, shown as `XXXXX-XXXXX`. A server that swaps the key
///   would have to grind 50 bits to keep the code the user typed valid.
/// * Seal: ephemeral X25519 -> HKDF-SHA256 -> AES-256-GCM.
class PairingCrypto {
  const PairingCrypto._();

  /// HKDF info and AES-GCM associated data of the sealed box.
  static const String sealInfo = 'chukdoo-pairing-v1';

  /// Crockford base32 alphabet (no I, L, O, U).
  static const String _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

  /// Number of characters in a normalized code (50 bits / 5).
  static const int codeLength = 10;

  static final Random _rng = Random.secure();

  /// SHA-256 as lowercase hex, matching `encode(sha256(..), 'hex')` in SQL.
  static String sha256Hex(String value) =>
      _hex(const DartSha256().hashSync(utf8.encode(value)).bytes);

  /// The normalized 10-character code for a public key.
  static String codeForPublicKey(List<int> publicKey) {
    final digest = const DartSha256().hashSync(publicKey).bytes;
    // 56 bits from the first 7 bytes, keep the top 50.
    var bits = BigInt.zero;
    for (var i = 0; i < 7; i++) {
      bits = (bits << 8) | BigInt.from(digest[i]);
    }
    bits = bits >> 6;
    final out = StringBuffer();
    for (var i = codeLength - 1; i >= 0; i--) {
      final index = ((bits >> (i * 5)) & BigInt.from(31)).toInt();
      out.write(_alphabet[index]);
    }
    return out.toString();
  }

  /// `ABCDE-FGHJK` for display.
  static String formatCode(String code) {
    final n = normalizeCode(code) ?? code;
    if (n.length != codeLength) return n;
    return '${n.substring(0, 5)}-${n.substring(5)}';
  }

  /// Uppercases, drops separators and maps the look-alikes O->0, I/L->1.
  /// Returns null if the result is not a valid 10-character code.
  static String? normalizeCode(String input) {
    final buf = StringBuffer();
    for (final rune in input.toUpperCase().runes) {
      var ch = String.fromCharCode(rune);
      if (ch == ' ' || ch == '-' || ch == '_' || ch == '\t') continue;
      if (ch == 'O') ch = '0';
      if (ch == 'I' || ch == 'L') ch = '1';
      if (!_alphabet.contains(ch)) return null;
      buf.write(ch);
    }
    final s = buf.toString();
    return s.length == codeLength ? s : null;
  }

  /// The value the server stores and looks up: sha256(normalized code).
  static String codeHash(String code) {
    final n = normalizeCode(code);
    if (n == null) throw FormatException('Invalid pairing code: $code');
    return sha256Hex(n);
  }

  /// True if [code] (as typed) belongs to [publicKey]. The app must check
  /// this before it seals anything to that key.
  static bool codeMatchesPublicKey(String code, List<int> publicKey) {
    final n = normalizeCode(code);
    if (n == null) return false;
    return _constantTimeEquals(
      utf8.encode(n),
      utf8.encode(codeForPublicKey(publicKey)),
    );
  }

  /// A fresh X25519 key pair for a device.
  static Future<SimpleKeyPair> newKeyPair() => X25519().newKeyPair();

  /// Rebuilds a key pair from its 32-byte private seed.
  static Future<SimpleKeyPair> keyPairFromSeed(List<int> seed) =>
      X25519().newKeyPairFromSeed(seed);

  /// Random secret as hex (default 32 bytes), e.g. the poll secret.
  static String randomHex([int bytes = 32]) =>
      _hex(List<int>.generate(bytes, (_) => _rng.nextInt(256)));

  /// Seals [payload] (JSON) to the device's X25519 [recipientPublicKey].
  ///
  /// Output is a JSON string
  /// `{"v":1,"alg":"x25519-hkdf-sha256-aes256gcm","epk":b64,"nonce":b64,"ciphertext":b64,"mac":b64}`.
  static Future<String> seal(
    Map<String, dynamic> payload,
    List<int> recipientPublicKey,
  ) async {
    if (recipientPublicKey.length != 32) {
      throw ArgumentError('X25519 public key must be 32 bytes.');
    }
    final x25519 = X25519();
    final ephemeral = await x25519.newKeyPair();
    final epk = (await ephemeral.extractPublicKey()).bytes;
    final shared = await x25519.sharedSecretKey(
      keyPair: ephemeral,
      remotePublicKey: SimplePublicKey(
        recipientPublicKey,
        type: KeyPairType.x25519,
      ),
    );
    final key = await _deriveKey(shared, epk, recipientPublicKey);
    final nonce = List<int>.generate(12, (_) => _rng.nextInt(256));
    final box = await AesGcm.with256bits().encrypt(
      utf8.encode(jsonEncode(payload)),
      secretKey: key,
      nonce: nonce,
      aad: utf8.encode(sealInfo),
    );
    return jsonEncode({
      'v': 1,
      'alg': 'x25519-hkdf-sha256-aes256gcm',
      'epk': base64Encode(epk),
      'nonce': base64Encode(box.nonce),
      'ciphertext': base64Encode(box.cipherText),
      'mac': base64Encode(box.mac.bytes),
    });
  }

  /// Opens a box made by [seal] with the device's key pair.
  static Future<Map<String, dynamic>> open(
    String sealed,
    SimpleKeyPair keyPair,
  ) async {
    final box = jsonDecode(sealed) as Map<String, dynamic>;
    if (box['v'] != 1) {
      throw StateError('Unsupported sealed box version: ${box['v']}');
    }
    final epk = base64Decode(box['epk'] as String);
    final ownPublic = (await keyPair.extractPublicKey()).bytes;
    final shared = await X25519().sharedSecretKey(
      keyPair: keyPair,
      remotePublicKey: SimplePublicKey(epk, type: KeyPairType.x25519),
    );
    final key = await _deriveKey(shared, epk, ownPublic);
    final clear = await AesGcm.with256bits().decrypt(
      SecretBox(
        base64Decode(box['ciphertext'] as String),
        nonce: base64Decode(box['nonce'] as String),
        mac: Mac(base64Decode(box['mac'] as String)),
      ),
      secretKey: key,
      aad: utf8.encode(sealInfo),
    );
    return jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
  }

  /// The payload the app seals for a device.
  static Map<String, dynamic> buildKeyPayload({
    required String userId,
    required List<int> dataKey,
    DateTime? createdAt,
  }) =>
      {
        'v': 1,
        'user_id': userId,
        'data_key': base64Encode(dataKey),
        'created_at': (createdAt ?? DateTime.now().toUtc()).toIso8601String(),
      };

  static Future<SecretKey> _deriveKey(
    SecretKey shared,
    List<int> ephemeralPublic,
    List<int> recipientPublic,
  ) {
    return Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
      secretKey: shared,
      nonce: [...ephemeralPublic, ...recipientPublic],
      info: utf8.encode(sealInfo),
    );
  }

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}
