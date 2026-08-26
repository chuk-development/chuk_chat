// Tests for the local SQLite `skills` store: per-user CRUD, the transactional
// replaceSkills, and that catalog_name / baseline_hash round-trip.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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

Map<String, dynamic> _skillRow(
  String id,
  String userId, {
  required String source,
  String? catalogName,
  String? baselineHash,
  String updatedAt = '2026-08-20T10:00:00.000Z',
}) {
  return {
    'id': id,
    'user_id': userId,
    'source': source,
    'catalog_name': catalogName,
    'baseline_hash': baselineHash,
    'updated_at': updatedAt,
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;
  const userId = 'user-1';

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('skills_store_test');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    await LocalChatCacheService.debugReset();
  });

  tearDown(() async {
    await LocalChatCacheService.debugReset();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('upsert then read round-trips every column', () async {
    await LocalChatCacheService.upsertSkill(
      _skillRow(
        's1',
        userId,
        source: '---\nname: a\n---\nbody',
        catalogName: 'browser-skill',
        baselineHash: 'sha256:abc',
      ),
    );

    final rows = await LocalChatCacheService.skillRows(userId);
    expect(rows, hasLength(1));
    expect(rows.first['id'], 's1');
    expect(rows.first['source'], '---\nname: a\n---\nbody');
    expect(rows.first['catalog_name'], 'browser-skill');
    expect(rows.first['baseline_hash'], 'sha256:abc');
  });

  test('upsert on the same id replaces, it does not duplicate', () async {
    await LocalChatCacheService.upsertSkill(
      _skillRow('s1', userId, source: 'v1'),
    );
    await LocalChatCacheService.upsertSkill(
      _skillRow('s1', userId, source: 'v2', baselineHash: 'h2'),
    );

    final rows = await LocalChatCacheService.skillRows(userId);
    expect(rows, hasLength(1));
    expect(rows.first['source'], 'v2');
    expect(rows.first['baseline_hash'], 'h2');
  });

  test('rows are scoped to their user', () async {
    await LocalChatCacheService.upsertSkill(
      _skillRow('s1', userId, source: 'mine'),
    );
    await LocalChatCacheService.upsertSkill(
      _skillRow('s2', 'user-2', source: 'theirs'),
    );

    final mine = await LocalChatCacheService.skillRows(userId);
    expect(mine, hasLength(1));
    expect(mine.first['id'], 's1');
  });

  test('delete removes only the targeted row', () async {
    await LocalChatCacheService.upsertSkill(
      _skillRow('s1', userId, source: 'a'),
    );
    await LocalChatCacheService.upsertSkill(
      _skillRow('s2', userId, source: 'b'),
    );

    await LocalChatCacheService.deleteSkill(userId, 's1');

    final rows = await LocalChatCacheService.skillRows(userId);
    expect(rows, hasLength(1));
    expect(rows.first['id'], 's2');
  });

  test('replaceSkills swaps the whole set atomically', () async {
    await LocalChatCacheService.upsertSkill(
      _skillRow('old', userId, source: 'stale'),
    );

    await LocalChatCacheService.replaceSkills(userId, [
      _skillRow('n1', userId, source: 'fresh-1'),
      _skillRow('n2', userId, source: 'fresh-2'),
    ]);

    final rows = await LocalChatCacheService.skillRows(userId);
    expect(rows.map((r) => r['id']), containsAll(['n1', 'n2']));
    expect(rows.map((r) => r['id']), isNot(contains('old')));
  });

  test('skillRows returns newest first', () async {
    await LocalChatCacheService.upsertSkill(
      _skillRow('old', userId, source: 'a', updatedAt: '2026-08-01T00:00:00Z'),
    );
    await LocalChatCacheService.upsertSkill(
      _skillRow('new', userId, source: 'b', updatedAt: '2026-08-25T00:00:00Z'),
    );

    final rows = await LocalChatCacheService.skillRows(userId);
    expect(rows.first['id'], 'new');
  });
}
