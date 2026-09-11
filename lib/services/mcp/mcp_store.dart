// lib/services/mcp/mcp_store.dart
//
// Storage for MCP connections. The non-secret config is a JSON list in
// SharedPreferences under `mcp_connections_v1`; each connection's secret
// record lives in secure storage under `mcp_secrets_<id>`.
//
// The secret record is chuk_chat's exact shape — the registered client, the
// tokens (access, refresh, expiry, scope) and the authorization server that
// issued them. CoWork needs all of it, not just the bearer: the device signs
// in once and the Python host keeps the connection alive for days, so the
// host is handed the refresh material as well and mints its own tokens when
// the app is closed. A record written by an older build was a bare bearer
// string; it is still read, and upgraded in place on the next write.
//
// The store also assembles the forward payloads WS-D sends at task launch —
// `[{name, url, auth, access_token?, oauth?}]` — refreshing a token that is
// about to lapse first, so a live app always hands the host a fresh one.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cowork/services/cowork/cowork_pairing_store.dart'
    show CoworkSecureKeyValueStore, FlutterSecureKeyValueStore;
import 'package:cowork/services/mcp/mcp_connection.dart';
import 'package:cowork/services/mcp/mcp_oauth.dart';
import 'package:cowork/services/mcp/mcp_service.dart';

/// Everything secret about one connection: the client this device registered
/// with the authorization server, the tokens it issued, and where they came
/// from. Never written to SharedPreferences.
///
/// The JSON is chuk_chat's `_McpSecrets` shape verbatim, so a record written
/// by either app reads in the other.
class McpSecrets {
  const McpSecrets({
    this.credentials = const McpClientCredentials(clientId: ''),
    this.tokens = const McpTokens(accessToken: ''),
    this.issuer,
    this.authorizationEndpoint,
    this.tokenEndpoint,
    this.scope,
  });

  final McpClientCredentials credentials;
  final McpTokens tokens;
  final String? issuer;
  final String? authorizationEndpoint;
  final String? tokenEndpoint;

  /// The scope the authorization request asked for, needed again on refresh.
  final String? scope;

  /// True when there is nothing worth storing.
  bool get isEmpty =>
      tokens.accessToken.isEmpty &&
      (tokens.refreshToken ?? '').isEmpty &&
      credentials.clientId.isEmpty;

  /// The authorization server, when enough of it was recorded to talk to.
  McpAuthServer? get authServer {
    final authorize = Uri.tryParse(authorizationEndpoint ?? '');
    final token = Uri.tryParse(tokenEndpoint ?? '');
    if (authorize == null || token == null) return null;
    if (!token.hasScheme || token.host.isEmpty) return null;
    return McpAuthServer(
      issuer: issuer ?? '',
      authorizationEndpoint: authorize,
      tokenEndpoint: token,
    );
  }

  McpSecrets withTokens(McpTokens next) => McpSecrets(
    credentials: credentials,
    tokens: next,
    issuer: issuer,
    authorizationEndpoint: authorizationEndpoint,
    tokenEndpoint: tokenEndpoint,
    scope: scope,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'credentials': credentials.toJson(),
    'tokens': _tokensJson(),
    'issuer': issuer,
    'authorization_endpoint': authorizationEndpoint,
    'token_endpoint': tokenEndpoint,
    'scope': scope,
  };

  /// The tokens, with the expiry written in UTC.
  ///
  /// [McpTokens.toJson] serializes the local `DateTime` it was built from, and
  /// a local timestamp carries no zone, so it reads as whatever zone the
  /// reader is in. That is invisible on one device and wrong on two: this
  /// record is mirrored, and a device in another zone would read an expiry
  /// hours off and either refresh a live token or trust a dead one. A DST
  /// change does the same by an hour on a single device.
  Map<String, dynamic> _tokensJson() {
    final json = tokens.toJson();
    final expiresAt = tokens.expiresAt;
    if (expiresAt != null) {
      json['expires_at'] = expiresAt.toUtc().toIso8601String();
    }
    return json;
  }

