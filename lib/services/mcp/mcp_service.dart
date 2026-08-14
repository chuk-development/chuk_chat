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

/// What a connect attempt ended in, for the UI to show.
enum McpConnectStatus { connected, cancelled, failed }

class McpConnectResult {
  const McpConnectResult(this.status, {this.message, this.connection});

  final McpConnectStatus status;
  final String? message;
  final McpConnection? connection;
}

/// The secrets of one connection. Never written to shared preferences.
class _McpSecrets {
  const _McpSecrets({required this.credentials, required this.tokens, this.issuer, this.authorizationEndpoint, this.tokenEndpoint, this.scope});

  final McpClientCredentials credentials;
  final McpTokens tokens;
  final String? issuer;
  final String? authorizationEndpoint;
  final String? tokenEndpoint;
  final String? scope;

  Map<String, dynamic> toJson() => {
    'credentials': credentials.toJson(),
    'tokens': tokens.toJson(),
    'issuer': issuer,
    'authorization_endpoint': authorizationEndpoint,
    'token_endpoint': tokenEndpoint,
    'scope': scope,
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
  }) async {
    final endpoint = Uri.tryParse(url);
    if (endpoint == null || !endpoint.isScheme('https')) {
      return const McpConnectResult(
        McpConnectStatus.failed,
        message: 'That is not an https address.',
      );
    }

    try {
      // Some servers need no sign-in at all. Try without a token first.
      McpServerInfo? info;
      String? accessToken;
      try {
        info = await McpClient(endpoint: endpoint).initialize();
      } on McpUnauthorized catch (unauthorized) {
        final authorized = await _authorize(
          id: id,
          endpoint: endpoint,
          wwwAuthenticate: unauthorized.wwwAuthenticate,
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
      );

      connections.value = [
        ...connections.value.where((c) => c.id != id),
        connection,
      ];
      await _persist();
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

  /// Run the OAuth flow and store what came out of it. Returns the access
  /// token, or null when the reader closed the browser.
  static Future<String?> _authorize({
    required String id,
    required Uri endpoint,
    String? wwwAuthenticate,
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

      final callback = await listener.callback.timeout(
        const Duration(minutes: 5),
        onTimeout: () => throw const McpAuthException(
          'The sign-in took too long. Try again.',
        ),
      );

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

  /// Forget a server: its tokens, its tools and its entry.
  static Future<void> disconnect(String id) async {
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

  /// A client carrying a valid token, refreshing it first when it is stale.
  static Future<McpClient?> _clientFor(McpConnection connection) async {
    final endpoint = Uri.tryParse(connection.url);
    if (endpoint == null) return null;

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
    }

    return McpClient(endpoint: endpoint, accessToken: tokens.accessToken);
  }

  /// Add a server the reader typed in by hand.
  static Future<McpConnectResult> connectByUrl(String url, {String? name}) {
    final trimmed = url.trim();
    final id = slugFor(trimmed);
    return connect(
      id: id,
      name: name?.trim().isNotEmpty == true ? name!.trim() : '',
      url: trimmed,
      addedByHand: true,
    );
  }
}
