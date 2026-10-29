// lib/services/mcp/mcp_oauth.dart
//
// The OAuth 2.1 flow MCP servers use, as defined in the MCP authorization
// spec. It is the part that makes "add a server by URL" work without any
// per-service setup on our side:
//
//   401 → protected resource metadata (RFC 9728) → authorization server
//   metadata (RFC 8414 / OpenID discovery) → dynamic client registration
//   (RFC 7591) → authorization code with PKCE and a `resource` parameter
//   (RFC 8707) → access token.
//
// No client id is baked into the app. Every server hands us one when we
// register, so a reader can paste any compliant MCP URL and connect.

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// What a server's authorization looks like once discovered.
class McpAuthServer {
  const McpAuthServer({
    required this.issuer,
    required this.authorizationEndpoint,
    required this.tokenEndpoint,
    this.registrationEndpoint,
    this.scopesSupported = const <String>[],
  });

  final String issuer;
  final Uri authorizationEndpoint;
  final Uri tokenEndpoint;
  final Uri? registrationEndpoint;
  final List<String> scopesSupported;
}

/// The client id (and secret, if the server insists on one) we registered.
class McpClientCredentials {
  const McpClientCredentials({
    required this.clientId,
    this.clientSecret,
    this.clientName,
  });

  final String clientId;
  final String? clientSecret;

  /// The `client_name` this client was registered under: what the provider's
  /// consent screen shows. Null for a record from before it was kept. Every
  /// sign-in registers anew ([McpService.connect]), so a record under an
  /// older name is replaced by the next sign-in; this says which one it is.
  final String? clientName;

  /// Whether this registration was made under the app's current name.
  bool get isCurrentRegistration => clientName == McpOAuth.clientName;

  Map<String, dynamic> toJson() => {
    'client_id': clientId,
    if (clientSecret != null) 'client_secret': clientSecret,
    if (clientName != null) 'client_name': clientName,
  };

  static McpClientCredentials fromJson(Map<String, dynamic> json) =>
      McpClientCredentials(
        clientId: (json['client_id'] ?? '').toString(),
        clientSecret: json['client_secret']?.toString(),
        clientName: json['client_name']?.toString(),
      );
}

/// The tokens a server issued.
class McpTokens {
  const McpTokens({
    required this.accessToken,
    this.refreshToken,
    this.expiresAt,
    this.scope,
  });

  final String accessToken;
  final String? refreshToken;
  final DateTime? expiresAt;
  final String? scope;

  /// True shortly before the real expiry, so a call does not race it.
  bool get isExpired {
    final at = expiresAt;
    if (at == null) return false;
    return DateTime.now().isAfter(at.subtract(const Duration(seconds: 30)));
  }

  Map<String, dynamic> toJson() => {
    'access_token': accessToken,
    if (refreshToken != null) 'refresh_token': refreshToken,
    if (expiresAt != null) 'expires_at': expiresAt!.toIso8601String(),
    if (scope != null) 'scope': scope,
  };

  static McpTokens fromJson(Map<String, dynamic> json) => McpTokens(
    accessToken: (json['access_token'] ?? '').toString(),
    refreshToken: json['refresh_token']?.toString(),
    expiresAt: DateTime.tryParse(json['expires_at']?.toString() ?? ''),
    scope: json['scope']?.toString(),
  );

  static McpTokens fromTokenResponse(Map<String, dynamic> json) {
    final expiresIn = json['expires_in'];
    final seconds = expiresIn is num
        ? expiresIn.toInt()
        : int.tryParse(expiresIn?.toString() ?? '');
    return McpTokens(
      accessToken: (json['access_token'] ?? '').toString(),
      refreshToken: json['refresh_token']?.toString(),
      expiresAt: seconds == null
          ? null
          : DateTime.now().add(Duration(seconds: seconds)),
      scope: json['scope']?.toString(),
    );
  }
}

