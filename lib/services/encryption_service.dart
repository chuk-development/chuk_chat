import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:chuk_chat/services/supabase_service.dart';

class EncryptionService {
  const EncryptionService._();

  static const FlutterSecureStorage _storage = FlutterSecureStorage();
  static const String _storagePrefix = 'chat_key_';
  static final AesGcm _cipher = AesGcm.with256bits();
  static final Random _rng = Random.secure();

  static SecretKey? _cachedKey;
  static String? _cachedUserId;

  static bool get hasKey => _cachedKey != null;

  /// Derives and caches the encryption key for the authenticated user using
  /// their password. The derived key is stored in the platform secure storage
  /// so subsequent sessions can decrypt chats without re-entering the password.
  static Future<void> initializeForPassword(String password) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError(
        'Cannot initialise encryption without an authenticated user.',
      );
    }
    final keyBytes = await _deriveKey(password, user.id);
    _cachedKey = SecretKey(keyBytes);
    _cachedUserId = user.id;
    await _storage.write(
      key: '$_storagePrefix${user.id}',
      value: base64Encode(keyBytes),
    );
  }

  /// Attempts to read the cached encryption key from secure storage. Returns
  /// true if a key was found and loaded into memory.
  static Future<bool> tryLoadKey() async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) return false;
    final encoded = await _storage.read(key: '$_storagePrefix${user.id}');
    if (encoded == null) return false;
    _cachedKey = SecretKey(base64Decode(encoded));
    _cachedUserId = user.id;
    return true;
  }

  /// Removes the cached key from memory and secure storage for the active user.
  static Future<void> clearKey() async {
    final userId = SupabaseService.auth.currentUser?.id ?? _cachedUserId;
    if (userId != null) {
      await _storage.delete(key: '$_storagePrefix$userId');
    }
    _cachedKey = null;
    _cachedUserId = null;
  }

  static Future<String> encrypt(String plaintext) async {
    final secretKey = await _ensureKey();
    final nonce = _randomNonce(12);
    final secretBox = await _cipher.encrypt(
      utf8.encode(plaintext),
      secretKey: secretKey,
      nonce: nonce,
    );
    final payload = <String, String>{
      'v': '1',
      'nonce': base64Encode(secretBox.nonce),
      'ciphertext': base64Encode(secretBox.cipherText),
      'mac': base64Encode(secretBox.mac.bytes),
    };
    return jsonEncode(payload);
  }

  static Future<String> decrypt(String encrypted) async {
    final secretKey = await _ensureKey();
    final Map<String, dynamic> payload = jsonDecode(encrypted);
    final nonce = base64Decode(payload['nonce'] as String);
    final cipherText = base64Decode(payload['ciphertext'] as String);
    final mac = Mac(base64Decode(payload['mac'] as String));
    final secretBox = SecretBox(cipherText, nonce: nonce, mac: mac);
    final cleartextBytes = await _cipher.decrypt(
      secretBox,
      secretKey: secretKey,
    );
    return utf8.decode(cleartextBytes);
  }

  static Future<SecretKey> _ensureKey() async {
    if (_cachedKey != null) return _cachedKey!;
    final loaded = await tryLoadKey();
    if (!loaded) {
      throw StateError('Encryption key is not available for the current user.');
    }
    return _cachedKey!;
  }

  static Future<List<int>> _deriveKey(String password, String userId) async {
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: 150000,
      bits: 256,
    );
    final salt = utf8.encode('chukchat:$userId');
    final newSecretKey = await pbkdf2.deriveKeyFromPassword(
      password,
      nonce: salt,
    );
    return newSecretKey.extractBytes();
  }

  static List<int> _randomNonce(int length) {
    return List<int>.generate(length, (_) => _rng.nextInt(256));
  }
}
