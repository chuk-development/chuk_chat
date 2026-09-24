import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chuk_chat/platform_config.dart';
import 'package:chuk_chat/services/chat_payload_codec.dart';
import 'package:chuk_chat/services/payload_compression.dart';
import 'package:chuk_chat/services/supabase_service.dart';

/// Envelope version of a plain ciphertext: the cleartext is UTF-8 text or
/// raw bytes. Titles, prompts, images and every other value use it.
const String kPlainEnvelopeVersion = '1';

/// Envelope version of a compressed chat payload: the cleartext is a
/// payload frame (see payload_compression.dart) holding a v3 payload JSON.
///
/// An app from before v3 accepts only [kPlainEnvelopeVersion] and throws
/// `StateError('Unsupported ciphertext version: 2')` before it decrypts
/// anything, so it can neither misread nor rewrite such a chat.
const String kCompressedEnvelopeVersion = '2';

/// The text of a decrypted envelope of [version].
String _cleartextToString(List<int> cleartext, Object? version) {
  if (version == kCompressedEnvelopeVersion) {
    return utf8.decode(decompressPayloadFrame(cleartext));
  }
  return utf8.decode(cleartext);
}

void _checkEnvelopeVersion(Object? version) {
  if (version != kPlainEnvelopeVersion &&
      version != kCompressedEnvelopeVersion) {
    throw StateError('Unsupported ciphertext version: $version');
  }
}

/// Seal a chat payload JSON: compress it into a frame, encrypt the frame
/// with AES-256-GCM and wrap it in a [kCompressedEnvelopeVersion] envelope.
/// Pure, so it runs in an isolate and in tests without a signed-in user.
Future<String> sealChatPayload({
  required String json,
  required List<int> keyBytes,
  required int keyVersion,
  bool allowBzip2 = true,
}) async {
  final frame = compressPayloadStrong(json, allowBzip2: allowBzip2);
  final cipher = AesGcm.with256bits();
  final rng = Random.secure();
  final nonce = List<int>.generate(12, (_) => rng.nextInt(256));
  final secretBox = await cipher.encrypt(
    frame,
    secretKey: SecretKey(keyBytes),
    nonce: nonce,
  );
  return jsonEncode(<String, dynamic>{
    'v': kCompressedEnvelopeVersion,
    'kv': keyVersion,
    'nonce': base64Encode(secretBox.nonce),
    'ciphertext': base64Encode(secretBox.cipherText),
    'mac': base64Encode(secretBox.mac.bytes),
  });
}

/// Decrypt an envelope of either version to its text. Pure, see
/// [sealChatPayload].
Future<String> openEnvelopeText(String encrypted, List<int> keyBytes) async {
  final Map<String, dynamic> payload = jsonDecode(encrypted);
  final version = payload['v'];
  _checkEnvelopeVersion(version);
  final secretBox = SecretBox(
    base64Decode(payload['ciphertext'] as String),
    nonce: base64Decode(payload['nonce'] as String),
    mac: Mac(base64Decode(payload['mac'] as String)),
  );
  final cleartext = await AesGcm.with256bits().decrypt(
    secretBox,
    secretKey: SecretKey(keyBytes),
  );
  return _cleartextToString(cleartext, version);
}

/// The envelope version of [encrypted] without decrypting it, or null when
/// it is not an envelope.
String? envelopeVersionOf(String encrypted) {
  try {
    final decoded = jsonDecode(encrypted);
    if (decoded is! Map) return null;
    final version = decoded['v'];
    return version is String ? version : null;
  } catch (_) {
    return null;
  }
}

/// Parameters for sealing a chat payload in the background.
class _SealParams {
  const _SealParams(this.json, this.keyBytes, this.keyVersion, this.allowBzip2);

  final String json;
  final List<int> keyBytes;
  final int keyVersion;
  final bool allowBzip2;
}

