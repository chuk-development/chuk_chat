// Tests for the per-mode config store: the baked defaults, save/load
// round-trips per mode, that the two modes never bleed into each other, that
// a corrupt record falls back, and that reasoning levels are gated per
// provider.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/chat_mode_service.dart';

void main() {
  group('baked defaults', () {
    test('Fast is flash-0731 on fireworks/serverless, reasoning off', () {
      final fast = ChatModeService.defaultConfig(ChatMode.fast);
      expect(fast.modelId, 'deepseek/deepseek-v4-flash-0731');
      expect(fast.providerSlug, 'fireworks/serverless');
      expect(fast.reasoningEffort, 'none');
      expect(fast.reasoningOn, isFalse);
    });

    test('Thinking is pro-0813 on fireworks/serverless, reasoning medium', () {
      final thinking = ChatModeService.defaultConfig(ChatMode.thinking);
      expect(thinking.modelId, 'deepseek/deepseek-v4-pro-0813');
      expect(thinking.providerSlug, 'fireworks/serverless');
      expect(thinking.reasoningEffort, 'medium');
      expect(thinking.reasoningOn, isTrue);
    });

    test('the general fallback matches Fast', () {
      expect(ChatModeService.defaultModelId, 'deepseek/deepseek-v4-flash-0731');
      expect(ChatModeService.defaultProviderSlug, 'fireworks/serverless');
    });
  });

  group('config persistence', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('a fresh install returns the baked default for each mode', () async {
      expect(
        await ChatModeService.loadConfig(ChatMode.fast),
        ChatModeService.defaultConfig(ChatMode.fast),
      );
      expect(
        await ChatModeService.loadConfig(ChatMode.thinking),
        ChatModeService.defaultConfig(ChatMode.thinking),
      );
    });

    test('a saved config round-trips per mode', () async {
      // 'high' is a valid graded level, so it survives the load-time clamp.
      const custom = ModeConfig(
        modelId: 'moonshotai/kimi-k3',
        providerSlug: 'openai',
        reasoningEffort: 'high',
      );
      await ChatModeService.saveConfig(ChatMode.thinking, custom);
      expect(await ChatModeService.loadConfig(ChatMode.thinking), custom);
    });

    test('the two modes never bleed into each other', () async {
      const custom = ModeConfig(
        modelId: 'a/b',
        providerSlug: 'openai',
        reasoningEffort: 'high',
      );
      await ChatModeService.saveConfig(ChatMode.fast, custom);

      // Fast changed; Thinking is untouched, so still its default.
      expect(await ChatModeService.loadConfig(ChatMode.fast), custom);
      expect(
        await ChatModeService.loadConfig(ChatMode.thinking),
        ChatModeService.defaultConfig(ChatMode.thinking),
      );
    });

    test('a corrupt stored record falls back to the default', () async {
      SharedPreferences.setMockInitialValues({
        'chat_mode_config_v1_fast': 'not json at all',
      });
      expect(
        await ChatModeService.loadConfig(ChatMode.fast),
        ChatModeService.defaultConfig(ChatMode.fast),
      );
    });

    test('a partial record takes missing fields from the default', () async {
      // Only the model is stored; provider and reasoning come from default.
      SharedPreferences.setMockInitialValues({
        'chat_mode_config_v1_fast': '{"model":"x/y"}',
      });
      final loaded = await ChatModeService.loadConfig(ChatMode.fast);
      expect(loaded.modelId, 'x/y');
      expect(loaded.providerSlug, 'fireworks/serverless');
      expect(loaded.reasoningEffort, 'none');
    });

    test('an invalid stored reasoning level is clamped on load', () async {
      // xhigh is not valid on Fireworks; it must come back as high.
      SharedPreferences.setMockInitialValues({
        'chat_mode_config_v1_thinking':
            '{"model":"deepseek/deepseek-v4-pro-0813",'
            '"provider":"fireworks/serverless","reasoning":"xhigh"}',
      });
      final loaded = await ChatModeService.loadConfig(ChatMode.thinking);
      expect(loaded.reasoningEffort, 'high');
    });

    test('setModelForMode swaps model+provider and re-clamps reasoning',
        () async {
      // Start Thinking on a non-Fireworks provider at xhigh.
      await ChatModeService.saveConfig(
        ChatMode.thinking,
        const ModeConfig(
          modelId: 'a/b',
          providerSlug: 'openai',
          reasoningEffort: 'xhigh',
        ),
      );
      // Move it to a Fireworks provider — xhigh must drop to high.
      final updated = await ChatModeService.setModelForMode(
        ChatMode.thinking,
        modelId: 'deepseek/deepseek-v4-pro-0813',
        providerSlug: 'fireworks/serverless',
      );
      expect(updated.modelId, 'deepseek/deepseek-v4-pro-0813');
      expect(updated.providerSlug, 'fireworks/serverless');
      expect(updated.reasoningEffort, 'high');
      expect(await ChatModeService.loadConfig(ChatMode.thinking), updated);
    });

    test('setModelForMode keeps the current provider when given none',
        () async {
      // Thinking starts pinned to a real provider.
      await ChatModeService.saveConfig(
        ChatMode.thinking,
        const ModeConfig(
          modelId: 'deepseek/deepseek-v4-pro-0813',
          providerSlug: 'fireworks/serverless',
          reasoningEffort: 'medium',
        ),
      );
      // An unresolved pin ('') must not be stored: keep the prior provider.
      final updated = await ChatModeService.setModelForMode(
        ChatMode.thinking,
        modelId: 'other/model',
        providerSlug: '',
      );
      expect(updated.modelId, 'other/model');
      expect(updated.providerSlug, 'fireworks/serverless');
      expect(updated.reasoningEffort, 'medium');
    });

    test('an empty stored provider field reads back as the default', () async {
      // Documents the fromJson substitution; the store never writes '' via
      // setModelForMode, but a hand-edited record must still resolve sanely.
      SharedPreferences.setMockInitialValues({
        'chat_mode_config_v1_fast':
            '{"model":"x/y","provider":"","reasoning":"medium"}',
      });
      final loaded = await ChatModeService.loadConfig(ChatMode.fast);
      expect(loaded.modelId, 'x/y');
      expect(loaded.providerSlug, 'fireworks/serverless');
      expect(loaded.reasoningEffort, 'medium');
    });

    test('setReasoningForMode clamps to the current provider', () async {
      await ChatModeService.saveConfig(
        ChatMode.fast,
        const ModeConfig(
          modelId: 'deepseek/deepseek-v4-flash-0731',
          providerSlug: 'fireworks/serverless',
          reasoningEffort: 'none',
        ),
      );
      final updated =
          await ChatModeService.setReasoningForMode(ChatMode.fast, 'xhigh');
      // Fireworks tops out at high.
      expect(updated.reasoningEffort, 'high');
    });
  });

  group('reasoning level gating', () {
    test('a Fireworks provider never yields minimal or xhigh', () {
      for (final slug in ['fireworks', 'fireworks/serverless']) {
        final levels = ChatModeService.reasoningLevelsFor(providerSlug: slug);
        expect(levels, ['none', 'low', 'medium', 'high']);
        expect(levels, isNot(contains('minimal')));
        expect(levels, isNot(contains('xhigh')));
      }
    });

    test('a non-Fireworks provider offers the same graded ladder', () {
      // The Fireworks-vs-all split is gone: a graded model offers
      // none/low/medium/high on every provider now.
      expect(
        ChatModeService.reasoningLevelsFor(providerSlug: 'openai'),
        ['none', 'low', 'medium', 'high'],
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
        ['none', 'low', 'medium', 'high'],
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
        ChatModeService.sanitizeReasoning('medium',
            providerSlug: 'fireworks/serverless'),
        'medium',
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
        'medium',
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
        'medium',
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
      expect(ChatModeService.reasoningLabel('xhigh'), 'Max');
    });
  });
}