class McpAuthException implements Exception {
  const McpAuthException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// One authorization attempt, kept together so the verifier, the state and
/// the expected issuer cannot drift apart.
class McpAuthorizationRequest {
  const McpAuthorizationRequest({
    required this.url,
    required this.state,
    required this.codeVerifier,
    required this.server,
    required this.credentials,
    required this.redirectUri,
    required this.resource,
    required this.scope,
  });

  final Uri url;
  final String state;
  final String codeVerifier;
  final McpAuthServer server;
  final McpClientCredentials credentials;
  final Uri redirectUri;
  final String resource;
  final String? scope;
}

class McpOAuth {
  McpOAuth({http.Client? httpClient}) : _http = httpClient ?? http.Client();

  final http.Client _http;

  /// What a provider's consent screen shows ("Chuk Chat wants to access your
  /// account"). Fixed at registration: an older client keeps its old name
  /// until the next sign-in registers a new one.
  static const String clientName = 'Chuk Chat';

  /// The product site. `agents.chuk.chat` (the old value) does not resolve.
  static const String clientUri = 'https://chuk.chat';

  // ─── Discovery ─────────────────────────────────────────────────────────

  /// [scopes] plus `offline_access` when the authorization server lists it
  /// and [scopes] does not ask for it yet. That scope is what makes an OpenID
  /// provider issue a refresh token at all, so without it a connector would
  /// need a new sign-in every time the access token lapses. Left alone when
  /// [scopes] is empty: then the request carries no scope and the server
  /// picks its default.
  static List<String> _withOfflineAccess(
    List<String> scopes,
    Object? serverScopes,
  ) {
    const offline = 'offline_access';
    if (scopes.isEmpty || scopes.contains(offline)) return scopes;
    final bool offered =
        serverScopes is List && serverScopes.map((e) => '$e').contains(offline);
    return offered ? <String>[...scopes, offline] : scopes;
  }

  /// The canonical resource identifier of an MCP server, as RFC 8707 wants
  /// it: no fragment, no trailing slash.
  static String canonicalResource(Uri serverUrl) {
    final path = serverUrl.path.endsWith('/') && serverUrl.path.length > 1
        ? serverUrl.path.substring(0, serverUrl.path.length - 1)
        : serverUrl.path;
    // Built from the origin rather than replaced field by field: replacing
    // a query with an empty string leaves the `?` behind, and a resource
    // identifier with a stray `?#` matches nothing.
    return '${serverUrl.origin}$path';
  }

  /// Pull `resource_metadata="…"` out of a `WWW-Authenticate` challenge.
  static Uri? resourceMetadataUrl(String? wwwAuthenticate) {
    if (wwwAuthenticate == null) return null;
    final match = RegExp(
      r'resource_metadata="?([^",\s]+)"?',
    ).firstMatch(wwwAuthenticate);
    final raw = match?.group(1);
    return raw == null ? null : Uri.tryParse(raw);
  }

  /// The scopes the challenge asks for, if it says.
  static List<String> challengeScopes(String? wwwAuthenticate) {
    if (wwwAuthenticate == null) return const [];
    final match = RegExp(r'scope="([^"]+)"').firstMatch(wwwAuthenticate);
    return match?.group(1)?.split(' ').where((s) => s.isNotEmpty).toList() ??
        const [];
  }

  /// Well-known locations for protected resource metadata: the one the
  /// challenge names, then the path-aware and root forms of RFC 9728.
  static List<Uri> resourceMetadataCandidates(
    Uri serverUrl,
    String? wwwAuthenticate,
  ) {
    final fromChallenge = resourceMetadataUrl(wwwAuthenticate);
    final path = serverUrl.path.replaceAll(RegExp(r'/+$'), '');
    return <Uri>[
      ?fromChallenge,
      if (path.isNotEmpty)
        Uri.parse(
          '${serverUrl.origin}/.well-known/oauth-protected-resource$path',
        ),
      Uri.parse('${serverUrl.origin}/.well-known/oauth-protected-resource'),
    ];
  }

