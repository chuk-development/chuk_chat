import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/utils/privacy_logger.dart';

/// Syncs encrypted OAuth tokens (Spotify, Google, GitHub, etc.) to Supabase
/// so they are available on every device the user signs into.
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
      }, onConflict: 'user_id,service_name');

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
  static Future<Map<String, Map<String, dynamic>>> loadAll() async {
    final results = <String, Map<String, dynamic>>{};
    try {
      final user = SupabaseService.auth.currentUser;
      if (user == null) return results;
      if (!EncryptionService.hasKey) return results;

      final rows = await SupabaseService.client
          .from(_table)
          .select('service_name, encrypted_data')
          .eq('user_id', user.id);

      for (final row in rows) {
        final name = row['service_name'] as String?;
        final encrypted = row['encrypted_data'] as String?;
        if (name == null || encrypted == null || encrypted.isEmpty) continue;

        try {
          final plaintext = await EncryptionService.decrypt(encrypted);
          results[name] = jsonDecode(plaintext) as Map<String, dynamic>;
        } catch (_) {
          // Skip credentials that fail to decrypt (key mismatch, corruption).
        }
      }

      if (kDebugMode) {
        pLog('ServiceCredentials: loaded ${results.length} credentials');
      }
    } catch (e) {
      if (kDebugMode) {
        pLog('ServiceCredentials: failed to load all – $e');
      }
    }
    return results;
  }

  /// Delete credentials for [serviceName].
  static Future<void> delete(String serviceName) async {
    try {
      final user = SupabaseService.auth.currentUser;
      if (user == null) return;

      await SupabaseService.client
          .from(_table)
          .delete()
          .eq('user_id', user.id)
          .eq('service_name', serviceName);

      if (kDebugMode) {
        pLog('ServiceCredentials: deleted $serviceName');
      }
    } catch (e) {
      if (kDebugMode) {
        pLog('ServiceCredentials: failed to delete $serviceName – $e');
      }
    }
  }
}
