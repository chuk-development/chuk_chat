/// chuk_chat's connector mirror, read (and later written) by CoWork.
///
/// chuk_chat keeps every connected MCP server in Supabase `service_credentials`
/// as one row per connector: `service_name = 'mcp_<catalogue id>'`,
/// `encrypted_data` = an `EncryptionService` envelope of
/// `{"connection": McpConnection.toJson, "secrets": _McpSecrets.toJson | null}`
/// (chuk's `McpSyncBlob`). CoWork and chuk_chat share the Supabase project, the
/// user and the password-derived key, so a row chuk wrote is readable here as
/// it is — which is how a connector signed in inside chuk_chat shows up as
/// connected in CoWork (bead cowork-hza).
///
/// CoWork's own mirror (`cowork_mcp_connectors`, one blob per user) stays the
/// primary; this one fills the gaps. Everything is best-effort: no Supabase,
/// no user, no key, a missing table, an undecryptable row — each resolves to
/// "nothing from chuk" and the local store keeps working. Nothing decrypted is
/// ever logged.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:cowork/services/encryption_service.dart';
import 'package:cowork/services/supabase_service.dart';

/// One chuk row, decrypted: the connection as JSON and its secrets, if any.
@immutable
class ChukMcpRow {
  const ChukMcpRow({required this.id, required this.connection, this.secrets});

  /// The catalogue id from the service name (`mcp_notion` -> `notion`).
  final String id;

  /// `McpConnection.toJson` as chuk wrote it (tools may be present; the
  /// receiver drops them and lists live).
  final Map<String, dynamic> connection;

  /// `_McpSecrets.toJson`, or null for a connector without a stored token (an
  /// app-session server authenticates with the live account instead).
  final Map<String, dynamic>? secrets;

  /// chuk's blob shape, for the write-back.
  Map<String, dynamic> toBlob() => <String, dynamic>{
    'connection': connection,
    'secrets': secrets,
  };

  /// Parses one decrypted blob. Null when it is not chuk's shape or the
  /// connection inside names a different id than the row (a foreign or
  /// corrupt row is skipped, not trusted).
  static ChukMcpRow? fromBlob(String id, Object? decoded) {
    if (decoded is! Map) return null;
    final rawConnection = decoded['connection'];
    if (rawConnection is! Map) return null;
    final connection = rawConnection.map((k, v) => MapEntry('$k', v));
    if ((connection['id'] ?? '').toString() != id) return null;
    final rawSecrets = decoded['secrets'];
    return ChukMcpRow(
      id: id,
      connection: connection,
      secrets: rawSecrets is Map
          ? rawSecrets.map((k, v) => MapEntry('$k', v))
          : null,
    );
  }
}

abstract interface class ChukMcpMirror {
  /// Every `mcp_*` row of the signed-in user, by catalogue id. Null when the
  /// mirror cannot be read at all (no Supabase, no user, no key, no table);
  /// an empty map when chuk has nothing.
  Future<Map<String, ChukMcpRow>?> load();

  /// Writes one row in chuk's shape. Best-effort.
  Future<void> save(ChukMcpRow row);

  /// Removes one row. Best-effort. Callers verify the row is theirs first.
  Future<void> delete(String id);
}

class NoopChukMcpMirror implements ChukMcpMirror {
  const NoopChukMcpMirror();

  @override
  Future<Map<String, ChukMcpRow>?> load() async => null;

  @override
  Future<void> save(ChukMcpRow row) async {}

  @override
  Future<void> delete(String id) async {}
}

class ChukMcpSync implements ChukMcpMirror {
  const ChukMcpSync();

  static const String table = 'service_credentials';
  static const String columnUserId = 'user_id';
  static const String columnServiceName = 'service_name';
  static const String columnEncryptedData = 'encrypted_data';
  static const String servicePrefix = 'mcp_';

  static String serviceName(String id) => '$servicePrefix$id';

  @override
  Future<Map<String, ChukMcpRow>?> load() async {
    try {
      if (!SupabaseService.isInitialized) return null;
      final user = SupabaseService.auth.currentUser;
      if (user == null) return null;
      final rows = await SupabaseService.client
          .from(table)
          .select('$columnServiceName, $columnEncryptedData')
          .eq(columnUserId, user.id)
          .like(columnServiceName, '$servicePrefix%');
      if (rows.isEmpty) return <String, ChukMcpRow>{};
      if (!await _ensureEncryptionKey()) return null;
      final out = <String, ChukMcpRow>{};
      var unreadable = 0;
      for (final row in rows) {
        final name = row[columnServiceName];
        final ciphertext = row[columnEncryptedData];
        if (name is! String || !name.startsWith(servicePrefix)) continue;
        if (ciphertext is! String || ciphertext.isEmpty) continue;
        final id = name.substring(servicePrefix.length);
        if (id.isEmpty) continue;
        try {
          final plaintext = await EncryptionService.decrypt(ciphertext);
          final parsed = ChukMcpRow.fromBlob(id, jsonDecode(plaintext));
          if (parsed != null) out[id] = parsed;
        } catch (_) {
          // Another key version, a foreign write: that row, not the set.
          unreadable++;
        }
      }
      if (unreadable > 0 && kDebugMode) {
        debugPrint('⚠️ [ChukMcpSync] $unreadable row(s) not readable');
      }
      return out;
    } catch (error) {
      if (kDebugMode) debugPrint('⚠️ [ChukMcpSync] load returned null: $error');
      return null;
    }
  }

  @override
  Future<void> save(ChukMcpRow row) async {
    try {
      if (!SupabaseService.isInitialized) return;
      final user = SupabaseService.auth.currentUser;
      if (user == null) return;
      if (!await _ensureEncryptionKey()) return;
      final ciphertext = await EncryptionService.encrypt(
        jsonEncode(row.toBlob()),
      );
      await SupabaseService.client.from(table).upsert(<String, dynamic>{
        columnUserId: user.id,
        columnServiceName: serviceName(row.id),
        columnEncryptedData: ciphertext,
      }, onConflict: '$columnUserId,$columnServiceName');
    } catch (error) {
      if (kDebugMode) debugPrint('⚠️ [ChukMcpSync] save skipped: $error');
    }
  }

  @override
  Future<void> delete(String id) async {
    try {
      if (!SupabaseService.isInitialized) return;
      final user = SupabaseService.auth.currentUser;
      if (user == null) return;
      await SupabaseService.client
          .from(table)
          .delete()
          .eq(columnUserId, user.id)
          .eq(columnServiceName, serviceName(id));
    } catch (error) {
      if (kDebugMode) debugPrint('⚠️ [ChukMcpSync] delete skipped: $error');
    }
  }

  Future<bool> _ensureEncryptionKey() async {
    if (EncryptionService.hasKey) return true;
    return EncryptionService.tryLoadKey();
  }
}
