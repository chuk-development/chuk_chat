import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/utils/privacy_logger.dart';

/// Syncs encrypted OAuth tokens (Google, GitHub, MCP connectors, etc.) to
/// Supabase so they are available on every device the user signs into.
///
/// Credentials are encrypted client-side with the same AES-256-GCM key used
/// for chats. The Supabase table `service_credentials` stores one row per
/// (user_id, service_name) with an `encrypted_data` TEXT column.
class ServiceCredentialsService {
  const ServiceCredentialsService._();

  static const String _table = 'service_credentials';

  // ---------------------------------------------------------------------------
  // Save / load / delete
  // ---------------------------------------------------------------------------

  /// Encrypt and upsert credentials for [serviceName].
  ///
  /// [data] is a plain-text JSON-serialisable map (e.g. access_token,
  /// refresh_token, expiry). It is encrypted before leaving the device.
  static Future<void> save(
    String serviceName,
    Map<String, dynamic> data,
  ) async {
    try {
      final user = SupabaseService.auth.currentUser;
      if (user == null) return;
      if (!EncryptionService.hasKey) return;

      final plaintext = jsonEncode(data);
      final encrypted = await EncryptionService.encrypt(plaintext);

      await SupabaseService.client.from(_table).upsert({
        'user_id': user.id,
        'service_name': serviceName,
        'encrypted_data': encrypted,
      }, onConflict: 'user_id,service_name').timeout(
        const Duration(seconds: 15),
      );

      if (kDebugMode) {
        pLog('ServiceCredentials: saved $serviceName');
      }
    } catch (e) {
      if (kDebugMode) {
        pLog('ServiceCredentials: failed to save $serviceName – $e');
      }
    }
  }

  /// Load and decrypt credentials for [serviceName].
  ///
  /// Returns null if no credentials are stored or decryption fails.
  static Future<Map<String, dynamic>?> load(String serviceName) async {
    try {
      final user = SupabaseService.auth.currentUser;
      if (user == null) return null;
      if (!EncryptionService.hasKey) return null;

      final rows = await SupabaseService.client
          .from(_table)
          .select('encrypted_data')
          .eq('user_id', user.id)
          .eq('service_name', serviceName);

      if (rows.isEmpty) return null;
      final row = rows.first;

      final encrypted = row['encrypted_data'] as String?;
      if (encrypted == null || encrypted.isEmpty) return null;

      final plaintext = await EncryptionService.decrypt(encrypted);
      return jsonDecode(plaintext) as Map<String, dynamic>;
    } catch (e) {
      if (kDebugMode) {
        pLog('ServiceCredentials: failed to load $serviceName – $e');
      }
      return null;
    }
  }

  /// Load all stored credentials for the current user.
  ///
  /// Returns a map of service_name → decrypted data.
  ///
  /// By default a network or query failure is swallowed and an empty map is
  /// returned. Pass [throwOnError] to have such a failure rethrow instead — a
  /// caller that reconciles deletions needs to tell "the server has no rows"
  /// apart from "the fetch failed", or a transient outage would look like a
  /// remote deletion. Individual rows that fail to decrypt are always skipped,
  /// never thrown.
  ///
  /// Pass [undecryptable] to collect the service names of rows that were
  /// present but could not be decrypted. A caller that reconciles deletions
  /// must exclude these — a skipped row is present on the server, not deleted,
  /// so treating it as absent would wrongly forget a still-working local copy.
  static Future<Map<String, Map<String, dynamic>>> loadAll({
    bool throwOnError = false,
    Set<String>? undecryptable,
  }) async {
    final results = <String, Map<String, dynamic>>{};
    try {
      final user = SupabaseService.auth.currentUser;
      if (user == null) {
        // With throwOnError this must not read as "the server has no rows": a
        // deletion-reconciling caller would then forget every local row.
        if (throwOnError) {
          throw StateError('Not signed in; cannot load credentials.');
        }
        return results;
      }
      if (!EncryptionService.hasKey) {
        if (throwOnError) {
          throw StateError('No encryption key; cannot load credentials.');
        }
        return results;
      }

      final rows = await SupabaseService.client
          .from(_table)
          .select('service_name, encrypted_data')
          .eq('user_id', user.id)
          .timeout(const Duration(seconds: 15));

      for (final row in rows) {
        final name = row['service_name'] as String?;
        final encrypted = row['encrypted_data'] as String?;
        if (name == null) continue;
        if (encrypted == null || encrypted.isEmpty) {
          // Present on the server but carrying no payload. Report it so a
          // deletion-reconciling caller does not read the gap as a deletion.
          undecryptable?.add(name);
          continue;
        }

        try {
          final plaintext = await EncryptionService.decrypt(encrypted);
          results[name] = jsonDecode(plaintext) as Map<String, dynamic>;
        } catch (_) {
          // Present but unreadable (key mismatch, corruption). Skipped from the
          // result, but reported so a deletion-reconciling caller does not read
          // the gap as "the row is gone".
          undecryptable?.add(name);
        }
      }

      if (kDebugMode) {
        pLog('ServiceCredentials: loaded ${results.length} credentials');
      }
    } catch (e) {
      if (kDebugMode) {
        pLog('ServiceCredentials: failed to load all – $e');
      }
      if (throwOnError) rethrow;
    }
    return results;
  }

  /// Delete credentials for [serviceName]. Returns how many rows were removed.
  ///
  /// A Postgres delete whose filter matches no visible row completes without
  /// error, so a caller that must know the row is truly gone cannot rely on the
  /// absence of an exception. The `.select()` returns the deleted rows, so a
  /// return of 0 means "nothing was removed" — the row was already absent, or
  /// not visible to this session (e.g. an RLS mismatch). The tombstone caller
  /// keeps retrying in that case instead of resurrecting the connector.
  ///
  /// By default a failure is swallowed and 0 is returned. Pass [throwOnError]
  /// when the caller must distinguish a failed request from an empty delete.
  static Future<int> delete(
    String serviceName, {
    bool throwOnError = false,
  }) async {
    try {
      final user = SupabaseService.auth.currentUser;
      if (user == null) {
        if (throwOnError) {
          throw StateError('Not signed in; cannot delete $serviceName.');
        }
        return 0;
      }

      final deleted = await SupabaseService.client
          .from(_table)
          .delete()
          .eq('user_id', user.id)
          .eq('service_name', serviceName)
          .select('service_name')
          .timeout(const Duration(seconds: 15));

      if (kDebugMode) {
        pLog('ServiceCredentials: deleted $serviceName (${deleted.length} rows)');
      }
      return deleted.length;
    } catch (e) {
      if (kDebugMode) {
        pLog('ServiceCredentials: failed to delete $serviceName – $e');
      }
      if (throwOnError) rethrow;
      return 0;
    }
  }
}
