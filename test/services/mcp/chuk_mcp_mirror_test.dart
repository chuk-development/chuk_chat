import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cowork/services/cowork/cowork_pairing_store.dart';
import 'package:cowork/services/mcp/chuk_mcp_mirror.dart';
import 'package:cowork/services/mcp/mcp_connection.dart';
import 'package:cowork/services/mcp/mcp_connector_sync.dart';
import 'package:cowork/services/mcp/mcp_oauth.dart';
import 'package:cowork/services/mcp/mcp_service.dart';
import 'package:cowork/services/mcp/mcp_store.dart';

/// Keychain stand-in.
class _MemorySecrets implements CoworkSecureKeyValueStore {
  final Map<String, String> map = <String, String>{};

  @override
  Future<String?> read(String key) async => map[key];

  @override
  Future<void> write(String key, String value) async => map[key] = value;

  @override
  Future<void> delete(String key) async => map.remove(key);
}

/// CoWork's own mirror, in memory.
class _OwnMirror implements McpConnectorSync {
  Map<String, dynamic>? blob;

  @override
  Future<void> save(Map<String, dynamic> payload) async => blob = payload;

  @override
  Future<Map<String, dynamic>?> load() async => blob;

  @override
  Future<void> clear() async => blob = null;
}

/// chuk_chat's `service_credentials` rows, in memory, by catalogue id.
class _ChukTable implements ChukMcpMirror {
  _ChukTable({this.rows});

  /// Null = table unreadable (no user, no key, no table).
  Map<String, ChukMcpRow>? rows;
  final List<String> saved = <String>[];
  final List<String> deleted = <String>[];
  Object? saveError;

  @override
  Future<Map<String, ChukMcpRow>?> load() async =>
      rows == null ? null : Map<String, ChukMcpRow>.of(rows!);

  @override
  Future<void> save(ChukMcpRow row) async {
    if (saveError != null) throw saveError!;
    saved.add(row.id);
    rows?[row.id] = row;
  }

  @override
  Future<void> delete(String id) async {
    deleted.add(id);
    rows?.remove(id);
  }
}

Map<String, dynamic> _connectionJson(
  String id, {
  String auth = 'oauth',
  String? url,
}) =>
    <String, dynamic>{
      'id': id,
      'name': id[0].toUpperCase() + id.substring(1),
      'url': url ?? 'https://$id.example/mcp',
      'description': 'chuk wrote this',
      'icon_url': null,
      'added_by_hand': false,
      'auth': auth,
      // chuk keeps a cached tool list; the receiver must drop it.
      'tools': [
        {'name': 'search', 'description': 'stale'},
      ],
    };

/// chuk's `_McpSecrets.toJson` as it lands in the blob.
Map<String, dynamic> _secretsJson({
  String access = 'at-chuk',
  String? refresh = 'rt-chuk',
  Duration ttl = const Duration(hours: 1),
  Map<String, String>? apiCredentials,
}) =>
    <String, dynamic>{
      'credentials': {'client_id': 'cid-chuk'},
      'tokens': {
        'access_token': access,
        'refresh_token': ?refresh,
        'expires_at': DateTime.now().add(ttl).toIso8601String(),
      },
      'issuer': 'https://auth.example',
      'authorization_endpoint': 'https://auth.example/authorize',
      'token_endpoint': 'https://auth.example/token',
      'scope': 'read',
      'api_credentials': ?apiCredentials,
    };

ChukMcpRow _row(String id, {Map<String, dynamic>? secrets, String auth = 'oauth'}) =>
    ChukMcpRow(id: id, connection: _connectionJson(id, auth: auth), secrets: secrets);

