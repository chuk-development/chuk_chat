/// Supabase-backed encrypted mirror of the user's MCP connectors.
///
/// This is the connector half of "reinstall anywhere, reconnect
/// automatically". The local [McpStore] keeps the connector config in
/// SharedPreferences and each connector's secret in the OS keychain, which is
/// perfect while the app lives on one device but is gone the moment the user
/// deletes the client or moves to a new machine. To survive that, the whole
/// connector set — config and secrets — is mirrored to Supabase, keyed to the
/// signed-in user, so a fresh install can sign in and pull it back.
///
/// It works exactly like [SupabasePairingSync]: one row per user, holding
/// nothing but ciphertext. The blob carries real key material (OAuth tokens,
/// API keys), so Supabase must only ever see an opaque blob. Everything is
/// encrypted client-side with [EncryptionService] — the same per-user
/// AES-256-GCM key that already protects chat payloads and the pairing record.
/// It is NOT chuk_chat's per-row `mcp_sync_service.dart`: that one assumes the
/// hosted chuk infrastructure. This matches its intent (share connectors,
/// encrypted, owner-only) on CoWork's Supabase + encryption stack.
///
/// Every method is defensive: any failure (not initialised, not signed in, no
/// encryption key, network error, corrupt/foreign ciphertext) resolves to a
/// no-op on save and `null` on load, so an offline or half-configured client
/// keeps working from its local store.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:cowork/services/encryption_service.dart';
import 'package:cowork/services/supabase_service.dart';

/// Reads and writes the encrypted connector mirror in Supabase.
///
/// The contract for the table this talks to is in `docs/SUPABASE_SCHEMA.md`.
class McpConnectorSync {
  const McpConnectorSync();

  /// Table holding one encrypted connector blob per user.
  static const String table = 'cowork_mcp_connectors';

  /// `uuid` — the owner. Primary key. Row-level security ties every row to
  /// `auth.uid()`, so this is also the only row a client can ever see.
  static const String columnUserId = 'user_id';

  /// `text` — the AES-256-GCM ciphertext produced by [EncryptionService.encrypt].
  static const String columnCiphertext = 'ciphertext';

  /// `timestamptz` — last write, for debugging and last-writer-wins.
  static const String columnUpdatedAt = 'updated_at';

  /// Encrypts [payload] and upserts it under the signed-in user's id.
  ///
  /// Best-effort by contract: it silently does nothing when there is no
  /// Supabase, no signed-in user, or no encryption key available, and it
  /// swallows network / server errors. It never throws, so callers can mirror
  /// on every local change without guarding.
  Future<void> save(Map<String, dynamic> payload) async {
    try {
      if (!SupabaseService.isInitialized) return;
      final user = SupabaseService.auth.currentUser;
      if (user == null) return;
      if (!await _ensureEncryptionKey()) return;

      final plaintext = jsonEncode(payload);
      final ciphertext = await EncryptionService.encrypt(plaintext);

      await SupabaseService.client.from(table).upsert(<String, dynamic>{
        columnUserId: user.id,
        columnCiphertext: ciphertext,
        columnUpdatedAt: DateTime.now().toUtc().toIso8601String(),
      }, onConflict: columnUserId);
    } catch (error) {
      if (kDebugMode) {
        debugPrint('⚠️ [McpConnectorSync] save skipped: $error');
      }
    }
  }

  /// Fetches and decrypts the mirrored connector blob for the signed-in user.
  ///
  /// Returns `null` when there is nothing stored, when no user is signed in,
  /// when the encryption key is unavailable, or when the ciphertext cannot be
  /// decrypted or parsed. The caller then falls back to the local store.
  Future<Map<String, dynamic>?> load() async {
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
      final decoded = jsonDecode(plaintext);
      if (decoded is! Map) return null;
      return Map<String, dynamic>.from(decoded);
    } catch (error) {
      if (kDebugMode) {
        debugPrint('⚠️ [McpConnectorSync] load returned null: $error');
      }
      return null;
    }
  }

  /// Removes the mirrored blob for the signed-in user. Best-effort; never
  /// throws. Used when the user clears every connector.
  Future<void> clear() async {
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
        debugPrint('⚠️ [McpConnectorSync] clear skipped: $error');
      }
    }
  }

  /// Makes sure the per-user encryption key is loaded. It is cached after a
  /// password sign-in; on a fresh reinstall the caller must have unlocked it
  /// (the usual password step) before connectors can be mirrored or read back.
  Future<bool> _ensureEncryptionKey() async {
    if (EncryptionService.hasKey) return true;
    return EncryptionService.tryLoadKey();
  }
}
