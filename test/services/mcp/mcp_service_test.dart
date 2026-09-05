import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cowork/services/cowork/cowork_pairing_store.dart'
    show CoworkSecureKeyValueStore;
import 'package:cowork/services/mcp/mcp_connection.dart';
import 'package:cowork/services/mcp/mcp_connector_sync.dart';
import 'package:cowork/services/mcp/mcp_oauth.dart';
import 'package:cowork/services/mcp/mcp_service.dart';
import 'package:cowork/services/mcp/mcp_store.dart';

class _MemorySecrets implements CoworkSecureKeyValueStore {
  final Map<String, String> map = <String, String>{};

  @override
  Future<String?> read(String key) async => map[key];

  @override
  Future<void> write(String key, String value) async => map[key] = value;

  @override
  Future<void> delete(String key) async => map.remove(key);
}

/// An in-memory stand-in for the encrypted Supabase mirror.
class _FakeSync implements McpConnectorSync {
  Map<String, dynamic>? blob;

  @override
  Future<void> save(Map<String, dynamic> payload) async => blob = payload;

  @override
  Future<Map<String, dynamic>?> load() async => blob;

  @override
  Future<void> clear() async => blob = null;
}

http.Response _json(Map<String, dynamic> body) => http.Response(
      jsonEncode(body),
      200,
      headers: const {'content-type': 'application/json'},
    );

/// The server's answer to an unauthenticated request: a 401 that names both
/// the metadata document and the scope it wants. Real servers (Atlassian,
/// Linear) name the scope only here, so this is the path that decides whether
/// the token is minted for the right grant.
MockClient _challengingServer({String scope = 'read'}) =>
    MockClient((http.Request request) async => http.Response(
          'unauthorized',
          401,
          headers: <String, String>{
            'www-authenticate': 'Bearer '
                'resource_metadata='
                '"https://srv.example/.well-known/oauth-protected-resource/mcp", '
                'scope="$scope"',
          },
        ));

