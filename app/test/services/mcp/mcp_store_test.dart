import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cowork/services/cowork/cowork_pairing_store.dart'
    show CoworkSecureKeyValueStore;
import 'package:cowork/services/mcp/mcp_connection.dart';
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

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('config lands in prefs and the token in secure storage', () async {
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
    expect(secrets.map[McpStore.secretKey('gh')], 'tok-123');

    final loaded = await store.load();
    expect(loaded.single.name, 'GitHub');
    expect(await store.tokenFor('gh'), 'tok-123');
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

    final account = payloads.firstWhere((p) => p['name'] == 'AccountServer');
    expect(account['auth'], 'appSession');
    // Account auth forwards no device token.
    expect(account.containsKey('access_token'), isFalse);
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
}
