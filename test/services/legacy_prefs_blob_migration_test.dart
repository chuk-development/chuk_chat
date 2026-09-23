// The two big blobs that used to live in SharedPreferences — the MCP
// connection list (`mcp_connections_v1`) and the per-account sidebar title
// lists (`chat_titles_v1_<userId>`) — move into the SQLite kv_cache once.
// On Linux SharedPreferences rewrites the whole prefs file synchronously on
// every setX, so each byte left there is paid on every settings write.
//
// Both moves share the same rules: the kv write comes first and the prefs key
// is removed only after it succeeded; a failed kv write leaves the prefs value
// in place; a second run finds nothing to do.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/agents/agents_pairing_store.dart'
    show AgentsSecureKeyValueStore;
import 'package:chuk_chat/services/chat_storage_state.dart'
    show chatTitlesCacheKey;
import 'package:chuk_chat/services/chat_titles_prefs_cleanup.dart';
import 'package:chuk_chat/services/local_chat_cache_service.dart';
import 'package:chuk_chat/services/mcp/mcp_connection.dart';
import 'package:chuk_chat/services/mcp/mcp_store.dart';

import '../support/kv_cache_test_env.dart';

class _MemorySecrets implements AgentsSecureKeyValueStore {
  final Map<String, String> map = <String, String>{};

  @override
  Future<String?> read(String key) async => map[key];

  @override
  Future<void> write(String key, String value) async => map[key] = value;

  @override
  Future<void> delete(String key) async => map.remove(key);
}

/// An in-memory kv_cache that counts writes and can be told to fail them.
class _FakeKv {
  final Map<String, String> map = <String, String>{};
  bool failWrites = false;
  int writes = 0;

  McpListBackend get backend => McpListBackend(
    read: (k) async => map[k],
    write: (k, v) async {
      if (failWrites) throw StateError('kv_cache is not writable');
      writes++;
      map[k] = v;
    },
  );
}

