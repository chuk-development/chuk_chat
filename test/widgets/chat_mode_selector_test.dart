// Tests for the composer's mode control: what it shows, what the sheet
// offers, and that the model list stays one level deeper.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/chat_mode_service.dart';
import 'package:chuk_chat/services/model_cache_service.dart';
import 'package:chuk_chat/widgets/chat_mode_selector.dart';

Future<void> _pump(
  WidgetTester tester, {
  ChatMode mode = ChatMode.thinking,
  ValueChanged<ChatMode>? onModeChanged,
  ValueChanged<String>? onModelSelected,
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

      expect(ChatModeService.reasoningEffort(ChatMode.fast), 'none');
      expect(ChatModeService.reasoningEffort(ChatMode.thinking), 'high');
    });

    test('a fresh install starts on fast', () {
      expect(ChatModeService.fallbackMode, ChatMode.fast);
    });

    test('both modes run the same pinned model', () {
      expect(ChatModeService.defaultModelId, 'deepseek/deepseek-v4-flash');
      expect(ChatModeService.defaultProviderSlug, 'fireworks');
    });

    test('an unknown stored value falls back instead of throwing', () {
      expect(ChatModeService.parse('fast'), ChatMode.fast);
      expect(ChatModeService.parse('thinking'), ChatMode.thinking);
      expect(ChatModeService.parse('turbo'), ChatModeService.fallbackMode);
      expect(ChatModeService.parse(null), ChatModeService.fallbackMode);
    });
  });

  group('persistence', () {
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

  group('selector', () {
    testWidgets('shows the current mode', (tester) async {
      await _pump(tester, mode: ChatMode.fast);

      expect(find.text('Fast'), findsOneWidget);
      expect(find.byIcon(Icons.bolt), findsOneWidget);
      expect(find.text('Thinking'), findsNothing);
    });

    testWidgets('opens a sheet listing both modes', (tester) async {
      await _pump(tester, mode: ChatMode.thinking);

      await tester.tap(find.text('Thinking'));
      await tester.pumpAndSettle();

      // Both modes, one row each, in the same menu the model dropdown uses.
      expect(find.text('Fast'), findsOneWidget);
      expect(find.text('Thinking'), findsNWidgets(2)); // pill + menu row
      // The current mode is ticked.
      expect(find.byIcon(Icons.check), findsOneWidget);
    });

    testWidgets('picking the other mode reports it once', (tester) async {
      final picked = <ChatMode>[];
      await _pump(
        tester,
        mode: ChatMode.thinking,
        onModeChanged: picked.add,
      );

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
      // The menu's own row for the mode that is already active.
      await tester.tap(find.text('Fast').last);
      await tester.pumpAndSettle();

      expect(picked, isEmpty);
    });

    testWidgets('the second menu lists only the picked models', (
      tester,
    ) async {
      final picked = <String>[];
      await _pump(
        tester,
        mode: ChatMode.fast,
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
      );

      // Level 1 shows the model in use, without the lab prefix.
      await tester.tap(find.text('Fast'));
      await tester.pumpAndSettle();
      expect(find.text('V4 Flash'), findsOneWidget);
      expect(find.text('DeepSeek: V4 Flash'), findsNothing);

      // Level 2: the picked models only, same menu style.
      await tester.tap(find.text('V4 Flash'));
      await tester.pumpAndSettle();
      expect(find.text('Kimi K3'), findsOneWidget);

      await tester.tap(find.text('Kimi K3'));
      await tester.pumpAndSettle();
      expect(picked, ['moonshotai/kimi-k3']);
    });

    testWidgets('the second menu offers the way to the model screen', (
      tester,
    ) async {
      var opened = 0;
      await _pump(
        tester,
        mode: ChatMode.fast,
        selectedModelId: 'a/b',
        modelLabel: 'Model B',
        pickedModels: const [ChatModelChoice(id: 'a/b', name: 'Model B')],
        onModelSelected: (_) {},
        onOpenModelScreen: () => opened++,
      );

      await tester.tap(find.text('Fast'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Model B'));
      await tester.pumpAndSettle();

      expect(find.text('More models'), findsOneWidget);
      await tester.tap(find.text('More models'));
      await tester.pumpAndSettle();
      expect(opened, 1);
    });

    testWidgets('with nothing picked yet it goes straight to the screen', (
      tester,
    ) async {
      var opened = 0;
      await _pump(
        tester,
        mode: ChatMode.fast,
        modelLabel: 'Model B',
        onModelSelected: (_) {},
        onOpenModelScreen: () => opened++,
      );

      await tester.tap(find.text('Fast'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Model B'));
      await tester.pumpAndSettle();

      expect(opened, 1);
    });

    testWidgets('without any model callback that row is absent', (
      tester,
    ) async {
      await _pump(tester, mode: ChatMode.fast);

      await tester.tap(find.text('Fast'));
      await tester.pumpAndSettle();

      expect(find.text('Choose model'), findsNothing);
    });
  });
}
