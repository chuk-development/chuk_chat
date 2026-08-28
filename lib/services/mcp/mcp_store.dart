// lib/services/mcp/mcp_store.dart
//
// Storage for MCP connections. The non-secret config is a JSON list in
// SharedPreferences under `mcp_connections_v1`; each connection's bearer token
// lives in secure storage under `mcp_secrets_<id>`, exactly as the plan asks.
//
// The store also assembles the forward payloads WS-D needs at task launch —
// `[{name, url, auth, access_token?}]` — resolving each oauth connection's
// stored token. That is the only data the Python side reads from here.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cowork/services/cowork/cowork_pairing_store.dart'
    show CoworkSecureKeyValueStore, FlutterSecureKeyValueStore;
import 'package:cowork/services/mcp/mcp_connection.dart';

class McpStore {
  McpStore({CoworkSecureKeyValueStore? secrets})
      : _secrets = secrets ?? const FlutterSecureKeyValueStore();

  /// Non-secret connection config.
  static const String prefsKey = 'mcp_connections_v1';

  /// Per-connection secret key prefix in secure storage.
  static const String secretPrefix = 'mcp_secrets_';

  final CoworkSecureKeyValueStore _secrets;

  static String secretKey(String id) => '$secretPrefix$id';

  /// Every stored connection, in saved order. Never throws — a corrupt record
  /// reads as an empty list rather than a crash.
  Future<List<McpConnection>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(prefsKey);
      if (raw == null || raw.isEmpty) return const <McpConnection>[];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <McpConnection>[];
      return <McpConnection>[
        for (final entry in decoded)
          if (entry is Map)
            McpConnection.fromJson(Map<String, dynamic>.from(entry)),
      ];
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ [Mcp] Could not read connections: $e');
      return const <McpConnection>[];
    }
  }

  /// Persist the whole list (config only; secrets are written separately).
  Future<void> _saveAll(List<McpConnection> connections) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      prefsKey,
      jsonEncode(<Map<String, dynamic>>[
        for (final c in connections) c.toJson(),
      ]),
    );
  }

  /// Add or replace [connection] (matched by id) and, when given, store its
  /// [accessToken] in secure storage. A null token leaves any stored one
  /// alone; an empty token clears it.
  Future<void> upsert(McpConnection connection, {String? accessToken}) async {
    final current = List<McpConnection>.of(await load());
    final index = current.indexWhere((c) => c.id == connection.id);
    if (index >= 0) {
      current[index] = connection;
    } else {
      current.add(connection);
    }
    await _saveAll(current);
    if (accessToken != null) {
      await setToken(connection.id, accessToken);
    }
  }

  /// Remove a connection and its stored secret.
  Future<void> remove(String id) async {
    final current = List<McpConnection>.of(await load())
      ..removeWhere((c) => c.id == id);
    await _saveAll(current);
    await _secrets.delete(secretKey(id));
  }

  /// Store (or clear, on empty) the bearer token for [id].
  Future<void> setToken(String id, String token) async {
    if (token.isEmpty) {
      await _secrets.delete(secretKey(id));
    } else {
      await _secrets.write(secretKey(id), token);
    }
  }

  /// The stored bearer token for [id], or null when none is set.
  Future<String?> tokenFor(String id) => _secrets.read(secretKey(id));

  /// The payloads WS-D forwards to the Python agent, one per connection:
  /// `{name, url, auth, access_token?}`. Each oauth connection's token is
  /// resolved from secure storage; appSession connections carry none.
  Future<List<Map<String, dynamic>>> forwardPayloads() async {
    final connections = await load();
    final payloads = <Map<String, dynamic>>[];
    for (final c in connections) {
      final token =
          c.auth == McpAuth.oauth ? await tokenFor(c.id) : null;
      payloads.add(c.toForwardJson(accessToken: token));
    }
    return payloads;
  }
}