  /// Well-known locations for authorization server metadata, in the order
  /// the spec asks clients to try them.
  static List<Uri> authServerMetadataCandidates(Uri issuer) {
    final path = issuer.path.replaceAll(RegExp(r'/+$'), '');
    return <Uri>[
      issuer.replace(path: '/.well-known/oauth-authorization-server$path'),
      if (path.isNotEmpty)
        issuer.replace(path: '$path/.well-known/openid-configuration'),
      issuer.replace(path: '/.well-known/openid-configuration$path'),
      issuer.replace(path: '/.well-known/oauth-authorization-server'),
    ];
  }

  /// Find the authorization server behind an MCP endpoint.
  Future<McpAuthServer> discover(
    Uri serverUrl, {
    String? wwwAuthenticate,
  }) async {
    Map<String, dynamic>? resourceMetadata;
    for (final url in resourceMetadataCandidates(serverUrl, wwwAuthenticate)) {
      resourceMetadata = await _getJson(url);
      if (resourceMetadata != null) break;
    }

    final issuers = <String>[
      ...?(resourceMetadata?['authorization_servers'] as List?)?.map(
        (e) => e.toString(),
      ),
      // Servers that skip the metadata document usually are their own
      // authorization server.
      serverUrl.origin,
    ];

    final scopes = <String>[
      ...challengeScopes(wwwAuthenticate),
      ...?(resourceMetadata?['scopes_supported'] as List?)?.map(
        (e) => e.toString(),
      ),
    ];

    for (final issuer in issuers) {
      final issuerUri = Uri.tryParse(issuer);
      if (issuerUri == null) continue;
      for (final url in authServerMetadataCandidates(issuerUri)) {
        final metadata = await _getJson(url);
        if (metadata == null) continue;
        final authorize = _uriOrNull(metadata['authorization_endpoint']);
        final token = _uriOrNull(metadata['token_endpoint']);
        if (authorize == null || token == null) continue;
        return McpAuthServer(
          issuer: (metadata['issuer'] ?? issuer).toString(),
          authorizationEndpoint: authorize,
          tokenEndpoint: token,
          // Not `Uri.tryParse('')`: that returns an empty URI rather than
          // null, and an empty registration endpoint reads as "this server
          // registers clients" — which is how a server without dynamic
          // registration looked connectable and then failed at the POST.
          registrationEndpoint: _uriOrNull(metadata['registration_endpoint']),
          scopesSupported: _withOfflineAccess(
            scopes.isNotEmpty
                ? scopes.toSet().toList()
                : ((metadata['scopes_supported'] as List?)
                          ?.map((e) => e.toString())
                          .toList() ??
                      const <String>[]),
            metadata['scopes_supported'],
          ),
        );
      }
    }

    throw const McpAuthException(
      'This server did not say where to sign in. It may not support '
      'OAuth, or it may not be an MCP server.',
    );
  }

  // ─── Registration ──────────────────────────────────────────────────────

