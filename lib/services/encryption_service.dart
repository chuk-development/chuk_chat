import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chuk_chat/services/supabase_service.dart';

class EncryptionService {
  const EncryptionService._();

  static const FlutterSecureStorage _storage = FlutterSecureStorage();
  static const String _storagePrefix = 'chat_key_';
  static const String _storageSaltPrefix = 'chat_salt_';
  static const String _storageVersionPrefix = 'chat_key_version_';
  static const String _metadataSaltKey = 'chat_kdf_salt';
  static const String _metadataVersionKey = 'chat_key_version';
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
      User user = await _requireAuthenticatedUser();
      final userId = user.id;
      final saltKey = '$_storageSaltPrefix$userId';
      final keyKey = '$_storagePrefix$userId';
      final versionKey = '$_storageVersionPrefix$userId';
      final storedSaltBase64 = await _storage.read(key: saltKey);
      final storedKeyBase64 = await _storage.read(key: keyKey);
      if (storedKeyBase64 != null && storedSaltBase64 == null) {
        throw StateError(
          'Stored encryption key is missing its salt; please sign in again.',
        );
      }

      final metadataUpdates = <String, dynamic>{};
      final remoteSaltBase64 = user.userMetadata?[_metadataSaltKey] as String?;
      final remoteVersion = user.userMetadata?[_metadataVersionKey] as String?;

      final canonicalSaltBase64 = await _resolveCanonicalSalt(
        userId: userId,
        password: password,
        storedSaltBase64: storedSaltBase64,
        remoteSaltBase64: remoteSaltBase64,
        storedKeyBase64: storedKeyBase64,
        metadataUpdates: metadataUpdates,
      );

      if (remoteVersion != _payloadVersion) {
        metadataUpdates[_metadataVersionKey] = _payloadVersion;
      }

      if (metadataUpdates.isNotEmpty) {
        final updatedUser = await _updateUserMetadata(user, metadataUpdates);
        if (updatedUser != null) {
          user = updatedUser;
        }
      }

      final saltBytes = _decodeBase64OrThrow(
        canonicalSaltBase64,
        'Stored encryption salt is corrupted; please sign in again.',
      );

