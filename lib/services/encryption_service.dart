import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:chuk_chat/services/supabase_service.dart';

class EncryptionService {
  const EncryptionService._();

  static const FlutterSecureStorage _storage = FlutterSecureStorage();
  static const String _storagePrefix = 'chat_key_';
  static const String _storageSaltPrefix = 'chat_salt_';
  static const String _storageVersionPrefix = 'chat_key_version_';
  static const String _payloadVersion = '1';
  static const int _kdfIterations = 600000;
  static const int _saltLength = 16;
  static final AesGcm _cipher = AesGcm.with256bits();
  static final Random _rng = Random.secure();

  static SecretKey? _cachedKey;
  static String? _cachedUserId;
  static Future<void> _lock = Future<void>.value();

  static bool get hasKey => _cachedKey != null;

  static Future<void> initializeForPassword(String password) async {
    await _runExclusive(() async {
      final user = SupabaseService.auth.currentUser;
      if (user == null) {
        throw StateError(
          'Cannot initialise encryption without an authenticated user.',
        );
      }

      final saltKey = '$_storageSaltPrefix${user.id}';
      final keyKey = '$_storagePrefix${user.id}';
      final versionKey = '$_storageVersionPrefix${user.id}';
      final storedSalt = await _storage.read(key: saltKey);
      final storedKey = await _storage.read(key: keyKey);
      if (storedKey != null && storedSalt == null) {
        throw StateError(
          'Stored encryption key is missing its salt; please sign in again.',
        );
      }
      final saltBytes = storedSalt != null
          ? base64Decode(storedSalt)
          : _randomNonce(_saltLength);
      if (storedSalt == null) {
        await _storage.write(key: saltKey, value: base64Encode(saltBytes));
      }

      final derivedKeyBytes = await _deriveKey(password, saltBytes);
      if (storedKey != null) {
        final storedKeyBytes = base64Decode(storedKey);
        if (!_constantTimeEquals(derivedKeyBytes, storedKeyBytes)) {
          throw StateError('Incorrect password provided.');
        }
      } else {
        await _storage.write(key: keyKey, value: base64Encode(derivedKeyBytes));
      }

      await _storage.write(key: versionKey, value: _payloadVersion);
      _cachedKey = SecretKey(derivedKeyBytes);
      _cachedUserId = user.id;
    });
  }

  static Future<bool> tryLoadKey() {
    return _runExclusive(() async {
      final user = SupabaseService.auth.currentUser;
      if (user == null) {
        _cachedKey = null;
        _cachedUserId = null;
        return false;
      }
      final encoded = await _storage.read(key: '$_storagePrefix${user.id}');
      if (encoded == null) {
        _cachedKey = null;
        _cachedUserId = null;
        return false;
      }
      _cachedKey = SecretKey(base64Decode(encoded));
      _cachedUserId = user.id;
      return true;
    });
  }

  static Future<void> clearKey() {
    return _runExclusive(() async {
      final userId = SupabaseService.auth.currentUser?.id ?? _cachedUserId;
      if (userId != null) {
        await _storage.delete(key: '$_storagePrefix$userId');
        await _storage.delete(key: '$_storageSaltPrefix$userId');
        await _storage.delete(key: '$_storageVersionPrefix$userId');
      }
      _cachedKey = null;
      _cachedUserId = null;
    });
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
      'v': _payloadVersion,
      'nonce': base64Encode(secretBox.nonce),
      'ciphertext': base64Encode(secretBox.cipherText),
      'mac': base64Encode(secretBox.mac.bytes),
    };
    return jsonEncode(payload);
  }

  static Future<String> decrypt(String encrypted) async {
    final secretKey = await _ensureKey();
    final Map<String, dynamic> payload = jsonDecode(encrypted);
    final version = payload['v'];
    if (version != _payloadVersion) {
      throw StateError('Unsupported ciphertext version: $version');
    }
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
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      _cachedKey = null;
      _cachedUserId = null;
      throw StateError('Cannot use encryption without an authenticated user.');
    }

    if (_cachedKey != null) {
      if (_cachedUserId == user.id) {
        return _cachedKey!;
      }
      _cachedKey = null;
      _cachedUserId = null;
      throw StateError('Encryption key does not match active user.');
    }

    final loaded = await tryLoadKey();
    if (!loaded || _cachedUserId != user.id) {
      throw StateError('Encryption key is not available for the current user.');
    }
    return _cachedKey!;
  }

  static Future<List<int>> _deriveKey(String password, List<int> salt) async {
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: _kdfIterations,
      bits: 256,
    );
    final newSecretKey = await pbkdf2.deriveKeyFromPassword(
      password: password,
      nonce: salt,
    );
    return newSecretKey.extractBytes();
  }

  static List<int> _randomNonce(int length) {
    return List<int>.generate(length, (_) => _rng.nextInt(256));
  }

  static Future<T> _runExclusive<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _lock = _lock
        .then((_) => action())
        .then<void>(
          (result) {
            completer.complete(result);
          },
          onError: (Object error, StackTrace stackTrace) {
            completer.completeError(error, stackTrace);
          },
        );
    return completer.future;
  }

  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) {
      return false;
    }
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}
