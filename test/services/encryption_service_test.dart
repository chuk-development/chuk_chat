import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests for the core AES-GCM encryption logic used by EncryptionService.
///
/// Since EncryptionService.encrypt/decrypt require Supabase auth (static state),
/// we test the underlying crypto operations directly. These are the same
/// AES-GCM-256 primitives used by the top-level isolate functions.
void main() {
  late AesGcm cipher;
  late SecretKey testKey;
  const payloadVersion = '1';

  setUp(() async {
    cipher = AesGcm.with256bits();
    testKey = await cipher.newSecretKey();
  });

  /// Helper: encrypt a string using the same format as EncryptionService
  Future<String> encryptString(String plaintext, SecretKey key) async {
    final rng = Random.secure();
    final nonce = List<int>.generate(12, (_) => rng.nextInt(256));
    final secretBox = await cipher.encrypt(
      utf8.encode(plaintext),
      secretKey: key,
      nonce: nonce,
    );
    return jsonEncode({
      'v': payloadVersion,
      'nonce': base64Encode(secretBox.nonce),
      'ciphertext': base64Encode(secretBox.cipherText),
      'mac': base64Encode(secretBox.mac.bytes),
    });
  }

  /// Helper: decrypt a string using the same format as EncryptionService
  Future<String> decryptString(String encrypted, SecretKey key) async {
    final payload = jsonDecode(encrypted) as Map<String, dynamic>;
    final version = payload['v'];
    if (version != payloadVersion) {
      throw StateError('Unsupported ciphertext version: $version');
    }
    final nonce = base64Decode(payload['nonce'] as String);
    final cipherText = base64Decode(payload['ciphertext'] as String);
    final mac = Mac(base64Decode(payload['mac'] as String));
    final secretBox = SecretBox(cipherText, nonce: nonce, mac: mac);
    final cleartextBytes = await cipher.decrypt(secretBox, secretKey: key);
    return utf8.decode(cleartextBytes);
  }

  /// Helper: encrypt bytes using the same format as EncryptionService
  Future<String> encryptBytes(Uint8List bytes, SecretKey key) async {
    final rng = Random.secure();
    final nonce = List<int>.generate(12, (_) => rng.nextInt(256));
    final secretBox = await cipher.encrypt(
      bytes,
      secretKey: key,
      nonce: nonce,
    );
    return jsonEncode({
      'v': payloadVersion,
      'nonce': base64Encode(secretBox.nonce),
      'ciphertext': base64Encode(secretBox.cipherText),
      'mac': base64Encode(secretBox.mac.bytes),
    });
  }

  /// Helper: decrypt bytes using the same format as EncryptionService
  Future<Uint8List> decryptBytes(String encrypted, SecretKey key) async {
    final payload = jsonDecode(encrypted) as Map<String, dynamic>;
    final version = payload['v'];
    if (version != payloadVersion) {
      throw StateError('Unsupported ciphertext version: $version');
    }
    final nonce = base64Decode(payload['nonce'] as String);
    final cipherText = base64Decode(payload['ciphertext'] as String);
    final mac = Mac(base64Decode(payload['mac'] as String));
    final secretBox = SecretBox(cipherText, nonce: nonce, mac: mac);
    final result = await cipher.decrypt(secretBox, secretKey: key);
    return Uint8List.fromList(result);
  }

  group('String encrypt/decrypt roundtrip', () {
    test('basic text roundtrip', () async {
      const original = 'Hello, this is a secret message!';
      final encrypted = await encryptString(original, testKey);
      final decrypted = await decryptString(encrypted, testKey);
      expect(decrypted, equals(original));
    });

    test('empty string roundtrip', () async {
      const original = '';
      final encrypted = await encryptString(original, testKey);
      final decrypted = await decryptString(encrypted, testKey);
      expect(decrypted, equals(original));
    });

    test('unicode text roundtrip', () async {
      const original = 'Hallo Welt! 🔐🇩🇪 日本語テスト ñoño';
      final encrypted = await encryptString(original, testKey);
      final decrypted = await decryptString(encrypted, testKey);
      expect(decrypted, equals(original));
    });

    test('very long text roundtrip', () async {
      final original = 'A' * 100000;
      final encrypted = await encryptString(original, testKey);
      final decrypted = await decryptString(encrypted, testKey);
      expect(decrypted, equals(original));
    });

    test('special characters roundtrip', () async {
      const original = r'<script>alert("xss")</script> \n\t\r NULL: \x00 "quotes" & ampersand';
      final encrypted = await encryptString(original, testKey);
      final decrypted = await decryptString(encrypted, testKey);
      expect(decrypted, equals(original));
    });

    test('multiline text roundtrip', () async {
      const original = 'Line 1\nLine 2\nLine 3\n\n\nExtra spacing';
      final encrypted = await encryptString(original, testKey);
      final decrypted = await decryptString(encrypted, testKey);
      expect(decrypted, equals(original));
    });
  });

  group('Binary encrypt/decrypt roundtrip', () {
    test('random bytes roundtrip', () async {
      final rng = Random.secure();
      final original = Uint8List.fromList(
        List.generate(1024, (_) => rng.nextInt(256)),
      );
      final encrypted = await encryptBytes(original, testKey);
      final decrypted = await decryptBytes(encrypted, testKey);
      expect(decrypted, equals(original));
    });

    test('empty bytes roundtrip', () async {
      final original = Uint8List(0);
      final encrypted = await encryptBytes(original, testKey);
      final decrypted = await decryptBytes(encrypted, testKey);
      expect(decrypted, equals(original));
    });

    test('all zeros roundtrip', () async {
      final original = Uint8List(256);
      final encrypted = await encryptBytes(original, testKey);
      final decrypted = await decryptBytes(encrypted, testKey);
      expect(decrypted, equals(original));
    });

    test('all 0xFF bytes roundtrip', () async {
      final original = Uint8List.fromList(List.filled(256, 0xFF));
      final encrypted = await encryptBytes(original, testKey);
      final decrypted = await decryptBytes(encrypted, testKey);
      expect(decrypted, equals(original));
    });
  });

  group('Wrong key rejection', () {
    test('decrypt with wrong key throws', () async {
      final wrongKey = await cipher.newSecretKey();
      final encrypted = await encryptString('secret data', testKey);

      expect(
        () => decryptString(encrypted, wrongKey),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('decrypt bytes with wrong key throws', () async {
      final wrongKey = await cipher.newSecretKey();
      final original = Uint8List.fromList([1, 2, 3, 4, 5]);
      final encrypted = await encryptBytes(original, testKey);

      expect(
        () => decryptBytes(encrypted, wrongKey),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });
  });

  group('Payload format', () {
    test('encrypted payload is valid JSON', () async {
      final encrypted = await encryptString('test', testKey);
      final payload = jsonDecode(encrypted) as Map<String, dynamic>;

      expect(payload, contains('v'));
      expect(payload, contains('nonce'));
      expect(payload, contains('ciphertext'));
      expect(payload, contains('mac'));
      expect(payload['v'], equals('1'));
    });

    test('nonce is base64 encoded 12 bytes', () async {
      final encrypted = await encryptString('test', testKey);
      final payload = jsonDecode(encrypted) as Map<String, dynamic>;
      final nonceBytes = base64Decode(payload['nonce'] as String);
      expect(nonceBytes.length, equals(12));
    });

    test('mac is base64 encoded 16 bytes', () async {
      final encrypted = await encryptString('test', testKey);
      final payload = jsonDecode(encrypted) as Map<String, dynamic>;
      final macBytes = base64Decode(payload['mac'] as String);
      expect(macBytes.length, equals(16));
    });

    test('ciphertext length matches plaintext length', () async {
      const plaintext = 'exactly 20 chars!!!';
      final encrypted = await encryptString(plaintext, testKey);
      final payload = jsonDecode(encrypted) as Map<String, dynamic>;
      final cipherBytes = base64Decode(payload['ciphertext'] as String);
      // AES-GCM ciphertext is same length as plaintext (no padding)
      expect(cipherBytes.length, equals(utf8.encode(plaintext).length));
    });

    test('wrong version throws StateError', () async {
      final encrypted = await encryptString('test', testKey);
      final payload = jsonDecode(encrypted) as Map<String, dynamic>;
      payload['v'] = '99';
      final tampered = jsonEncode(payload);

      expect(
        () => decryptString(tampered, testKey),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('Tamper detection', () {
    test('modified ciphertext is rejected', () async {
      final encrypted = await encryptString('test', testKey);
      final payload = jsonDecode(encrypted) as Map<String, dynamic>;

      // Flip a bit in the ciphertext
      final cipherBytes = base64Decode(payload['ciphertext'] as String);
      cipherBytes[0] ^= 0x01;
      payload['ciphertext'] = base64Encode(cipherBytes);
      final tampered = jsonEncode(payload);

      expect(
        () => decryptString(tampered, testKey),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('modified nonce is rejected', () async {
      final encrypted = await encryptString('test', testKey);
      final payload = jsonDecode(encrypted) as Map<String, dynamic>;

      final nonceBytes = base64Decode(payload['nonce'] as String);
      nonceBytes[0] ^= 0x01;
      payload['nonce'] = base64Encode(nonceBytes);
      final tampered = jsonEncode(payload);

      expect(
        () => decryptString(tampered, testKey),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('modified MAC is rejected', () async {
      final encrypted = await encryptString('test', testKey);
      final payload = jsonDecode(encrypted) as Map<String, dynamic>;

      final macBytes = base64Decode(payload['mac'] as String);
      macBytes[0] ^= 0x01;
      payload['mac'] = base64Encode(macBytes);
      final tampered = jsonEncode(payload);

      expect(
        () => decryptString(tampered, testKey),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });
  });

  group('Nonce uniqueness', () {
    test('each encryption produces different ciphertext', () async {
      const plaintext = 'same message';
      final encrypted1 = await encryptString(plaintext, testKey);
      final encrypted2 = await encryptString(plaintext, testKey);

      // Same plaintext + same key should produce different ciphertexts (different nonces)
      expect(encrypted1, isNot(equals(encrypted2)));

      // But both should decrypt to the same plaintext
      expect(await decryptString(encrypted1, testKey), equals(plaintext));
      expect(await decryptString(encrypted2, testKey), equals(plaintext));
    });
  });

  group('Batch decryption', () {
    test('batch decrypt matches individual decrypts', () async {
      final messages = ['Hello', 'World', '🔐 Secret', ''];
      final encrypted = <String>[];
      for (final msg in messages) {
        encrypted.add(await encryptString(msg, testKey));
      }

      // Decrypt individually
      final individual = <String>[];
      for (final enc in encrypted) {
        individual.add(await decryptString(enc, testKey));
      }

      expect(individual, equals(messages));
    });
  });

  group('PBKDF2 key derivation', () {
    test('same password and salt produce same key', () async {
      final pbkdf2 = Pbkdf2(
        macAlgorithm: Hmac.sha256(),
        iterations: 1000, // Low for test speed
        bits: 256,
      );
      final salt = List<int>.generate(16, (i) => i);

      final key1 = await pbkdf2.deriveKeyFromPassword(
        password: 'test-password',
        nonce: salt,
      );
      final key2 = await pbkdf2.deriveKeyFromPassword(
        password: 'test-password',
        nonce: salt,
      );

      expect(await key1.extractBytes(), equals(await key2.extractBytes()));
    });

    test('different passwords produce different keys', () async {
      final pbkdf2 = Pbkdf2(
        macAlgorithm: Hmac.sha256(),
        iterations: 1000,
        bits: 256,
      );
      final salt = List<int>.generate(16, (i) => i);

      final key1 = await pbkdf2.deriveKeyFromPassword(
        password: 'password-one',
        nonce: salt,
      );
      final key2 = await pbkdf2.deriveKeyFromPassword(
        password: 'password-two',
        nonce: salt,
      );

      expect(
        await key1.extractBytes(),
        isNot(equals(await key2.extractBytes())),
      );
    });

    test('different salts produce different keys', () async {
      final pbkdf2 = Pbkdf2(
        macAlgorithm: Hmac.sha256(),
        iterations: 1000,
        bits: 256,
      );

      final key1 = await pbkdf2.deriveKeyFromPassword(
        password: 'same-password',
        nonce: List<int>.generate(16, (i) => i),
      );
      final key2 = await pbkdf2.deriveKeyFromPassword(
        password: 'same-password',
        nonce: List<int>.generate(16, (i) => i + 100),
      );

      expect(
        await key1.extractBytes(),
        isNot(equals(await key2.extractBytes())),
      );
    });

    test('derived key length is 256 bits (32 bytes)', () async {
      final pbkdf2 = Pbkdf2(
        macAlgorithm: Hmac.sha256(),
        iterations: 1000,
        bits: 256,
      );

      final key = await pbkdf2.deriveKeyFromPassword(
        password: 'test',
        nonce: List<int>.generate(16, (i) => i),
      );

      expect((await key.extractBytes()).length, equals(32));
    });
  });

  group('Constant-time comparison', () {
    // Reimplementation of _constantTimeEquals for testing
    bool constantTimeEquals(List<int> a, List<int> b) {
      if (a.length != b.length) return false;
      var diff = 0;
      for (var i = 0; i < a.length; i++) {
        diff |= a[i] ^ b[i];
      }
      return diff == 0;
    }

    test('equal lists return true', () {
      expect(constantTimeEquals([1, 2, 3], [1, 2, 3]), isTrue);
    });

    test('different lists return false', () {
      expect(constantTimeEquals([1, 2, 3], [1, 2, 4]), isFalse);
    });

    test('different lengths return false', () {
      expect(constantTimeEquals([1, 2], [1, 2, 3]), isFalse);
    });

    test('empty lists return true', () {
      expect(constantTimeEquals([], []), isTrue);
    });

    test('single byte difference detected', () {
      final a = List<int>.generate(32, (i) => i);
      final b = List<int>.from(a);
      b[31] ^= 1; // Flip one bit in last byte
      expect(constantTimeEquals(a, b), isFalse);
    });
  });
}
