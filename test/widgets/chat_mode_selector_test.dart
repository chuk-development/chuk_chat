// Tests for the composer's mode control: what it shows, what the level-1
// menu offers (only the two modes plus the way deeper), and what the deeper
// menu offers (reasoning levels, the picked models, and the way out to the
// full model screen).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/chat_mode_service.dart';
import 'package:chuk_chat/services/chat_profile_service.dart';
import 'package:chuk_chat/services/model_cache_service.dart';
import 'package:chuk_chat/widgets/chat_mode_selector.dart';
import 'package:chuk_chat/widgets/icons/model_logo.dart';

import '../support/kv_cache_test_env.dart';
import '../helpers/icon_finder.dart';

// Fireworks levels, the common case in the composer.
const _fireworksLevels = <String>['none', 'low', 'high'];

Future<void> _pump(
  WidgetTester tester, {
  ChatMode mode = ChatMode.custom,
  ValueChanged<ChatMode>? onModeChanged,
  ValueChanged<String>? onModelSelected,
  String reasoningEffort = 'none',
  List<String> reasoningLevels = _fireworksLevels,
  ValueChanged<String>? onReasoningEffortChanged,
  VoidCallback? onOpenModelScreen,
  String? selectedModelId,
  String? modelLabel,
  List<ChatModelChoice> pickedModels = const <ChatModelChoice>[],
  String? standardDetail,
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
            standardDetail: standardDetail,
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('mode semantics', () {
    test('a fresh install starts on standard', () {
      expect(ChatModeService.fallbackMode, ChatMode.standard);
    });

    test('each mode carries its own model, provider and reasoning', () {
      ChatProfileService.resetForTest();
      final standard = ChatModeService.defaultConfig(ChatMode.standard);
      expect(standard.modelId, ChatProfileService.standardModelId);
      expect(standard.providerSlug, 'profile:standard');
      expect(standard.reasoningEffort, 'low');

      final custom = ChatModeService.defaultConfig(ChatMode.custom);
      expect(custom.modelId, 'z-ai/glm-5.3-flash');
      expect(custom.providerSlug, 'fireworks/serverless');
      expect(custom.reasoningEffort, 'none');
    });

    test('an unknown stored value falls back instead of throwing', () {
      expect(ChatModeService.parse('fast'), ChatMode.standard);
      expect(ChatModeService.parse('thinking'), ChatMode.standard);
      expect(ChatModeService.parse('custom'), ChatMode.custom);
      expect(ChatModeService.parse('turbo'), ChatModeService.fallbackMode);
      expect(ChatModeService.parse(null), ChatModeService.fallbackMode);
    });

    test('labels and descriptions', () {
      expect(ChatModeSelector.labelFor(ChatMode.standard), 'Standard');
      expect(ChatModeSelector.labelFor(ChatMode.custom), 'Custom model');
      expect(
        ChatModeSelector.descriptionFor(ChatMode.standard),
        'Best value, picked by us',
      );
    });
  });

  group('mode persistence', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('a fresh install starts on the fallback mode', () async {
      expect(await ChatModeService.load(), ChatModeService.fallbackMode);
    });

    test('a saved mode comes back', () async {
      await ChatModeService.save(ChatMode.custom);
      expect(await ChatModeService.load(), ChatMode.custom);

      await ChatModeService.save(ChatMode.standard);
      expect(await ChatModeService.load(), ChatMode.standard);
    });
  });

  group('model display name', () {
    late Directory tempDir;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      tempDir = await useTempKvCache();
    });
    tearDown(() async => disposeTempKvCache(tempDir));

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
      await _pump(tester, mode: ChatMode.standard);

      expect(find.text('Standard'), findsOneWidget);
      expect(findIcon(Icons.bolt), findsOneWidget);
      expect(find.text('Custom model'), findsNothing);
    });

    testWidgets('opens a menu with Standard and the Custom point, current '
        'ticked', (tester) async {
      await _pump(
        tester,
        mode: ChatMode.standard,
        onModelSelected: (_) {},
        onOpenModelScreen: () {},
      );

      await tester.tap(find.text('Standard'));
      await tester.pumpAndSettle();

      expect(find.text('Standard'), findsNWidgets(2)); // pill + menu row
      expect(find.text('Choose model'), findsOneWidget);
      expect(findIcon(Icons.check), findsOneWidget);
    });

    testWidgets('shows the standard detail line only when given', (
      tester,
    ) async {
      await _pump(
        tester,
        mode: ChatMode.standard,
        onOpenModelScreen: () {},
        standardDetail: 'DeepSeek V4.1 Flash · Wafer → Ionstream',
      );
      await tester.tap(find.text('Standard'));
      await tester.pumpAndSettle();
      expect(
        find.text('DeepSeek V4.1 Flash · Wafer → Ionstream'),
        findsOneWidget,
      );
    });

    testWidgets('has no detail line without standardDetail', (tester) async {
      await _pump(tester, mode: ChatMode.standard, onOpenModelScreen: () {});
      await tester.tap(find.text('Standard'));
      await tester.pumpAndSettle();
      expect(find.textContaining('·'), findsNothing);
    });

    testWidgets('has no reasoning row at level 1', (tester) async {
      await _pump(
        tester,
        mode: ChatMode.standard,
        onReasoningEffortChanged: (_) {},
      );

      await tester.tap(find.text('Standard'));
      await tester.pumpAndSettle();

      // Reasoning lives one level deeper now, not on the pill menu.
      expect(find.text('REASONING'), findsNothing);
      expect(find.text('Low'), findsNothing);
    });

    testWidgets('picking Standard from Custom reports it once', (tester) async {
      final picked = <ChatMode>[];
      await _pump(
        tester,
        mode: ChatMode.custom,
        onModeChanged: picked.add,
        onOpenModelScreen: () {},
      );

      await tester.tap(find.text('Custom model'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Standard'));
      await tester.pumpAndSettle();

      expect(picked, [ChatMode.standard]);
    });

    testWidgets('picking the mode already active changes nothing', (
      tester,
    ) async {
      final picked = <ChatMode>[];
      await _pump(
        tester,
        mode: ChatMode.standard,
        onModeChanged: picked.add,
        onOpenModelScreen: () {},
      );

      await tester.tap(find.text('Standard'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Standard').last);
      await tester.pumpAndSettle();

      expect(picked, isEmpty);
    });

    testWidgets('under Standard the third point stays neutral, not the model', (
      tester,
    ) async {
      await _pump(
        tester,
        mode: ChatMode.standard,
        selectedModelId: 'deepseek/deepseek-v4-flash',
        modelLabel: 'DeepSeek: V4 Flash',
        onModelSelected: (_) {},
      );

      await tester.tap(find.text('Standard'));
      await tester.pumpAndSettle();
      // Standard runs what the server picked — the composer never surfaces
      // the model here. The third point is the neutral Custom entry.
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

      await tester.tap(findIcon(Icons.tune).first);
      await tester.pumpAndSettle();
      // In Custom the third point is the chosen model, lab prefix stripped.
      expect(find.text('V4 Flash'), findsWidgets);
      expect(find.text('Choose model'), findsNothing);
    });

    testWidgets('with no deeper handlers there is no opener row', (
      tester,
    ) async {
      await _pump(tester, mode: ChatMode.standard);

      await tester.tap(find.text('Standard'));
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
        mode: ChatMode.custom,
        reasoningEffort: 'high',
        onReasoningEffortChanged: levels.add,
        onOpenModelScreen: () {},
      );

      await tester.tap(find.text('Custom model'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose model'));
      await tester.pumpAndSettle();

      // Reasoning is a submenu opener now, not the inline ladder.
      expect(find.text('Reasoning'), findsOneWidget);
      expect(find.text('REASONING'), findsNothing);

      await tester.tap(find.text('Reasoning'));
      await tester.pumpAndSettle();

      // The reasoning ladder for a Fireworks provider, in the cascade. The
      // current level (High) also shows as the row's value, hence two.
      expect(find.text('REASONING'), findsOneWidget);
      expect(find.text('Off'), findsOneWidget);
      expect(find.text('Low'), findsOneWidget);
      expect(find.text('High'), findsWidgets);

      await tester.tap(find.text('Low'));
      await tester.pumpAndSettle();
      expect(levels, ['low']);
    });

    testWidgets('picking the active level reports nothing', (tester) async {
      final levels = <String>[];
      await _pump(
        tester,
        mode: ChatMode.custom,
        reasoningEffort: 'high',
        onReasoningEffortChanged: levels.add,
        onOpenModelScreen: () {},
      );

      await tester.tap(find.text('Custom model'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose model'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reasoning'));
      await tester.pumpAndSettle();
      // 'Medium' also shows as the opener's trailing label; the cascade row
      // is the later one.
      await tester.tap(find.text('High').last);
      await tester.pumpAndSettle();

      expect(levels, isEmpty);
    });

    testWidgets('lists the picked models and reports the pick', (tester) async {
      final picked = <String>[];
      await _pump(
        tester,
        mode: ChatMode.standard,
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

      await tester.tap(find.text('Standard'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose model')); // third point → deeper menu
      await tester.pumpAndSettle();

      expect(find.text('Kimi K3'), findsOneWidget);
      await tester.tap(find.text('Kimi K3'));
      await tester.pumpAndSettle();
      expect(picked, ['moonshotai/kimi-k3']);
    });

    testWidgets(
      'each model row carries its lab logo, an unknown lab an empty slot',
      (tester) async {
        await _pump(
          tester,
          mode: ChatMode.custom,
          reasoningLevels: const ['none'],
          selectedModelId: 'deepseek/deepseek-v4-flash',
          modelLabel: 'DeepSeek: V4 Flash',
          pickedModels: const [
            ChatModelChoice(
              id: 'deepseek/deepseek-v4-flash',
              name: 'DeepSeek: V4 Flash',
            ),
            ChatModelChoice(
              id: 'moonshotai/kimi-k3',
              name: 'Moonshot: Kimi K3',
            ),
            ChatModelChoice(id: 'acme/foo-1', name: 'Acme: Foo 1'),
          ],
          onModelSelected: (_) {},
          onOpenModelScreen: () {},
        );

        await tester.tap(find.text('V4 Flash')); // the pill
        await tester.pumpAndSettle();
        await tester.tap(find.text('V4 Flash').last); // third point
        await tester.pumpAndSettle();

        Finder rowOf(String label) => find
            .ancestor(of: find.text(label).last, matching: find.byType(Row))
            .first;
        Finder logoIn(String label) =>
            find.descendant(of: rowOf(label), matching: find.byType(ModelLogo));
        // The logo's own picture; the tick on the chosen row is one too.
        Finder pictureIn(String label) => find.descendant(
          of: logoIn(label),
          matching: find.byType(SvgPicture),
        );

        // A known lab draws its logo, tinted like the row's name: full for
        // the model in use, a step back for the rest.
        for (final label in const ['V4 Flash', 'Kimi K3']) {
          expect(logoIn(label), findsOneWidget, reason: label);
          expect(pictureIn(label), findsOneWidget, reason: label);
          final Color? nameColor = tester
              .widget<Text>(
                find.descendant(of: rowOf(label), matching: find.text(label)),
              )
              .style
              ?.color;
          expect(
            tester.widget<SvgPicture>(pictureIn(label)).colorFilter,
            ColorFilter.mode(nameColor!, BlendMode.srcIn),
            reason: label,
          );
        }

        // An unknown lab keeps the slot, empty.
        expect(logoIn('Foo 1'), findsOneWidget);
        expect(pictureIn('Foo 1'), findsNothing);
        expect(tester.getSize(logoIn('Foo 1')), const Size(18, 18));

        // So every name starts at the same x, and lines up with the row
        // below that carries an icon.
        final double nameX = tester.getTopLeft(find.text('Kimi K3')).dx;
        expect(tester.getTopLeft(find.text('Foo 1')).dx, nameX);
        expect(tester.getTopLeft(find.text('V4 Flash').last).dx, nameX);
        expect(tester.getTopLeft(find.text('More models')).dx, nameX);
      },
    );

    testWidgets('the deeper menu reaches the full model screen', (
      tester,
    ) async {
      var opened = 0;
      await _pump(
        tester,
        mode: ChatMode.standard,
        reasoningLevels: const ['none'],
        selectedModelId: 'a/b',
        modelLabel: 'Model B',
        pickedModels: const [ChatModelChoice(id: 'a/b', name: 'Model B')],
        onModelSelected: (_) {},
        onOpenModelScreen: () => opened++,
      );

      await tester.tap(find.text('Standard'));
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
          mode: ChatMode.standard,
          reasoningLevels: const ['none'], // off only → no reasoning choice
          modelLabel: 'Model B',
          onModelSelected: (_) {},
          onOpenModelScreen: () => opened++,
        );

        await tester.tap(find.text('Standard'));
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
