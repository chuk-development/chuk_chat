/// Supabase-backed encrypted mirror of the user's secret set
/// (docs/WIRE_CONTRACT.md "Secrets", docs/SUPABASE_SCHEMA.md `cowork_secrets`).
///
/// One row per name: the name in plaintext (a label, so the sync can compare
/// without decrypting) and the value as an [EncryptionService] envelope, the
/// same per-user password-derived AES-256-GCM key every other Agents mirror
/// uses. A fresh install signs in, pulls the rows, decrypts, and adopts them
/// into the local [SecretsStore].
///
/// Every method is defensive: any failure (not initialised, not signed in, no
/// encryption key, network error, corrupt ciphertext) is a no-op on save and
/// `null` on load, so an offline or half-configured client keeps working from
/// its local store. Values are never logged.
library;

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';

/// The pluggable half, so a test and a signed-out app can swap it out.
abstract interface class SecretsMirror {
  Future<void> save(String name, String value);
  Future<void> delete(String name);

  /// Name -> value, or null when nothing usable could be read.
  Future<Map<String, String>?> load();
}

/// A mirror that does nothing. The default before sign-in and in tests.
class NoopSecretsMirror implements SecretsMirror {
  const NoopSecretsMirror();

  @override
  Future<void> save(String name, String value) async {}

  @override
  Future<void> delete(String name) async {}

  @override
  Future<Map<String, String>?> load() async => null;
}

class SecretsSync implements SecretsMirror {
  const SecretsSync();

  static const String table = 'cowork_secrets';
  static const String columnUserId = 'user_id';
  static const String columnName = 'name';
  static const String columnCiphertext = 'ciphertext';
  static const String columnUpdatedAt = 'updated_at';

  @override
  Future<void> save(String name, String value) async {
    try {
      if (!SupabaseService.isInitialized) return;
      final user = SupabaseService.auth.currentUser;
      if (user == null) return;
      if (!await _ensureEncryptionKey()) return;
      final ciphertext = await EncryptionService.encrypt(value);
      await SupabaseService.client.from(table).upsert(<String, dynamic>{
        columnUserId: user.id,
        columnName: name,
        columnCiphertext: ciphertext,
        columnUpdatedAt: DateTime.now().toUtc().toIso8601String(),
      }, onConflict: '$columnUserId,$columnName');
    } catch (error) {
      if (kDebugMode) debugPrint('⚠️ [SecretsSync] save skipped: $error');
    }
  }

  @override
  Future<void> delete(String name) async {
    try {
      if (!SupabaseService.isInitialized) return;
      final user = SupabaseService.auth.currentUser;
      if (user == null) return;
      await SupabaseService.client
          .from(table)
          .delete()
          .eq(columnUserId, user.id)
          .eq(columnName, name);
    } catch (error) {
      if (kDebugMode) debugPrint('⚠️ [SecretsSync] delete skipped: $error');
    }
  }

  @override
  Future<Map<String, String>?> load() async {
    try {
      if (!SupabaseService.isInitialized) return null;
      final user = SupabaseService.auth.currentUser;
      if (user == null) return null;
      final rows = await SupabaseService.client
          .from(table)
          .select('$columnName, $columnCiphertext')
          .eq(columnUserId, user.id);
      if (rows.isEmpty) return <String, String>{};
      if (!await _ensureEncryptionKey()) return null;
      final out = <String, String>{};
      for (final row in rows) {
        final name = row[columnName];
        final ciphertext = row[columnCiphertext];
        if (name is! String || ciphertext is! String || ciphertext.isEmpty) {
          continue;
        }
        try {
          final value = await EncryptionService.decrypt(ciphertext);
          if (value.isNotEmpty) out[name] = value;
        } catch (_) {
          // One undecryptable row (another key version, a foreign write)
          // costs that row, not the set.
        }
      }
      return out;
    } catch (error) {
      if (kDebugMode) debugPrint('⚠️ [SecretsSync] load returned null: $error');
      return null;
    }
  }

  Future<bool> _ensureEncryptionKey() async {
    if (EncryptionService.hasKey) return true;
    return EncryptionService.tryLoadKey();
  }
}
