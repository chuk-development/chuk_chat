// Tests for the per-mode config store: the baked defaults, save/load
// round-trips per mode, that the two modes never bleed into each other, that
// a corrupt record falls back, and that reasoning levels are gated per
// provider.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/chat_mode_service.dart';
import 'package:chuk_chat/services/chat_profile_service.dart';

void main() {
  setUp(ChatProfileService.resetForTest);

  group('baked defaults', () {
    test('Standard is the profile model and marker, reasoning low', () {
      ChatProfileService.resetForTest();
      final standard = ChatModeService.defaultConfig(ChatMode.standard);
      expect(standard.modelId, ChatProfileService.standardModelId);
      expect(standard.modelId, 'deepseek/deepseek-v4.1-flash-1017');
      expect(standard.providerSlug, ChatProfileService.standardMarker);
      expect(standard.providerSlug, 'profile:standard');
      expect(standard.reasoningEffort, 'low');
      expect(standard.reasoningOn, isTrue);
    });

    test('the cold-cache ladders never offer medium', () {
      // With no catalog entry the derived ladder is the only guard; `medium`
      // is exactly the level the default models reject, so it is not on it.
      expect(ChatModeService.reasoningLevelsGraded, isNot(contains('medium')));
      expect(ChatModeService.reasoningLevelsFireworks, isNot(contains('medium')));
      expect(
        ChatModeService.reasoningLevelsFor(
          providerSlug: 'fireworks/serverless',
          reasoningMandatory: true,
        ),
        isNot(contains('medium')),
      );
      // A stored `medium` on a cold cache clamps to the strongest level below
      // it that every graded ladder honours — never to a silent no-op.
      expect(
        ChatModeService.sanitizeReasoningForModel(
          'medium',
          modelId: 'z-ai/glm-5.3-flash',
          providerSlug: 'fireworks/serverless',
        ),
        'low',
      );
    });

    test('the general fallback matches Custom', () {
      expect(ChatModeService.defaultModelId, 'z-ai/glm-5.3-flash');
      expect(ChatModeService.defaultProviderSlug, 'fireworks/serverless');
    });

    test('Custom seeds on the general fallback, reasoning off', () {
      final custom = ChatModeService.defaultConfig(ChatMode.custom);
      expect(custom.modelId, 'z-ai/glm-5.3-flash');
      expect(custom.providerSlug, 'fireworks/serverless');
      expect(custom.reasoningEffort, 'none');
      expect(custom.reasoningOn, isFalse);
    });
  });

  group('setProviderForMode', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('re-pins the provider and re-clamps reasoning', () async {
      // Custom on a non-Fireworks provider at xhigh.
      await ChatModeService.saveConfig(
        ChatMode.custom,
        const ModeConfig(
          modelId: 'deepseek/deepseek-v4-pro-0813',
          providerSlug: 'openai',
          reasoningEffort: 'xhigh',
        ),
      );
      final updated = await ChatModeService.setProviderForMode(
        ChatMode.custom,
        'fireworks/serverless',
      );
      expect(updated.providerSlug, 'fireworks/serverless');
      // Model is untouched.
      expect(updated.modelId, 'deepseek/deepseek-v4-pro-0813');
      // xhigh is not valid on Fireworks → high.
      expect(updated.reasoningEffort, 'high');
      expect(await ChatModeService.loadConfig(ChatMode.custom), updated);
    });

    test('an empty slug is a no-op', () async {
      final before = await ChatModeService.loadConfig(ChatMode.standard);
      final updated = await ChatModeService.setProviderForMode(ChatMode.standard, '');
      expect(updated, before);
    });
  });

  group('config persistence', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('a fresh install returns the baked default for each mode', () async {
      expect(
        await ChatModeService.loadConfig(ChatMode.standard),
        ChatModeService.defaultConfig(ChatMode.standard),
      );
      expect(
        await ChatModeService.loadConfig(ChatMode.custom),
        ChatModeService.defaultConfig(ChatMode.custom),
      );
    });

    test('a saved config round-trips per mode', () async {
      // 'high' is a valid graded level, so it survives the load-time clamp.
      const custom = ModeConfig(
        modelId: 'moonshotai/kimi-k3',
        providerSlug: 'openai',
        reasoningEffort: 'high',
      );
      await ChatModeService.saveConfig(ChatMode.custom, custom);
      expect(await ChatModeService.loadConfig(ChatMode.custom), custom);
    });

    test('the two modes never bleed into each other', () async {
      const picked = ModeConfig(
        modelId: 'a/b',
        providerSlug: 'openai',
        reasoningEffort: 'high',
      );
      await ChatModeService.saveConfig(ChatMode.custom, picked);

      // Custom changed; Standard is untouched, so still its default.
      expect(await ChatModeService.loadConfig(ChatMode.custom), picked);
      expect(
        await ChatModeService.loadConfig(ChatMode.standard),
        ChatModeService.defaultConfig(ChatMode.standard),
      );
    });

    test('Standard ignores a stored model and provider, keeps the level',
        () async {
      ChatProfileService.resetForTest();
      SharedPreferences.setMockInitialValues({
        'chat_mode_config_v1_standard':
            '{"model":"other/model","provider":"openai","reasoning":"high"}',
      });
      final loaded = await ChatModeService.loadConfig(ChatMode.standard);
      expect(loaded.modelId, ChatProfileService.standardModelId);
      expect(loaded.providerSlug, ChatProfileService.standardMarker);
      expect(loaded.reasoningEffort, 'high');
    });

    test('Standard takes the model from the stored server profile', () async {
      ChatProfileService.resetForTest();
      SharedPreferences.setMockInitialValues({
        'chat_profile_standard_v1':
            '{"id":"standard","name":"Standard","description":"",'
            '"model":{"id":"vendor/new-model","name":"New"},"providers":[]}',
        'chat_mode_config_v1_standard':
            '{"model":"other/model","provider":"openai","reasoning":"low"}',
      });
      final loaded = await ChatModeService.loadConfig(ChatMode.standard);
      expect(loaded.modelId, 'vendor/new-model');
      expect(loaded.providerSlug, 'profile:standard');
      expect(loaded.reasoningEffort, 'low');
    });

    test('the old fast and thinking modes parse as Standard', () {
      expect(ChatModeService.parse('fast'), ChatMode.standard);
      expect(ChatModeService.parse('thinking'), ChatMode.standard);
      expect(ChatModeService.parse('standard'), ChatMode.standard);
      expect(ChatModeService.parse('custom'), ChatMode.custom);
      expect(ChatModeService.parse(null), ChatMode.standard);
      expect(ChatModeService.parse('garbage'), ChatMode.standard);
    });

    test('a corrupt stored record falls back to the default', () async {
      SharedPreferences.setMockInitialValues({
        'chat_mode_config_v1_standard': 'not json at all',
      });
      expect(
        await ChatModeService.loadConfig(ChatMode.standard),
        ChatModeService.defaultConfig(ChatMode.standard),
      );
    });

    test('a partial record takes missing fields from the default', () async {
      // Only the model is stored; provider and reasoning come from default.
      SharedPreferences.setMockInitialValues({
        'chat_mode_config_v1_custom': '{"model":"x/y"}',
      });
      final loaded = await ChatModeService.loadConfig(ChatMode.custom);
      expect(loaded.modelId, 'x/y');
      expect(loaded.providerSlug, 'fireworks/serverless');
      expect(loaded.reasoningEffort, 'none');
    });

    test('an invalid stored reasoning level is clamped on load', () async {
      // xhigh is not valid on Fireworks; it must come back as high.
      SharedPreferences.setMockInitialValues({
        'chat_mode_config_v1_custom':
            '{"model":"deepseek/deepseek-v4-pro-0813",'
            '"provider":"fireworks/serverless","reasoning":"xhigh"}',
      });
      final loaded = await ChatModeService.loadConfig(ChatMode.custom);
      expect(loaded.reasoningEffort, 'high');
    });

    test('setModelForMode swaps model+provider and re-clamps reasoning',
        () async {
      // Start Custom on a non-Fireworks provider at xhigh.
      await ChatModeService.saveConfig(
        ChatMode.custom,
        const ModeConfig(
          modelId: 'a/b',
          providerSlug: 'openai',
          reasoningEffort: 'xhigh',
        ),
      );
      // Move it to a Fireworks provider — xhigh must drop to high.
      final updated = await ChatModeService.setModelForMode(
        ChatMode.custom,
        modelId: 'deepseek/deepseek-v4-pro-0813',
        providerSlug: 'fireworks/serverless',
      );
      expect(updated.modelId, 'deepseek/deepseek-v4-pro-0813');
      expect(updated.providerSlug, 'fireworks/serverless');
      expect(updated.reasoningEffort, 'high');
      expect(await ChatModeService.loadConfig(ChatMode.custom), updated);
    });

    test('setModelForMode keeps the current provider when given none',
        () async {
      // Custom starts pinned to a real provider.
      await ChatModeService.saveConfig(
        ChatMode.custom,
        const ModeConfig(
          modelId: 'deepseek/deepseek-v4-pro-0813',
          providerSlug: 'fireworks/serverless',
          reasoningEffort: 'high',
        ),
      );
      // An unresolved pin ('') must not be stored: keep the prior provider.
      final updated = await ChatModeService.setModelForMode(
        ChatMode.custom,
        modelId: 'other/model',
        providerSlug: '',
      );
      expect(updated.modelId, 'other/model');
      expect(updated.providerSlug, 'fireworks/serverless');
      expect(updated.reasoningEffort, 'high');
    });

    test('an empty stored provider field reads back as the default', () async {
      // Documents the fromJson substitution; the store never writes '' via
      // setModelForMode, but a hand-edited record must still resolve sanely.
      SharedPreferences.setMockInitialValues({
        'chat_mode_config_v1_custom':
            '{"model":"x/y","provider":"","reasoning":"high"}',
      });
      final loaded = await ChatModeService.loadConfig(ChatMode.custom);
      expect(loaded.modelId, 'x/y');
      expect(loaded.providerSlug, 'fireworks/serverless');
      expect(loaded.reasoningEffort, 'high');
    });

    test('setReasoningForMode clamps to the current provider', () async {
      await ChatModeService.saveConfig(
        ChatMode.custom,
        const ModeConfig(
          modelId: 'deepseek/deepseek-v4-flash-0731',
          providerSlug: 'fireworks/serverless',
          reasoningEffort: 'none',
        ),
      );
      final updated =
          await ChatModeService.setReasoningForMode(ChatMode.custom, 'xhigh');
      // Fireworks tops out at high.
      expect(updated.reasoningEffort, 'high');
    });
  });

  group('reasoning level gating', () {
    test('a Fireworks provider never yields minimal or xhigh', () {
      for (final slug in ['fireworks', 'fireworks/serverless']) {
        final levels = ChatModeService.reasoningLevelsFor(providerSlug: slug);
        expect(levels, ['none', 'low', 'high']);
        expect(levels, isNot(contains('minimal')));
        expect(levels, isNot(contains('xhigh')));
      }
    });

    test('a non-Fireworks provider offers the same graded ladder', () {
      // The Fireworks-vs-all split is gone: a graded model offers
      // none/low/high on every provider now (no `medium` as a cold guess).
      expect(
        ChatModeService.reasoningLevelsFor(providerSlug: 'openai'),
        ['none', 'low', 'high'],
      );
    });

    test('a model that cannot reason offers only off', () {
      expect(
        ChatModeService.reasoningLevelsFor(
          providerSlug: 'openai',
          supportsReasoning: false,
        ),
        ['none'],
      );
    });

    test('a reasoning model without graded effort offers an on/off toggle', () {
      expect(
        ChatModeService.reasoningLevelsFor(
          providerSlug: 'openai',
          supportsReasoningEffort: false,
        ),
        ['none', 'on'],
      );
    });

    test('a reasoning model with graded effort offers the graded ladder', () {
      expect(
        ChatModeService.reasoningLevelsFor(
          providerSlug: 'openai',
          supportsReasoningEffort: true,
        ),
        ['none', 'low', 'high'],
      );
    });

    test('isFireworksProvider spots direct and routed slugs', () {
      expect(ChatModeService.isFireworksProvider('fireworks'), isTrue);
      expect(ChatModeService.isFireworksProvider('fireworks/serverless'), isTrue);
      expect(ChatModeService.isFireworksProvider('openai'), isFalse);
      expect(ChatModeService.isFireworksProvider(''), isFalse);
    });

    test('sanitize keeps a valid level and clamps an invalid one down', () {
      // Valid stays.
      expect(
        ChatModeService.sanitizeReasoning('high',
            providerSlug: 'fireworks/serverless'),
        'high',
      );
      // medium is not a cold-cache level any more: nearest weaker is low.
      expect(
        ChatModeService.sanitizeReasoning('medium',
            providerSlug: 'fireworks/serverless'),
        'low',
      );
      // xhigh → high on Fireworks (nearest allowed no stronger).
      expect(
        ChatModeService.sanitizeReasoning('xhigh',
            providerSlug: 'fireworks/serverless'),
        'high',
      );
      // minimal → none on Fireworks (nothing between none and low).
      expect(
        ChatModeService.sanitizeReasoning('minimal',
            providerSlug: 'fireworks/serverless'),
        'none',
      );
      // An unknown token on a graded model means "reason on at some strength":
      // it lands on a safe graded level, never an invalid/empty token.
      expect(
        ChatModeService.sanitizeReasoning('turbo',
            providerSlug: 'fireworks/serverless'),
        'low',
      );
      // xhigh on a graded model clamps to high (no ladder split any more).
      expect(
        ChatModeService.sanitizeReasoning('xhigh', providerSlug: 'openai'),
        'high',
      );
    });

    test('sanitize maps a graded level to on for a binary model', () {
      // A model that reasons but has no graded effort: any strength → on.
      expect(
        ChatModeService.sanitizeReasoning(
          'medium',
          providerSlug: 'openai',
          supportsReasoningEffort: false,
        ),
        'on',
      );
      // Off stays off.
      expect(
        ChatModeService.sanitizeReasoning(
          'none',
          providerSlug: 'openai',
          supportsReasoningEffort: false,
        ),
        'none',
      );
      // An unknown token on a binary model still collapses to on.
      expect(
        ChatModeService.sanitizeReasoning(
          'turbo',
          providerSlug: 'openai',
          supportsReasoningEffort: false,
        ),
        'on',
      );
    });

    test('sanitize maps the on token to a valid graded level', () {
      // A stored 'on' on a graded model resolves to a real graded level.
      expect(
        ChatModeService.sanitizeReasoning(
          'on',
          providerSlug: 'openai',
        ),
        'low',
      );
      // On a binary model 'on' is valid and survives untouched.
      expect(
        ChatModeService.sanitizeReasoning(
          'on',
          providerSlug: 'openai',
          supportsReasoningEffort: false,
        ),
        'on',
      );
      // A non-reasoning model clamps 'on' back to off.
      expect(
        ChatModeService.sanitizeReasoning(
          'on',
          providerSlug: 'openai',
          supportsReasoning: false,
        ),
        'none',
      );
    });

    test('reasoningLabel names each level for the menu', () {
      expect(ChatModeService.reasoningLabel('none'), 'Off');
      expect(ChatModeService.reasoningLabel('on'), 'On');
      expect(ChatModeService.reasoningLabel('low'), 'Low');
      expect(ChatModeService.reasoningLabel('medium'), 'Medium');
      expect(ChatModeService.reasoningLabel('high'), 'High');
      expect(ChatModeService.reasoningLabel('xhigh'), 'X-High');
      expect(ChatModeService.reasoningLabel('max'), 'Max');
    });
  });
}
