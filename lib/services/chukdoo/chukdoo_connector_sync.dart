// lib/services/chukdoo/chukdoo_connector_sync.dart
//
// The encrypted cloud copy of the Chukdoo connector, so every chuk_chat
// install of the same account has it without pairing again.
//
// One row per user in `chukdoo_connectors` (migration
// supabase/migrations/20261102000000_chukdoo_connectors.sql), holding only an
// AES-256-GCM envelope made by [EncryptionService.encrypt]. The plaintext is
// the connector record (see `ChukdooRecord`): the paired device's token and
// the chukdoo data key, or a tombstone after a disconnect. Supabase never
// sees either in the clear.
//
// Unlike `McpConnectorSync`, [load] tells "there is no row" apart from "the
// row could not be read": an empty table means "push what this device has",
// a failed read means "do nothing this time".

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';

/// What a read of the mirror found.
class ChukdooMirrorRead {
  const ChukdooMirrorRead.row(Map<String, dynamic> this.payload)
    : ok = true,
      unreadable = false;
  const ChukdooMirrorRead.empty()
    : payload = null,
      ok = true,
      unreadable = false;
  const ChukdooMirrorRead.failed({this.unreadable = false})
    : payload = null,
      ok = false;

  /// False when the read failed (offline, no key, foreign ciphertext).
  final bool ok;

  /// True when the row exists but cannot be opened with the current key
  /// (sealed under another key, or corrupt). Retrying will not help.
  final bool unreadable;

  /// The decrypted record, or null when there is no row (or [ok] is false).
  final Map<String, dynamic>? payload;
}

/// The cloud side of the connector. An interface so tests can swap it.
abstract interface class ChukdooMirror {
  Future<ChukdooMirrorRead> load();

  /// Encrypts and stores [payload]. Returns false when it could not.
  Future<bool> save(Map<String, dynamic> payload);
}

/// [ChukdooMirror] over chuk_chat's Supabase and [EncryptionService].
class SupabaseChukdooMirror implements ChukdooMirror {
  const SupabaseChukdooMirror();

  static const String table = 'chukdoo_connectors';
  static const String columnUserId = 'user_id';
  static const String columnCiphertext = 'ciphertext';
  static const String columnUpdatedAt = 'updated_at';

  @override
  Future<ChukdooMirrorRead> load() async {
    try {
      if (!SupabaseService.isInitialized) {
        return const ChukdooMirrorRead.failed();
      }
      final user = SupabaseService.auth.currentUser;
      if (user == null) return const ChukdooMirrorRead.failed();
      final row = await SupabaseService.client
          .from(table)
          .select(columnCiphertext)
          .eq(columnUserId, user.id)
          .maybeSingle();
      if (row == null) return const ChukdooMirrorRead.empty();
      final ciphertext = row[columnCiphertext] as String?;
      if (ciphertext == null || ciphertext.isEmpty) {
        return const ChukdooMirrorRead.empty();
      }
      if (!await _ensureKey()) return const ChukdooMirrorRead.failed();
      final Object? decoded;
      try {
        decoded = jsonDecode(await EncryptionService.decrypt(ciphertext));
      } catch (_) {
        return const ChukdooMirrorRead.failed(unreadable: true);
      }
      if (decoded is! Map) {
        return const ChukdooMirrorRead.failed(unreadable: true);
      }
      return ChukdooMirrorRead.row(Map<String, dynamic>.from(decoded));
    } on PostgrestException catch (error) {
      // A missing table (migration not applied) holds no row, so no record
      // can exist under any key.
      if (error.code == 'PGRST205' || error.code == '42P01') {
        return const ChukdooMirrorRead.empty();
      }
      if (kDebugMode) {
        debugPrint('[ChukdooMirror] load failed: ${error.code}');
      }
      return const ChukdooMirrorRead.failed();
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[ChukdooMirror] load failed: ${error.runtimeType}');
      }
      return const ChukdooMirrorRead.failed();
    }
  }

  @override
  Future<bool> save(Map<String, dynamic> payload) async {
    try {
      if (!SupabaseService.isInitialized) return false;
      final user = SupabaseService.auth.currentUser;
      if (user == null) return false;
      if (!await _ensureKey()) return false;
      final ciphertext = await EncryptionService.encrypt(jsonEncode(payload));
      await SupabaseService.client.from(table).upsert(<String, dynamic>{
        columnUserId: user.id,
        columnCiphertext: ciphertext,
        columnUpdatedAt: DateTime.now().toUtc().toIso8601String(),
      }, onConflict: columnUserId);
      return true;
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[ChukdooMirror] save failed: ${error.runtimeType}');
      }
      return false;
    }
  }

  Future<bool> _ensureKey() async {
    if (EncryptionService.hasKey) return true;
    return EncryptionService.tryLoadKey();
  }
}