  /// Register this app with the authorization server (RFC 7591), so no
  /// client id has to be configured per service.
  Future<McpClientCredentials> register(
    McpAuthServer server,
    Uri redirectUri, {
    String? scope,
  }) async {
    final endpoint = server.registrationEndpoint;
    if (endpoint == null) {
      throw const McpAuthException(
        'This server does not register clients automatically, so it cannot '
        'be added without credentials from its operator.',
      );
    }

    final response = await _http.post(
      endpoint,
      headers: const {
        'content-type': 'application/json',
        'accept': 'application/json',
      },
      body: jsonEncode({
        'client_name': clientName,
        'client_uri': clientUri,
        'redirect_uris': [redirectUri.toString()],
        'grant_types': ['authorization_code', 'refresh_token'],
        'response_types': ['code'],
        'token_endpoint_auth_method': 'none',
        if (scope != null && scope.isNotEmpty) 'scope': scope,
      }),
    );

    if (response.statusCode >= 400) {
      throw McpAuthException(
        'The server refused to register this app (${response.statusCode}).',
      );
    }

    final json = jsonDecode(response.body);
    if (json is! Map || json['client_id'] == null) {
      throw const McpAuthException('The server registered no client id.');
    }

    // Some servers accept the registration but hand back a fixed set of
    // redirect URIs — an allowlist of a few first-party apps (Namecheap
    // returns Cursor, Claude, VS Code, ChatGPT and the like) — and drop the
    // one we asked for. The loopback address we listen on is never in that
    // list, so the sign-in that follows would redirect to the server's own
    // error page and the app would sit on the callback until it timed out.
    // Catch it here, before any browser opens, and say why.
    //
    // But an exact string match would refuse servers that are fine. A loopback
    // redirect is defined by RFC 8252 §7.3 to carry a VARIABLE port, and the
    // server is allowed to normalise what it registers: Fastmail answers our
    // `http://localhost:49152/mcp/callback` with `http://localhost/mcp/callback`
    // — the port dropped, the host kept. What matters is that the server
    // registered SOME loopback redirect with the same path, because that is
    // the shape of URI it will send the browser back to. A registration whose
    // every entry is a first-party app (a custom scheme, or an https page on
    // the provider's own domain) really cannot send the sign-in to us.
    final registered = (json['redirect_uris'] as List?)
        ?.map((e) => e.toString())
        .toList();
    if (registered != null &&
        registered.isNotEmpty &&
        _isLoopbackRedirect(redirectUri) &&
        !registered.any(_loopbackCompatibleWith(redirectUri))) {
      throw const McpAuthException(
        'This server only signs in a fixed set of apps and will not let this '
        'one receive the sign-in, so it cannot be connected here.',
      );
    }

    final issued = McpClientCredentials.fromJson(Map<String, dynamic>.from(json));
    // Recorded as asked: a server that does not echo the name still showed
    // this one on its consent screen.
    return McpClientCredentials(
      clientId: issued.clientId,
      clientSecret: issued.clientSecret,
      clientName: clientName,
    );
  }

  /// True for a redirect URI the app can actually receive a sign-in on: plain
  /// http on a loopback name, any port. That is the whole shape the loopback
  /// listener serves.
  static bool _isLoopbackRedirect(Uri uri) =>
      uri.scheme == 'http' && _isLoopbackHost(uri.host);

  static bool _isLoopbackHost(String host) =>
      host == 'localhost' ||
      host == '127.0.0.1' ||
      host == '[::1]' ||
      host == '::1';

  /// A closure that says whether one registered redirect URI can carry the
  /// sign-in meant for [requested]. Loopback entries match on scheme + host
  /// family + path with the port ignored (RFC 8252 §7.3); anything else must
  /// match exactly, because a non-loopback URI has no variable part.
  static bool Function(String) _loopbackCompatibleWith(Uri requested) {
    final String path = requested.path;
    return (String registeredRaw) {
      final Uri? registered = Uri.tryParse(registeredRaw);
      if (registered == null) return false;
      if (registered.scheme != 'http') return false;
      if (!_isLoopbackHost(registered.host)) return false;
      return registered.path == path;
    };
  }

  // ─── Authorization ─────────────────────────────────────────────────────

  /// Build the URL to open in the browser, with PKCE and the resource the
  /// token is meant for.
  McpAuthorizationRequest buildAuthorizationRequest({
    required McpAuthServer server,
    required McpClientCredentials credentials,
    required Uri redirectUri,
    required String resource,
    List<String> scopes = const [],
  }) {
    final verifier = _randomString(64);
    final challenge = base64Url
        .encode(sha256.convert(ascii.encode(verifier)).bytes)
        .replaceAll('=', '');
    final state = _randomString(32);
    final scope = scopes.isEmpty ? null : scopes.toSet().join(' ');

    final url = server.authorizationEndpoint.replace(
      queryParameters: <String, String>{
        ...server.authorizationEndpoint.queryParameters,
        'response_type': 'code',
        'client_id': credentials.clientId,
        'redirect_uri': redirectUri.toString(),
        'state': state,
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
        'resource': resource,
        'scope': ?scope,
      },
    );

    return McpAuthorizationRequest(
      url: url,
      state: state,
      codeVerifier: verifier,
      server: server,
      credentials: credentials,
      redirectUri: redirectUri,
      resource: resource,
      scope: scope,
    );
  }

