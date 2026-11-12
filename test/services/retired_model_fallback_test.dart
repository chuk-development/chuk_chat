// A mode whose saved model the server retired moves to the successor named
// in the catalog's `replaces` list, or to the mode default, instead of
// sending a request the server refuses.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/chat_mode_service.dart';
import 'package:chuk_chat/services/model_cache_service.dart';
import 'package:chuk_chat/services/retired_model_fallback.dart';

import '../support/kv_cache_test_env.dart';

void main() {
  group('replacementForRetiredModel', () {
    final catalog = <Map<String, dynamic>>[
      {
        'id': 'moonshotai/kimi-k3',
        'replaces': ['moonshotai/kimi-k2.5', 'moonshotai/kimi-k2.6'],
      },
      {'id': 'z-ai/glm-5.3-flash'},
    ];

    test('a model still served stays', () {
      expect(
        replacementForRetiredModel(
          'moonshotai/kimi-k3',
          catalog,
          fallbackModelId: 'z-ai/glm-5.3-flash',
        ),
        isNull,
      );
    });

    test('a retired model moves to the successor that replaces it', () {
      expect(
        replacementForRetiredModel(
          'MoonshotAI/Kimi-K2.5',
          catalog,
          fallbackModelId: 'z-ai/glm-5.3-flash',
        ),
        'moonshotai/kimi-k3',
      );
    });

    test('a gone model with no successor moves to the fallback', () {
      expect(
        replacementForRetiredModel(
          'old/unknown',
          catalog,
          fallbackModelId: 'z-ai/glm-5.3-flash',
        ),
        'z-ai/glm-5.3-flash',
      );
    });

    test('no catalog means no evidence: keep the model', () {
      expect(
        replacementForRetiredModel(
          'old/unknown',
          const <Map<String, dynamic>>[],
          fallbackModelId: 'z-ai/glm-5.3-flash',
        ),
        isNull,
      );
    });
  });

  group('ChatModeService.loadConfig', () {
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

    Future<void> storeCustom(String modelId, String provider) async {
      SharedPreferences.setMockInitialValues({
        'chat_mode_config_v1_custom': jsonEncode({
          'model': modelId,
          'provider': provider,
          'reasoning': 'none',
        }),
      });
    }

    test('moves a retired model to its successor and clears the pin', () async {
      await ModelCacheService.saveAvailableModels([
        {
          'id': 'moonshotai/kimi-k3',
          'replaces': ['moonshotai/kimi-k2.5'],
        },
        {'id': 'z-ai/glm-5.3-flash'},
      ]);
      await storeCustom('moonshotai/kimi-k2.5', 'old-provider/fp8');

      final config = await ChatModeService.loadConfig(ChatMode.custom);
      expect(config.modelId, 'moonshotai/kimi-k3');
      expect(config.providerSlug, '');

      // Stored, so the move happens once.
      ModelCacheService.debugClearMemo();
      final again = await ChatModeService.loadConfig(ChatMode.custom);
      expect(again.modelId, 'moonshotai/kimi-k3');
    });

    test('a gone model with no successor gets the mode default', () async {
      await ModelCacheService.saveAvailableModels([
        {'id': 'z-ai/glm-5.3-flash'},
      ]);
      await storeCustom('old/unknown', 'old-provider/fp8');

      final config = await ChatModeService.loadConfig(ChatMode.custom);
      expect(config.modelId, ChatModeService.defaultModelId);
      expect(config.providerSlug, ChatModeService.defaultProviderSlug);
    });

    test('a served model is left alone', () async {
      await ModelCacheService.saveAvailableModels([
        {'id': 'moonshotai/kimi-k3'},
      ]);
      await storeCustom('moonshotai/kimi-k3', 'some/provider');

      final config = await ChatModeService.loadConfig(ChatMode.custom);
      expect(config.modelId, 'moonshotai/kimi-k3');
      expect(config.providerSlug, 'some/provider');
    });
  });
}
