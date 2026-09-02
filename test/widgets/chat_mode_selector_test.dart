// Tests for the composer's mode control: what it shows, what the level-1
// menu offers (only the two modes plus the way deeper), and what the deeper
// menu offers (reasoning levels, the picked models, and the way out to the
// full model screen).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/chat_mode_service.dart';
import 'package:chuk_chat/services/model_cache_service.dart';
import 'package:chuk_chat/widgets/chat_mode_selector.dart';

// Fireworks levels, the common case in the composer.
const _fireworksLevels = <String>['none', 'low', 'medium', 'high'];

Future<void> _pump(
  WidgetTester tester, {
  ChatMode mode = ChatMode.thinking,
  ValueChanged<ChatMode>? onModeChanged,
  ValueChanged<String>? onModelSelected,
  String reasoningEffort = 'none',
  List<String> reasoningLevels = _fireworksLevels,
  ValueChanged<String>? onReasoningEffortChanged,
  VoidCallback? onOpenModelScreen,
  String? selectedModelId,
  String? modelLabel,
  List<ChatModelChoice> pickedModels = const <ChatModelChoice>[],
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: ChatModeSelector(
            mode: mode,
            onModeChanged: onModeChanged ?? (_) {},
            onModelSelected: onModelSelected,
            reasoningEffort: reasoningEffort,
            reasoningLevels: reasoningLevels,
            onReasoningEffortChanged: onReasoningEffortChanged,
            onOpenModelScreen: onOpenModelScreen,
            selectedModelId: selectedModelId,
            modelLabel: modelLabel,
            pickedModels: pickedModels,
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('mode semantics', () {
    test('fast answers straight, thinking takes the deep pass', () {
      expect(ChatModeService.isDeepThinking(ChatMode.fast), isFalse);
      expect(ChatModeService.isDeepThinking(ChatMode.thinking), isTrue);
    });

    test('a fresh install starts on fast', () {
      expect(ChatModeService.fallbackMode, ChatMode.fast);
    });

    test('each mode carries its own model, provider and reasoning', () {
      final fast = ChatModeService.defaultConfig(ChatMode.fast);
      expect(fast.modelId, 'z-ai/glm-5.3-flash');
      expect(fast.providerSlug, 'fireworks/serverless');
      expect(fast.reasoningEffort, 'none');

      final thinking = ChatModeService.defaultConfig(ChatMode.thinking);
      expect(thinking.modelId, 'deepseek/deepseek-v4-pro-0813');
      expect(thinking.providerSlug, 'fireworks/serverless');
      expect(thinking.reasoningEffort, 'medium');
    });

    test('an unknown stored value falls back instead of throwing', () {
      expect(ChatModeService.parse('fast'), ChatMode.fast);
      expect(ChatModeService.parse('thinking'), ChatMode.thinking);
      expect(ChatModeService.parse('turbo'), ChatModeService.fallbackMode);
      expect(ChatModeService.parse(null), ChatModeService.fallbackMode);
    });
  });

  group('mode persistence', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('a fresh install starts on the fallback mode', () async {
      expect(await ChatModeService.load(), ChatModeService.fallbackMode);
    });

    test('a saved mode comes back', () async {
      await ChatModeService.save(ChatMode.fast);
      expect(await ChatModeService.load(), ChatMode.fast);

      await ChatModeService.save(ChatMode.thinking);
      expect(await ChatModeService.load(), ChatMode.thinking);
    });
  });

  group('model display name', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('resolves the human name of a cached model', () async {
      await ModelCacheService.saveAvailableModels([
        {'id': 'deepseek/deepseek-v4-flash', 'name': 'DeepSeek V4 Flash'},
        {'id': 'moonshotai/kimi-k3', 'name': 'Kimi K3'},
      ]);

      expect(
        await ModelCacheService.displayNameFor('deepseek/deepseek-v4-flash'),
        'DeepSeek V4 Flash',
      );
    });

    test('is null for an unknown id, an empty id or an empty cache', () async {
      expect(await ModelCacheService.displayNameFor('nope/nope'), isNull);
      expect(await ModelCacheService.displayNameFor(''), isNull);

      await ModelCacheService.saveAvailableModels([
        {'id': 'a/b', 'name': '   '},
      ]);
      expect(await ModelCacheService.displayNameFor('a/b'), isNull);
    });
  });

  group('level 1: the mode', () {
    testWidgets('shows the current mode', (tester) async {
      await _pump(tester, mode: ChatMode.fast);

      expect(find.text('Fast'), findsOneWidget);
      expect(find.byIcon(Icons.bolt), findsOneWidget);
      expect(find.text('Thinking'), findsNothing);
    });

    testWidgets('opens a menu listing both modes, current ticked', (
      tester,
    ) async {
      await _pump(tester, mode: ChatMode.thinking);

      await tester.tap(find.text('Thinking'));
      await tester.pumpAndSettle();

      expect(find.text('Fast'), findsOneWidget);
      expect(find.text('Thinking'), findsNWidgets(2)); // pill + menu row
      expect(find.byIcon(Icons.check), findsOneWidget);
    });

    testWidgets('has no reasoning row at level 1', (tester) async {
      await _pump(
        tester,
        mode: ChatMode.fast,
        onReasoningEffortChanged: (_) {},
      );

      await tester.tap(find.text('Fast'));
      await tester.pumpAndSettle();

      // Reasoning lives one level deeper now, not on the pill menu.
      expect(find.text('REASONING'), findsNothing);
      expect(find.text('Low'), findsNothing);
    });

    testWidgets('picking the other mode reports it once', (tester) async {
      final picked = <ChatMode>[];
      await _pump(tester, mode: ChatMode.thinking, onModeChanged: picked.add);

      await tester.tap(find.text('Thinking'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fast'));
      await tester.pumpAndSettle();

      expect(picked, [ChatMode.fast]);
    });

    testWidgets('picking the mode already active changes nothing', (
      tester,
    ) async {
      final picked = <ChatMode>[];
      await _pump(tester, mode: ChatMode.fast, onModeChanged: picked.add);

      await tester.tap(find.text('Fast'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fast').last);
      await tester.pumpAndSettle();

      expect(picked, isEmpty);
    });

    testWidgets('under Fast the third point stays neutral, not the model', (
      tester,
    ) async {
      await _pump(
        tester,
        mode: ChatMode.fast,
        selectedModelId: 'deepseek/deepseek-v4-flash',
        modelLabel: 'DeepSeek: V4 Flash',
        onModelSelected: (_) {},
      );

      await tester.tap(find.text('Fast'));
      await tester.pumpAndSettle();
      // Fast runs the model set in the model screen — the composer never
      // surfaces it. The third point is the neutral Custom entry.
      expect(find.text('Choose model'), findsOneWidget);
      expect(find.text('V4 Flash'), findsNothing);
    });

    testWidgets('the third point names the model once Custom is active', (
      tester,
    ) async {
      await _pump(
        tester,
        mode: ChatMode.custom,
        selectedModelId: 'deepseek/deepseek-v4-flash',
        modelLabel: 'DeepSeek: V4 Flash',
        onModelSelected: (_) {},
      );

      await tester.tap(find.byIcon(Icons.tune).first);
      await tester.pumpAndSettle();
      // In Custom the third point is the chosen model, lab prefix stripped.
      expect(find.text('V4 Flash'), findsWidgets);
      expect(find.text('Choose model'), findsNothing);
    });

    testWidgets('with no deeper handlers there is no opener row', (
      tester,
    ) async {
      await _pump(tester, mode: ChatMode.fast);

      await tester.tap(find.text('Fast'));
      await tester.pumpAndSettle();

      expect(find.text('Choose model'), findsNothing);
    });
  });

  group('level 2: reasoning and model', () {
    testWidgets('offers Off plus the provider levels, current ticked', (
      tester,
    ) async {
      final levels = <String>[];
      await _pump(
        tester,
        mode: ChatMode.thinking,
        reasoningEffort: 'medium',
        onReasoningEffortChanged: levels.add,
        onOpenModelScreen: () {},
      );

      await tester.tap(find.text('Thinking'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose model'));
      await tester.pumpAndSettle();

      // Reasoning is a submenu opener now, not the inline ladder.
      expect(find.text('Reasoning'), findsOneWidget);
      expect(find.text('REASONING'), findsNothing);

      await tester.tap(find.text('Reasoning'));
      await tester.pumpAndSettle();

      // The reasoning ladder for a Fireworks provider, in the cascade.
      expect(find.text('REASONING'), findsOneWidget);
      expect(find.text('Off'), findsOneWidget);
      expect(find.text('Low'), findsOneWidget);
      expect(find.text('High'), findsOneWidget);

      await tester.tap(find.text('High'));
      await tester.pumpAndSettle();
      expect(levels, ['high']);
    });

    testWidgets('picking the active level reports nothing', (tester) async {
      final levels = <String>[];
      await _pump(
        tester,
        mode: ChatMode.thinking,
        reasoningEffort: 'medium',
        onReasoningEffortChanged: levels.add,
        onOpenModelScreen: () {},
      );

      await tester.tap(find.text('Thinking'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose model'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reasoning'));
      await tester.pumpAndSettle();
      // 'Medium' also shows as the opener's trailing label; the cascade row
      // is the later one.
      await tester.tap(find.text('Medium').last);
      await tester.pumpAndSettle();

      expect(levels, isEmpty);
    });

    testWidgets('lists the picked models and reports the pick', (tester) async {
      final picked = <String>[];
      await _pump(
        tester,
        mode: ChatMode.fast,
        // No reasoning handler here, to keep this menu about models only.
        reasoningLevels: const ['none'],
        selectedModelId: 'deepseek/deepseek-v4-flash',
        modelLabel: 'DeepSeek: V4 Flash',
        pickedModels: const [
          ChatModelChoice(
            id: 'deepseek/deepseek-v4-flash',
            name: 'DeepSeek: V4 Flash',
          ),
          ChatModelChoice(id: 'moonshotai/kimi-k3', name: 'Moonshot: Kimi K3'),
        ],
        onModelSelected: picked.add,
        onOpenModelScreen: () {},
      );

      await tester.tap(find.text('Fast'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose model')); // third point → deeper menu
      await tester.pumpAndSettle();

      expect(find.text('Kimi K3'), findsOneWidget);
      await tester.tap(find.text('Kimi K3'));
      await tester.pumpAndSettle();
      expect(picked, ['moonshotai/kimi-k3']);
    });

    testWidgets('the deeper menu reaches the full model screen', (
      tester,
    ) async {
      var opened = 0;
      await _pump(
        tester,
        mode: ChatMode.fast,
        reasoningLevels: const ['none'],
        selectedModelId: 'a/b',
        modelLabel: 'Model B',
        pickedModels: const [ChatModelChoice(id: 'a/b', name: 'Model B')],
        onModelSelected: (_) {},
        onOpenModelScreen: () => opened++,
      );

      await tester.tap(find.text('Fast'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose model')); // third point → deeper menu
      await tester.pumpAndSettle();
      expect(find.text('More models'), findsOneWidget);
      await tester.tap(find.text('More models'));
      await tester.pumpAndSettle();
      expect(opened, 1);
    });

    testWidgets(
      'with no reasoning and nothing picked it goes straight to the screen',
      (tester) async {
        var opened = 0;
        await _pump(
          tester,
          mode: ChatMode.fast,
          reasoningLevels: const ['none'], // off only → no reasoning choice
          modelLabel: 'Model B',
          onModelSelected: (_) {},
          onOpenModelScreen: () => opened++,
        );

        await tester.tap(find.text('Fast'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Choose model'));
        await tester.pumpAndSettle();

        expect(opened, 1);
      },
    );
  });

  group('a model id the catalogue does not know', () {
    test('reads as a name, not as a slug', () {
      expect(prettyModelId('deepseek/deepseek-v4-pro'), 'Deepseek v4 Pro');
      expect(prettyModelId('openai/gpt-oss-120b'), 'GPT OSS 120b');
      expect(prettyModelId('moonshotai/kimi-k3'), 'Kimi K3');
    });

    test('an id with nothing in it is handed back unchanged', () {
      expect(prettyModelId(''), '');
      expect(prettyModelId('/'), '/');
    });
  });
}
