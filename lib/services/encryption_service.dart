// lib/services/encryption_service.dart
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:flutter_dotenv/flutter_dotenv.dart';

class EncryptionService {
  EncryptionService._();

  static Uint8List _deriveKey(String email) {
    final secret = dotenv.env['ENCRYPTION_SECRET'];
    if (secret == null || secret.isEmpty) {
      throw const FormatException('Missing ENCRYPTION_SECRET env variable.');
    }
    final raw = utf8.encode('$email|$secret');
    final digest = sha256.convert(raw);
    return Uint8List.fromList(digest.bytes);
  }

  static encrypt.Encrypter _createEncrypter(String email) {
    final key = encrypt.Key(_deriveKey(email));
    return encrypt.Encrypter(encrypt.AES(key, mode: encrypt.AESMode.cbc));
  }

  static String encryptForUser({required String email, required String plaintext}) {
    final encrypter = _createEncrypter(email);
    final iv = encrypt.IV.fromSecureRandom(16);
    final encrypted = encrypter.encrypt(plaintext, iv: iv);
    final payload = jsonEncode({
      'iv': base64Encode(iv.bytes),
      'ciphertext': encrypted.base64,
    });
    return payload;
  }

  static String decryptForUser({required String email, required String payload}) {
    final decoded = jsonDecode(payload) as Map<String, dynamic>;
    final iv = encrypt.IV(base64Decode(decoded['iv'] as String));
    final ciphertext = decoded['ciphertext'] as String;
    final encrypter = _createEncrypter(email);
    final decrypted = encrypter.decrypt64(ciphertext, iv: iv);
    return decrypted;
  }
}
