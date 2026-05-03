import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/per_model_system_prompt_service.dart';

void main() {
  group('mergeModelPrompt', () {
    test('returns base unchanged when mode is off', () {
      final result = mergeModelPrompt(
        base: 'Base prompt.',
        modelPrompt: 'Per-model instruction.',
        mode: ModelPromptMode.off,
      );
      expect(result, 'Base prompt.');
    });

    test('returns base unchanged when modelPrompt is empty', () {
      final result = mergeModelPrompt(
        base: 'Base prompt.',
        modelPrompt: '',
        mode: ModelPromptMode.append,
      );
      expect(result, 'Base prompt.');
    });

    test('returns base unchanged when modelPrompt is whitespace-only', () {
      final result = mergeModelPrompt(
        base: 'Base prompt.',
        modelPrompt: '   \n\t  ',
        mode: ModelPromptMode.replace,
      );
      expect(result, 'Base prompt.');
    });

    test('replace returns trimmed modelPrompt and ignores base', () {
      final result = mergeModelPrompt(
        base: 'Base prompt.',
        modelPrompt: '  Per-model only.  ',
        mode: ModelPromptMode.replace,
      );
      expect(result, 'Per-model only.');
    });

    test('append puts base first then per-model with separator', () {
      final result = mergeModelPrompt(
        base: 'Base prompt.',
        modelPrompt: 'Per-model addition.',
        mode: ModelPromptMode.append,
      );
      expect(result, 'Base prompt.\n\n---\n\nPer-model addition.');
    });

    test('prepend puts per-model first then base with separator', () {
      final result = mergeModelPrompt(
        base: 'Base prompt.',
        modelPrompt: 'Per-model addition.',
        mode: ModelPromptMode.prepend,
      );
      expect(result, 'Per-model addition.\n\n---\n\nBase prompt.');
    });

    test('append falls back to per-model only when base is empty', () {
      final result = mergeModelPrompt(
        base: '',
        modelPrompt: 'Per-model only.',
        mode: ModelPromptMode.append,
      );
      expect(result, 'Per-model only.');
    });

    test('append falls back to per-model only when base is null', () {
      final result = mergeModelPrompt(
        base: null,
        modelPrompt: 'Per-model only.',
        mode: ModelPromptMode.append,
      );
      expect(result, 'Per-model only.');
    });

    test('prepend falls back to per-model only when base is whitespace', () {
      final result = mergeModelPrompt(
        base: '   ',
        modelPrompt: 'Per-model only.',
        mode: ModelPromptMode.prepend,
      );
      expect(result, 'Per-model only.');
    });

    test('replace returns per-model when base is null', () {
      final result = mergeModelPrompt(
        base: null,
        modelPrompt: 'Per-model only.',
        mode: ModelPromptMode.replace,
      );
      expect(result, 'Per-model only.');
    });

    test('off with empty model and null base returns null', () {
      final result = mergeModelPrompt(
        base: null,
        modelPrompt: '',
        mode: ModelPromptMode.off,
      );
      expect(result, isNull);
    });

    test('multi-line content is preserved verbatim with append', () {
      const base = 'Line 1\nLine 2';
      const modelPrompt = 'Extra line A\nExtra line B';
      final result = mergeModelPrompt(
        base: base,
        modelPrompt: modelPrompt,
        mode: ModelPromptMode.append,
      );
      expect(result, 'Line 1\nLine 2\n\n---\n\nExtra line A\nExtra line B');
    });
  });

  group('ModelPromptConfig', () {
    test('isActive false when mode is off', () {
      const cfg = ModelPromptConfig(
        prompt: 'something',
        mode: ModelPromptMode.off,
      );
      expect(cfg.isActive, isFalse);
    });

    test('isActive false when prompt is empty', () {
      const cfg = ModelPromptConfig(
        prompt: '',
        mode: ModelPromptMode.append,
      );
      expect(cfg.isActive, isFalse);
    });

    test('isActive false when prompt is whitespace-only', () {
      const cfg = ModelPromptConfig(
        prompt: '   \n  ',
        mode: ModelPromptMode.replace,
      );
      expect(cfg.isActive, isFalse);
    });

    test('isActive true with non-empty prompt and a real mode', () {
      const cfg = ModelPromptConfig(
        prompt: 'do thing',
        mode: ModelPromptMode.append,
      );
      expect(cfg.isActive, isTrue);
    });

    test('copyWith updates fields independently', () {
      const cfg = ModelPromptConfig(
        prompt: 'a',
        mode: ModelPromptMode.append,
      );
      expect(
        cfg.copyWith(prompt: 'b').prompt,
        'b',
      );
      expect(
        cfg.copyWith(prompt: 'b').mode,
        ModelPromptMode.append,
      );
      expect(
        cfg.copyWith(mode: ModelPromptMode.off).mode,
        ModelPromptMode.off,
      );
      expect(
        cfg.copyWith(mode: ModelPromptMode.off).prompt,
        'a',
      );
    });
  });
}
