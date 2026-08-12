// Tests for the SQLite chat cache: gzip payload storage, the v3→v4
// upgrade, and the byte-bounded batched reads that keep a large cache off
// the platform-channel allocation limit.

import 'dart:convert';
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

/// A chat payload of roughly [messages] messages carrying a fat tool
/// result, mirroring what actually fills the cache in production.
String _buildPayload({int messages = 6, int resultChars = 20000}) {
  final result = List.filled(resultChars ~/ 20, 'TOOL RESULT LINE 42 ').join();
  return jsonEncode({
    'messages': [
      for (int i = 0; i < messages; i++)
        {
          'role': i.isEven ? 'user' : 'assistant',
          'text': 'message number $i about quantensprung',
          if (i.isOdd) 'toolCalls': jsonEncode([
            {'id': 'call_$i', 'name': 'search', 'result': result},
          ]),
        },
    ],
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;
  const userId = 'user-1';

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('chat_cache_test');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    await LocalChatCacheService.debugReset();
  });

  tearDown(() async {
    await LocalChatCacheService.debugReset();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  Map<String, dynamic> row(String id, String payload, {String? title}) {
    return LocalChatCacheService.buildPlaintextRow(
      id: id,
      payload: payload,
      createdAt: '2026-08-1${id.length % 9}T10:00:00.000Z',
      isStarred: false,
      title: title,
    );
  }

  test('payload survives the gzip round trip byte for byte', () async {
    final payload = _buildPayload();
    await LocalChatCacheService.upsert(userId, row('chat-1', payload));

    final loaded = await LocalChatCacheService.loadById(userId, 'chat-1');
    expect(loaded, isNotNull);
    expect(loaded!['payload'], payload);
  });

  test('payload is stored compressed, not as plain text', () async {
    final payload = _buildPayload();
    await LocalChatCacheService.upsert(userId, row('chat-1', payload));

    final db = await databaseFactory.openDatabase(
      p.join(tempDir.path, 'chat_cache.db'),
    );
    final stored = await db.rawQuery(
      'SELECT payload, LENGTH(payload) AS n FROM chat_cache WHERE id = ?',
      ['chat-1'],
    );
    await db.close();

    final storedBytes = (stored.first['n'] as num).toInt();
    expect(stored.first['payload'], isA<List<int>>());
    expect(storedBytes, lessThan(utf8.encode(payload).length ~/ 3));
  });

  test('tiny payloads stay uncompressed', () async {
    const payload = '{"messages":[]}';
    await LocalChatCacheService.upsert(userId, row('chat-small', payload));

    final loaded = await LocalChatCacheService.loadById(userId, 'chat-small');
    expect(loaded!['payload'], payload);
  });

  test('loadMeta returns every chat, newest first', () async {
    for (int i = 0; i < 30; i++) {
      await LocalChatCacheService.upsert(
        userId,
        LocalChatCacheService.buildPlaintextRow(
          id: 'chat-$i',
          payload: _buildPayload(),
          createdAt:
              '2026-08-${((i % 28) + 1).toString().padLeft(2, '0')}'
              'T10:00:00.000Z',
          isStarred: false,
        ),
      );
    }

    final rows = await LocalChatCacheService.loadMeta(userId);
    expect(rows, hasLength(30));

    final dates = rows
        .map((r) => DateTime.parse(r['created_at'] as String))
        .toList();
    for (int i = 1; i < dates.length; i++) {
      expect(dates[i].isAfter(dates[i - 1]), isFalse);
    }
  });

  test('search stays correct when a chat exceeds the batch budget', () async {
    // 6 MB of payload in a single row — larger than the batch budget, so it
    // has to travel in a batch of its own.
    final huge = _buildPayload(messages: 2, resultChars: 6 * 1024 * 1024);
    await LocalChatCacheService.upsert(userId, row('chat-huge', huge));
    await LocalChatCacheService.upsert(
      userId,
      row('chat-small', _buildPayload(messages: 2, resultChars: 800)),
    );

    final hits = await LocalChatCacheService.search(userId, 'quantensprung');
    expect(hits, hasLength(2));
    final byId = {for (final r in hits) r['id'] as String: r['payload']};
    expect(byId['chat-huge'], huge);
  });

  test('loadMeta omits payloads but keeps the sidebar fields', () async {
    await LocalChatCacheService.upsert(
      userId,
      row('chat-1', _buildPayload(), title: 'Titel A'),
    );

    final meta = await LocalChatCacheService.loadMeta(userId);
    expect(meta, hasLength(1));
    expect(meta.first.containsKey('payload'), isFalse);
    expect(meta.first['id'], 'chat-1');
    expect(meta.first['title'], 'Titel A');
    expect(meta.first['is_starred'], false);
  });

  test('search matches message text and chat titles', () async {
    await LocalChatCacheService.upsert(
      userId,
      row('chat-1', _buildPayload(), title: 'Alltag'),
    );
    await LocalChatCacheService.upsert(
      userId,
      row('chat-2', jsonEncode({
        'messages': [
          {'role': 'user', 'text': 'nichts passendes hier'},
        ],
      }), title: 'Zweiter Chat'),
    );

    final byText = await LocalChatCacheService.search(userId, 'quantensprung');
    expect(byText.map((r) => r['id']), ['chat-1']);

    final byTitle = await LocalChatCacheService.search(userId, 'zweiter');
    expect(byTitle.map((r) => r['id']), ['chat-2']);

    final none = await LocalChatCacheService.search(userId, 'gibtesnicht');
    expect(none, isEmpty);
  });

  test('search does not match inside tool results', () async {
    await LocalChatCacheService.upsert(userId, row('chat-1', _buildPayload()));

    // 'TOOL RESULT LINE' only exists in the tool output, which is
    // deliberately not indexed.
    final hits = await LocalChatCacheService.search(userId, 'TOOL RESULT LINE');
    expect(hits, isEmpty);
  });

  test('a v3 database upgrades: plain payloads become compressed', () async {
    final dbPath = p.join(tempDir.path, 'chat_cache.db');
    final payload = _buildPayload();

    // Build the pre-upgrade schema by hand and insert plain text.
    final legacy = await databaseFactory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 3,
        onCreate: (db, _) async {
          await db.execute('''
            CREATE TABLE chat_cache (
              id TEXT NOT NULL,
              user_id TEXT NOT NULL,
              payload TEXT NOT NULL,
              title TEXT,
              created_at TEXT NOT NULL,
              updated_at TEXT,
              is_starred INTEGER NOT NULL DEFAULT 0,
              PRIMARY KEY (user_id, id)
            )
          ''');
          await db.execute('''
            CREATE TABLE kv_cache (
              key TEXT PRIMARY KEY,
              value TEXT NOT NULL
            )
          ''');
        },
      ),
    );
    for (int i = 0; i < 5; i++) {
      await legacy.insert('chat_cache', {
        'id': 'legacy-$i',
        'user_id': userId,
        'payload': payload,
        'title': 'Alter Chat $i',
        'created_at': '2026-07-0${i + 1}T10:00:00.000Z',
        'is_starred': 0,
      });
    }
    await legacy.close();

    // Opening through the service triggers the v4 upgrade.
    final meta = await LocalChatCacheService.loadMeta(userId);
    expect(meta, hasLength(5));
    for (final row in meta) {
      final full = await LocalChatCacheService.loadById(
        userId,
        row['id'] as String,
      );
      expect(full!['payload'], payload);
    }

    // Search works on migrated rows, which means search_text was filled.
    final hits = await LocalChatCacheService.search(userId, 'quantensprung');
    expect(hits, hasLength(5));

    final db = await databaseFactory.openDatabase(dbPath);
    final stored = await db.rawQuery(
      'SELECT payload FROM chat_cache LIMIT 1',
    );
    await db.close();
    expect(stored.first['payload'], isA<List<int>>());
  });
}
