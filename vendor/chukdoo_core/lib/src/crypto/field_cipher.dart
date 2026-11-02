import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

/// Field encryption exactly like the app's `EncryptionService`.
///
/// Ciphertext is a JSON string
/// `{"v":"1","nonce":b64(12 bytes),"ciphertext":b64,"mac":b64(16 bytes)}`,
/// AES-256-GCM without associated data, standard base64 with padding.
/// The key is the account's data key (32 bytes). Legacy accounts use their
/// PBKDF2 password key as data key; for this class that is the same thing.
class FieldCipher {
  /// Version tag the app writes and insists on when decrypting.
  static const String payloadVersion = '1';

  final SecretKey _key;
  final AesGcm _cipher = AesGcm.with256bits();
  final Random _rng = Random.secure();

  FieldCipher(List<int> keyBytes) : _key = SecretKey(List<int>.of(keyBytes)) {
    if (keyBytes.length != 32) {
      throw ArgumentError('The data key must be 32 bytes, got ${keyBytes.length}.');
    }
  }

  /// Builds a cipher from the base64 data key stored in the credentials.
  factory FieldCipher.fromBase64(String keyBase64) =>
      FieldCipher(base64Decode(keyBase64));

  Future<String> encrypt(String plaintext) async {
    final nonce = List<int>.generate(12, (_) => _rng.nextInt(256));
    final box = await _cipher.encrypt(
      utf8.encode(plaintext),
      secretKey: _key,
      nonce: nonce,
    );
    return jsonEncode(<String, String>{
      'v': payloadVersion,
      'nonce': base64Encode(box.nonce),
      'ciphertext': base64Encode(box.cipherText),
      'mac': base64Encode(box.mac.bytes),
    });
  }

  Future<String> decrypt(String encrypted) async {
    final payload = jsonDecode(encrypted) as Map<String, dynamic>;
    final version = payload['v'];
    if (version != payloadVersion) {
      throw StateError('Unsupported ciphertext version: $version');
    }
    final box = SecretBox(
      base64Decode(payload['ciphertext'] as String),
      nonce: base64Decode(payload['nonce'] as String),
      mac: Mac(base64Decode(payload['mac'] as String)),
    );
    final clear = await _cipher.decrypt(box, secretKey: _key);
    return utf8.decode(clear);
  }

  Future<String> encryptJson(Map<String, dynamic> data) =>
      encrypt(jsonEncode(data));

  Future<Map<String, dynamic>> decryptJson(String encrypted) async =>
      jsonDecode(await decrypt(encrypted)) as Map<String, dynamic>;
}
