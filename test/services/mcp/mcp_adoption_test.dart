// Bead cowork-7zd: the connectors the user signed into in chuk_chat have to
// reach the Python backend, not just the connectors page.
//
// The pull used to happen exactly once, from `McpService.load()`, the first
// time the connectors page was built. These tests pin the three things that
// were wrong with that: nobody drives it when the page is never opened, an
// attempt made before the user is signed in and keyed latched forever, and the
// task launch could assemble its `mcp_servers` list before anything had been
// adopted at all.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cowork/services/cowork/cowork_pairing_store.dart';
import 'package:cowork/services/mcp/chuk_mcp_mirror.dart';
import 'package:cowork/services/mcp/mcp_connector_sync.dart';
import 'package:cowork/services/mcp/mcp_service.dart';
import 'package:cowork/services/mcp/mcp_store.dart';
import 'package:cowork/services/mcp/mcp_sync_service.dart';

import '../../support/kv_cache_test_env.dart';

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

/// CoWork's own mirror, in memory. Always readable, always empty here — these
/// tests are about chuk's rows.
class _OwnMirror implements McpConnectorSync {
  @override
  Future<void> save(Map<String, dynamic> payload) async {}

  @override
  Future<Map<String, dynamic>?> load() async => null;

  @override
  Future<void> clear() async {}
}

/// chuk_chat's `service_credentials` rows, in memory, counting every read.
class _ChukTable implements ChukMcpMirror {
  _ChukTable({this.rows});

  /// Null = the table could not be read at all (no Supabase, no signed-in
  /// user, no encryption key) — NOT "chuk has no connectors".
  Map<String, ChukMcpRow>? rows;
  int loads = 0;

  @override
  Future<Map<String, ChukMcpRow>?> load() async {
    loads++;
    return rows == null ? null : Map<String, ChukMcpRow>.of(rows!);
  }

  @override
  Future<void> save(ChukMcpRow row) async => rows?[row.id] = row;

  @override
  Future<void> delete(String id) async => rows?.remove(id);
}

Map<String, dynamic> _connectionJson(String id) => <String, dynamic>{
      'id': id,
      'name': id[0].toUpperCase() + id.substring(1),
      'url': 'https://$id.example/mcp',
      'description': 'chuk wrote this',
      'icon_url': null,
      'added_by_hand': false,
      'auth': 'oauth',
      'tools': [
        {'name': 'search', 'description': 'stale'},
      ],
    };

Map<String, dynamic> _secretsJson() => <String, dynamic>{
      'credentials': {'client_id': 'cid-chuk'},
      'tokens': {
        'access_token': 'at-chuk',
        'refresh_token': 'rt-chuk',
        'expires_at':
            DateTime.now().add(const Duration(hours: 1)).toIso8601String(),
      },
      'issuer': 'https://auth.example',
      'authorization_endpoint': 'https://auth.example/authorize',
      'token_endpoint': 'https://auth.example/token',
      'scope': 'read',
    };

ChukMcpRow _row(String id) => ChukMcpRow(
      id: id,
      connection: _connectionJson(id),
      secrets: _secretsJson(),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MemorySecrets secrets;
  late _ChukTable chuk;
  late Directory kvDir;
  late DateTime now;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    kvDir = await useTempKvCache();
    secrets = _MemorySecrets();
    chuk = _ChukTable(rows: <String, ChukMcpRow>{});
    McpService.resetForTest(
      store: McpStore(secrets: secrets),
      sync: _OwnMirror(),
      chukMirror: chuk,
    );
    now = DateTime.utc(2026, 9, 7, 12);
    McpService.clock = () => now;
  });

  tearDown(() async {
    McpService.resetForTest();
    await disposeTempKvCache(kvDir);
  });

  test('the chat sync tick adopts what chuk connected, without the page',
      () async {
    chuk.rows!['notion'] = _row('notion');

    // Nobody opened the connectors page: `McpService.load()` was never called.
    await McpSyncService.pullAndReconcile();

    expect(McpService.connectionFor('notion'), isNotNull);
    expect(McpService.hasAdopted, isTrue);
    final record = (await McpService.store.secretsFor('notion'))!;
    expect(record.tokens.accessToken, 'at-chuk');
    expect(record.tokens.refreshToken, 'rt-chuk');
  });

  test('a mirror that could not be read is retried, not latched', () async {
    // A cold start: signed out, or the encryption key not unlocked yet.
    chuk.rows = null;
    await McpSyncService.pullAndReconcile();
    expect(McpService.hasAdopted, isFalse);
    expect(McpService.connections.value, isEmpty);

    // The retry window passes and the user signs in.
    chuk.rows = <String, ChukMcpRow>{'notion': _row('notion')};
    now = now.add(McpService.adoptRetryInterval + const Duration(seconds: 1));
    await McpSyncService.pullAndReconcile();

    expect(McpService.hasAdopted, isTrue);
    expect(McpService.connectionFor('notion'), isNotNull);
  });

  test('a tick inside the retry window does not hit the mirror again',
      () async {
    chuk.rows = null;
    await McpSyncService.pullAndReconcile();
    expect(chuk.loads, 1);

    now = now.add(const Duration(seconds: 1));
    await McpSyncService.pullAndReconcile();
    expect(chuk.loads, 1, reason: 'still inside adoptRetryInterval');
  });

  test('a successful adoption is trusted for adoptInterval, then pulled again',
      () async {
    await McpSyncService.pullAndReconcile();
    expect(chuk.loads, 1);

    now = now.add(McpService.adoptRetryInterval + const Duration(seconds: 1));
    await McpSyncService.pullAndReconcile();
    expect(chuk.loads, 1, reason: 'still inside adoptInterval');

    // The user connects something in chuk_chat; the next window picks it up.
    chuk.rows!['slack'] = _row('slack');
    now = now.add(McpService.adoptInterval);
    await McpSyncService.pullAndReconcile();
    expect(chuk.loads, 2);
    expect(McpService.connectionFor('slack'), isNotNull);
  });

  test('two callers at once share one pull', () async {
    chuk.rows!['notion'] = _row('notion');

    await Future.wait<void>(<Future<void>>[
      McpService.adoptMirrors(),
      McpService.adoptMirrors(),
    ]);

    expect(chuk.loads, 1);
    expect(McpService.connectionFor('notion'), isNotNull);
  });

  test('the first task forwards chuk\'s connector with its credentials',
      () async {
    chuk.rows!['notion'] = _row('notion');

    // Straight to the launch path: no page, no tick has run yet. This is what
    // `CoworkRelayClient.sendTask` calls to build the `mcp_servers` list.
    final payloads = await McpService.store.forwardPayloads();

    final payload = payloads.single;
    expect(payload['id'], 'notion');
    expect(payload['url'], 'https://notion.example/mcp');
    expect(payload['auth'], 'oauth');
    expect(payload['access_token'], 'at-chuk');
    final oauth = payload['oauth'] as Map;
    expect(oauth['refresh_token'], 'rt-chuk');
    expect(oauth['token_endpoint'], 'https://auth.example/token');
    expect(oauth['client_id'], 'cid-chuk');
  });

  test('forwardPayloads pays nothing once the mirrors have been adopted',
      () async {
    await McpService.adoptMirrors();
    expect(chuk.loads, 1);

    await McpService.store.forwardPayloads();
    await McpService.store.forwardPayloads();

    expect(chuk.loads, 1);
  });
}
