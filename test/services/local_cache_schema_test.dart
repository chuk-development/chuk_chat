// Schema fingerprint of the native chat cache (`chat_cache.db`).
//
// `LocalChatCacheService` (lib/services/local_chat_cache_native.dart) opens
// the database at `_dbVersion` and runs `onCreate` for a new file or
// `onUpgrade` for an old one. Both paths must end at the same schema. This
// test:
//
// 1. opens a fresh database through the service and compares its
//    `sqlite_master` to the checked-in fingerprint
//    `test/fixtures/cache_schema_v<N>.sql`, where N is the `user_version`
//    the service wrote. A schema change without a new fixture fails here;
// 2. builds a database as every older version created it (the `onCreate`
//    SQL of that release), puts one chat in it, opens it through the
//    service and compares the result column by column and index by index
//    with the fresh schema. The chat must survive.
//
// After a deliberate schema change (raise `_dbVersion`, add the `onUpgrade`
// step, add the old version's `onCreate` below), write the new fixture:
//
//   UPDATE_CACHE_SCHEMA=1 flutter test test/services/local_cache_schema_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:chuk_chat/services/local_chat_cache_service.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.dir);

  final String dir;

  @override
  Future<String?> getApplicationSupportPath() async => dir;

  @override
  Future<String?> getApplicationDocumentsPath() async => dir;

  @override
  Future<String?> getTemporaryPath() async => dir;
}

const String _userId = 'schema-user';

// ── Schemas as older releases created them ──────────────────────────────

const String _chatCacheV1 = '''
  CREATE TABLE chat_cache (
    id TEXT NOT NULL,
    user_id TEXT NOT NULL,
    payload TEXT NOT NULL,
    title TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT,
    is_starred INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (user_id, id)
  )''';

const String _chatCacheV4 = '''
  CREATE TABLE chat_cache (
    id TEXT NOT NULL,
    user_id TEXT NOT NULL,
    payload BLOB NOT NULL,
    title TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT,
    is_starred INTEGER NOT NULL DEFAULT 0,
    search_text TEXT,
    PRIMARY KEY (user_id, id)
  )''';

const String _idxUser =
    'CREATE INDEX idx_chat_cache_user ON chat_cache (user_id)';
const String _idxUserUpdated =
    'CREATE INDEX idx_chat_cache_user_updated '
    'ON chat_cache (user_id, updated_at DESC, created_at DESC)';
const String _kvCache = '''
  CREATE TABLE kv_cache (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
  )''';
const List<String> _skills = <String>[
  '''
  CREATE TABLE skills (
    id TEXT NOT NULL,
    user_id TEXT NOT NULL,
    source TEXT NOT NULL,
    catalog_name TEXT,
    baseline_hash TEXT,
    updated_at TEXT NOT NULL,
    PRIMARY KEY (user_id, id)
  )''',
  'CREATE INDEX idx_skills_user ON skills (user_id)',
];

/// The `onCreate` statements of each released version before the current.
final Map<int, List<String>> _legacyCreate = <int, List<String>>{
  1: <String>[_chatCacheV1, _idxUser],
  2: <String>[_chatCacheV1, _idxUser, _kvCache],
  3: <String>[_chatCacheV1, _idxUser, _idxUserUpdated, _kvCache],
  4: <String>[_chatCacheV4, _idxUser, _idxUserUpdated, _kvCache],
  5: <String>[_chatCacheV4, _idxUser, _idxUserUpdated, _kvCache, ..._skills],
};

/// Columns whose declared type differs on an upgraded file, and why that is
/// harmless. Key: `table.column`; value: the declared type an upgraded file
/// keeps.
///
/// `ALTER TABLE` cannot change a column type. Releases before v4 declared
/// `payload TEXT`; v4 stores compressed BLOBs in it. SQLite never converts a
/// BLOB value for column affinity, so the stored bytes are the same.
const Map<String, String> _upgradedTypeExceptions = <String, String>{
  'chat_cache.payload': 'TEXT',
};

// ── Fingerprints ─────────────────────────────────────────────────────────

String _normalizeSql(String sql) => sql
    .replaceAll(RegExp(r'\s+'), ' ')
    .replaceAll(RegExp(r'IF NOT EXISTS ', caseSensitive: false), '')
    .replaceAll('( ', '(')
    .replaceAll(' )', ')')
    .trim();

/// `sqlite_master` as stable text: one normalized statement per object,
/// sorted by type and name. Internal objects (`sqlite_*`, sqflite's
/// `android_metadata`) and implicit indexes (no SQL) are left out.
Future<String> _masterFingerprint(Database db) async {
  final rows = await db.rawQuery(
    "SELECT type, name, sql FROM sqlite_master "
    "WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%' "
    "AND name != 'android_metadata' ORDER BY type DESC, name",
  );
  return rows.map((r) => '${_normalizeSql(r['sql'] as String)};').join('\n');
}