String _connectionsJson(List<String> names) => jsonEncode(<Object>[
  for (final n in names)
    McpConnection(
      id: n.toLowerCase(),
      name: n,
      url: 'https://$n.example/mcp',
      tools: <McpTool>[
        McpTool(
          name: 'search',
          description: 'Search $n',
          inputSchema: const <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'q': <String, dynamic>{'type': 'string'},
            },
          },
        ),
      ],
    ).toJson(),
]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('mcp_connections_v1 moves from prefs to the kv_cache', () {
    const key = McpStore.prefsKey;

    test('happy path: kv written first, then the prefs key removed', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        key: _connectionsJson(<String>['GitHub', 'Linear']),
        'theme_mode_v1': 'dark',
      });
      final kv = _FakeKv();
      final store = McpStore(secrets: _MemorySecrets(), list: kv.backend);

      final loaded = await store.load();

      // Same connections, same order, tools and schemas intact.
      expect(loaded.map((c) => c.name), <String>['GitHub', 'Linear']);
      expect(loaded.first.tools.single.inputSchema['type'], 'object');
      expect(kv.map[key], _connectionsJson(<String>['GitHub', 'Linear']));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(key), isFalse);
      // Unrelated settings are untouched.
      expect(prefs.getString('theme_mode_v1'), 'dark');
      // And the next load reads the kv_cache.
      expect((await store.load()).map((c) => c.name), <String>[
        'GitHub',
        'Linear',
      ]);
    });

    test('a kv value already present loses to the prefs copy', () async {
      // The prefs copy is the live list of this build; a kv row can only be
      // an older one (upstream chuk_chat's, or a previous move).
      SharedPreferences.setMockInitialValues(<String, Object>{
        key: _connectionsJson(<String>['GitHub', 'Notion']),
      });
      final kv = _FakeKv()..map[key] = _connectionsJson(<String>['Old']);
      final store = McpStore(secrets: _MemorySecrets(), list: kv.backend);

      final loaded = await store.load();

      expect(loaded.map((c) => c.name), <String>['GitHub', 'Notion']);
      expect(kv.map[key], _connectionsJson(<String>['GitHub', 'Notion']));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(key), isFalse);
    });

    test('a failed kv write keeps the prefs value and the store working',
        () async {
      final original = _connectionsJson(<String>['GitHub']);
      SharedPreferences.setMockInitialValues(<String, Object>{key: original});
      final kv = _FakeKv()..failWrites = true;
      final store = McpStore(secrets: _MemorySecrets(), list: kv.backend);

      expect(await McpStore.migrateLegacyPrefs(list: kv.backend), isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(key), original);

      // Reads still come from prefs…
      expect((await store.load()).single.name, 'GitHub');
      expect(prefs.getString(key), original);

      // …and a write falls back to prefs rather than being lost.
      await store.upsert(
        const McpConnection(id: 'x', name: 'Extra', url: 'https://x/mcp'),
      );
      expect((await store.load()).map((c) => c.name), <String>[
        'GitHub',
        'Extra',
      ]);
      expect(prefs.getString(key), contains('Extra'));
      expect(kv.map, isEmpty);

      // Once the kv_cache works again, the next load moves it over.
      kv.failWrites = false;
      expect((await store.load()).length, 2);
      expect(prefs.containsKey(key), isFalse);
      expect(kv.map[key], contains('Extra'));
    });

    test('a second run is a no-op', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        key: _connectionsJson(<String>['GitHub']),
      });
      final kv = _FakeKv();

      expect(await McpStore.migrateLegacyPrefs(list: kv.backend), isTrue);
      expect(kv.writes, 1);
      expect(await McpStore.migrateLegacyPrefs(list: kv.backend), isFalse);
      final store = McpStore(secrets: _MemorySecrets(), list: kv.backend);
      expect((await store.load()).single.name, 'GitHub');
      expect(kv.writes, 1);
    });

    group('against the real SQLite kv_cache', () {
      late Directory tempDir;
      setUp(() async => tempDir = await useTempKvCache());
      tearDown(() async => disposeTempKvCache(tempDir));

      test('upsert writes the kv_cache and never prefs', () async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          key: _connectionsJson(<String>['GitHub']),
        });
        final store = McpStore(secrets: _MemorySecrets());

        await store.upsert(
          const McpConnection(id: 'n', name: 'Notion', url: 'https://n/mcp'),
        );

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.containsKey(key), isFalse);
        expect(await LocalChatCacheService.kvGet(key), contains('Notion'));
        expect((await store.load()).map((c) => c.name), <String>[
          'GitHub',
          'Notion',
        ]);
      });
    });
  });

  group('chat_titles_v1_* leave prefs', () {
    final keyA = chatTitlesCacheKey('user-a');
    final keyB = chatTitlesCacheKey('user-b');
    const titlesOld = '[{"id":"c1","title":"old"}]';
    const titlesNew = '[{"id":"c1","title":"new"}]';

    late Directory tempDir;
    setUp(() async => tempDir = await useTempKvCache());
    tearDown(() async {
      ChatTitlesPrefsCleanup.putIfAbsent = LocalChatCacheService.kvSetIfAbsent;
      await disposeTempKvCache(tempDir);
    });

    test('happy path: moved into kv_cache, then removed from prefs', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        keyA: titlesOld,
        'theme_mode_v1': 'dark',
      });
      final prefs = await SharedPreferences.getInstance();

      expect(await ChatTitlesPrefsCleanup.run(prefs: prefs), 1);

      expect(await LocalChatCacheService.kvGet(keyA), titlesOld);
      expect(prefs.containsKey(keyA), isFalse);
      expect(prefs.getString('theme_mode_v1'), 'dark');
    });

    test('kv value already present: the stale prefs copy is dropped',
        () async {
      await LocalChatCacheService.kvSet(keyA, titlesNew);
      SharedPreferences.setMockInitialValues(<String, Object>{
        keyA: titlesOld,
        keyB: titlesOld,
      });
      final prefs = await SharedPreferences.getInstance();

      expect(await ChatTitlesPrefsCleanup.run(prefs: prefs), 2);

      // The live kv list is never overwritten by the old prefs copy…
      expect(await LocalChatCacheService.kvGet(keyA), titlesNew);
      // …and the other account's copy, which kv lacked, is moved over.
      expect(await LocalChatCacheService.kvGet(keyB), titlesOld);
      expect(prefs.getKeys().where((k) => k.startsWith('chat_titles_v1_')),
          isEmpty);
    });

    test('a failed kv write keeps the prefs value', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        keyA: titlesOld,
      });
      final prefs = await SharedPreferences.getInstance();
      ChatTitlesPrefsCleanup.putIfAbsent = (_, _) async =>
          throw StateError('kv_cache is not writable');

      expect(await ChatTitlesPrefsCleanup.run(prefs: prefs), 0);

      expect(prefs.getString(keyA), titlesOld);
      expect(await LocalChatCacheService.kvGet(keyA), isNull);
    });

    test('a second run is a no-op', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        keyA: titlesOld,
      });
      final prefs = await SharedPreferences.getInstance();
      expect(await ChatTitlesPrefsCleanup.run(prefs: prefs), 1);

      var calls = 0;
      ChatTitlesPrefsCleanup.putIfAbsent = (k, v) async {
        calls++;
        return LocalChatCacheService.kvSetIfAbsent(k, v);
      };
      expect(await ChatTitlesPrefsCleanup.run(prefs: prefs), 0);
      expect(calls, 0);
      expect(await LocalChatCacheService.kvGet(keyA), titlesOld);
    });
  });
}
