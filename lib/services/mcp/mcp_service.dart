// lib/services/mcp/mcp_service.dart
//
// Connecting, storing and calling remote MCP servers.
//
// The reader taps Connect; the browser opens; the app gets a token and asks
// the server what it can do. From then on those tools are ordinary tools:
// they are registered with the same executor the built-in ones use, so the
// model reaches them through the same discovery and the same call path.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:chuk_chat/services/mcp/mcp_catalogue.dart';
import 'package:chuk_chat/services/mcp/mcp_client.dart';
import 'package:chuk_chat/services/mcp/mcp_connection.dart';
import 'package:chuk_chat/services/mcp/mcp_oauth.dart';
import 'package:chuk_chat/services/mcp/mcp_redirect.dart';
import 'package:chuk_chat/services/mcp/mcp_sync_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';

/// What a connect attempt ended in, for the UI to show.
enum McpConnectStatus { connected, cancelled, failed }

/// A handle the screen keeps so it can stop a connect while the browser
/// sign-in is still open. Without it the reader would sit on the spinner
/// until the five-minute callback timeout — the back button was the only way
/// out. Cancelling completes the wait early; the connect returns [cancelled].
class McpConnectCanceler {
  final Completer<void> _canceled = Completer<void>();

  void cancel() {
    if (!_canceled.isCompleted) _canceled.complete();
  }

  bool get isCanceled => _canceled.isCompleted;
  Future<void> get whenCanceled => _canceled.future;
}

/// Thrown inside [McpService] when the reader cancels the sign-in. Private:
/// it never leaves the service — it is turned into [McpConnectStatus.cancelled].
class _ConnectCanceled implements Exception {
  const _ConnectCanceled();
}

class McpConnectResult {
  const McpConnectResult(this.status, {this.message, this.connection});

  final McpConnectStatus status;
  final String? message;
  final McpConnection? connection;
}

/// The secrets of one connection. Never written to shared preferences.
class _McpSecrets {
  const _McpSecrets({
    this.credentials = const McpClientCredentials(clientId: ''),
    this.tokens = const McpTokens(accessToken: ''),
    this.issuer,
    this.authorizationEndpoint,
    this.tokenEndpoint,
    this.scope,
    this.apiCredentials = const <String, String>{},
  });

  final McpClientCredentials credentials;
  final McpTokens tokens;
  final String? issuer;
  final String? authorizationEndpoint;
  final String? tokenEndpoint;
  final String? scope;

  /// Reader-supplied API credentials for an [McpAuth.apiKey] server, keyed by
  /// the query-parameter name the server expects. Empty for OAuth servers.
  final Map<String, String> apiCredentials;

  Map<String, dynamic> toJson() => {
    'credentials': credentials.toJson(),
    'tokens': tokens.toJson(),
    'issuer': issuer,
    'authorization_endpoint': authorizationEndpoint,
    'token_endpoint': tokenEndpoint,
    'scope': scope,
    if (apiCredentials.isNotEmpty) 'api_credentials': apiCredentials,
  };

  static _McpSecrets fromJson(Map<String, dynamic> json) => _McpSecrets(
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
    apiCredentials: <String, String>{
      for (final e in (json['api_credentials'] as Map? ?? const {}).entries)
        e.key.toString(): e.value.toString(),
    },
  );

  McpAuthServer? get authServer {
    final authorize = Uri.tryParse(authorizationEndpoint ?? '');
    final token = Uri.tryParse(tokenEndpoint ?? '');
    if (authorize == null || token == null) return null;
    return McpAuthServer(
      issuer: issuer ?? '',
      authorizationEndpoint: authorize,
      tokenEndpoint: token,
    );
  }

  _McpSecrets withTokens(McpTokens next) => _McpSecrets(
    credentials: credentials,
    tokens: next,
    issuer: issuer,
    authorizationEndpoint: authorizationEndpoint,
    tokenEndpoint: tokenEndpoint,
    scope: scope,
  );
}