/// A compliant authorization server for `https://srv.example/mcp`.
MockClient _authServer({bool refuseRegistration = false}) =>
    MockClient((http.Request request) async {
      final path = request.url.path;
      if (request.method == 'GET' &&
          path == '/.well-known/oauth-protected-resource/mcp') {
        return _json(<String, dynamic>{
          'authorization_servers': <String>['https://auth.example'],
          'scopes_supported': <String>['read'],
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
        if (refuseRegistration) return http.Response('no', 403);
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        return _json(<String, dynamic>{
          'client_id': 'cid-live',
          'redirect_uris': body['redirect_uris'],
        });
      }
      if (request.method == 'POST' && path == '/token') {
        return _json(<String, dynamic>{
          'access_token': 'at-live',
          'refresh_token': 'rt-live',
          'expires_in': 3600,
          'scope': 'read',
        });
      }
      return http.Response('not found', 404);
    });

/// Stands in for the browser: takes the authorization URL, hands the loopback
/// listener a callback with a matching state, exactly as a real sign-in would.
Future<bool> _signIn(Uri authorizationUrl) async {
  final redirect = Uri.parse(authorizationUrl.queryParameters['redirect_uri']!);
  final state = authorizationUrl.queryParameters['state']!;
  final client = HttpClient();
  try {
    final request = await client.getUrl(
      redirect.replace(queryParameters: <String, String>{
        'code': 'the-code',
        'state': state,
      }),
    );
    final response = await request.close();
    await response.drain<void>();
    return true;
  } finally {
    client.close(force: true);
  }
}

void main() {
  late _MemorySecrets secrets;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    secrets = _MemorySecrets();
    McpService.resetForTest(
      store: McpStore(secrets: secrets, oauth: McpOAuth(httpClient: _authServer())),
    );
    McpService.oauthFactory = () => McpOAuth(httpClient: _authServer());
    McpService.probeClientFactory = _challengingServer;
  });

  tearDown(McpService.resetForTest);

  test('connecting an OAuth connector signs in and stores the whole record',
      () async {
    McpService.launcher = _signIn;

    final result = await McpService.connect(
      id: 'srv',
      name: 'Srv',
      url: 'https://srv.example/mcp',
    );

    expect(result.status, McpConnectStatus.connected);
    expect(McpService.connections.value.single.id, 'srv');

    final record = (await McpService.store.secretsFor('srv'))!;
    expect(record.tokens.accessToken, 'at-live');
    expect(record.tokens.refreshToken, 'rt-live');
    expect(record.credentials.clientId, 'cid-live');
    expect(record.tokenEndpoint, 'https://auth.example/token');
    expect(record.issuer, 'https://auth.example');
    expect(record.scope, 'read');
  });

  test('the signed-in connector forwards its token and its refresh block',
      () async {
    McpService.launcher = _signIn;
    await McpService.connect(
      id: 'srv',
      name: 'Srv',
      url: 'https://srv.example/mcp',
    );

    final payload = (await McpService.store.forwardPayloads()).single;

    expect(payload['auth'], 'oauth');
    expect(payload['access_token'], 'at-live');
    final block = payload['oauth'] as Map<String, dynamic>;
    expect(block['refresh_token'], 'rt-live');
    expect(block['token_endpoint'], 'https://auth.example/token');
    expect(block['client_id'], 'cid-live');
    expect(block['resource'], 'https://srv.example/mcp');
  });

  test('a live sign-in produces exactly the frozen wire shape', () async {
    // The end of the chain: a real browser round trip (loopback listener, real
    // redirect, real code exchange) has to come out as the payload frozen in
    // app/test/fixtures/mcp_forward_payload.json — the same file the Python
    // side parses in agent/tests/test_mcp_client.py. If the two ever drift,
    // the host stops being able to renew tokens and nobody notices until a
    // connector quietly stops working.
    McpService.launcher = _signIn;
    await McpService.connect(
      id: 'srv',
      name: 'Srv',
      url: 'https://srv.example/mcp',
    );

    final payload = (await McpService.store.forwardPayloads()).single;

    final fixture = jsonDecode(
      File('test/fixtures/mcp_forward_payload.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final frozen = (fixture['mcp_servers'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((e) => e['name'] == 'Notion');

    expect(payload.keys.toSet(), frozen.keys.toSet());
    expect(
      (payload['oauth'] as Map).keys.toSet(),
      (frozen['oauth'] as Map).keys.toSet(),
    );
  });

  test('a connector that is already signed in does not open the browser again',
      () async {
    var opened = 0;
    McpService.launcher = (Uri url) async {
      opened++;
      return _signIn(url);
    };

    await McpService.connect(
      id: 'srv',
      name: 'Srv',
      url: 'https://srv.example/mcp',
    );
    final again = await McpService.connect(
      id: 'srv',
      name: 'Srv renamed',
      url: 'https://srv.example/mcp',
    );

    expect(again.status, McpConnectStatus.connected);
    expect(opened, 1);
    expect(McpService.connections.value.single.name, 'Srv renamed');
  });

  test('cancelling the sign-in reports a cancel and stores nothing', () async {
    final canceler = McpConnectCanceler();
    // The browser opens and the user backs out instead of signing in.
    McpService.launcher = (Uri url) async {
      canceler.cancel();
      return true;
    };

    final result = await McpService.connect(
      id: 'srv',
      name: 'Srv',
      url: 'https://srv.example/mcp',
      canceler: canceler,
    );

    expect(result.status, McpConnectStatus.cancelled);
    expect(McpService.connections.value, isEmpty);
    expect(await McpService.store.secretsFor('srv'), isNull);
  });

  test('a browser that will not open is a failure, not a silent connect',
      () async {
    McpService.launcher = (Uri url) async => false;

    final result = await McpService.connect(
      id: 'srv',
      name: 'Srv',
      url: 'https://srv.example/mcp',
    );

    expect(result.status, McpConnectStatus.failed);
    expect(result.message, contains('browser'));
    expect(McpService.connections.value, isEmpty);
  });

  test('a server that refuses to register this app says so', () async {
    McpService.oauthFactory =
        () => McpOAuth(httpClient: _authServer(refuseRegistration: true));
    McpService.launcher = _signIn;

    final result = await McpService.connect(
      id: 'srv',
      name: 'Srv',
      url: 'https://srv.example/mcp',
    );

    expect(result.status, McpConnectStatus.failed);
    expect(result.message, contains('register'));
  });

  test('an account-auth connector never opens a browser', () async {
    var opened = 0;
    McpService.launcher = (Uri url) async {
      opened++;
      return true;
    };

    final result = await McpService.connect(
      id: 'gh',
      name: 'GitHub',
      url: 'https://api.example/v1/mcp/github',
      auth: McpAuth.appSession,
    );

    expect(result.status, McpConnectStatus.connected);
    expect(opened, 0);
  });

  test('an API-key connector stores its credentials and opens no browser',
      () async {
    var opened = 0;
    McpService.launcher = (Uri url) async {
      opened++;
      return true;
    };

    final result = await McpService.connectWithCredentials(
      id: 'brave',
      name: 'Brave',
      url: 'https://brave.example/mcp',
      credentials: <String, String>{'key': 'k-123'},
    );

    expect(result.status, McpConnectStatus.connected);
    expect(opened, 0);
    expect(
      await McpService.store.apiCredentialsFor('brave'),
      <String, String>{'key': 'k-123'},
    );
  });

  test('a URL that is not https is refused before anything is opened',
      () async {
    var opened = 0;
    McpService.launcher = (Uri url) async {
      opened++;
      return true;
    };

    final result = await McpService.connect(
      id: 'x',
      name: 'X',
      url: 'ftp://srv.example/mcp',
    );

    expect(result.status, McpConnectStatus.failed);
    expect(opened, 0);
  });

  test('disconnect forgets the connector and its record', () async {
    McpService.launcher = _signIn;
    await McpService.connect(
      id: 'srv',
      name: 'Srv',
      url: 'https://srv.example/mcp',
    );

    await McpService.disconnect('srv');

    expect(McpService.connections.value, isEmpty);
    expect(await McpService.store.secretsFor('srv'), isNull);
  });

  test('the mirror carries the whole record, so a reinstall stays signed in',
      () async {
    final mirror = _FakeSync();
    McpService.resetForTest(
      store: McpStore(secrets: secrets, oauth: McpOAuth(httpClient: _authServer())),
      sync: mirror,
    );
    McpService.oauthFactory = () => McpOAuth(httpClient: _authServer());
    McpService.probeClientFactory = _challengingServer;
    McpService.launcher = _signIn;

    await McpService.connect(
      id: 'srv',
      name: 'Srv',
      url: 'https://srv.example/mcp',
    );
    // The push is fired and not awaited, so give it its turn.
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final mirrored = (mirror.blob!['secrets'] as Map)['srv'] as Map;
    final record = mirrored['record'] as Map;
    expect((record['tokens'] as Map)['refresh_token'], 'rt-live');
    expect(record['token_endpoint'], 'https://auth.example/token');
    // Still readable by a build that only knows the old field.
    expect(mirrored['token'], 'at-live');

    // Now the user deletes the app and installs it again: empty device, same
    // mirror. The connector and its refresh material have to come back.
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final fresh = _MemorySecrets();
    McpService.resetForTest(store: McpStore(secrets: fresh), sync: mirror);
    await McpService.pullRemoteForTest();

    expect(McpService.connections.value.single.id, 'srv');
    final back = (await McpService.store.secretsFor('srv'))!;
    expect(back.tokens.accessToken, 'at-live');
    expect(back.tokens.refreshToken, 'rt-live');
    expect(back.credentials.clientId, 'cid-live');
    final payload = (await McpService.store.forwardPayloads()).single;
    expect((payload['oauth'] as Map)['refresh_token'], 'rt-live');
  });

  test('a mirror written before P5 still restores the bearer', () async {
    final mirror = _FakeSync()
      ..blob = <String, dynamic>{
        'connections': <Map<String, dynamic>>[
          const McpConnection(
            id: 'old',
            name: 'Old',
            url: 'https://old.example/mcp',
          ).toJson(),
        ],
        'secrets': <String, dynamic>{
          'old': <String, dynamic>{'token': 'at-old'},
        },
      };
    McpService.resetForTest(store: McpStore(secrets: secrets), sync: mirror);

    await McpService.pullRemoteForTest();

    expect(McpService.connections.value.single.id, 'old');
    expect(await McpService.store.tokenFor('old'), 'at-old');
  });

  test('the mirror never overwrites a record this device already holds',
      () async {
    final mirror = _FakeSync()
      ..blob = <String, dynamic>{
        'connections': <Map<String, dynamic>>[
          const McpConnection(
            id: 'srv',
            name: 'Srv',
            url: 'https://srv.example/mcp',
          ).toJson(),
        ],
        'secrets': <String, dynamic>{
          'srv': <String, dynamic>{'token': 'at-stale'},
        },
      };
    McpService.resetForTest(
      store: McpStore(secrets: secrets, oauth: McpOAuth(httpClient: _authServer())),
      sync: mirror,
    );
    McpService.oauthFactory = () => McpOAuth(httpClient: _authServer());
    McpService.probeClientFactory = _challengingServer;
    McpService.launcher = _signIn;
    await McpService.connect(
      id: 'srv',
      name: 'Srv',
      url: 'https://srv.example/mcp',
    );

    await McpService.pullRemoteForTest();

    // The mirror is routinely the older copy — adopting it here would sign the
    // user straight back out of a connector they just signed in to.
    expect(await McpService.store.tokenFor('srv'), 'at-live');
  });

  test('the scope the challenge asks for reaches the authorization request',
      () async {
    // The connect path has no MCP client, so the only way it can learn a scope
    // the server names nowhere else is the unauthenticated probe. If that goes
    // away, the token is minted for the wrong grant and every tool call comes
    // back 403 — which looks like a broken connector, not a broken sign-in.
    McpService.probeClientFactory = () => _challengingServer(scope: 'drive.file');
    Uri? authorizationUrl;
    McpService.launcher = (Uri url) async {
      authorizationUrl = url;
      return _signIn(url);
    };

    await McpService.connect(
      id: 'srv',
      name: 'Srv',
      url: 'https://srv.example/mcp',
    );

    expect(authorizationUrl!.queryParameters['scope'], contains('drive.file'));
    expect((await McpService.store.secretsFor('srv'))!.scope,
        contains('drive.file'));
  });

  test('a server that does not challenge still signs in through the well-known '
      'paths', () async {
    // The probe is an improvement, not a dependency: a server that answers the
    // unauthenticated request with anything but a challenge must still connect.
    McpService.probeClientFactory =
        () => MockClient((_) async => http.Response('{}', 200));
    McpService.launcher = _signIn;

    final result = await McpService.connect(
      id: 'srv',
      name: 'Srv',
      url: 'https://srv.example/mcp',
    );

    expect(result.status, McpConnectStatus.connected);
    expect((await McpService.store.secretsFor('srv'))!.tokens.accessToken,
        'at-live');
  });

  test('a probe that cannot reach the server does not fail the sign-in',
      () async {
    McpService.probeClientFactory =
        () => MockClient((_) async => throw const SocketException('no route'));
    McpService.launcher = _signIn;

    final result = await McpService.connect(
      id: 'srv',
      name: 'Srv',
      url: 'https://srv.example/mcp',
    );

    expect(result.status, McpConnectStatus.connected);
  });

  test('a dead local record is replaced by a good one from the mirror',
      () async {
    // The device signed in before the refresh material was kept, and that
    // bearer has since died. Another device has a full record. Leaving the
    // dead one in place would make the user disconnect and sign in again for
    // no reason.
    final mirror = _FakeSync()
      ..blob = <String, dynamic>{
        'connections': <Map<String, dynamic>>[
          const McpConnection(
            id: 'srv',
            name: 'Srv',
            url: 'https://srv.example/mcp',
          ).toJson(),
        ],
        'secrets': <String, dynamic>{
          'srv': <String, dynamic>{
            'record': McpSecrets(
              credentials: const McpClientCredentials(clientId: 'cid-live'),
              tokens: McpTokens(
                accessToken: 'at-good',
                refreshToken: 'rt-good',
                expiresAt: DateTime.now().add(const Duration(hours: 1)),
              ),
              tokenEndpoint: 'https://auth.example/token',
            ).toJson(),
          },
        },
      };
    final store = McpStore(secrets: secrets);
    McpService.resetForTest(store: store, sync: mirror);
    await store.setSecrets(
      'srv',
      McpSecrets(
        tokens: McpTokens(
          accessToken: 'at-dead',
          expiresAt: DateTime.now().subtract(const Duration(hours: 2)),
        ),
      ),
    );

    await McpService.pullRemoteForTest();

    expect(await McpService.store.tokenFor('srv'), 'at-good');
    expect((await McpService.store.secretsFor('srv'))!.tokens.refreshToken,
        'rt-good');
  });

  // ─── mcp_credentials: the host handing a rotated token back ─────────────

  Map<String, dynamic> credentialsFrame({
    String? id = 'srv',
    String name = 'Srv',
    String url = 'https://srv.example/mcp',
    String? accessToken = 'at-rotated',
    String? refreshToken = 'rt-rotated',
    String clientId = 'cid-live',
    String? expiresAt,
  }) =>
      <String, dynamic>{
        'type': 'mcp_credentials',
        'session_key': 'amber-otter-2',
        'id': ?id,
        'name': name,
        'url': url,
        'access_token': ?accessToken,
        'oauth': <String, dynamic>{
          'refresh_token': ?refreshToken,
          'token_endpoint': 'https://auth.example/token',
          'client_id': clientId,
          'expires_at':
              expiresAt ?? DateTime.utc(2126, 9, 5, 10).toIso8601String(),
        },
        'rotated_at': '2026-09-05T09:00:00.000Z',
      };

  Future<void> signIn() async {
    McpService.launcher = _signIn;
    await McpService.connect(
      id: 'srv',
      name: 'Srv',
      url: 'https://srv.example/mcp',
    );
  }

  test('a rotated refresh token from the host replaces the dead one', () async {
    await signIn();
    expect((await McpService.store.secretsFor('srv'))!.tokens.refreshToken,
        'rt-live');

    expect(await McpService.applyRotatedCredentials(credentialsFrame()), 1);

    final record = (await McpService.store.secretsFor('srv'))!;
    expect(record.tokens.refreshToken, 'rt-rotated');
    expect(record.tokens.accessToken, 'at-rotated');
    // Identity is the device's, and the frame never touches it.
    expect(record.credentials.clientId, 'cid-live');
    expect(record.tokenEndpoint, 'https://auth.example/token');
    expect(record.issuer, 'https://auth.example');
  });

  test('the rotated token reaches the encrypted mirror too', () async {
    final mirror = _FakeSync();
    McpService.resetForTest(
      store: McpStore(secrets: secrets, oauth: McpOAuth(httpClient: _authServer())),
      sync: mirror,
    );
    McpService.oauthFactory = () => McpOAuth(httpClient: _authServer());
    McpService.probeClientFactory = _challengingServer;
    await signIn();

    await McpService.applyRotatedCredentials(credentialsFrame());
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final record =
        ((mirror.blob!['secrets'] as Map)['srv'] as Map)['record'] as Map;
    // A reinstall must not come back holding the token the provider killed.
    expect((record['tokens'] as Map)['refresh_token'], 'rt-rotated');
  });

  test('the same frame twice writes once', () async {
    // The host re-sends on every task end and every reconnect until the app
    // forwards the new token back, because a frame to a detached controller is
    // dropped. Re-applying must not churn the keychain and the mirror.
    await signIn();
    final frame = credentialsFrame();

    expect(await McpService.applyRotatedCredentials(frame), 1);
    expect(await McpService.applyRotatedCredentials(frame), 0);
  });

  test('a frame for a connector this device does not have is ignored',
      () async {
    await signIn();

    final applied = await McpService.applyRotatedCredentials(
      credentialsFrame(id: 'somebody-else', url: 'https://other.example/mcp'),
    );

    expect(applied, 0);
    expect(McpService.connections.value.single.id, 'srv');
    expect((await McpService.store.secretsFor('srv'))!.tokens.refreshToken,
        'rt-live');
  });

  test('a frame with no refresh token is ignored', () async {
    await signIn();

    expect(
      await McpService.applyRotatedCredentials(
        credentialsFrame(refreshToken: null),
      ),
      0,
    );
    expect((await McpService.store.secretsFor('srv'))!.tokens.accessToken,
        'at-live');
  });

  test('a rotation against a replaced registration is ignored', () async {
    // The user signed in again in the meantime, so dynamic registration issued
    // a new client. This frame belongs to a registration that no longer exists;
    // applying it would break the fresh sign-in.
    await signIn();

    final applied = await McpService.applyRotatedCredentials(
      credentialsFrame(clientId: 'cid-from-an-older-signin'),
    );

    expect(applied, 0);
    expect((await McpService.store.secretsFor('srv'))!.tokens.refreshToken,
        'rt-live');
  });

  test('a frame with no id is matched on url and name', () async {
    await signIn();

    expect(
      await McpService.applyRotatedCredentials(credentialsFrame(id: null)),
      1,
    );
    expect((await McpService.store.secretsFor('srv'))!.tokens.refreshToken,
        'rt-rotated');
  });

  test('entries batched under a servers array are read the same way', () async {
    // The wire form is one frame per connector. Reading a batched array too
    // costs three lines and means a later change on the host side needs none
    // here.
    await signIn();
    final batched = <String, dynamic>{
      'type': 'mcp_credentials',
      'servers': <Map<String, dynamic>>[credentialsFrame()],
    };

    expect(await McpService.applyRotatedCredentials(batched), 1);
    expect((await McpService.store.secretsFor('srv'))!.tokens.refreshToken,
        'rt-rotated');
  });

  test('the rotated token is what the next task forwards', () async {
    // The whole point: the forward is also the acknowledgement that stops the
    // host re-sending.
    await signIn();
    await McpService.applyRotatedCredentials(credentialsFrame());

    final payload = (await McpService.store.forwardPayloads()).single;

    expect(payload['access_token'], 'at-rotated');
    expect((payload['oauth'] as Map)['refresh_token'], 'rt-rotated');
  });
}
