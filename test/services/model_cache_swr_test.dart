// The model catalogue is served from the cache at once. When it is older
// than 10 minutes, a read starts one background refresh (stale while
// revalidate); concurrent stale reads share it.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/local_chat_cache_service.dart';
import 'package:chuk_chat/services/model_cache_service.dart';

import '../support/kv_cache_test_env.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await useTempKvCache();
    ModelCacheService.debugClearMemo();
    ModelCacheService.debugResetRevalidation();
  });

  tearDown(() async {
    ModelCacheService.debugResetRevalidation();
    await disposeTempKvCache(tempDir);
  });

  Future<void> ageCache(Duration age) => LocalChatCacheService.kvSet(
    'cached_models_timestamp_v2',
    DateTime.now().subtract(age).millisecondsSinceEpoch.toString(),
  );

  test('fresh window is 10 minutes', () {
    expect(ModelCacheService.cacheFreshDuration, const Duration(minutes: 10));
  });

  test('a fresh cache is served and not refreshed', () async {
    await ModelCacheService.saveAvailableModels([
      {'id': 'a/one'},
    ]);
    var calls = 0;
    ModelCacheService.registerRevalidator(() async => calls++);
    expect(await ModelCacheService.isCacheValid(), isTrue);
    expect((await ModelCacheService.loadAvailableModels()).single['id'], 'a/one');
    await Future<void>.delayed(Duration.zero);
    expect(calls, 0);
  });

  test('a stale cache is served at once and refreshed once', () async {
    await ModelCacheService.saveAvailableModels([
      {'id': 'a/one'},
    ]);
    await ageCache(const Duration(minutes: 11));
    ModelCacheService.debugResetRevalidation();
    expect(await ModelCacheService.isCacheValid(), isFalse);

    final gate = Completer<void>();
    var calls = 0;
    ModelCacheService.registerRevalidator(() async {
      calls++;
      await gate.future;
      await ModelCacheService.saveAvailableModels([
        {'id': 'b/two'},
      ]);
    });

    // Both reads return the stale list without waiting for the network.
    final reads = await Future.wait([
      ModelCacheService.loadAvailableModels(),
      ModelCacheService.loadAvailableModels(),
    ]);
    expect(reads.every((r) => r.single['id'] == 'a/one'), isTrue);
    await pumpEventQueue();
    expect(calls, 1);
    expect(ModelCacheService.debugRevalidating, isNotNull);

    gate.complete();
    await ModelCacheService.debugRevalidating;
    await pumpEventQueue();
    expect((await ModelCacheService.loadAvailableModels()).single['id'], 'b/two');
    expect(calls, 1, reason: 'the fresh save stops further refreshes');
  });

  test('a failed refresh is swallowed', () async {
    await ModelCacheService.saveAvailableModels([
      {'id': 'a/one'},
    ]);
    await ageCache(const Duration(hours: 2));
    ModelCacheService.debugResetRevalidation();
    ModelCacheService.registerRevalidator(() async => throw StateError('x'));
    expect((await ModelCacheService.loadAvailableModels()).single['id'], 'a/one');
    await pumpEventQueue();
    expect(ModelCacheService.debugRevalidating, isNull);
  });
}
