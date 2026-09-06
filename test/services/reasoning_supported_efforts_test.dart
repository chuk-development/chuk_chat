// Tests that the reasoning-effort picker is single-sourced from the server's
// per-model `supported_efforts` contract: the cached list drives the picker
// verbatim, a stale selection is clamped to the model's real ladder, and the
// derived list is used only when the catalog cache has no entry (cold start).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/chat_mode_service.dart';
import 'package:chuk_chat/services/model_cache_service.dart';
import 'package:chuk_chat/services/model_capabilities_service.dart';

import '../support/kv_cache_test_env.dart';

/// Seed the on-disk catalog cache with [models] and hydrate the capability
/// service from it, so the sync accessors read them.
Future<void> _seedCatalog(List<Map<String, dynamic>> models) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  await ModelCacheService.saveAvailableModels(models);
  await ModelCapabilitiesService.refresh();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const graded = 'lab/graded';
  const mandatory = 'lab/mandatory';
  const toggle = 'lab/toggle';

  late Directory tempDir;

  tearDown(() async => disposeTempKvCache(tempDir));

  setUp(() async {
    tempDir = await useTempKvCache();
    await _seedCatalog(<Map<String, dynamic>>[
      // Irregular graded ladder that omits medium and includes the new `max`.
      <String, dynamic>{
        'id': graded,
        'supports_reasoning': true,
        'supports_reasoning_effort': true,
        'reasoning_mandatory': false,
        'supported_efforts': <String>['none', 'low', 'high', 'max'],
        'reasoning_default_effort': 'high',
      },
      // Mandatory graded model: no "none" — reasoning cannot be turned off.
      <String, dynamic>{
        'id': mandatory,
        'supports_reasoning': true,
        'supports_reasoning_effort': true,
        'reasoning_mandatory': true,
        'supported_efforts': <String>['low', 'high', 'max'],
        'reasoning_default_effort': 'high',
      },
      // Toggle model: reasons but has no graded dial.
      <String, dynamic>{
        'id': toggle,
        'supports_reasoning': true,
        'supports_reasoning_effort': false,
        'reasoning_mandatory': false,
        'supported_efforts': <String>['none', 'on'],
      },
    ]);
  });

  group('supportedEffortsSync / reasoningDefaultEffortSync', () {
    test('return the cached server list verbatim', () {
      expect(
        ModelCapabilitiesService.supportedEffortsSync(graded),
        <String>['none', 'low', 'high', 'max'],
      );
      expect(
        ModelCapabilitiesService.reasoningDefaultEffortSync(graded),
        'high',
      );
    });

    test('unknown model has no list and no default', () {
      expect(
        ModelCapabilitiesService.supportedEffortsSync('who/knows'),
        isEmpty,
      );
      expect(
        ModelCapabilitiesService.reasoningDefaultEffortSync('who/knows'),
        isNull,
      );
    });

    test('the returned list is a copy the caller cannot mutate', () {
      ModelCapabilitiesService.supportedEffortsSync(graded).add('bogus');
      expect(
        ModelCapabilitiesService.supportedEffortsSync(graded),
        <String>['none', 'low', 'high', 'max'],
      );
    });
  });

  group('reasoningLevelsForModel — the picker options', () {
    test('renders the server list verbatim, including max', () {
      expect(
        ChatModeService.reasoningLevelsForModel(
          modelId: graded,
          providerSlug: 'openai',
        ),
        <String>['none', 'low', 'high', 'max'],
      );
    });

    test('a mandatory model never offers off', () {
      final levels = ChatModeService.reasoningLevelsForModel(
        modelId: mandatory,
        providerSlug: 'openai',
      );
      expect(levels, <String>['low', 'high', 'max']);
      expect(levels, isNot(contains('none')));
    });

    test('a toggle model offers off/on only', () {
      expect(
        ChatModeService.reasoningLevelsForModel(
          modelId: toggle,
          providerSlug: 'openai',
        ),
        <String>['none', 'on'],
      );
    });

    test('an uncached model falls back to the derived ladder', () {
      // Cold start: no cache entry → derived graded ladder, permissive default.
      expect(
        ChatModeService.reasoningLevelsForModel(
          modelId: 'cold/start',
          providerSlug: 'openai',
        ),
        <String>['none', 'low', 'medium', 'high'],
      );
    });
  });

  group('sanitizeReasoningForModel — clamp to the real ladder', () {
    test('a level in the list survives', () {
      expect(
        ChatModeService.sanitizeReasoningForModel(
          'max',
          modelId: graded,
          providerSlug: 'openai',
        ),
        'max',
      );
    });

    test('a level not in the list clamps to the nearest weaker', () {
      // medium is not on this ladder → nearest weaker is low.
      expect(
        ChatModeService.sanitizeReasoningForModel(
          'medium',
          modelId: graded,
          providerSlug: 'openai',
        ),
        'low',
      );
      // xhigh is not on this ladder → nearest weaker is high.
      expect(
        ChatModeService.sanitizeReasoningForModel(
          'xhigh',
          modelId: graded,
          providerSlug: 'openai',
        ),
        'high',
      );
    });

    test('off is refused on a mandatory model and drops to the weakest', () {
      expect(
        ChatModeService.sanitizeReasoningForModel(
          'none',
          modelId: mandatory,
          providerSlug: 'openai',
        ),
        'low',
      );
    });

    test('a graded intent collapses to on for a toggle model', () {
      expect(
        ChatModeService.sanitizeReasoningForModel(
          'high',
          modelId: toggle,
          providerSlug: 'openai',
        ),
        'on',
      );
    });
  });
}