/// The result of [convertChatEnvelopeToV3]: the new envelope, the v3
/// payload JSON sealed in it, and the fingerprint of the original messages
/// (see `chatPayloadFingerprint`).
typedef ChatEnvelopeV3 = ({
  String envelope,
  String payloadJson,
  String fingerprint,
});

/// Convert the chat payload envelope [encrypted] (any version) to a v3
/// payload in a compressed envelope, and prove the result before it is
/// returned: the v3 JSON must decode to the same messages as the original,
/// and the new envelope must decrypt to exactly that JSON. Returns null when
/// either proof fails. Pure, so it runs in an isolate.
Future<ChatEnvelopeV3?> convertChatEnvelopeToV3({
  required String encrypted,
  required List<int> keyBytes,
  required int keyVersion,
  bool allowBzip2 = true,
}) async {
  final original = await openEnvelopeText(encrypted, keyBytes);
  final before = decodeChatPayload(original);
  final payloadJson = before.version == kChatPayloadVersion
      ? original
      : encodeChatPayload(before.messages, customName: before.customName);
  final after = decodeChatPayload(payloadJson);
  if (!chatPayloadsEquivalent(before, after)) return null;
  final fingerprint = chatPayloadFingerprint(before);
  final envelope = await sealChatPayload(
    json: payloadJson,
    keyBytes: keyBytes,
    keyVersion: keyVersion,
    allowBzip2: allowBzip2,
  );
  if (await openEnvelopeText(envelope, keyBytes) != payloadJson) return null;
  return (
    envelope: envelope,
    payloadJson: payloadJson,
    fingerprint: fingerprint,
  );
}

/// Decrypt a chat envelope and return the fingerprint of its messages.
/// Pure, for isolates and tests.
Future<String> chatEnvelopeFingerprint(
  String encrypted,
  List<int> keyBytes,
) async => chatPayloadJsonFingerprint(
  await openEnvelopeText(encrypted, keyBytes),
);

class _FingerprintParams {
  const _FingerprintParams(this.encrypted, this.keyBytes);

  final String encrypted;
  final List<int> keyBytes;
}

Future<String> _fingerprintInBackground(_FingerprintParams params) =>
    chatEnvelopeFingerprint(params.encrypted, params.keyBytes);

class _ConvertParams {
  const _ConvertParams(this.encrypted, this.keyBytes, this.keyVersion);

  final String encrypted;
  final List<int> keyBytes;
  final int keyVersion;
}

Future<ChatEnvelopeV3?> _convertChatEnvelopeInBackground(
  _ConvertParams params,
) => convertChatEnvelopeToV3(
  encrypted: params.encrypted,
  keyBytes: params.keyBytes,
  keyVersion: params.keyVersion,
  allowBzip2: !kIsWeb,
);

Future<String> _sealChatPayloadInBackground(_SealParams params) =>
    sealChatPayload(
      json: params.json,
      keyBytes: params.keyBytes,
      keyVersion: params.keyVersion,
      allowBzip2: params.allowBzip2,
    );

/// Parameters for background encryption
class _EncryptionParams {
  final Uint8List bytes;
  final List<int> keyBytes;
  final String payloadVersion;
  final int keyVersion;

  _EncryptionParams({
    required this.bytes,
    required this.keyBytes,
    required this.payloadVersion,
    required this.keyVersion,
  });
}

/// Parameters for background decryption
class _DecryptionParams {
  final String encrypted;
  final List<int> keyBytes;
  final String payloadVersion;

  _DecryptionParams({
    required this.encrypted,
    required this.keyBytes,
    required this.payloadVersion,
  });
}

/// Parameters for batch background decryption
class _BatchDecryptionParams {
  final List<String> encryptedList;
  final List<int> keyBytes;
  final String payloadVersion;

  _BatchDecryptionParams({
    required this.encryptedList,
    required this.keyBytes,
    required this.payloadVersion,
  });
}