      final derivedKeyBytes = await _deriveKey(password, saltBytes);
      if (storedKeyBase64 != null) {
        final storedKeyBytes = _decodeBase64OrThrow(
          storedKeyBase64,
          'Stored encryption key is corrupted; please sign in again.',
        );
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
      final currentUser = SupabaseService.auth.currentUser;
      if (currentUser == null) {
        _cachedKey = null;
        _cachedUserId = null;
        return false;
      }
      User user = currentUser;
      try {
        final response = await SupabaseService.auth.getUser();
        user = response.user ?? user;
      } catch (_) {
        // Ignore refresh failures; fall back to cached metadata.
      }

      final userId = user.id;
      final keyKey = '$_storagePrefix$userId';
      final saltKey = '$_storageSaltPrefix$userId';
      final versionKey = '$_storageVersionPrefix$userId';

      final encoded = await _storage.read(key: keyKey);
      if (encoded == null) {
        _cachedKey = null;
        _cachedUserId = null;
        return false;
      }
      final saltBase64 = await _storage.read(key: saltKey);
      final remoteSaltBase64 = user.userMetadata?[_metadataSaltKey] as String?;
      final remoteVersion = user.userMetadata?[_metadataVersionKey] as String?;

      final metadataUpdates = <String, dynamic>{};

      if (saltBase64 != null) {
        if (remoteSaltBase64 == null || remoteSaltBase64 != saltBase64) {
          metadataUpdates[_metadataSaltKey] = saltBase64;
        }
      } else if (remoteSaltBase64 != null) {
        await _storage.write(key: saltKey, value: remoteSaltBase64);
      }

      if (remoteVersion != _payloadVersion) {
        metadataUpdates[_metadataVersionKey] = _payloadVersion;
      }

      if (metadataUpdates.isNotEmpty) {
        try {
          final updated = await _updateUserMetadata(user, metadataUpdates);
          if (updated != null) {
            user = updated;
          }
        } catch (_) {
          // Ignore metadata sync failures during background load.
        }
      }

      final version = await _storage.read(key: versionKey);
      if (version == null) {
        await _storage.write(key: versionKey, value: _payloadVersion);
      }

      _cachedKey = SecretKey(
        _decodeBase64OrThrow(
          encoded,
          'Stored encryption key is corrupted; please sign in again.',
        ),
      );
      _cachedUserId = user.id;
      return true;
    });
  }

  static Future<void> rotateKeyForPasswordChange({
    required String currentPassword,
    required String newPassword,
    required Future<void> Function() migrateWithNewKey,
    required Future<void> Function() rollbackWithOldKey,
  }) {
    return _runExclusive(() async {
      User user = await _requireAuthenticatedUser();
      final userId = user.id;
      final saltStorageKey = '$_storageSaltPrefix$userId';
      final keyStorageKey = '$_storagePrefix$userId';
      final versionStorageKey = '$_storageVersionPrefix$userId';

      final storedSaltBase64 = await _storage.read(key: saltStorageKey);
      final storedKeyBase64 = await _storage.read(key: keyStorageKey);

      if (storedSaltBase64 == null || storedKeyBase64 == null) {
        throw StateError(
          'Encryption data is incomplete. Please sign out and sign in again before changing your password.',
        );
      }

      final saltBytes = _decodeBase64OrThrow(
        storedSaltBase64,
        'Stored encryption salt is corrupted; please sign in again.',
      );
      final storedKeyBytes = _decodeBase64OrThrow(
        storedKeyBase64,
        'Stored encryption key is corrupted; please sign in again.',
      );

      final currentDerivedKey = await _deriveKey(currentPassword, saltBytes);
      if (!_constantTimeEquals(currentDerivedKey, storedKeyBytes)) {
        throw StateError('Current password is incorrect.');
      }

      final oldKey = SecretKey(currentDerivedKey);

      final newSaltBytes = _randomNonce(_saltLength);
      final newSaltBase64 = base64Encode(newSaltBytes);
      final newKeyBytes = await _deriveKey(newPassword, newSaltBytes);
      final newKeyBase64 = base64Encode(newKeyBytes);
      final newKey = SecretKey(newKeyBytes);

      final previousCachedKey = _cachedKey;
      final previousCachedUserId = _cachedUserId;

      _cachedKey = newKey;
      _cachedUserId = userId;

      try {
        await migrateWithNewKey();
      } catch (error) {
        _cachedKey = oldKey;
        _cachedUserId = userId;
        try {
          await rollbackWithOldKey();
        } catch (_) {
          // We already failed the migration; keep propagating the original error.
        }
        _cachedKey = previousCachedKey ?? oldKey;
        _cachedUserId = previousCachedUserId ?? userId;
        rethrow;
      }

      try {
        await _storage.write(key: keyStorageKey, value: newKeyBase64);
        await _storage.write(key: saltStorageKey, value: newSaltBase64);
        await _storage.write(key: versionStorageKey, value: _payloadVersion);
        final metadataUpdates = <String, dynamic>{
          _metadataSaltKey: newSaltBase64,
          _metadataVersionKey: _payloadVersion,
        };
        final updatedUser = await _updateUserMetadata(user, metadataUpdates);
        if (updatedUser != null) {
          user = updatedUser;
        }
      } catch (error) {
        _cachedKey = oldKey;
        _cachedUserId = userId;
        try {
          await rollbackWithOldKey();
        } catch (_) {
          // If rollback fails we cannot do much else; we still rethrow the original error.
        }
        await _storage.write(key: keyStorageKey, value: storedKeyBase64);
        await _storage.write(key: saltStorageKey, value: storedSaltBase64);
        await _storage.write(key: versionStorageKey, value: _payloadVersion);
        _cachedKey = previousCachedKey ?? oldKey;
        _cachedUserId = previousCachedUserId ?? userId;
        rethrow;
      }

      _cachedKey = newKey;
      _cachedUserId = userId;
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

  /// Encrypts binary data (e.g., image files) and returns encrypted JSON
  /// Format: {"v":"1","nonce":"...","ciphertext":"...","mac":"..."}
  static Future<String> encryptBytes(Uint8List bytes) async {
    final secretKey = await _ensureKey();
    final nonce = _randomNonce(12);
    final secretBox = await _cipher.encrypt(
      bytes,
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

  /// Decrypts binary data from encrypted JSON format
  /// Returns the original binary data as Uint8List
  static Future<Uint8List> decryptBytes(String encrypted) async {
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
    return Uint8List.fromList(cleartextBytes);
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

  static Future<User> _requireAuthenticatedUser() async {
    final currentUser = SupabaseService.auth.currentUser;
    if (currentUser == null) {
      throw StateError(
        'Cannot initialise encryption without an authenticated user.',
      );
    }
    User user = currentUser;
    try {
      final response = await SupabaseService.auth.getUser();
      user = response.user ?? user;
    } catch (_) {
      // If fetching latest metadata fails we fall back to cached user data.
    }
    return user;
  }

  static Future<String> _resolveCanonicalSalt({
    required String userId,
    required String password,
    required String? storedSaltBase64,
    required String? remoteSaltBase64,
    required String? storedKeyBase64,
    required Map<String, dynamic> metadataUpdates,
  }) async {
    final saltKey = '$_storageSaltPrefix$userId';

    if (storedSaltBase64 != null && remoteSaltBase64 != null) {
      if (remoteSaltBase64 == storedSaltBase64) {
        return storedSaltBase64;
      }

      if (storedKeyBase64 != null) {
        final storedKeyBytes = _decodeBase64OrThrow(
          storedKeyBase64,
          'Stored encryption key is corrupted; please sign out and sign in again.',
        );

        final remoteSaltBytes = _decodeBase64OrThrow(
          remoteSaltBase64,
          'Remote encryption salt is corrupted. Sign out on other devices and retry.',
        );
        final derivedWithRemote = await _deriveKey(password, remoteSaltBytes);
        if (_constantTimeEquals(derivedWithRemote, storedKeyBytes)) {
          await _storage.write(key: saltKey, value: remoteSaltBase64);
          metadataUpdates[_metadataSaltKey] = remoteSaltBase64;
          return remoteSaltBase64;
        }

        final storedSaltBytes = _decodeBase64OrThrow(
          storedSaltBase64,
          'Stored encryption salt is corrupted; please sign out and sign in again.',
        );
        final derivedWithStored = await _deriveKey(password, storedSaltBytes);
        if (_constantTimeEquals(derivedWithStored, storedKeyBytes)) {
          metadataUpdates[_metadataSaltKey] = storedSaltBase64;
          return storedSaltBase64;
        }

        throw StateError(
          'Encryption data mismatch detected. Sign out everywhere, then sign back in with your password to regenerate encryption keys.',
        );
      }

      await _storage.write(key: saltKey, value: remoteSaltBase64);
      metadataUpdates[_metadataSaltKey] = remoteSaltBase64;
      return remoteSaltBase64;
    }

    if (remoteSaltBase64 != null) {
      await _storage.write(key: saltKey, value: remoteSaltBase64);
      return remoteSaltBase64;
    }

    if (storedSaltBase64 != null) {
      metadataUpdates[_metadataSaltKey] = storedSaltBase64;
      return storedSaltBase64;
    }

    final generatedSalt = base64Encode(_randomNonce(_saltLength));
    await _storage.write(key: saltKey, value: generatedSalt);
    metadataUpdates[_metadataSaltKey] = generatedSalt;
    return generatedSalt;
  }

  static List<int> _decodeBase64OrThrow(String data, String errorMessage) {
    try {
      return base64Decode(data);
    } on FormatException {
      throw StateError(errorMessage);
    }
  }

  static Future<User?> _updateUserMetadata(
    User user,
    Map<String, dynamic> patch,
  ) async {
    if (patch.isEmpty) return null;
    final existing = Map<String, dynamic>.from(user.userMetadata ?? {});
    var hasChanges = false;
    for (final entry in patch.entries) {
      if (existing[entry.key] != entry.value) {
        hasChanges = true;
        existing[entry.key] = entry.value;
      }
    }
    if (!hasChanges) return null;

    try {
      final response = await SupabaseService.auth.updateUser(
        UserAttributes(data: existing),
      );
      return response.user;
    } on AuthException catch (error) {
      throw StateError('Failed to sync encryption metadata: ${error.message}');
    }
  }
}