class McpService {
  McpService._();

  static const String _prefsKey = 'mcp_connections_v1';
  static const FlutterSecureStorage _secure = FlutterSecureStorage();

  static final ValueNotifier<List<McpConnection>> connections =
      ValueNotifier<List<McpConnection>>(const <McpConnection>[]);

  /// Injected in tests so no browser opens and no real server is called.
  @visibleForTesting
  static Future<bool> Function(Uri url)? launcher;

  static bool _loaded = false;

  // ─── Storage ───────────────────────────────────────────────────────────

  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      connections.value = [
        for (final entry in decoded)
          if (entry is Map) McpConnection.fromJson(Map<String, dynamic>.from(entry)),
      ];
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ [MCP] Could not read the connections: $e');
    }
  }

  static Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode([for (final c in connections.value) c.toJson()]),
    );
  }

  static Future<_McpSecrets?> _readSecrets(String id) async {
    try {
      final raw = await _secure.read(key: 'mcp_secrets_$id');
      if (raw == null || raw.isEmpty) return null;
      return _McpSecrets.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ [MCP] Could not read the token: $e');
      return null;
    }
  }

  static Future<void> _writeSecrets(String id, _McpSecrets secrets) =>
      _secure.write(key: 'mcp_secrets_$id', value: jsonEncode(secrets.toJson()));

  // ─── Connecting ────────────────────────────────────────────────────────

  /// Connect [url] and remember it. Opens the browser when the server asks
  /// for a sign-in, which is the normal case.
  static Future<McpConnectResult> connect({
    required String id,
    required String name,
    required String url,
    String description = '',
    String? iconUrl,
    bool addedByHand = false,
    McpAuth auth = McpAuth.oauth,
    McpConnectCanceler? canceler,
  }) async {
    final endpoint = Uri.tryParse(url);
    if (endpoint == null || !_isAcceptableEndpoint(endpoint)) {
      return const McpConnectResult(
        McpConnectStatus.failed,
        message: 'That is not an https address.',
      );
    }

    try {
      McpServerInfo? info;
      String? accessToken;

      if (auth == McpAuth.appSession) {
        // Our own server. The reader is signed in already, so there is
        // nothing to authorize — and a 401 here means the app session
        // expired, not that a browser sign-in is due.
        accessToken = await _appSessionToken();
        if (accessToken == null) {
          return const McpConnectResult(
            McpConnectStatus.failed,
            message: 'Sign in to Chuk Chat first.',
          );
        }
        info = await McpClient(
          endpoint: endpoint,
          accessToken: accessToken,
        ).initialize();
      } else {
        // Some servers need no sign-in at all. Try without a token first.
        try {
          info = await McpClient(endpoint: endpoint).initialize();
        } on McpUnauthorized catch (unauthorized) {
          final authorized = await _authorize(
            id: id,
            endpoint: endpoint,
            wwwAuthenticate: unauthorized.wwwAuthenticate,
            canceler: canceler,
          );
          if (authorized == null) {
            return const McpConnectResult(McpConnectStatus.cancelled);
          }
          accessToken = authorized;
          info = await McpClient(
            endpoint: endpoint,
            accessToken: accessToken,
          ).initialize();
        }
      }

      final client = McpClient(endpoint: endpoint, accessToken: accessToken);
      await client.initialize();
      final tools = await client.listTools();

      final connection = McpConnection(
        id: id,
        name: name.trim().isEmpty ? info.displayName : name,
        url: url,
        description: description.isEmpty
            ? (info.instructions ?? '').split('\n').first
            : description,
        iconUrl: iconUrl ?? info.iconUrl,
        tools: tools,
        addedByHand: addedByHand,
        auth: auth,
      );

      connections.value = [
        ...connections.value.where((c) => c.id != id),
        connection,
      ];
      await _persist();
      // Reconnecting clears any leftover tombstone, then shares it, encrypted,
      // so the reader's other devices pick it up. A failure here is only a
      // resilience gap — the next reconcile re-pushes — so log, don't leak an
      // unhandled async error.
      unawaited(
        McpSyncService.clearPendingDelete(id)
            .then((_) => McpSyncService.push(connection))
            .catchError((Object e) {
          if (kDebugMode) debugPrint('⚠️ [MCP] Could not share $id: $e');
        }),
      );
      return McpConnectResult(
        McpConnectStatus.connected,
        connection: connection,
      );
    } on McpAuthException catch (e) {
      return McpConnectResult(McpConnectStatus.failed, message: e.message);
    } on McpException catch (e) {
      return McpConnectResult(McpConnectStatus.failed, message: e.message);
    } catch (e) {
      return McpConnectResult(
        McpConnectStatus.failed,
        message: 'Could not reach the server: $e',
      );
    }
  }

  /// Connect a server that takes the reader's own credentials on its URL
  /// (an API key, a project id) instead of a browser sign-in. The values are
  /// added to the endpoint as query parameters to reach the server, but only
  /// the plain base [url] is stored in the connection row — the values go to
  /// secure storage, keyed by the connection id, and ride the same encrypted
  /// sync as OAuth tokens.
  static Future<McpConnectResult> connectWithCredentials({
    required String id,
    required String name,
    required String url,
    required Map<String, String> credentials,
    String description = '',
    String? iconUrl,
    bool addedByHand = false,
  }) async {
    final base = Uri.tryParse(url);
    if (base == null || !_isAcceptableEndpoint(base)) {
      return const McpConnectResult(
        McpConnectStatus.failed,
        message: 'That is not an https address.',
      );
    }

    final endpoint = _endpointWithCredentials(base, credentials);
    try {
      final client = McpClient(endpoint: endpoint);
      final info = await client.initialize();
      final tools = await client.listTools();

      final connection = McpConnection(
        id: id,
        name: name.trim().isEmpty ? info.displayName : name,
        url: url,
        description: description.isEmpty
            ? (info.instructions ?? '').split('\n').first
            : description,
        iconUrl: iconUrl ?? info.iconUrl,
        tools: tools,
        addedByHand: addedByHand,
        auth: McpAuth.apiKey,
      );

      await _writeSecrets(id, _McpSecrets(apiCredentials: credentials));
      connections.value = [
        ...connections.value.where((c) => c.id != id),
        connection,
      ];
      await _persist();
      unawaited(
        McpSyncService.clearPendingDelete(id)
            .then((_) => McpSyncService.push(connection))
            .catchError((Object e) {
          if (kDebugMode) debugPrint('⚠️ [MCP] Could not share $id: $e');
        }),
      );
      return McpConnectResult(
        McpConnectStatus.connected,
        connection: connection,
      );
    } on McpUnauthorized {
      return const McpConnectResult(
        McpConnectStatus.failed,
        message: 'The server refused those credentials. Check the key.',
      );
    } on McpException catch (e) {
      return McpConnectResult(McpConnectStatus.failed, message: e.message);
    } catch (e) {
      return McpConnectResult(
        McpConnectStatus.failed,
        message: 'Could not reach the server: $e',
      );
    }
  }

  /// The endpoint the server is actually called on: the base URL with the
  /// reader's credentials added as query parameters, keeping any the URL
  /// already carried.
  static Uri _endpointWithCredentials(Uri base, Map<String, String> creds) =>
      base.replace(
        queryParameters: <String, String>{...base.queryParameters, ...creds},
      );

  /// The credentialed endpoint, exposed for tests: the reader's key must land
  /// on the request URL, and never in the stored connection row.
  @visibleForTesting
  static Uri endpointWithCredentialsForTest(
    Uri base,
    Map<String, String> creds,
  ) => _endpointWithCredentials(base, creds);

  /// Run the OAuth flow and store what came out of it. Returns the access
  /// token, or null when the reader closed the browser.
  static Future<String?> _authorize({
    required String id,
    required Uri endpoint,
    String? wwwAuthenticate,
    McpConnectCanceler? canceler,
  }) async {
    final oauth = McpOAuth();
    final server = await oauth.discover(
      endpoint,
      wwwAuthenticate: wwwAuthenticate,
    );

    final listener = await McpRedirectListener.start();
    try {
      final credentials = await oauth.register(
        server,
        listener.redirectUri,
        scope: server.scopesSupported.join(' '),
      );

      final request = oauth.buildAuthorizationRequest(
        server: server,
        credentials: credentials,
        redirectUri: listener.redirectUri,
        resource: McpOAuth.canonicalResource(endpoint),
        scopes: server.scopesSupported,
      );

      final opened = await (launcher ?? _launch)(request.url);
      if (!opened) {
        throw const McpAuthException('The browser did not open.');
      }

      // Wait for the redirect, but let the reader cancel out of it. The
      // cancel and the five-minute timeout both end the wait; only the real
      // callback carries a code on.
      final Uri callback;
      try {
        callback = await Future.any(<Future<Uri>>[
          listener.callback.timeout(
            const Duration(minutes: 5),
            onTimeout: () => throw const McpAuthException(
              'The sign-in took too long. Try again.',
            ),
          ),
          if (canceler != null)
            canceler.whenCanceled.then<Uri>(
              (_) => throw const _ConnectCanceled(),
            ),
        ]);
      } on _ConnectCanceled {
        // Reader tapped Cancel: shut the browser and report a clean cancel,
        // not a failure.
        await _closeBrowser();
        return null;
      }

      // The sign-in tab has done its job — close it so the reader lands
      // back in the app instead of on a "you can close this" page.
      await _closeBrowser();

      final tokens = await oauth.exchange(request, callback);
      await _writeSecrets(
        id,
        _McpSecrets(
          credentials: credentials,
          tokens: tokens,
          issuer: server.issuer,
          authorizationEndpoint: server.authorizationEndpoint.toString(),
          tokenEndpoint: server.tokenEndpoint.toString(),
          scope: request.scope,
        ),
      );
      return tokens.accessToken;
    } finally {
      await listener.close();
    }
  }

  /// Opens the sign-in inside the app: a Custom Tab on Android, a Safari
  /// sheet on iOS, a browser window on desktop. It can be closed again
  /// from here, which a separate browser app cannot.
  static Future<bool> _launch(Uri url) async {
    try {
      return await launchUrl(url, mode: LaunchMode.inAppBrowserView);
    } catch (_) {
      // Desktop has no in-app browser view.
      return launchUrl(url, mode: LaunchMode.externalApplication);
    }
  }

  static Future<void> _closeBrowser() async {
    // Only the in-app view can be closed, and only where one exists.
    if (launcher != null) return;
    try {
      await closeInAppWebView();
    } catch (_) {
      // Nothing was open, or the platform does not support it.
    }
  }

  /// Forget a server: its tokens, its tools and its entry — here and on the
  /// reader's other devices.
  static Future<void> disconnect(String id) async {
    // Tombstone first so a surviving remote row can never re-add the
    // connection, token and all, on the next reconcile. Then forget it here at
    // once — the reader does not wait on the network — and delete the remote
    // row in the background, clearing the tombstone once that lands. A delete
    // that never lands is retried by the next pull.
    final epoch = await McpSyncService.markPendingDelete(id);
    await _forgetLocal(id);
    // Delete the remote row in the background, but only while this disconnect's
    // tombstone is still the current one — a reconnect (or a later disconnect)
    // bumps the epoch and this older request then steps aside.
    unawaited(McpSyncService.deleteIfStillPending(id, epoch));
  }

  /// Forget a server on this device only: entry, tools and stored token. Used
  /// both by [disconnect] and by the sync reconcile when the server dropped a
  /// connection another device had already deleted remotely.
  static Future<void> _forgetLocal(String id) async {
    connections.value = [
      for (final c in connections.value)
        if (c.id != id) c,
    ];
    await _persist();
    try {
      await _secure.delete(key: 'mcp_secrets_$id');
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ [MCP] Could not delete the token: $e');
    }
  }

  /// Ask a connected server for its tools again.
  static Future<McpConnection?> refreshTools(String id) async {
    final connection = connectionFor(id);
    if (connection == null) return null;
    final client = await _clientFor(connection);
    if (client == null) return null;
    try {
      await client.initialize();
      final tools = await client.listTools();
      final updated = connection.copyWith(tools: tools);
      connections.value = [
        for (final c in connections.value)
          if (c.id == id) updated else c,
      ];
      await _persist();
      return updated;
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ [MCP] Could not list the tools: $e');
      return null;
    }
  }

  // ─── Calling ───────────────────────────────────────────────────────────

  static McpConnection? connectionFor(String id) {
    for (final connection in connections.value) {
      if (connection.id == id) return connection;
    }
    return null;
  }

  /// Which connection and which remote tool a model-facing tool name means.
  static ({McpConnection connection, String tool})? resolve(String toolName) {
    for (final connection in connections.value) {
      for (final tool in connection.tools) {
        if (connection.toolNameFor(tool.name) == toolName) {
          return (connection: connection, tool: tool.name);
        }
      }
    }
    return null;
  }

  /// Run a tool on the server it belongs to.
  static Future<McpCallResult> call(
    String toolName,
    Map<String, dynamic> arguments,
  ) async {
    final target = resolve(toolName);
    if (target == null) {
      return const McpCallResult(
        text: 'That connector is no longer connected.',
        isError: true,
      );
    }

    final client = await _clientFor(target.connection);
    if (client == null) {
      return McpCallResult(
        text:
            '${target.connection.name} is not signed in any more. Open '
            'Connectors and connect it again.',
        isError: true,
      );
    }

    try {
      await client.initialize();
      return await client.callTool(target.tool, arguments);
    } on McpUnauthorized {
      return McpCallResult(
        text:
            '${target.connection.name} refused the token. Connect it again '
            'in Connectors.',
        isError: true,
      );
    } on McpException catch (e) {
      return McpCallResult(text: e.message, isError: true);
    }
  }

  /// https everywhere, except a server on this machine.
  ///
  /// A debug build points at `http://localhost:8000`, which is where the
  /// first-party connectors live while their API server is being worked on.
  /// Loopback never leaves the device, so plaintext there costs nothing —
  /// the same reasoning the OAuth redirect listener runs on.
  static bool _isAcceptableEndpoint(Uri endpoint) {
    if (endpoint.isScheme('https')) return true;
    if (!endpoint.isScheme('http')) return false;
    const loopback = {
      'localhost',
      '127.0.0.1',
      '::1',
      // The host machine, seen from the Android emulator.
      '10.0.2.2',
    };
    return loopback.contains(endpoint.host);
  }

  /// The app's own session token, refreshed when it is about to lapse.
  ///
  /// Read fresh on every call rather than stored: it rotates, and a copy
  /// kept next to the connection would be stale within the hour.
  static Future<String?> _appSessionToken() async {
    var session = SupabaseService.auth.currentSession;
    if (session == null) return null;
    if (session.isExpired) {
      session = await SupabaseService.refreshSession();
    }
    final token = session?.accessToken ?? '';
    return token.isEmpty ? null : token;
  }

  /// A client carrying a valid token, refreshing it first when it is stale.
  static Future<McpClient?> _clientFor(McpConnection connection) async {
    final endpoint = Uri.tryParse(connection.url);
    if (endpoint == null) return null;

    if (connection.auth == McpAuth.appSession) {
      final token = await _appSessionToken();
      if (token == null) return null;
      return McpClient(endpoint: endpoint, accessToken: token);
    }

    if (connection.auth == McpAuth.apiKey) {
      final secrets = await _readSecrets(connection.id);
      if (secrets == null || secrets.apiCredentials.isEmpty) return null;
      return McpClient(
        endpoint: _endpointWithCredentials(endpoint, secrets.apiCredentials),
      );
    }

    final secrets = await _readSecrets(connection.id);
    if (secrets == null) {
      // A server that never asked for a token needs none now either.
      return McpClient(endpoint: endpoint);
    }

    var tokens = secrets.tokens;
    if (tokens.isExpired && tokens.refreshToken != null) {
      final server = secrets.authServer;
      if (server == null) return null;
      final refreshed = await McpOAuth().refresh(
        server: server,
        credentials: secrets.credentials,
        refreshToken: tokens.refreshToken!,
        resource: McpOAuth.canonicalResource(endpoint),
        scope: secrets.scope,
      );
      if (refreshed == null) return null;
      tokens = refreshed;
      await _writeSecrets(connection.id, secrets.withTokens(refreshed));
      // The token rotated: push the new one so other devices refresh too.
      unawaited(McpSyncService.push(connection));
    }

    return McpClient(endpoint: endpoint, accessToken: tokens.accessToken);
  }

  /// Add a server the reader typed in by hand.
  static Future<McpConnectResult> connectByUrl(
    String url, {
    String? name,
    McpConnectCanceler? canceler,
  }) {
    final trimmed = url.trim();
    final id = slugFor(trimmed);
    return connect(
      id: id,
      name: name?.trim().isNotEmpty == true ? name!.trim() : '',
      url: trimmed,
      addedByHand: true,
      canceler: canceler,
    );
  }

  // ─── Internal API for McpSyncService ───────────────────────────────────────
  //
  // The sync service works in plain JSON maps; _McpSecrets and the storage
  // keys stay private here. These methods are the whole surface it touches, so
  // the secret type and the shared-preferences shape never escape this file.
  // (@internal is not usable here — it is only valid under lib/src/, and this
  // package keeps its sources directly under lib/. The `internal` prefix and
  // these docs mark the boundary instead.)

  /// True when [url] is one this device will send a token to — https, or a
  /// loopback address. Mirrors the check `connect()` applies, for connections
  /// that arrive by sync: the URL decides where key material travels, so both
  /// entry paths must validate it.
  static bool internalIsAcceptableUrl(String url) {
    final endpoint = Uri.tryParse(url);
    return endpoint != null && _isAcceptableEndpoint(endpoint);
  }

  /// The connection's secrets as a plain map, or null when it has none.
  static Future<Map<String, dynamic>?> internalReadSecretsJson(String id) async {
    final secrets = await _readSecrets(id);
    return secrets?.toJson();
  }

  /// Write a connection's secrets from a plain map (from a synced blob).
  static Future<void> internalWriteSecretsJson(
    String id,
    Map<String, dynamic> json,
  ) => _writeSecrets(id, _McpSecrets.fromJson(json));

  /// Add or replace [connection] in the live list and persist. Registers its
  /// tools through the existing connections listener.
  static Future<void> internalUpsertConnection(McpConnection connection) async {
    connections.value = [
      ...connections.value.where((c) => c.id != connection.id),
      connection,
    ];
    await _persist();
  }

  /// Forget a connection on this device without touching the remote row —
  /// used when the reconcile honours a deletion made on another device.
  static Future<void> internalForgetLocal(String id) => _forgetLocal(id);

  /// List a connection's tools live, building a client from its stored token
  /// (or the app session, for our own servers). Null on any failure — the
  /// caller keeps the connection and retries on the next tick.
  static Future<List<McpTool>?> internalFetchTools(
    McpConnection connection,
  ) async {
    final client = await _clientFor(connection);
    if (client == null) return null;
    try {
      await client.initialize();
      return await client.listTools();
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ [MCP] Could not list synced tools: $e');
      return null;
    }
  }
}