  /// Swap the code from the callback for tokens. Rejects a callback whose
  /// `state` or `iss` does not match what was recorded.
  Future<McpTokens> exchange(
    McpAuthorizationRequest request,
    Uri callback,
  ) async {
    final params = callback.queryParameters;

    final issuer = params['iss'];
    if (issuer != null && issuer != request.server.issuer) {
      throw const McpAuthException(
        'The answer came from a different sign-in server than the one asked.',
      );
    }
    if (params['state'] != request.state) {
      throw const McpAuthException(
        'The sign-in answer did not match the request.',
      );
    }
    final error = params['error'];
    if (error != null) {
      throw McpAuthException(
        params['error_description'] ?? 'Sign-in was refused ($error).',
      );
    }
    final code = params['code'];
    if (code == null || code.isEmpty) {
      throw const McpAuthException('The sign-in answer carried no code.');
    }

    return _token(request.server, request.credentials, {
      'grant_type': 'authorization_code',
      'code': code,
      'redirect_uri': request.redirectUri.toString(),
      'code_verifier': request.codeVerifier,
      'resource': request.resource,
    });
  }

  /// Trade a refresh token for a fresh access token. Returns null when the
  /// server refuses, which means the reader has to sign in again.
  Future<McpTokens?> refresh({
    required McpAuthServer server,
    required McpClientCredentials credentials,
    required String refreshToken,
    required String resource,
    String? scope,
  }) async {
    try {
      final tokens = await _token(server, credentials, {
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
        'resource': resource,
        if (scope != null && scope.isNotEmpty) 'scope': scope,
      });
      // Servers may rotate the refresh token, or keep the old one.
      return tokens.refreshToken == null
          ? McpTokens(
              accessToken: tokens.accessToken,
              refreshToken: refreshToken,
              expiresAt: tokens.expiresAt,
              scope: tokens.scope ?? scope,
            )
          : tokens;
    } on McpAuthException {
      return null;
    }
  }

  Future<McpTokens> _token(
    McpAuthServer server,
    McpClientCredentials credentials,
    Map<String, String> body,
  ) async {
    final response = await _http.post(
      server.tokenEndpoint,
      headers: {
        'content-type': 'application/x-www-form-urlencoded',
        'accept': 'application/json',
        if (credentials.clientSecret case final String secret)
          'authorization':
              'Basic ${base64.encode(utf8.encode('${credentials.clientId}:$secret'))}',
      },
      body: {...body, 'client_id': credentials.clientId},
    );

    if (response.statusCode >= 400) {
      throw McpAuthException(
        'The server refused the sign-in (${response.statusCode}).',
      );
    }

    final json = jsonDecode(response.body);
    if (json is! Map || json['access_token'] == null) {
      throw const McpAuthException('The server issued no token.');
    }
    return McpTokens.fromTokenResponse(Map<String, dynamic>.from(json));
  }

  Future<Map<String, dynamic>?> _getJson(Uri url) async {
    try {
      final response = await _http
          .get(url, headers: const {'accept': 'application/json'})
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return null;
      final json = jsonDecode(response.body);
      return json is Map ? Map<String, dynamic>.from(json) : null;
    } catch (_) {
      return null;
    }
  }

  /// An absolute URI, or null for anything that is not one.
  static Uri? _uriOrNull(Object? value) {
    final raw = value?.toString().trim() ?? '';
    if (raw.isEmpty) return null;
    final uri = Uri.tryParse(raw);
    return (uri != null && uri.hasScheme && uri.host.isNotEmpty) ? uri : null;
  }

  static final Random _random = Random.secure();

  static String _randomString(int length) {
    final bytes = List<int>.generate(length, (_) => _random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '').substring(0, length);
  }
}