/// Top-level function for background encryption
Future<String> _encryptBytesInBackground(_EncryptionParams params) async {
  final cipher = AesGcm.with256bits();
  final secretKey = SecretKey(params.keyBytes);
  final rng = Random.secure();

  final nonce = List<int>.generate(12, (_) => rng.nextInt(256));
  final secretBox = await cipher.encrypt(
    params.bytes,
    secretKey: secretKey,
    nonce: nonce,
  );

  final payload = <String, dynamic>{
    'v': params.payloadVersion,
    'kv': params.keyVersion,
    'nonce': base64Encode(secretBox.nonce),
    'ciphertext': base64Encode(secretBox.cipherText),
    'mac': base64Encode(secretBox.mac.bytes),
  };

  return jsonEncode(payload);
}

/// Top-level function for background decryption
Future<Uint8List> _decryptBytesInBackground(_DecryptionParams params) async {
  final cipher = AesGcm.with256bits();
  final secretKey = SecretKey(params.keyBytes);

  final Map<String, dynamic> payload = jsonDecode(params.encrypted);
  final version = payload['v'];
  if (version != params.payloadVersion) {
    throw StateError('Unsupported ciphertext version: $version');
  }

  final nonce = base64Decode(payload['nonce'] as String);
  final cipherText = base64Decode(payload['ciphertext'] as String);
  final mac = Mac(base64Decode(payload['mac'] as String));
  final secretBox = SecretBox(cipherText, nonce: nonce, mac: mac);

  final cleartextBytes = await cipher.decrypt(secretBox, secretKey: secretKey);

  return Uint8List.fromList(cleartextBytes);
}

/// Top-level function for background string decryption (for chat text)
Future<String> _decryptStringInBackground(_DecryptionParams params) async {
  final cipher = AesGcm.with256bits();
  final secretKey = SecretKey(params.keyBytes);

  final Map<String, dynamic> payload = jsonDecode(params.encrypted);
  final version = payload['v'];
  _checkEnvelopeVersion(version);

  final nonce = base64Decode(payload['nonce'] as String);
  final cipherText = base64Decode(payload['ciphertext'] as String);
  final mac = Mac(base64Decode(payload['mac'] as String));
  final secretBox = SecretBox(cipherText, nonce: nonce, mac: mac);

  final cleartextBytes = await cipher.decrypt(secretBox, secretKey: secretKey);

  return _cleartextToString(cleartextBytes, version);
}

/// Top-level function for batch background decryption
/// Decrypts multiple strings in a single isolate for better performance
Future<List<String?>> _decryptBatchInBackground(
  _BatchDecryptionParams params,
) async {
  final cipher = AesGcm.with256bits();
  final secretKey = SecretKey(params.keyBytes);
  final results = <String?>[];

  for (final encrypted in params.encryptedList) {
    try {
      final Map<String, dynamic> payload = jsonDecode(encrypted);
      final version = payload['v'];
      if (version != kPlainEnvelopeVersion &&
          version != kCompressedEnvelopeVersion) {
        results.add(null);
        continue;
      }

      final nonce = base64Decode(payload['nonce'] as String);
      final cipherText = base64Decode(payload['ciphertext'] as String);
      final mac = Mac(base64Decode(payload['mac'] as String));
      final secretBox = SecretBox(cipherText, nonce: nonce, mac: mac);

      final cleartextBytes = await cipher.decrypt(
        secretBox,
        secretKey: secretKey,
      );

      results.add(_cleartextToString(cleartextBytes, version));
    } catch (_) {
      results.add(null);
    }
  }

  return results;
}

/// Parameters for PBKDF2 key derivation in background isolate
class _KeyDerivationParams {
  final String password;
  final List<int> salt;
  final int iterations;
  final int bits;

  _KeyDerivationParams({
    required this.password,
    required this.salt,
    required this.iterations,
    required this.bits,
  });
}

