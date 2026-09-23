// The decoded model catalogue is kept in memory after the first read (the
// Agents build reads it several times on every agent switch). These tests pin
// the two things the memo must never break: a save is seen by the next read,
// and a caller that edits what it got back does not edit the memo.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/model_cache_service.dart';

import '../support/kv_cache_test_env.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await useTempKvCache();
    ModelCacheService.debugClearMemo();
  });

  tearDown(() async => disposeTempKvCache(tempDir));

  test('a save replaces what the next read returns', () async {
    await ModelCacheService.saveAvailableModels(<Map<String, dynamic>>[
      <String, dynamic>{'id': 'a/one', 'name': 'One'},
    ]);
    expect((await ModelCacheService.loadAvailableModels()).single['id'], 'a/one');

    await ModelCacheService.saveAvailableModels(<Map<String, dynamic>>[
      <String, dynamic>{'id': 'b/two', 'name': 'Two'},
    ]);
    expect((await ModelCacheService.loadAvailableModels()).single['id'], 'b/two');
    expect(await ModelCacheService.displayNameFor('b/two'), 'Two');
  });

  test('editing a returned entry does not change the next read', () async {
    await ModelCacheService.saveAvailableModels(<Map<String, dynamic>>[
      <String, dynamic>{'id': 'a/one', 'name': 'One'},
    ]);
    final first = await ModelCacheService.loadAvailableModels();
    first.single['name'] = 'edited';

    final second = await ModelCacheService.loadAvailableModels();
    expect(second.single['name'], 'One');
    expect(identical(first.single, second.single), isFalse);
  });
}
