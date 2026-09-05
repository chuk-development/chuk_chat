import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cowork/services/cowork/cowork_pairing_store.dart'
    show CoworkSecureKeyValueStore;
import 'package:cowork/services/mcp/mcp_connection.dart';
import 'package:cowork/services/mcp/mcp_oauth.dart';
import 'package:cowork/services/mcp/mcp_store.dart';

/// In-memory secure backend so secrets round-trip with no platform channel.
class _MemorySecrets implements CoworkSecureKeyValueStore {
  final Map<String, String> map = <String, String>{};

  @override
  Future<String?> read(String key) async => map[key];

  @override
  Future<void> write(String key, String value) async => map[key] = value;

  @override
  Future<void> delete(String key) async => map.remove(key);
}

/// A full record, as `_authorize` writes one after a real sign-in.
McpSecrets _record({
  String accessToken = 'at-1',
  String? refreshToken = 'rt-1',
  DateTime? expiresAt,
  String tokenEndpoint = 'https://auth.example/token',
}) =>
    McpSecrets(
      credentials: const McpClientCredentials(clientId: 'cid-1'),
      tokens: McpTokens(
        accessToken: accessToken,
        refreshToken: refreshToken,
        expiresAt: expiresAt,
      ),
      issuer: 'https://auth.example',
      authorizationEndpoint: 'https://auth.example/authorize',
      tokenEndpoint: tokenEndpoint,
      scope: 'read write',
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('config lands in prefs and the secret in secure storage', () async {
    final secrets = _MemorySecrets();
    final store = McpStore(secrets: secrets);

    await store.upsert(
      const McpConnection(
        id: 'gh',
        name: 'GitHub',
        url: 'https://api.github.com/mcp',
      ),
      accessToken: 'tok-123',
    );

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(McpStore.prefsKey);
    expect(raw, contains('GitHub'));
    // The token never touches SharedPreferences.
    expect(raw, isNot(contains('tok-123')));

    // The secret is now a record, not a bare string.
    final stored = jsonDecode(secrets.map[McpStore.secretKey('gh')]!) as Map;
    expect((stored['tokens'] as Map)['access_token'], 'tok-123');

    final loaded = await store.load();
    expect(loaded.single.name, 'GitHub');
    expect(await store.tokenFor('gh'), 'tok-123');
  });

  test('a full record round-trips in chuk_chat’s shape', () async {
    final secrets = _MemorySecrets();
    final store = McpStore(secrets: secrets);

    await store.setSecrets(
      'n',
      _record(expiresAt: DateTime.utc(2126, 9, 5, 10)),
    );

    final json = jsonDecode(secrets.map[McpStore.secretKey('n')]!) as Map;
    expect(json.keys, containsAll(<String>[
      'credentials',
      'tokens',
      'issuer',
      'authorization_endpoint',
      'token_endpoint',
      'scope',
    ]));
    expect((json['credentials'] as Map)['client_id'], 'cid-1');
    expect((json['tokens'] as Map)['refresh_token'], 'rt-1');

    final back = (await store.secretsFor('n'))!;
    expect(back.credentials.clientId, 'cid-1');
    expect(back.tokens.refreshToken, 'rt-1');
    expect(back.tokenEndpoint, 'https://auth.example/token');
    expect(back.scope, 'read write');
    expect(back.authServer, isNotNull);
  });

  test('a legacy bare-token secret still reads, and upgrades on write',
      () async {
    final secrets = _MemorySecrets()
      ..map[McpStore.secretKey('old')] = 'legacy-bearer';
    final store = McpStore(secrets: secrets);

    expect(await store.tokenFor('old'), 'legacy-bearer');
    final record = (await store.secretsFor('old'))!;
    expect(record.tokens.accessToken, 'legacy-bearer');
    expect(record.tokens.refreshToken, isNull);

    await store.setToken('old', 'fresh-bearer');
    final upgraded = jsonDecode(secrets.map[McpStore.secretKey('old')]!) as Map;
    expect((upgraded['tokens'] as Map)['access_token'], 'fresh-bearer');
  });

  test('setToken keeps the refresh material already recorded', () async {
    final secrets = _MemorySecrets();
    final store = McpStore(secrets: secrets);
    await store.setSecrets('n', _record());

    await store.setToken('n', 'at-2');

    final back = (await store.secretsFor('n'))!;
    expect(back.tokens.accessToken, 'at-2');
    expect(back.tokens.refreshToken, 'rt-1');
    expect(back.credentials.clientId, 'cid-1');
  });

  test('remove drops both the config and the secret', () async {
    final secrets = _MemorySecrets();
    final store = McpStore(secrets: secrets);
    await store.upsert(
      const McpConnection(id: 'a', name: 'A', url: 'https://a/mcp'),
      accessToken: 'secret-a',
    );

    await store.remove('a');

    expect(await store.load(), isEmpty);
    expect(secrets.map.containsKey(McpStore.secretKey('a')), isFalse);
  });

  test('forwardPayloads resolves the oauth token and omits it for account auth',
      () async {
    final secrets = _MemorySecrets();
    final store = McpStore(secrets: secrets);
    await store.upsert(
      const McpConnection(
        id: 'oauth1',
        name: 'OAuthServer',
        url: 'https://o/mcp',
        auth: McpAuth.oauth,
      ),
      accessToken: 'bearer-xyz',
    );
    await store.upsert(
      const McpConnection(
        id: 'acct1',
        name: 'AccountServer',
        url: 'https://acct/mcp',
        auth: McpAuth.appSession,
      ),
    );

    final payloads = await store.forwardPayloads();
    expect(payloads.length, 2);

    final oauth = payloads.firstWhere((p) => p['name'] == 'OAuthServer');
    expect(oauth['url'], 'https://o/mcp');
    expect(oauth['auth'], 'oauth');
    expect(oauth['access_token'], 'bearer-xyz');
    // No refresh material recorded, so nothing for the host to renew with.
    expect(oauth.containsKey('oauth'), isFalse);

    final account = payloads.firstWhere((p) => p['name'] == 'AccountServer');
    expect(account['auth'], 'appSession');
    // Account auth forwards no device token.
    expect(account.containsKey('access_token'), isFalse);
  });

  test('forwardPayloads carries the oauth block when a record has a refresh '
      'token', () async {
    final secrets = _MemorySecrets();
    final store = McpStore(secrets: secrets);
    await store.upsert(
      const McpConnection(
        id: 'n',
        name: 'Notion',
        url: 'https://mcp.notion.example/mcp',
        auth: McpAuth.oauth,
      ),
    );
    await store.setSecrets('n', _record(expiresAt: DateTime.utc(2126, 9, 5, 10)));

    final payload = (await store.forwardPayloads()).single;
    expect(payload['access_token'], 'at-1');
    final block = payload['oauth'] as Map<String, dynamic>;
    expect(block['token_endpoint'], 'https://auth.example/token');
    expect(block['client_id'], 'cid-1');
    expect(block['refresh_token'], 'rt-1');
    expect(block['resource'], 'https://mcp.notion.example/mcp');
    expect(block['scope'], 'read write');
    expect(block['issuer'], 'https://auth.example');
    expect(block['expires_at'], '2126-09-05T10:00:00.000Z');
    // A client secret is only sent when the server issued one.
    expect(block.containsKey('client_secret'), isFalse);
  });

  test('forwardPayloads refreshes an expired token before it forwards it',
      () async {
    final secrets = _MemorySecrets();
    var tokenCalls = 0;
    final client = MockClient((http.Request request) async {
      tokenCalls++;
      expect(request.url.toString(), 'https://auth.example/token');
      expect(request.bodyFields['grant_type'], 'refresh_token');
      expect(request.bodyFields['refresh_token'], 'rt-1');
      return http.Response(
        jsonEncode(<String, dynamic>{
          'access_token': 'at-fresh',
          'expires_in': 3600,
        }),
        200,
        headers: const {'content-type': 'application/json'},
      );
    });
    final store = McpStore(
      secrets: secrets,
      oauth: McpOAuth(httpClient: client),
    );

    await store.upsert(
      const McpConnection(
        id: 'n',
        name: 'Notion',
        url: 'https://mcp.notion.example/mcp',
        auth: McpAuth.oauth,
      ),
    );
    await store.setSecrets(
      'n',
      _record(expiresAt: DateTime.now().subtract(const Duration(hours: 1))),
    );

    final payload = (await store.forwardPayloads()).single;

    expect(tokenCalls, 1);
    expect(payload['access_token'], 'at-fresh');
    // The rotated token is written back, so the next launch does not re-refresh.
    expect((await store.secretsFor('n'))!.tokens.accessToken, 'at-fresh');
    // The server kept the old refresh token, so it must survive the write-back.
    expect((payload['oauth'] as Map)['refresh_token'], 'rt-1');
  });

  test('a refusal to refresh still forwards the stale token and the block',
      () async {
    final secrets = _MemorySecrets();
    final client = MockClient(
      (http.Request request) async => http.Response('nope', 400),
    );
    final store = McpStore(
      secrets: secrets,
      oauth: McpOAuth(httpClient: client),
    );

    await store.upsert(
      const McpConnection(
        id: 'n',
        name: 'Notion',
        url: 'https://mcp.notion.example/mcp',
        auth: McpAuth.oauth,
      ),
    );
    await store.setSecrets(
      'n',
      _record(expiresAt: DateTime.now().subtract(const Duration(hours: 1))),
    );

    final payload = (await store.forwardPayloads()).single;

    // The host has its own go at it — the device does not silently drop the
    // connector just because one refresh failed.
    expect(payload['access_token'], 'at-1');
    expect((payload['oauth'] as Map)['refresh_token'], 'rt-1');
  });

  test('upsert with a null token leaves an existing secret intact', () async {
    final secrets = _MemorySecrets();
    final store = McpStore(secrets: secrets);
    await store.upsert(
      const McpConnection(id: 'k', name: 'K', url: 'https://k/mcp'),
      accessToken: 'keep-me',
    );

    // Rename without touching the token.
    await store.upsert(
      const McpConnection(id: 'k', name: 'K2', url: 'https://k/mcp'),
    );

    expect((await store.load()).single.name, 'K2');
    expect(await store.tokenFor('k'), 'keep-me');
  });

  test('the forward payload matches the frozen cross-language fixture',
      () async {
    final fixture = jsonDecode(
      File('test/fixtures/mcp_forward_payload.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final expected = (fixture['mcp_servers'] as List)
        .cast<Map<String, dynamic>>();

    final secrets = _MemorySecrets();
    final store = McpStore(secrets: secrets);

    await store.upsert(
      const McpConnection(
        id: 'notion',
        name: 'Notion',
        url: 'https://mcp.notion.example/mcp',
        auth: McpAuth.oauth,
      ),
    );
    await store.setSecrets(
      'notion',
      McpSecrets(
        credentials: const McpClientCredentials(clientId: 'cid-notion'),
        tokens: McpTokens(
          accessToken: 'at-notion',
          refreshToken: 'rt-notion',
          expiresAt: DateTime.utc(2126, 9, 5, 10),
        ),
        issuer: 'https://auth.notion.example',
        authorizationEndpoint: 'https://auth.notion.example/authorize',
        tokenEndpoint: 'https://auth.notion.example/token',
        scope: 'read write',
      ),
    );

    // A connector signed in by an older build: bearer only, nothing to renew.
    await store.upsert(
      const McpConnection(
        id: 'legacy',
        name: 'Legacy',
        url: 'https://legacy.example/mcp',
        auth: McpAuth.oauth,
      ),
      accessToken: 'at-legacy',
    );

    await store.upsert(
      const McpConnection(
        id: 'brave',
        name: 'Brave',
        url: 'https://brave.example/mcp',
        auth: McpAuth.apiKey,
      ),
    );
    await store.setApiCredentials('brave', <String, String>{'key': 'k-123'});

    await store.upsert(
      const McpConnection(
        id: 'github',
        name: 'GitHub',
        url: 'https://api.example/v1/mcp/github',
        auth: McpAuth.appSession,
      ),
    );

    expect(await store.forwardPayloads(), expected);
  });

  test('a rotated refresh token is persisted, not dropped', () async {
    // Google, Okta and Auth0 with rotation on hand back a NEW refresh token and
    // kill the old one. Keeping the old one would work exactly once and then
    // leave the connector dead with no way back but a fresh sign-in.
    final secrets = _MemorySecrets();
    final client = MockClient((http.Request request) async {
      expect(request.bodyFields['refresh_token'], 'rt-1');
      return http.Response(
        jsonEncode(<String, dynamic>{
          'access_token': 'at-fresh',
          'refresh_token': 'rt-2',
          'expires_in': 3600,
        }),
        200,
        headers: const {'content-type': 'application/json'},
      );
    });
    final store = McpStore(secrets: secrets, oauth: McpOAuth(httpClient: client));
    await store.upsert(
      const McpConnection(
        id: 'n',
        name: 'Notion',
        url: 'https://mcp.notion.example/mcp',
        auth: McpAuth.oauth,
      ),
    );
    await store.setSecrets(
      'n',
      _record(expiresAt: DateTime.now().subtract(const Duration(hours: 1))),
    );

    final payload = (await store.forwardPayloads()).single;

    expect((payload['oauth'] as Map)['refresh_token'], 'rt-2');
    expect((await store.secretsFor('n'))!.tokens.refreshToken, 'rt-2');
  });

  test('two launches at once spend the refresh token only once', () async {
    // Both callers read the same lapsed record. On a rotating server the second
    // request would be answered with invalid_grant, and whichever write landed
    // last would decide what is stored — including, in the bad ordering, the
    // now-dead old token.
    final secrets = _MemorySecrets();
    var tokenCalls = 0;
    final client = MockClient((http.Request request) async {
      tokenCalls++;
      if (tokenCalls > 1) return http.Response('invalid_grant', 400);
      // Let the second caller reach the store while this one is in flight.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return http.Response(
        jsonEncode(<String, dynamic>{
          'access_token': 'at-fresh',
          'refresh_token': 'rt-2',
          'expires_in': 3600,
        }),
        200,
        headers: const {'content-type': 'application/json'},
      );
    });
    final store = McpStore(secrets: secrets, oauth: McpOAuth(httpClient: client));
    await store.upsert(
      const McpConnection(
        id: 'n',
        name: 'Notion',
        url: 'https://mcp.notion.example/mcp',
        auth: McpAuth.oauth,
      ),
    );
    await store.setSecrets(
      'n',
      _record(expiresAt: DateTime.now().subtract(const Duration(hours: 1))),
    );

    final both = await Future.wait(<Future<List<Map<String, dynamic>>>>[
      store.forwardPayloads(),
      store.forwardPayloads(),
    ]);

    expect(tokenCalls, 1);
    for (final payloads in both) {
      expect(payloads.single['access_token'], 'at-fresh');
    }
    expect((await store.secretsFor('n'))!.tokens.refreshToken, 'rt-2');
  });

  test('clearing the bearer keeps the refresh material', () async {
    // "Make the next call re-authenticate" must not mean "forget this server":
    // the host can still mint a bearer from the refresh token.
    final secrets = _MemorySecrets();
    final store = McpStore(secrets: secrets);
    await store.setSecrets('n', _record());

    await store.setToken('n', '');

    expect(await store.tokenFor('n'), isNull);
    final back = (await store.secretsFor('n'))!;
    expect(back.tokens.refreshToken, 'rt-1');
    expect(back.credentials.clientId, 'cid-1');
    expect(back.tokenEndpoint, 'https://auth.example/token');
  });

  test('the stored expiry is UTC, whatever zone the device is in', () async {
    // The record is mirrored to other devices. A local timestamp carries no
    // zone, so a device elsewhere would read the expiry hours out and either
    // refresh a live token or trust a dead one.
    final secrets = _MemorySecrets();
    final store = McpStore(secrets: secrets);
    final local = DateTime.now().add(const Duration(hours: 1));

    await store.setSecrets('n', _record(expiresAt: local));

    final stored = jsonDecode(secrets.map[McpStore.secretKey('n')]!) as Map;
    final written = (stored['tokens'] as Map)['expires_at'] as String;
    expect(written, endsWith('Z'));
    expect(DateTime.parse(written).toUtc(), local.toUtc());
  });
}
