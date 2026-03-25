import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';

/// Represents a previous encryption key's metadata.
class PreviousKeyInfo {
  final String salt;
  final int version;

  const PreviousKeyInfo({required this.salt, required this.version});

  factory PreviousKeyInfo.fromJson(Map<String, dynamic> json) {
    final salt = json['salt'];
    if (salt is! String || salt.isEmpty) {
      throw const FormatException('Invalid or missing salt in previous key');
    }
    return PreviousKeyInfo(
      salt: salt,
      version: json['version'] is int
          ? json['version'] as int
          : int.tryParse(json['version'].toString()) ?? 1,
    );
  }

  Map<String, dynamic> toJson() => {'salt': salt, 'version': version};
}

/// Manages encryption key versions for password reset recovery.
///
/// When a user resets their password, the old salt+version is preserved
/// in the `previous_keys` array in Supabase user metadata. This allows
/// recovering old chats later by entering the old password.
class KeyVersionService {
  const KeyVersionService._();

  static const String _metadataPreviousKeysKey = 'previous_keys';
  static const String _metadataSaltKey = 'chat_kdf_salt';
  static const String _metadataVersionKey = 'chat_key_version';

  /// Get the list of previous keys from user metadata.
  static List<PreviousKeyInfo> getPreviousKeys(User user) {
    final raw = user.userMetadata?[_metadataPreviousKeysKey];
    if (raw == null) return [];
    if (raw is! List) return [];
    try {
      return raw
          .whereType<Map<String, dynamic>>()
          .map(PreviousKeyInfo.fromJson)
          .toList();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ [KeyVersion] Failed to parse previous_keys: $e');
      }
      return [];
    }
  }

  /// Push the current key (salt + version) into the previous_keys array.
  /// Called during password reset before generating a new key.
  static Future<User?> promoteCurrentToPrevious(User user) async {
    final currentSalt = user.userMetadata?[_metadataSaltKey] as String?;
    final currentVersionRaw = user.userMetadata?[_metadataVersionKey];
    if (currentSalt == null) return null;

    final currentVersion = _parseVersion(currentVersionRaw);

    final previousKeys = getPreviousKeys(user);

    // Don't add duplicate entries
    if (previousKeys.any((k) => k.version == currentVersion)) return null;

    previousKeys.add(PreviousKeyInfo(
      salt: currentSalt,
      version: currentVersion,
    ));

    return _updateMetadata(user, {
      _metadataPreviousKeysKey:
          previousKeys.map((k) => k.toJson()).toList(),
    });
  }

  /// Remove a previous key entry after successful recovery or deletion.
  static Future<User?> removePreviousKey(User user, int version) async {
    final previousKeys = getPreviousKeys(user);
    previousKeys.removeWhere((k) => k.version == version);

    return _updateMetadata(user, {
      _metadataPreviousKeysKey:
          previousKeys.map((k) => k.toJson()).toList(),
    });
  }

  /// Check if there are any previous keys (i.e., password was reset).
  static bool hasPreviousKeys(User user) {
    return getPreviousKeys(user).isNotEmpty;
  }

  /// Get the salt for a specific previous key version.
  /// Returns null if the version is not found.
  static String? getSaltForVersion(User user, int version) {
    final previousKeys = getPreviousKeys(user);
    for (final key in previousKeys) {
      if (key.version == version) return key.salt;
    }
    return null;
  }

  /// Derive an encryption key for a specific old password + salt.
  /// Used during the recovery flow.
  static Future<SecretKey> deriveKeyForVersion(
    String password,
    String saltBase64,
  ) {
    return EncryptionService.deriveKeyFromPasswordAndSalt(password, saltBase64);
  }

  static int _parseVersion(dynamic raw) {
    if (raw == null) return 1;
    if (raw is int) return raw;
    if (raw is String) return int.tryParse(raw) ?? 1;
    return 1;
  }

  static Future<User?> _updateMetadata(
    User user,
    Map<String, dynamic> patch,
  ) async {
    final existing = Map<String, dynamic>.from(user.userMetadata ?? {});
    for (final entry in patch.entries) {
      existing[entry.key] = entry.value;
    }
    try {
      final response = await SupabaseService.auth.updateUser(
        UserAttributes(data: existing),
      );
      return response.user;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ [KeyVersion] Failed to update metadata: $e');
      }
      return null;
    }
  }
}
