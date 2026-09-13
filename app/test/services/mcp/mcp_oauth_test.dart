import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:chuk_chat/services/mcp/mcp_oauth.dart';

http.Response _json(Map<String, dynamic> body) => http.Response(
      jsonEncode(body),
      200,
      headers: const {'content-type': 'application/json'},
    );

/// A server that publishes protected-resource metadata pointing at its own
/// authorization server, registers any client, and issues tokens.
MockClient _compliantServer({
  List<String> scopes = const <String>['read', 'write'],
  void Function(Map<String, String> body)? onToken,
  Map<String, dynamic> Function()? tokenResponse,
  List<String>? registeredRedirectUris,
}) {
  return MockClient((http.Request request) async {
    final path = request.url.path;
    if (request.method == 'GET' &&
        path == '/.well-known/oauth-protected-resource/mcp') {
      return _json(<String, dynamic>{
        'resource': 'https://srv.example/mcp',
        'authorization_servers': <String>['https://auth.example'],
        'scopes_supported': scopes,
      });
    }
    if (request.method == 'GET' &&
        path == '/.well-known/oauth-authorization-server') {
      return _json(<String, dynamic>{
        'issuer': 'https://auth.example',
        'authorization_endpoint': 'https://auth.example/authorize',
        'token_endpoint': 'https://auth.example/token',
        'registration_endpoint': 'https://auth.example/register',
      });
    }
    if (request.method == 'POST' && path == '/register') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      return _json(<String, dynamic>{
        'client_id': 'cid-9',
        'redirect_uris':
            registeredRedirectUris ?? (body['redirect_uris'] as List),
      });
    }
    if (request.method == 'POST' && path == '/token') {
      onToken?.call(request.bodyFields);
      return _json(
        tokenResponse?.call() ??
            <String, dynamic>{
              'access_token': 'at-9',
              'refresh_token': 'rt-9',
              'expires_in': 3600,
              'scope': 'read write',
            },
      );
    }
    return http.Response('not found', 404);
  });
}

