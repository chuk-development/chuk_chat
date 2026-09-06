// Proves the one-time move of the big model catalogue cache out of
// SharedPreferences (where it bloated the prefs file the legacy plugin
// re-parses on every getInstance) into the SQLite kv_cache: the data survives
// the move and the old prefs key is deleted so the file shrinks.
//
// Only ONE migration test per file: ModelCacheService gates its migration on a
// one-shot static, so a second call in the same isolate would find migration
// already done.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/local_chat_cache_service.dart';
import 'package:chuk_chat/services/model_cache_service.dart';

import '../support/kv_cache_test_env.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await useTempKvCache();
  });

  tearDown(() async => disposeTempKvCache(tempDir));

  test('model cache moves from prefs to kv_cache and clears the prefs key',
      () async {
    final models = <Map<String, dynamic>>[
      {'id': 'deepseek/deepseek-v4-flash', 'name': 'DeepSeek V4 Flash'},
    ];
    // An account written by an older build: the catalogue sits in prefs.
    SharedPreferences.setMockInitialValues(<String, Object>{
      'cached_models_v2': jsonEncode(models),
      'cached_models_timestamp_v2': DateTime.now().millisecondsSinceEpoch,
    });

    // A read triggers the one-time migration.
    final loaded = await ModelCacheService.loadAvailableModels();
    expect(loaded, isNotEmpty);
    expect(loaded.first['id'], 'deepseek/deepseek-v4-flash');
    expect(await ModelCacheService.isCacheValid(), isTrue);

    // The data now lives in the SQLite kv_cache…
    expect(await LocalChatCacheService.kvGet('cached_models_v2'), isNotNull);

    // …and the bulky prefs keys are gone, so the prefs file shrinks.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('cached_models_v2'), isFalse);
    expect(prefs.containsKey('cached_models_timestamp_v2'), isFalse);
  });
}
