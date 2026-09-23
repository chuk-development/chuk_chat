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
  /// [readEncryptedPairing] says which of those it was.
  Future<AgentsStoredPairing?> loadEncryptedPairing() async =>
      (await readEncryptedPairing()).pairing;

  /// The same read as [loadEncryptedPairing], with the reason when there is no
  /// record. The restore supervisor shows the reason to the user ("Looking for
  /// your computer…" is not "Add your computer"). Never throws.
  Future<AgentsCloudPairingRead> readEncryptedPairing() async {
    if (!SupabaseService.isInitialized) {
      return const AgentsCloudPairingRead(AgentsCloudPairingOutcome.noSession);
    }
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      return const AgentsCloudPairingRead(AgentsCloudPairingOutcome.noSession);
    }
    final Map<String, dynamic>? row;
    try {
      row = await SupabaseService.client
          .from(table)
          .select(columnCiphertext)
          .eq(columnUserId, user.id)
          .maybeSingle();
    } catch (error) {
      if (kDebugMode) {
        debugPrint(
          '⚠️ [AgentsPairingSync] read failed: ${error.runtimeType}',
        );
      }
      return const AgentsCloudPairingRead(AgentsCloudPairingOutcome.network);
    }
    final ciphertext = row?[columnCiphertext] as String?;
    if (ciphertext == null || ciphertext.isEmpty) {
      return const AgentsCloudPairingRead(AgentsCloudPairingOutcome.noRecord);
    }
    try {
      if (!await _ensureEncryptionKey()) {
        return const AgentsCloudPairingRead(
          AgentsCloudPairingOutcome.keyLocked,
        );
      }
    } catch (_) {
      return const AgentsCloudPairingRead(AgentsCloudPairingOutcome.keyLocked);
    }
    try {
      final plaintext = await EncryptionService.decrypt(ciphertext);
      final pairing = AgentsStoredPairing.tryParse(plaintext);
      if (pairing == null) {
        return const AgentsCloudPairingRead(
          AgentsCloudPairingOutcome.decryptFailed,
        );
      }
      return AgentsCloudPairingRead(AgentsCloudPairingOutcome.found, pairing);
    } catch (error) {
      if (kDebugMode) {
        debugPrint(
          '⚠️ [AgentsPairingSync] decrypt failed: ${error.runtimeType}',
        );
      }
      return const AgentsCloudPairingRead(
        AgentsCloudPairingOutcome.decryptFailed,
      );
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

/// How a read of the encrypted mirror ended.
enum AgentsCloudPairingOutcome {
  /// A record was read and decrypted.
  found,

  /// No Supabase client or no signed-in user yet.
  noSession,

  /// The account has no mirrored record: this account never added a computer.
  noRecord,

  /// A record exists, but the account key is not unlocked yet.
  keyLocked,

  /// The read did not reach Supabase (offline, timeout, server error).
  network,

  /// A record exists, but it cannot be decrypted or parsed with this key.
  decryptFailed,
}

/// One read of the encrypted mirror: the record, or why there is none.
@immutable
class AgentsCloudPairingRead {
  const AgentsCloudPairingRead(this.outcome, [this.pairing]);

  final AgentsCloudPairingOutcome outcome;

  /// Non-null only when [outcome] is [AgentsCloudPairingOutcome.found].
  final AgentsStoredPairing? pairing;
}