  static McpSecrets fromJson(Map<String, dynamic> json) => McpSecrets(
    credentials: McpClientCredentials.fromJson(
      Map<String, dynamic>.from(json['credentials'] as Map? ?? const {}),
    ),
    tokens: McpTokens.fromJson(
      Map<String, dynamic>.from(json['tokens'] as Map? ?? const {}),
    ),
    issuer: json['issuer']?.toString(),
    authorizationEndpoint: json['authorization_endpoint']?.toString(),
    tokenEndpoint: json['token_endpoint']?.toString(),
    scope: json['scope']?.toString(),
  );
}

class McpStore {
  McpStore({CoworkSecureKeyValueStore? secrets, McpOAuth? oauth})
    : _secrets = secrets ?? const FlutterSecureKeyValueStore(),
      _oauth = oauth ?? McpOAuth();

  /// Non-secret connection config.
  static const String prefsKey = 'mcp_connections_v1';

  /// Per-connection secret key prefix in secure storage (the secret record).
  static const String secretPrefix = 'mcp_secrets_';

  /// Per-connection API-credential key prefix in secure storage. Holds a JSON
  /// map of query-parameter name to value, for an [McpAuth.apiKey] server.
  static const String apiCredsPrefix = 'mcp_apicreds_';

  final CoworkSecureKeyValueStore _secrets;
  final McpOAuth _oauth;

  /// The refresh in flight for a connection id, if any.
  ///
  /// Two task launches close together both read the same lapsed record and
  /// would both spend the same refresh token. A server that rotates refresh
  /// tokens answers one of them and invalidates the other's, and whichever
  /// write lands last decides what is stored — so the loser can leave a dead
  /// refresh token behind and the connector needs a fresh sign-in. Sharing the
  /// one in-flight future makes the second caller wait for the first's answer
  /// instead of asking again. Static because callers hold their own [McpStore]
  /// instances over the same keychain.
  static final Map<String, Future<McpSecrets?>> _refreshes =
      <String, Future<McpSecrets?>>{};

  static String secretKey(String id) => '$secretPrefix$id';

  static String apiCredsKey(String id) => '$apiCredsPrefix$id';

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
  /// alone; an empty token clears the record.
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

  /// Remove a connection and its stored secrets.
  Future<void> remove(String id) async {
    final current = List<McpConnection>.of(await load())
      ..removeWhere((c) => c.id == id);
    await _saveAll(current);
    await _secrets.delete(secretKey(id));
    await _secrets.delete(apiCredsKey(id));
  }

  // ─── Secrets ───────────────────────────────────────────────────────────