void main() {
  late _MemorySecrets secrets;
  late _OwnMirror own;
  late _ChukTable chuk;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    secrets = _MemorySecrets();
    own = _OwnMirror();
    chuk = _ChukTable(rows: <String, ChukMcpRow>{});
    McpService.resetForTest(
      store: McpStore(secrets: secrets),
      sync: own,
      chukMirror: chuk,
    );
  });

  tearDown(McpService.resetForTest);

  group('ChukMcpRow.fromBlob', () {
    test('reads chuk\'s blob shape and keeps the secrets', () {
      final row = ChukMcpRow.fromBlob('notion', {
        'connection': _connectionJson('notion'),
        'secrets': _secretsJson(),
      })!;
      expect(row.id, 'notion');
      expect(row.connection['url'], 'https://notion.example/mcp');
      expect((row.secrets!['tokens'] as Map)['access_token'], 'at-chuk');
      // Round-trips into the same shape for the write-back.
      expect(row.toBlob().keys, ['connection', 'secrets']);
    });

    test('a row whose connection names another id, or is not a blob, is skipped', () {
      expect(ChukMcpRow.fromBlob('notion', {'connection': _connectionJson('slack')}), isNull);
      expect(ChukMcpRow.fromBlob('notion', {'secrets': {}}), isNull);
      expect(ChukMcpRow.fromBlob('notion', 'garbage'), isNull);
      expect(ChukMcpRow.fromBlob('notion', {'connection': _connectionJson('notion')})!.secrets, isNull);
    });
  });

  test('a connector signed in inside chuk_chat shows up connected, tokens and all', () async {
    chuk.rows!['notion'] = _row('notion', secrets: _secretsJson());

    await McpService.pullRemoteForTest();

    final connection = McpService.connections.value.single;
    expect(connection.id, 'notion');
    expect(connection.url, 'https://notion.example/mcp');
    expect(connection.tools, isEmpty, reason: 'chuk\'s cached tool list is dropped');
    expect(McpService.connectionFor('notion'), isNotNull);
    final record = (await McpService.store.secretsFor('notion'))!;
    expect(record.tokens.accessToken, 'at-chuk');
    expect(record.tokens.refreshToken, 'rt-chuk');
    expect(record.credentials.clientId, 'cid-chuk');
    expect(record.tokenEndpoint, 'https://auth.example/token');
    // The next task forwards the whole record to the host.
    final payload = (await McpService.store.forwardPayloads()).single;
    expect(payload['id'], 'notion');
    expect((payload['oauth'] as Map)['refresh_token'], 'rt-chuk');
  });

  test('a live local record is never overwritten by chuk\'s (47\'s rule)', () async {
    await McpService.store.upsert(McpConnection.fromJson(_connectionJson('notion')));
    await McpService.store.setSecrets(
      'notion',
      McpSecrets(
        credentials: const McpClientCredentials(clientId: 'cid-local'),
        tokens: McpTokens(
          accessToken: 'at-local',
          refreshToken: 'rt-local',
          expiresAt: DateTime.now().add(const Duration(hours: 1)),
        ),
      ),
    );
    chuk.rows!['notion'] = _row('notion', secrets: _secretsJson());

    await McpService.pullRemoteForTest();

    final record = (await McpService.store.secretsFor('notion'))!;
    expect(record.tokens.accessToken, 'at-local');
    expect(record.credentials.clientId, 'cid-local');
    expect(McpService.connections.value.single.description, 'chuk wrote this');
  });

  test('an unusable local record (expired, no refresh) is replaced by chuk\'s usable one', () async {
    await McpService.store.upsert(McpConnection.fromJson(_connectionJson('notion')));
    await McpService.store.setSecrets(
      'notion',
      McpSecrets(
        tokens: McpTokens(
          accessToken: 'at-dead',
          expiresAt: DateTime.now().subtract(const Duration(hours: 1)),
        ),
      ),
    );
    chuk.rows!['notion'] = _row('notion', secrets: _secretsJson());

    await McpService.pullRemoteForTest();

    expect((await McpService.store.secretsFor('notion'))!.tokens.accessToken, 'at-chuk');
  });

  test('chuk\'s unusable secrets are not adopted; the connection still appears', () async {
    chuk.rows!['notion'] = _row(
      'notion',
      secrets: _secretsJson(access: 'at-dead', refresh: null, ttl: const Duration(hours: -1)),
    );

    await McpService.pullRemoteForTest();

    expect(McpService.connections.value.single.id, 'notion');
    expect(await McpService.store.secretsFor('notion'), isNull);
  });

  test('an app-session connector (no secrets in chuk) is connected without a record', () async {
    chuk.rows!['github'] = _row('github', auth: 'appSession');

    await McpService.pullRemoteForTest();

    final connection = McpService.connections.value.single;
    expect(connection.id, 'github');
    expect(connection.auth, McpAuth.appSession);
    expect(await McpService.store.secretsFor('github'), isNull);
  });

  test('an API-key connector brings its query credentials along', () async {
    chuk.rows!['brave'] = _row(
      'brave',
      auth: 'apiKey',
      secrets: _secretsJson(access: '', refresh: null, apiCredentials: {'key': 'k-chuk'}),
    );

    await McpService.pullRemoteForTest();

    expect(McpService.connections.value.single.auth, McpAuth.apiKey);
    expect(await McpService.store.apiCredentialsFor('brave'), {'key': 'k-chuk'});
    final payload = (await McpService.store.forwardPayloads()).single;
    expect(payload['url'], contains('key=k-chuk'));
  });

  test('CoWork\'s own mirror wins; chuk only fills the gaps', () async {
    own.blob = <String, dynamic>{
      'connections': [_connectionJson('notion', url: 'https://own.example/mcp')],
      'secrets': {
        'notion': {'record': _secretsJson(access: 'at-own', refresh: 'rt-own')},
      },
    };
    chuk.rows!['notion'] = _row('notion', secrets: _secretsJson());
    chuk.rows!['slack'] = _row('slack', secrets: _secretsJson());

    await McpService.pullRemoteForTest();

    final ids = McpService.connections.value.map((c) => c.id).toList();
    expect(ids, ['notion', 'slack']);
    expect(McpService.connectionFor('notion')!.url, 'https://own.example/mcp');
    expect((await McpService.store.secretsFor('notion'))!.tokens.accessToken, 'at-own');
    expect((await McpService.store.secretsFor('slack'))!.tokens.accessToken, 'at-chuk');
  });

  test('an unreadable chuk table (no login, no table) changes nothing', () async {
    chuk.rows = null;
    await McpService.pullRemoteForTest();
    expect(McpService.connections.value, isEmpty);
  });

  test('a row without a url is skipped', () async {
    chuk.rows!['odd'] = ChukMcpRow(
      id: 'odd',
      connection: _connectionJson('odd', url: ''),
      secrets: _secretsJson(),
    );
    await McpService.pullRemoteForTest();
    expect(McpService.connections.value, isEmpty);
  });

  group('write-back into chuk\'s table', () {
    Future<void> seedLocal() async {
      await McpService.store.upsert(McpConnection.fromJson(_connectionJson('notion')));
      await McpService.store.setSecrets(
        'notion',
        McpSecrets(
          credentials: const McpClientCredentials(clientId: 'cid-own'),
          tokens: McpTokens(
            accessToken: 'at-own',
            refreshToken: 'rt-own',
            expiresAt: DateTime.now().add(const Duration(hours: 1)),
          ),
          tokenEndpoint: 'https://auth.example/token',
        ),
      );
      await McpService.store.upsert(
        McpConnection.fromJson(_connectionJson('brave', auth: 'apiKey')),
      );
      await McpService.store.setApiCredentials('brave', {'key': 'k-own'});
      await McpService.store.upsert(
        McpConnection.fromJson(_connectionJson('github', auth: 'appSession')),
      );
    }

    test('a push writes one mcp_<id> row per connector in chuk\'s blob shape', () async {
      await seedLocal();

      await McpService.pushRemoteForTest();

      expect(chuk.saved.toSet(), {'notion', 'brave', 'github'});
      final notion = chuk.rows!['notion']!;
      expect(notion.connection['id'], 'notion');
      expect(notion.connection['tools'], isEmpty, reason: 'tools are listed live');
      expect((notion.secrets!['tokens'] as Map)['refresh_token'], 'rt-own');
      expect((notion.secrets!['credentials'] as Map)['client_id'], 'cid-own');
      expect(notion.secrets!['token_endpoint'], 'https://auth.example/token');
      // The blob is exactly {connection, secrets}: what chuk's McpSyncBlob reads.
      expect(notion.toBlob().keys.toList(), ['connection', 'secrets']);
      final brave = chuk.rows!['brave']!;
      expect(brave.secrets!['api_credentials'], {'key': 'k-own'});
      expect(chuk.rows!['github']!.secrets, isNull);
      // The own mirror was written too.
      expect((own.blob!['connections'] as List).length, 3);
    });

    test('a failing chuk write never costs the own mirror', () async {
      await seedLocal();
      chuk.saveError = StateError('no table');

      await McpService.pushRemoteForTest();

      expect(chuk.saved, isEmpty);
      expect(own.blob, isNotNull);
    });

    test('disconnect deletes chuk\'s row only after reading it back as the same id', () async {
      await seedLocal();
      chuk.rows!['notion'] = _row('notion', secrets: _secretsJson());

      await McpService.disconnect('notion');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(chuk.deleted, ['notion']);
      expect(chuk.rows!.containsKey('notion'), isFalse);
      expect(McpService.connections.value.map((c) => c.id), isNot(contains('notion')));
    });

    test('a row whose blob names another connector is never deleted', () async {
      await seedLocal();
      chuk.rows!['notion'] = ChukMcpRow(
        id: 'notion',
        connection: _connectionJson('slack'),
        secrets: null,
      );

      await McpService.disconnect('notion');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(chuk.deleted, isEmpty);
      expect(chuk.rows!.containsKey('notion'), isTrue);
    });

    test('a missing row is not deleted (and nothing else is)', () async {
      await McpService.store.upsert(
        McpConnection.fromJson(_connectionJson('github', auth: 'appSession')),
      );
      chuk.rows!['slack'] = _row('slack');

      await McpService.disconnect('github');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(chuk.deleted, isEmpty);
      expect(chuk.rows!.keys, ['slack']);
    });

    test('an unreadable chuk table makes disconnect leave it alone', () async {
      await seedLocal();
      chuk.rows = null;
      await McpService.disconnect('notion');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(chuk.deleted, isEmpty);
    });
  });
}