/// Top-level function for background PBKDF2 key derivation
Future<List<int>> _deriveKeyInBackground(_KeyDerivationParams params) async {
  final pbkdf2 = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: params.iterations,
    bits: params.bits,
  );
  final newSecretKey = await pbkdf2.deriveKeyFromPassword(
    password: params.password,
    nonce: params.salt,
  );
  return newSecretKey.extractBytes();
}

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
  static SharedPreferences? _prefsCache;
  static Future<void> _lock = Future<void>.value();
  static int _currentKeyVersion = 1;

  /// The current key version used for encrypting new payloads.
  static int get currentKeyVersion => _currentKeyVersion;

  static bool get hasKey => _cachedKey != null;

  // SharedPreferences fallback for platforms where Keychain/keyring
  // is unreliable without code signing (macOS unsigned builds) or
  // causes startup stalls (Linux without libsecret).
  static bool get _usePrefsBackend =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.macOS ||
          (defaultTargetPlatform == TargetPlatform.linux &&
              !kFeatureLinuxKeyring));

  static Future<SharedPreferences> _prefs() async {
    _prefsCache ??= await SharedPreferences.getInstance();
    return _prefsCache!;
  }

  static Future<String?> _readLocalSecret(String key) async {
    if (_usePrefsBackend) {
      final prefs = await _prefs();
      return prefs.getString(key);
    }
    return _storage.read(key: key);
  }

  static Future<void> _writeLocalSecret(String key, String value) async {
    if (_usePrefsBackend) {
      final prefs = await _prefs();
      await prefs.setString(key, value);
      return;
    }
    await _storage.write(key: key, value: value);
  }

  static Future<void> _deleteLocalSecret(String key) async {
    if (_usePrefsBackend) {
      final prefs = await _prefs();
      await prefs.remove(key);
      return;
    }
    await _storage.delete(key: key);
  }

  static Future<void> initializeForPassword(String password) async {
    await _runExclusive(() async {
      User user = await _requireAuthenticatedUser();
      final userId = user.id;
      final saltKey = '$_storageSaltPrefix$userId';
      final keyKey = '$_storagePrefix$userId';
      final versionKey = '$_storageVersionPrefix$userId';
      // Parallelize storage reads for better performance
      final storageResults = await Future.wait([
        _readLocalSecret(saltKey),
        _readLocalSecret(keyKey),
      ]);
      final storedSaltBase64 = storageResults[0];
      final storedKeyBase64 = storageResults[1];
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

      // Don't overwrite key version here — it's managed by
      // initializeForPasswordReset and rotateKeyForPasswordChange.
      // Only sync if there's no remote version at all (first-time setup).
      if (remoteVersion == null) {
        metadataUpdates[_metadataVersionKey] = '1';
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
        await _writeLocalSecret(keyKey, base64Encode(derivedKeyBytes));
      }

      await _writeLocalSecret(versionKey, _payloadVersion);
      _cachedKey = SecretKey(derivedKeyBytes);
      _cachedUserId = user.id;

      // Load key version from metadata (defaults to 1 for legacy accounts)
      final kvRaw = user.userMetadata?[_metadataVersionKey];
      _currentKeyVersion = _parseKeyVersion(kvRaw);
    });
  }

  /// Initialize encryption after a password reset.
  /// Generates a new salt and key, incrementing the key version.
  /// The old salt+version should have already been preserved in previous_keys
  /// by the caller (SetNewPasswordPage) before calling this.
  static Future<void> initializeForPasswordReset(String newPassword) async {
    await _runExclusive(() async {
      final user = await _requireAuthenticatedUser();
      final userId = user.id;
      final saltKey = '$_storageSaltPrefix$userId';
      final keyKey = '$_storagePrefix$userId';
      final versionKey = '$_storageVersionPrefix$userId';

      // Determine the new key version (increment from current)
      final currentVersionRaw = user.userMetadata?[_metadataVersionKey];
      final currentVersion = _parseKeyVersion(currentVersionRaw);
      final newVersion = currentVersion + 1;

      // Generate new salt and derive new key
      final newSaltBytes = _randomNonce(_saltLength);
      final newSaltBase64 = base64Encode(newSaltBytes);
      final newKeyBytes = await _deriveKey(newPassword, newSaltBytes);
      final newKeyBase64 = base64Encode(newKeyBytes);

      // Backup current local state for potential rollback
      final oldLocalKey = await _readLocalSecret(keyKey);
      final oldLocalSalt = await _readLocalSecret(saltKey);
      final oldLocalVersion = await _readLocalSecret(versionKey);

      // Persist locally
      await Future.wait([
        _writeLocalSecret(keyKey, newKeyBase64),
        _writeLocalSecret(saltKey, newSaltBase64),
        _writeLocalSecret(versionKey, '$newVersion'),
      ]);

      // Persist to Supabase metadata
      final metadataUpdates = <String, dynamic>{
        _metadataSaltKey: newSaltBase64,
        _metadataVersionKey: '$newVersion',
      };
      try {
        await _updateUserMetadata(user, metadataUpdates);
      } catch (_) {
        // Rollback local storage to maintain consistency
        await Future.wait([
          if (oldLocalKey != null)
            _writeLocalSecret(keyKey, oldLocalKey)
          else
            _deleteLocalSecret(keyKey),
          if (oldLocalSalt != null)
            _writeLocalSecret(saltKey, oldLocalSalt)
          else
            _deleteLocalSecret(saltKey),
          if (oldLocalVersion != null)
            _writeLocalSecret(versionKey, oldLocalVersion)
          else
            _deleteLocalSecret(versionKey),
        ]);
        rethrow;
      }

      // Update in-memory state only after both local and remote succeed
      _cachedKey = SecretKey(newKeyBytes);
      _cachedUserId = userId;
      _currentKeyVersion = newVersion;
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
      // NOTE: Don't call getUser() here - it's a network call that blocks for 5-7 seconds!
      // Use currentUser which is already cached from the auth session.

      final userId = user.id;
      final keyKey = '$_storagePrefix$userId';
      final saltKey = '$_storageSaltPrefix$userId';
      final versionKey = '$_storageVersionPrefix$userId';

      // Load key from secure storage (fast, local operation)
      final encoded = await _readLocalSecret(keyKey);
      if (encoded == null) {
        _cachedKey = null;
        _cachedUserId = null;
        return false;
      }

      // Load and cache the key immediately - don't wait for metadata sync
      _cachedKey = SecretKey(
        _decodeBase64OrThrow(
          encoded,
          'Stored encryption key is corrupted; please sign in again.',
        ),
      );
      _cachedUserId = user.id;

      // Load key version from metadata (defaults to 1 for legacy accounts)
      final kvRaw = user.userMetadata?[_metadataVersionKey];
      _currentKeyVersion = _parseKeyVersion(kvRaw);

      // Sync metadata in BACKGROUND - don't block key loading
      unawaited(_syncMetadataInBackground(user, saltKey, versionKey));

      return true;
    });
  }

  /// Sync encryption metadata to Supabase in background (non-blocking)
  static Future<void> _syncMetadataInBackground(
    User user,
    String saltKey,
    String versionKey,
  ) async {
    try {
      // Parallelize storage reads to reduce blocking time
      final readResults = await Future.wait([
        _readLocalSecret(saltKey),
        _readLocalSecret(versionKey),
      ]);
      final saltBase64 = readResults[0];
      final version = readResults[1];

      final remoteSaltBase64 = user.userMetadata?[_metadataSaltKey] as String?;
      final remoteVersion = user.userMetadata?[_metadataVersionKey] as String?;

      final metadataUpdates = <String, dynamic>{};

      if (saltBase64 != null) {
        if (remoteSaltBase64 == null || remoteSaltBase64 != saltBase64) {
          metadataUpdates[_metadataSaltKey] = saltBase64;
        }
      } else if (remoteSaltBase64 != null) {
        await _writeLocalSecret(saltKey, remoteSaltBase64);
      }

      // Sync key version — use the actual current key version, not _payloadVersion.
      // _metadataVersionKey stores the encryption key version (1, 2, 3, ...),
      // NOT the payload format version.
      final expectedVersion = '$_currentKeyVersion';
      if (version != null && remoteVersion != version) {
        // Local version takes precedence (it was set during password init)
        metadataUpdates[_metadataVersionKey] = version;
      } else if (version == null && remoteVersion != null) {
        await _writeLocalSecret(versionKey, remoteVersion);
      } else if (version == null && remoteVersion == null) {
        await _writeLocalSecret(versionKey, expectedVersion);
        metadataUpdates[_metadataVersionKey] = expectedVersion;
      }

      if (metadataUpdates.isNotEmpty) {
        await _updateUserMetadata(user, metadataUpdates);
      }
    } catch (e) {
      // Ignore metadata sync failures - not critical for key loading
      if (kDebugMode) {
        debugPrint('⚠️ [Encryption] Background metadata sync failed: $e');
      }
    }
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

      // Parallelize storage reads for better performance
      final readResults = await Future.wait([
        _readLocalSecret(saltStorageKey),
        _readLocalSecret(keyStorageKey),
      ]);
      final storedSaltBase64 = readResults[0];
      final storedKeyBase64 = readResults[1];

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

      final newKeyVersionInt = _currentKeyVersion + 1;
      final newKeyVersionStr = '$newKeyVersionInt';

      try {
        // Parallelize storage writes for better performance
        await Future.wait([
          _writeLocalSecret(keyStorageKey, newKeyBase64),
          _writeLocalSecret(saltStorageKey, newSaltBase64),
          _writeLocalSecret(versionStorageKey, newKeyVersionStr),
        ]);
        final metadataUpdates = <String, dynamic>{
          _metadataSaltKey: newSaltBase64,
          _metadataVersionKey: newKeyVersionStr,
        };
        final updatedUser = await _updateUserMetadata(user, metadataUpdates);
        if (updatedUser != null) {
          user = updatedUser;
        }
        _currentKeyVersion = newKeyVersionInt;
      } catch (error) {
        _cachedKey = oldKey;
        _cachedUserId = userId;
        try {
          await rollbackWithOldKey();
        } catch (_) {
          // If rollback fails we cannot do much else; we still rethrow the original error.
        }
        final oldKeyVersionStr = '$_currentKeyVersion';
        // Parallelize storage writes for better performance
        await Future.wait([
          _writeLocalSecret(keyStorageKey, storedKeyBase64),
          _writeLocalSecret(saltStorageKey, storedSaltBase64),
          _writeLocalSecret(versionStorageKey, oldKeyVersionStr),
        ]);
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
        // Parallelize storage deletes to avoid sequential blocking
        await Future.wait([
          _deleteLocalSecret('$_storagePrefix$userId'),
          _deleteLocalSecret('$_storageSaltPrefix$userId'),
          _deleteLocalSecret('$_storageVersionPrefix$userId'),
        ]);
      }
      _cachedKey = null;
      _cachedUserId = null;
      _currentKeyVersion = 1;
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
    final payload = <String, dynamic>{
      'v': _payloadVersion,
      'kv': _currentKeyVersion,
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
    _checkEnvelopeVersion(version);
    final nonce = base64Decode(payload['nonce'] as String);
    final cipherText = base64Decode(payload['ciphertext'] as String);
    final mac = Mac(base64Decode(payload['mac'] as String));
    final secretBox = SecretBox(cipherText, nonce: nonce, mac: mac);
    final cleartextBytes = await _cipher.decrypt(
      secretBox,
      secretKey: secretKey,
    );
    return _cleartextToString(cleartextBytes, version);
  }

  /// Payloads up to this many characters are sealed on the calling isolate.
  static const int _backgroundSealMinChars = 4 * 1024;

  /// On the web there is no isolate: [compute] runs on the UI thread. bzip2
  /// is slow in JavaScript, so above this size the web seals with deflate.
  static const int _webBzip2MaxChars = 128 * 1024;

  /// Encrypt a chat payload JSON (v3) for `encrypted_chats`: compressed,
  /// then encrypted, in a [kCompressedEnvelopeVersion] envelope. Runs off
  /// the UI isolate for anything but a short chat.
  static Future<String> encryptChatPayload(String json) async {
    final secretKey = await _ensureKey();
    final keyBytes = await secretKey.extractBytes();
    final params = _SealParams(
      json,
      keyBytes,
      _currentKeyVersion,
      !kIsWeb || json.length <= _webBzip2MaxChars,
    );
    if (json.length < _backgroundSealMinChars) {
      return _sealChatPayloadInBackground(params);
    }
    return compute(_sealChatPayloadInBackground, params);
  }

  /// [convertChatEnvelopeToV3] with the current key, off the UI isolate.
  /// For the one-time migration of old chats.
  static Future<ChatEnvelopeV3?> convertChatPayloadToV3(
    String encrypted,
  ) async {
    final secretKey = await _ensureKey();
    final keyBytes = await secretKey.extractBytes();
    return compute(
      _convertChatEnvelopeInBackground,
      _ConvertParams(encrypted, keyBytes, _currentKeyVersion),
    );
  }

  /// [chatEnvelopeFingerprint] with the current key, off the UI isolate.
  /// Verifies a chat that was just rewritten.
  static Future<String> chatPayloadFingerprintOf(String encrypted) async {
    final secretKey = await _ensureKey();
    final keyBytes = await secretKey.extractBytes();
    return compute(
      _fingerprintInBackground,
      _FingerprintParams(encrypted, keyBytes),
    );
  }

  /// Encrypts binary data (e.g., image files) and returns encrypted JSON
  /// Format: {"v":"1","nonce":"...","ciphertext":"...","mac":"..."}
  static Future<String> encryptBytes(Uint8List bytes) async {
    final secretKey = await _ensureKey();
    final keyBytes = await secretKey.extractBytes();

    final params = _EncryptionParams(
      bytes: bytes,
      keyBytes: keyBytes,
      payloadVersion: _payloadVersion,
      keyVersion: _currentKeyVersion,
    );

    // Run encryption in background isolate to avoid blocking UI
    return await compute(_encryptBytesInBackground, params);
  }

  /// Inputs up to this size are sealed on the calling isolate: below it the
  /// isolate hop costs more than the cipher.
  static const int _backgroundEncryptMinChars = 16 * 1024;

  /// [encrypt] for a large string, run off the UI isolate.
  ///
  /// The cipher is pure Dart, so sealing a long chat payload on the UI isolate
  /// stalls frames. The output has exactly the format of [encrypt]; a short
  /// input simply goes through [encrypt].
  static Future<String> encryptInBackground(String plaintext) async {
    if (plaintext.length < _backgroundEncryptMinChars) {
      return encrypt(plaintext);
    }
    final secretKey = await _ensureKey();
    final keyBytes = await secretKey.extractBytes();
    final params = _EncryptionParams(
      bytes: utf8.encode(plaintext),
      keyBytes: keyBytes,
      payloadVersion: _payloadVersion,
      keyVersion: _currentKeyVersion,
    );
    return compute(_encryptBytesInBackground, params);
  }

  /// Decrypts binary data from encrypted JSON format
  /// Returns the original binary data as Uint8List
  static Future<Uint8List> decryptBytes(String encrypted) async {
    final secretKey = await _ensureKey();
    final keyBytes = await secretKey.extractBytes();

    final params = _DecryptionParams(
      encrypted: encrypted,
      keyBytes: keyBytes,
      payloadVersion: _payloadVersion,
    );

    // Run decryption in background isolate to avoid blocking UI
    return await compute(_decryptBytesInBackground, params);
  }

  /// Decrypt string in background isolate (for chat payloads)
  /// Use this for chat text to avoid blocking the UI thread
  static Future<String> decryptInBackground(String encrypted) async {
    final secretKey = await _ensureKey();
    final keyBytes = await secretKey.extractBytes();

    final params = _DecryptionParams(
      encrypted: encrypted,
      keyBytes: keyBytes,
      payloadVersion: _payloadVersion,
    );

    return await compute(_decryptStringInBackground, params);
  }

  /// Decrypt multiple strings in a single background isolate
  /// Much faster than calling decryptInBackground multiple times
  /// Returns list with null for items that failed to decrypt
  static Future<List<String?>> decryptBatchInBackground(
    List<String> encryptedList,
  ) async {
    if (encryptedList.isEmpty) return [];

    final secretKey = await _ensureKey();
    final keyBytes = await secretKey.extractBytes();

    final params = _BatchDecryptionParams(
      encryptedList: encryptedList,
      keyBytes: keyBytes,
      payloadVersion: _payloadVersion,
    );

    return await compute(_decryptBatchInBackground, params);
  }

  /// Try to decrypt with a specific key. Returns null on any failure.
  /// Used by the recovery flow to test old passwords.
  static Future<String?> tryDecryptWithKey(
    String encrypted,
    SecretKey key,
  ) async {
    try {
      final keyBytes = await key.extractBytes();
      final params = _DecryptionParams(
        encrypted: encrypted,
        keyBytes: keyBytes,
        payloadVersion: _payloadVersion,
      );
      return await compute(_decryptStringInBackground, params);
    } catch (_) {
      return null;
    }
  }

  /// Try to decrypt a batch with a specific key. Returns null for failed items.
  /// Used by the recovery flow to bulk-test old passwords.
  static Future<List<String?>> tryDecryptBatchWithKey(
    List<String> encryptedList,
    SecretKey key,
  ) async {
    if (encryptedList.isEmpty) return [];
    try {
      final keyBytes = await key.extractBytes();
      final params = _BatchDecryptionParams(
        encryptedList: encryptedList,
        keyBytes: keyBytes,
        payloadVersion: _payloadVersion,
      );
      return await compute(_decryptBatchInBackground, params);
    } catch (_) {
      return List.filled(encryptedList.length, null);
    }
  }


  /// Derive a key from a password and a base64-encoded salt.
  /// Public for use by KeyVersionService during recovery.
  static Future<SecretKey> deriveKeyFromPasswordAndSalt(
    String password,
    String saltBase64,
  ) async {
    final saltBytes = base64Decode(saltBase64);
    final keyBytes = await _deriveKey(password, saltBytes);
    return SecretKey(keyBytes);
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
    final params = _KeyDerivationParams(
      password: password,
      salt: salt,
      iterations: _kdfIterations,
      bits: 256,
    );
    return await compute(_deriveKeyInBackground, params);
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
          await _writeLocalSecret(saltKey, remoteSaltBase64);
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

      await _writeLocalSecret(saltKey, remoteSaltBase64);
      metadataUpdates[_metadataSaltKey] = remoteSaltBase64;
      return remoteSaltBase64;
    }

    if (remoteSaltBase64 != null) {
      await _writeLocalSecret(saltKey, remoteSaltBase64);
      return remoteSaltBase64;
    }

    if (storedSaltBase64 != null) {
      metadataUpdates[_metadataSaltKey] = storedSaltBase64;
      return storedSaltBase64;
    }

    final generatedSalt = base64Encode(_randomNonce(_saltLength));
    await _writeLocalSecret(saltKey, generatedSalt);
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

  /// Parse key version from metadata value. Returns 1 for legacy/missing values.
  static int _parseKeyVersion(dynamic raw) {
    if (raw == null) return 1;
    if (raw is int) return raw;
    if (raw is String) return int.tryParse(raw) ?? 1;
    return 1;
  }

  /// Extract the key version from an encrypted payload without decrypting it.
  /// Returns null if the payload is not valid JSON or has no 'kv' field.
  static int? extractKeyVersion(String encrypted) {
    try {
      final Map<String, dynamic> payload = jsonDecode(encrypted);
      final kv = payload['kv'];
      if (kv == null) return null;
      if (kv is int) return kv;
      if (kv is String) return int.tryParse(kv);
      return null;
    } catch (_) {
      return null;
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