  /// The whole secret record for [id], or null when none is stored.
  ///
  /// A value written by an older build is a bare bearer string rather than a
  /// record; it reads as a record carrying only that access token, so an
  /// existing install keeps working and is upgraded on the next write.
  Future<McpSecrets?> secretsFor(String id) async {
    final raw = await _secrets.read(secretKey(id));
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return McpSecrets.fromJson(Map<String, dynamic>.from(decoded));
      }
    } catch (_) {
      // Not JSON: the legacy bare-token form, handled below.
    }
    return McpSecrets(tokens: McpTokens(accessToken: raw));
  }

  /// Store the whole secret record for [id]. An empty record clears it.
  Future<void> setSecrets(String id, McpSecrets secrets) async {
    if (secrets.isEmpty) {
      await _secrets.delete(secretKey(id));
      return;
    }
    await _secrets.write(secretKey(id), jsonEncode(secrets.toJson()));
  }

  /// Store (or clear, on empty) just the bearer token for [id], keeping any
  /// refresh material already recorded.
  ///
  /// Clearing the bearer is "make the next call re-authenticate", not "forget
  /// this server" — the refresh token and the registered client stay, so the
  /// host can still mint a new bearer. Use [remove] to forget a connection.
  Future<void> setToken(String id, String token) async {
    final existing = await secretsFor(id) ?? const McpSecrets();
    if (token.isEmpty) {
      await setSecrets(
        id,
        existing.withTokens(
          McpTokens(
            accessToken: '',
            refreshToken: existing.tokens.refreshToken,
            expiresAt: existing.tokens.expiresAt,
            scope: existing.tokens.scope,
          ),
        ),
      );
      return;
    }
    await setSecrets(
      id,
      existing.withTokens(
        McpTokens(
          accessToken: token,
          refreshToken: existing.tokens.refreshToken,
          expiresAt: existing.tokens.expiresAt,
          scope: existing.tokens.scope,
        ),
      ),
    );
  }

  /// The stored bearer token for [id], or null when none is set.
  Future<String?> tokenFor(String id) async {
    final token = (await secretsFor(id))?.tokens.accessToken ?? '';
    return token.isEmpty ? null : token;
  }

  /// Store (or clear, on empty) the API credentials for [id]. The map is the
  /// query-parameter name to value pairs an [McpAuth.apiKey] server expects.
  Future<void> setApiCredentials(String id, Map<String, String> creds) async {
    if (creds.isEmpty) {
      await _secrets.delete(apiCredsKey(id));
    } else {
      await _secrets.write(apiCredsKey(id), jsonEncode(creds));
    }
  }

  /// The stored API credentials for [id], or an empty map when none are set.
  Future<Map<String, String>> apiCredentialsFor(String id) async {
    try {
      final raw = await _secrets.read(apiCredsKey(id));
      if (raw == null || raw.isEmpty) return const <String, String>{};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const <String, String>{};
      return <String, String>{
        for (final e in decoded.entries) e.key.toString(): e.value.toString(),
      };
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ [Mcp] Could not read API credentials: $e');
      return const <String, String>{};
    }
  }

  // ─── Forwarding ────────────────────────────────────────────────────────

  /// The payloads WS-D forwards to the Python agent, one per connection:
  /// `{id, name, url, auth, access_token?, oauth?}`.
  ///
  /// An [McpAuth.oauth] connection forwards its resolved bearer and, when the
  /// record holds the refresh material, an `oauth` block so the host can mint
  /// its own tokens after the app is gone. A token already past its expiry is
  /// refreshed here first and the fresh one written back, so a running app
  /// never hands the host a bearer it knows is dead.
  ///
  /// An [McpAuth.apiKey] connection is forwarded as an unauthenticated server
  /// whose credentials are already on the URL: the stored base URL gets the
  /// secret query parameters added and no `auth` field is sent. An
  /// [McpAuth.appSession] connection carries no device token — the host
  /// resolves the account credential.
  Future<List<Map<String, dynamic>>> forwardPayloads() async {
    // Make sure the encrypted mirrors have been read at least once before the
    // set is assembled (bead cowork-7zd). Without this the very first task of
    // a cold start forwards only what this device signed into itself, and a
    // connector the user connected in chuk_chat reaches the agent no earlier
    // than the next chat-sync tick — or never, if the user never opens the
    // connectors page. Throttled and single-flight inside the service, and a
    // no-op the moment the mirrors are unreachable, so the launch path pays
    // nothing when there is nothing to pay for.
    await McpService.adoptMirrors();
    final connections = await load();
    final payloads = <Map<String, dynamic>>[];
    for (final c in connections) {
      if (c.auth == McpAuth.apiKey) {
        payloads.add(<String, dynamic>{
          'id': c.id,
          'name': c.name,
          'url': _urlWithCredentials(c.url, await apiCredentialsFor(c.id)),
        });
        continue;
      }
      if (c.auth != McpAuth.oauth) {
        payloads.add(c.toForwardJson());
        continue;
      }
      final secrets = await _refreshedSecrets(c);
      final payload = c.toForwardJson(accessToken: secrets?.tokens.accessToken);
      final block = _oauthBlock(c, secrets);
      if (block != null) payload['oauth'] = block;
      payloads.add(payload);
    }
    return payloads;
  }

  /// The record for [connection], with the access token refreshed when it is
  /// about to lapse and enough was recorded to do so. Returns the record
  /// unchanged when there is nothing to refresh or the server refuses — a
  /// stale bearer plus the refresh block still lets the host try.
  Future<McpSecrets?> _refreshedSecrets(McpConnection connection) async {
    final secrets = await secretsFor(connection.id);
    if (secrets == null) return null;
    final refreshToken = secrets.tokens.refreshToken;
    if (!secrets.tokens.isExpired || refreshToken == null) return secrets;

    final server = secrets.authServer;
    final endpoint = Uri.tryParse(connection.url);
    if (server == null || endpoint == null) return secrets;

    final inFlight = _refreshes[connection.id];
    if (inFlight != null) return inFlight;
    final future = _refreshOnce(connection, secrets, server, refreshToken);
    _refreshes[connection.id] = future;
    try {
      return await future;
    } finally {
      _refreshes.remove(connection.id);
    }
  }

  /// One trip to the token endpoint, with the result written back.
  Future<McpSecrets?> _refreshOnce(
    McpConnection connection,
    McpSecrets secrets,
    McpAuthServer server,
    String refreshToken,
  ) async {
    final endpoint = Uri.parse(connection.url);
    try {
      final refreshed = await _oauth.refresh(
        server: server,
        credentials: secrets.credentials,
        refreshToken: refreshToken,
        resource: McpOAuth.canonicalResource(endpoint),
        scope: secrets.scope,
      );
      if (refreshed == null) return secrets;
      final next = secrets.withTokens(refreshed);
      await setSecrets(connection.id, next);
      return next;
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ [Mcp] Could not refresh a token: $e');
      return secrets;
    }
  }

  /// The `oauth` block the host needs to keep [connection] alive on its own,
  /// or null when the record holds no refresh token — there is nothing the
  /// host could do with the rest.
  static Map<String, dynamic>? _oauthBlock(
    McpConnection connection,
    McpSecrets? secrets,
  ) {
    if (secrets == null) return null;
    final refreshToken = secrets.tokens.refreshToken;
    final tokenEndpoint = secrets.tokenEndpoint;
    if (refreshToken == null || refreshToken.isEmpty) return null;
    if (tokenEndpoint == null || tokenEndpoint.isEmpty) return null;
    final endpoint = Uri.tryParse(connection.url);
    return <String, dynamic>{
      'token_endpoint': tokenEndpoint,
      'client_id': secrets.credentials.clientId,
      if ((secrets.credentials.clientSecret ?? '').isNotEmpty)
        'client_secret': secrets.credentials.clientSecret,
      'refresh_token': refreshToken,
      // Always UTC on the wire. A local-time stamp with no zone reads as
      // whatever zone the reader assumes, and the host is a different process
      // that may well assume another one.
      if (secrets.tokens.expiresAt != null)
        'expires_at': secrets.tokens.expiresAt!.toUtc().toIso8601String(),
      if (endpoint != null) 'resource': McpOAuth.canonicalResource(endpoint),
      if ((secrets.scope ?? '').isNotEmpty) 'scope': secrets.scope,
      if ((secrets.issuer ?? '').isNotEmpty) 'issuer': secrets.issuer,
    };
  }

  /// The base URL with the API credentials added as query parameters, keeping
  /// any the URL already carried. Returns the base URL unchanged when it does
  /// not parse or when there are no credentials.
  static String _urlWithCredentials(String url, Map<String, String> creds) {
    if (creds.isEmpty) return url;
    final base = Uri.tryParse(url);
    if (base == null) return url;
    return base
        .replace(
          queryParameters: <String, String>{...base.queryParameters, ...creds},
        )
        .toString();
  }
}
