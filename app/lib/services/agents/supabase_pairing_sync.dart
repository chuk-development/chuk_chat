/// Supabase-backed encrypted mirror of the Agents trust record.
///
/// This is the other half of "reinstall anywhere, reconnect automatically"
/// (see `docs/PRODUCT_PHILOSOPHY.md`). The local [AgentsPairingStore] keeps the
/// trust record in the OS keychain, which is perfect while the app lives on one
/// device but is gone the moment the user deletes the client or moves to a new
/// phone. To survive that, the same record is mirrored to Supabase, keyed to the
/// signed-in user, so a fresh install can sign in and pull it back.
///
/// The record contains real key material (the 32-byte channel key). Supabase
/// must therefore only ever hold **ciphertext**. Everything is encrypted
/// client-side with [EncryptionService] — the same per-user AES-256-GCM key that
/// already protects chat payloads, derived from the user's password via PBKDF2
/// with a salt held in `user_metadata`. Supabase, its admins, and anyone with a
/// stolen anon key see an opaque blob and nothing else.
///
/// Both methods are defensive: any failure (not initialised, not signed in, no
/// encryption key, network error, corrupt/foreign ciphertext) resolves to a
/// no-op on save and `null` on load, so an offline or half-configured client
/// keeps working from its local store.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/services/agents/agents_pairing_store.dart';
import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';

/// Reads and writes the encrypted trust-record mirror in Supabase.
///
/// The contract for the table this talks to is in `docs/SUPABASE_SCHEMA.md`.
class SupabasePairingSync {
  const SupabasePairingSync();

  /// Table holding one encrypted trust record per user.
  static const String table = 'cowork_pairings';

  /// `uuid` — the owner. Primary key. Row-level security ties every row to
  /// `auth.uid()`, so this is also the only row a client can ever see.
  static const String columnUserId = 'user_id';

  /// `text` — the AES-256-GCM ciphertext produced by [EncryptionService.encrypt].
  static const String columnCiphertext = 'ciphertext';

  /// `timestamptz` — last write, for debugging and last-writer-wins.
  static const String columnUpdatedAt = 'updated_at';

  /// Encrypts [pairing] and upserts it under the signed-in user's id.
  ///
  /// Best-effort by contract: it silently does nothing when there is no
  /// Supabase, no signed-in user, or no encryption key available, and it
  /// swallows network / server errors. It never throws, so callers can mirror
  /// on every local save without guarding.
  Future<void> saveEncryptedPairing(AgentsStoredPairing pairing) async {
    await publishEncryptedPairing(pairing);
  }

  /// Returns success so the supervisor can retry a locked key or failed upload.
  Future<bool> publishEncryptedPairing(AgentsStoredPairing pairing) async {
    try {
      if (!SupabaseService.isInitialized) return false;
      final user = SupabaseService.auth.currentUser;
      if (user == null) return false;
      if (!await _ensureEncryptionKey()) return false;

      final plaintext = jsonEncode(pairing.toJson());
      final ciphertext = await EncryptionService.encrypt(plaintext);

      await SupabaseService.client.from(table).upsert(<String, dynamic>{
        columnUserId: user.id,
        columnCiphertext: ciphertext,
        columnUpdatedAt: DateTime.now().toUtc().toIso8601String(),
      }, onConflict: columnUserId);
      return true;
    } catch (error) {
      // Best-effort mirror: offline / server errors must not break local save.
      if (kDebugMode) {
        debugPrint('⚠️ [AgentsPairingSync] save skipped: $error');
      }
      return false;
    }
  }

  /// Fetches and decrypts the mirrored trust record for the signed-in user.
  ///
  /// Returns `null` when there is nothing stored, when no user is signed in,
  /// when the encryption key is unavailable, or when the ciphertext cannot be
  /// decrypted or parsed (for example a row written under a different password
  /// era). The caller then falls back to the local store or a fresh pairing.
  Future<AgentsStoredPairing?> loadEncryptedPairing() async {
    try {
      if (!SupabaseService.isInitialized) return null;
      final user = SupabaseService.auth.currentUser;
      if (user == null) return null;

      final row = await SupabaseService.client
          .from(table)
          .select(columnCiphertext)
          .eq(columnUserId, user.id)
          .maybeSingle();
      if (row == null) return null;

      final ciphertext = row[columnCiphertext] as String?;
      if (ciphertext == null || ciphertext.isEmpty) return null;

      if (!await _ensureEncryptionKey()) return null;

      final plaintext = await EncryptionService.decrypt(ciphertext);
      return AgentsStoredPairing.tryParse(plaintext);
    } catch (error) {
      if (kDebugMode) {
        debugPrint('⚠️ [AgentsPairingSync] load returned null: $error');
      }
      return null;
    }
  }

  /// Removes the mirrored record for the signed-in user — the cloud side of the
  /// local "un-pair / forget" action. Best-effort; never throws.
  Future<void> clearEncryptedPairing() async {
    try {
      if (!SupabaseService.isInitialized) return;
      final user = SupabaseService.auth.currentUser;
      if (user == null) return;
      await SupabaseService.client
          .from(table)
          .delete()
          .eq(columnUserId, user.id);
    } catch (error) {
      if (kDebugMode) {
        debugPrint('⚠️ [AgentsPairingSync] clear skipped: $error');
      }
    }
  }

  /// Makes sure the per-user encryption key is loaded. It is cached after a
  /// password sign-in; on a fresh reinstall the caller must have unlocked it
  /// (the usual password step) before pairing can be mirrored or read back.
  Future<bool> _ensureEncryptionKey() async {
    if (EncryptionService.hasKey) return true;
    return EncryptionService.tryLoadKey();
  }
}