void main() {
  final serverUrl = Uri.parse('https://srv.example/mcp');

  group('discovery', () {
    test('follows the resource metadata to the authorization server',
        () async {
      final oauth = McpOAuth(httpClient: _compliantServer());

      final server = await oauth.discover(serverUrl);

      expect(server.issuer, 'https://auth.example');
      expect(server.authorizationEndpoint.toString(),
          'https://auth.example/authorize');
      expect(server.tokenEndpoint.toString(), 'https://auth.example/token');
      expect(server.registrationEndpoint.toString(),
          'https://auth.example/register');
      expect(server.scopesSupported, containsAll(<String>['read', 'write']));
    });

    test('a server that says nothing about signing in is reported as such',
        () async {
      final oauth = McpOAuth(
        httpClient: MockClient((_) async => http.Response('nope', 404)),
      );

      expect(
        () => oauth.discover(serverUrl),
        throwsA(isA<McpAuthException>()),
      );
    });

    test('the challenge names the metadata document and the scopes', () {
      const challenge =
          'Bearer resource_metadata="https://srv.example/meta", scope="a b"';
      expect(
        McpOAuth.resourceMetadataUrl(challenge).toString(),
        'https://srv.example/meta',
      );
      expect(McpOAuth.challengeScopes(challenge), <String>['a', 'b']);
    });

    test('the canonical resource drops a trailing slash and any query', () {
      expect(
        McpOAuth.canonicalResource(Uri.parse('https://srv.example/mcp/?x=1#f')),
        'https://srv.example/mcp',
      );
      expect(
        McpOAuth.canonicalResource(Uri.parse('https://srv.example')),
        'https://srv.example',
      );
    });
  });

  group('registration', () {
    test('registers this app and gets a client id back', () async {
      final oauth = McpOAuth(httpClient: _compliantServer());
      final server = await oauth.discover(serverUrl);

      final credentials = await oauth.register(
        server,
        Uri.parse('http://127.0.0.1:4321/mcp/callback'),
        scope: 'read write',
      );

      expect(credentials.clientId, 'cid-9');
    });

    test('a server that drops our redirect URI is refused before the browser '
        'opens', () async {
      final oauth = McpOAuth(
        httpClient: _compliantServer(
          registeredRedirectUris: <String>['https://someone.else/callback'],
        ),
      );
      final server = await oauth.discover(serverUrl);

      expect(
        () => oauth.register(
          server,
          Uri.parse('http://127.0.0.1:4321/mcp/callback'),
        ),
        throwsA(isA<McpAuthException>()),
      );
    });
  });

  group('authorization', () {
    test('the request carries PKCE, the resource and the state', () async {
      final oauth = McpOAuth(httpClient: _compliantServer());
      final server = await oauth.discover(serverUrl);
      final credentials =
          const McpClientCredentials(clientId: 'cid-9');

      final request = oauth.buildAuthorizationRequest(
        server: server,
        credentials: credentials,
        redirectUri: Uri.parse('http://127.0.0.1:4321/mcp/callback'),
        resource: McpOAuth.canonicalResource(serverUrl),
        scopes: const <String>['read', 'write'],
      );

      final q = request.url.queryParameters;
      expect(q['response_type'], 'code');
      expect(q['client_id'], 'cid-9');
      expect(q['code_challenge_method'], 'S256');
      expect(q['code_challenge'], isNotEmpty);
      expect(q['resource'], 'https://srv.example/mcp');
      expect(q['state'], request.state);
      expect(request.codeVerifier.length, 64);
    });

    test('exchange swaps the code for tokens', () async {
      Map<String, String>? sent;
      final oauth = McpOAuth(
        httpClient: _compliantServer(onToken: (body) => sent = body),
      );
      final server = await oauth.discover(serverUrl);
      final request = oauth.buildAuthorizationRequest(
        server: server,
        credentials: const McpClientCredentials(clientId: 'cid-9'),
        redirectUri: Uri.parse('http://127.0.0.1:4321/mcp/callback'),
        resource: McpOAuth.canonicalResource(serverUrl),
      );

      final tokens = await oauth.exchange(
        request,
        Uri.parse(
          'http://127.0.0.1:4321/mcp/callback?code=the-code&state=${request.state}',
        ),
      );

      expect(tokens.accessToken, 'at-9');
      expect(tokens.refreshToken, 'rt-9');
      expect(tokens.expiresAt, isNotNull);
      expect(sent!['grant_type'], 'authorization_code');
      expect(sent!['code'], 'the-code');
      expect(sent!['code_verifier'], request.codeVerifier);
      expect(sent!['resource'], 'https://srv.example/mcp');
    });

    test('a callback whose state does not match is refused', () async {
      final oauth = McpOAuth(httpClient: _compliantServer());
      final server = await oauth.discover(serverUrl);
      final request = oauth.buildAuthorizationRequest(
        server: server,
        credentials: const McpClientCredentials(clientId: 'cid-9'),
        redirectUri: Uri.parse('http://127.0.0.1:4321/mcp/callback'),
        resource: McpOAuth.canonicalResource(serverUrl),
      );

      expect(
        () => oauth.exchange(
          request,
          Uri.parse(
            'http://127.0.0.1:4321/mcp/callback?code=c&state=somebody-elses',
          ),
        ),
        throwsA(isA<McpAuthException>()),
      );
    });

    test('a callback carrying an error is reported with the description',
        () async {
      final oauth = McpOAuth(httpClient: _compliantServer());
      final server = await oauth.discover(serverUrl);
      final request = oauth.buildAuthorizationRequest(
        server: server,
        credentials: const McpClientCredentials(clientId: 'cid-9'),
        redirectUri: Uri.parse('http://127.0.0.1:4321/mcp/callback'),
        resource: McpOAuth.canonicalResource(serverUrl),
      );

      expect(
        () => oauth.exchange(
          request,
          Uri.parse(
            'http://127.0.0.1:4321/mcp/callback?error=access_denied'
            '&error_description=Nope&state=${request.state}',
          ),
        ),
        throwsA(isA<McpAuthException>()),
      );
    });
  });

  group('refresh', () {
    test('keeps the old refresh token when the server does not rotate it',
        () async {
      final oauth = McpOAuth(
        httpClient: _compliantServer(
          tokenResponse: () => <String, dynamic>{
            'access_token': 'at-new',
            'expires_in': 60,
          },
        ),
      );
      final server = await oauth.discover(serverUrl);

      final tokens = await oauth.refresh(
        server: server,
        credentials: const McpClientCredentials(clientId: 'cid-9'),
        refreshToken: 'rt-old',
        resource: 'https://srv.example/mcp',
        scope: 'read write',
      );

      expect(tokens!.accessToken, 'at-new');
      expect(tokens.refreshToken, 'rt-old');
      expect(tokens.scope, 'read write');
    });

    test('a refused refresh reads as null, not an exception', () async {
      final oauth = McpOAuth(
        httpClient: MockClient((http.Request request) async {
          if (request.method == 'GET') {
            return _json(<String, dynamic>{
              'issuer': 'https://auth.example',
              'authorization_endpoint': 'https://auth.example/authorize',
              'token_endpoint': 'https://auth.example/token',
            });
          }
          return http.Response('expired', 400);
        }),
      );
      final server = await oauth.discover(serverUrl);

      final tokens = await oauth.refresh(
        server: server,
        credentials: const McpClientCredentials(clientId: 'cid-9'),
        refreshToken: 'rt-dead',
        resource: 'https://srv.example/mcp',
      );

      expect(tokens, isNull);
    });
  });

  group('token expiry', () {
    test('a token is called expired shortly before it really is', () {
      final almost = McpTokens(
        accessToken: 'a',
        expiresAt: DateTime.now().add(const Duration(seconds: 5)),
      );
      final fresh = McpTokens(
        accessToken: 'a',
        expiresAt: DateTime.now().add(const Duration(minutes: 10)),
      );
      const noExpiry = McpTokens(accessToken: 'a');

      expect(almost.isExpired, isTrue);
      expect(fresh.isExpired, isFalse);
      expect(noExpiry.isExpired, isFalse);
    });
  });
}