/// Structure that must agree between a fresh and an upgraded file: every
/// column (name, declared type, not-null, default, primary-key position) and
/// every explicit index (columns and sort order).
Future<Map<String, String>> _structure(
  Database db, {
  Map<String, String> typeExceptions = const <String, String>{},
}) async {
  final out = <String, String>{};
  final tables = await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type = 'table' "
    "AND name NOT LIKE 'sqlite_%' AND name != 'android_metadata' "
    'ORDER BY name',
  );
  for (final t in tables) {
    final table = t['name'] as String;
    final cols = await db.rawQuery('PRAGMA table_info("$table")');
    for (final c in cols) {
      final key = '$table.${c['name']}';
      var type = (c['type'] as String).toUpperCase();
      final allowed = typeExceptions[key];
      if (allowed != null && type == allowed) type = '<any>';
      out['column $key'] =
          'cid=${c['cid']} type=$type notnull=${c['notnull']} '
          'default=${c['dflt_value']} pk=${c['pk']}';
    }
  }
  final indexes = await db.rawQuery(
    "SELECT name, tbl_name, sql FROM sqlite_master WHERE type = 'index' "
    'AND sql IS NOT NULL ORDER BY name',
  );
  for (final i in indexes) {
    out['index ${i['name']}'] =
        '${i['tbl_name']}: ${_normalizeSql(i['sql'] as String)}';
  }
  return out;
}

Map<String, String> _maskTypes(Map<String, String> s) => <String, String>{
  for (final e in s.entries)
    e.key:
        _upgradedTypeExceptions.containsKey(e.key.replaceFirst('column ', ''))
        ? e.value.replaceFirst(RegExp(r'type=\S+'), 'type=<any>')
        : e.value,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;
  late String dbPath;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cache_schema_test');
    dbPath = p.join(tempDir.path, 'chat_cache.db');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    await LocalChatCacheService.debugReset();
  });

  tearDown(() async {
    await LocalChatCacheService.debugReset();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// Opens the cache through the service (runs onCreate/onUpgrade), then
  /// closes it so the file can be inspected directly.
  Future<Database> openThroughService() async {
    await LocalChatCacheService.kvGet('schema-probe');
    await LocalChatCacheService.debugReset();
    return databaseFactory.openDatabase(dbPath);
  }

  test('a fresh cache matches the checked-in schema fingerprint', () async {
    final db = await openThroughService();
    final version = await db.getVersion();
    final actual = await _masterFingerprint(db);
    await db.close();

    final fixture = File('test/fixtures/cache_schema_v$version.sql');
    final header =
        '-- Schema of chat_cache.db at user_version $version, as\n'
        '-- LocalChatCacheService creates it. Generated by\n'
        '-- test/services/local_cache_schema_test.dart; do not edit by hand:\n'
        '--   UPDATE_CACHE_SCHEMA=1 flutter test '
        'test/services/local_cache_schema_test.dart\n';
    if (Platform.environment['UPDATE_CACHE_SCHEMA'] == '1') {
      fixture.writeAsStringSync('$header$actual\n');
    }
    expect(
      fixture.existsSync(),
      isTrue,
      reason:
          'No fingerprint for cache version $version. A schema change needs '
          'a new _dbVersion, an onUpgrade step, the old onCreate in this '
          'test, and a fixture: UPDATE_CACHE_SCHEMA=1 flutter test '
          'test/services/local_cache_schema_test.dart',
    );
    final expected = fixture
        .readAsLinesSync()
        .where((l) => !l.startsWith('--') && l.trim().isNotEmpty)
        .join('\n');
    expect(
      actual,
      expected,
      reason:
          'The schema of a fresh cache no longer matches ${fixture.path}. '
          'If the change is deliberate, raise _dbVersion, add the upgrade '
          'step and regenerate the fixture (see the file header).',
    );
  });

  test('every older version is covered by this test', () async {
    final db = await openThroughService();
    final version = await db.getVersion();
    await db.close();
    expect(
      _legacyCreate.keys.toSet(),
      {for (int v = 1; v < version; v++) v},
      reason:
          'Add the onCreate SQL of version ${version - 1} to _legacyCreate '
          'so its upgrade path is tested.',
    );
  });

  for (final entry in _legacyCreate.entries) {
    final from = entry.key;
    test(
      'a v$from cache upgrades to the fresh schema and keeps its chats',
      () async {
        // The fresh schema, from a separate directory.
        final freshDb = await openThroughService();
        final current = await freshDb.getVersion();
        final fresh = await _structure(freshDb);
        await freshDb.close();
        await LocalChatCacheService.debugReset();
        File(dbPath).deleteSync();

        final legacy = await databaseFactory.openDatabase(
          dbPath,
          options: OpenDatabaseOptions(
            version: from,
            onCreate: (db, _) async {
              for (final sql in entry.value) {
                await db.execute(sql);
              }
            },
          ),
        );
        await legacy.insert('chat_cache', <String, Object?>{
          'id': 'old-chat',
          'user_id': _userId,
          'payload': '{"messages":[{"role":"user","text":"hallo schema"}]}',
          'title': 'Old chat',
          'created_at': '2026-03-01T10:00:00.000Z',
          'is_starred': 0,
        });
        await legacy.close();

        final upgraded = await openThroughService();
        expect(await upgraded.getVersion(), current);
        final structure = await _structure(
          upgraded,
          typeExceptions: from < 4 ? _upgradedTypeExceptions : const {},
        );
        await upgraded.close();

        expect(
          structure,
          from < 4 ? _maskTypes(fresh) : fresh,
          reason: 'v$from → v$current ends at a different schema than onCreate',
        );

        final meta = await LocalChatCacheService.loadMeta(_userId);
        expect(meta.map((r) => r['id']), contains('old-chat'));
        final full = await LocalChatCacheService.loadById(_userId, 'old-chat');
        expect(full?['payload'], contains('hallo schema'));
      },
    );
  }
}
