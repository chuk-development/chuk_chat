// The sign-in flow: discovery, registration, PKCE, and the checks that
// stop a forged callback from becoming a token.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:chuk_chat/services/mcp/mcp_oauth.dart';

const _issuer = 'https://auth.example.com';

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: const {'content-type': 'application/json'},
);

MockClient _server({bool withRegistration = true}) {
  return MockClient((request) async {
    final path = request.url.path;
    if (path.contains('oauth-protected-resource')) {
      return _json({
        'resource': 'https://mcp.example.com/mcp',
        'authorization_servers': [_issuer],
        'scopes_supported': ['files:read'],
      });
    }
    if (path.contains('oauth-authorization-server') ||
        path.contains('openid-configuration')) {
      return _json({
        'issuer': _issuer,
        'authorization_endpoint': '$_issuer/authorize',
        'token_endpoint': '$_issuer/token',
        if (withRegistration) 'registration_endpoint': '$_issuer/register',
      });
    }
    if (path.endsWith('/register')) {
      return _json({'client_id': 'generated-id'});
    }
    if (path.endsWith('/token')) {
      return _json({
        'access_token': 'at-1',
        'refresh_token': 'rt-1',
        'expires_in': 3600,
      });
    }
    return http.Response('not found', 404);
  });
}

void main() {
  final endpoint = Uri.parse('https://mcp.example.com/mcp');

  group('reading the challenge', () {
    test('the metadata URL is pulled out of WWW-Authenticate', () {
      expect(
        McpOAuth.resourceMetadataUrl(
          'Bearer resource_metadata="https://a.example/.well-known/x", '
          'scope="files:read"',
        ).toString(),
        'https://a.example/.well-known/x',
      );
      expect(McpOAuth.resourceMetadataUrl(null), isNull);
    });

    test('the asked-for scopes are read from the challenge', () {
      expect(
        McpOAuth.challengeScopes('Bearer scope="files:read files:write"'),
        ['files:read', 'files:write'],
      );
    });

    test('the canonical resource keeps the path and drops the rest', () {
      expect(
        McpOAuth.canonicalResource(Uri.parse('https://mcp.example.com/mcp/')),
        'https://mcp.example.com/mcp',
      );
      expect(
        McpOAuth.canonicalResource(
          Uri.parse('https://mcp.example.com/mcp?x=1#f'),
        ),
        'https://mcp.example.com/mcp',
      );
    });
  });

  test('discovery finds the authorization server behind the endpoint', () async {
    final oauth = McpOAuth(httpClient: _server());
    final server = await oauth.discover(endpoint);

    expect(server.issuer, _issuer);
    expect(server.tokenEndpoint.toString(), '$_issuer/token');
    expect(server.scopesSupported, contains('files:read'));
  });

  test('a server without any metadata is refused, not guessed at', () async {
    final oauth = McpOAuth(
      httpClient: MockClient((_) async => http.Response('nope', 404)),
    );
    await expectLater(
      oauth.discover(endpoint),
      throwsA(isA<McpAuthException>()),
    );
  });

  test('registration asks the server for a client id', () async {
    final oauth = McpOAuth(httpClient: _server());
    final server = await oauth.discover(endpoint);
    final credentials = await oauth.register(
      server,
      Uri.parse('http://127.0.0.1:1234/mcp/callback'),
    );
    expect(credentials.clientId, 'generated-id');
  });

  test('a server that registers no clients says so', () async {
    final oauth = McpOAuth(httpClient: _server(withRegistration: false));
    final server = await oauth.discover(endpoint);
    await expectLater(
      oauth.register(server, Uri.parse('http://127.0.0.1:1/cb')),
      throwsA(isA<McpAuthException>()),
    );
  });

  group('the authorization request', () {
    Future<McpAuthorizationRequest> build() async {
      final oauth = McpOAuth(httpClient: _server());
      final server = await oauth.discover(endpoint);
      return oauth.buildAuthorizationRequest(
        server: server,
        credentials: const McpClientCredentials(clientId: 'cid'),
        redirectUri: Uri.parse('http://127.0.0.1:1234/mcp/callback'),
        resource: McpOAuth.canonicalResource(endpoint),
        scopes: server.scopesSupported,
      );
    }

    test('carries PKCE, the resource and the scopes', () async {
      final request = await build();
      final q = request.url.queryParameters;

      expect(q['response_type'], 'code');
      expect(q['code_challenge_method'], 'S256');
      expect(q['code_challenge'], isNotEmpty);
      expect(q['code_challenge'], isNot(request.codeVerifier));
      expect(q['resource'], 'https://mcp.example.com/mcp');
      expect(q['scope'], 'files:read');
      expect(q['state'], request.state);
    });

    test('a callback with the wrong state is thrown away', () async {
      final request = await build();
      final oauth = McpOAuth(httpClient: _server());
      await expectLater(
        oauth.exchange(
          request,
          Uri.parse('http://127.0.0.1:1234/mcp/callback?code=c&state=forged'),
        ),
        throwsA(isA<McpAuthException>()),
      );
    });

    test('a callback from another issuer is thrown away', () async {
      final request = await build();
      final oauth = McpOAuth(httpClient: _server());
      await expectLater(
        oauth.exchange(
          request,
          Uri.parse(
            'http://127.0.0.1:1234/mcp/callback'
            '?code=c&state=${request.state}&iss=https://evil.example',
          ),
        ),
        throwsA(isA<McpAuthException>()),
      );
    });

    test('a refusal is reported, not turned into a token', () async {
      final request = await build();
      final oauth = McpOAuth(httpClient: _server());
      await expectLater(
        oauth.exchange(
          request,
          Uri.parse(
            'http://127.0.0.1:1234/mcp/callback'
            '?error=access_denied&state=${request.state}',
          ),
        ),
        throwsA(isA<McpAuthException>()),
      );
    });

    test('a good callback becomes tokens', () async {
      final request = await build();
      final oauth = McpOAuth(httpClient: _server());
      final tokens = await oauth.exchange(
        request,
        Uri.parse(
          'http://127.0.0.1:1234/mcp/callback'
          '?code=c&state=${request.state}&iss=$_issuer',
        ),
      );

      expect(tokens.accessToken, 'at-1');
      expect(tokens.refreshToken, 'rt-1');
      expect(tokens.isExpired, isFalse);
    });
  });

  test('a token without an expiry never counts as expired', () {
    const tokens = McpTokens(accessToken: 'a');
    expect(tokens.isExpired, isFalse);
  });

  test('an expiry in the past counts as expired', () {
    final tokens = McpTokens(
      accessToken: 'a',
      expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
    );
    expect(tokens.isExpired, isTrue);
  });

  test('a refresh that returns no new refresh token keeps the old one', () async {
    final oauth = McpOAuth(
      httpClient: MockClient(
        (_) async => _json({'access_token': 'at-2', 'expires_in': 60}),
      ),
    );
    final tokens = await oauth.refresh(
      server: McpAuthServer(
        issuer: _issuer,
        authorizationEndpoint: Uri.parse('$_issuer/authorize'),
        tokenEndpoint: Uri.parse('$_issuer/token'),
      ),
      credentials: const McpClientCredentials(clientId: 'cid'),
      refreshToken: 'rt-1',
      resource: 'https://mcp.example.com/mcp',
    );

    expect(tokens?.accessToken, 'at-2');
    expect(tokens?.refreshToken, 'rt-1');
  });

  test('a refused refresh returns null so the reader is asked again', () async {
    final oauth = McpOAuth(
      httpClient: MockClient((_) async => http.Response('no', 400)),
    );
    final tokens = await oauth.refresh(
      server: McpAuthServer(
        issuer: _issuer,
        authorizationEndpoint: Uri.parse('$_issuer/authorize'),
        tokenEndpoint: Uri.parse('$_issuer/token'),
      ),
      credentials: const McpClientCredentials(clientId: 'cid'),
      refreshToken: 'rt-1',
      resource: 'https://mcp.example.com/mcp',
    );
    expect(tokens, isNull);
  });
}
