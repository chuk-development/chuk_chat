// The composer of a coworker's thread shows and changes the coworker's own
// model — the same record its profile edits — and never the account-wide
// mode. A plain chat keeps the account-wide behaviour.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/platform_specific/chat/chat_model_selection_mixin.dart';
import 'package:chuk_chat/platform_specific/chat/model_provider_resolution_mixin.dart';
import 'package:chuk_chat/services/agents/coworker_model.dart';
import 'package:chuk_chat/services/chat_mode_service.dart';
import 'package:chuk_chat/services/chat_model_selection_service.dart';
import 'package:chuk_chat/services/model_capabilities_service.dart';

import '../support/kv_cache_test_env.dart';

const String _chat = 'host:alex';
const String _pro = 'deepseek/deepseek-v4-pro-0813';

class _Composer extends StatefulWidget {
  const _Composer({super.key, required this.coworkerThread});
  final bool coworkerThread;
  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer>
    with ModelProviderResolutionMixin, ChatModelSelectionMixin {
  @override
  String? get activeChatId => _chat;

  @override
  bool get skipRepeatedModelSave => widget.coworkerThread;

  // The catalogue names and the picked-model menu read Supabase and the
  // disk cache; neither is what this test is about.
  @override
  Future<void> refreshSelectedModelName([String? modelId]) async {}
  @override
  Future<void> refreshCustomModelName() async {}
  @override
  Future<void> refreshPickedModels() async {}

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

void main() {
  late Directory kv;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    ChatModelSelectionService.instance.clearMemoryForTesting();
    CoworkerModel.debugCatalogue = () async => const <CoworkerCatalogueModel>[
      CoworkerCatalogueModel(
        id: _pro,
        name: 'DeepSeek: V4 Pro',
        providers: <CoworkerProvider>[
          CoworkerProvider(
            slug: 'expensive/one',
            name: 'Expensive',
            completionPrice: 0.00001,
          ),
          CoworkerProvider(
            slug: 'cheap/one',
            name: 'Cheap',
            completionPrice: 0.000001,
          ),
        ],
      ),
    ];
    kv = await useTempKvCache();
    await ModelCapabilitiesService.initialize();
  });
  tearDown(() async {
    CoworkerModel.debugCatalogue = null;
    await disposeTempKvCache(kv);
  });

  Future<_ComposerState> mount(
    WidgetTester tester, {
    bool coworkerThread = true,
  }) async {
    final key = GlobalKey<_ComposerState>();
    await tester.pumpWidget(
      MaterialApp(
        home: _Composer(key: key, coworkerThread: coworkerThread),
      ),
    );
    await key.currentState!.restoreChatMode();
    await tester.pump();
    return key.currentState!;
  }

  testWidgets('the composer shows the coworker s own model, named', (
    tester,
  ) async {
    await ChatModelSelectionService.instance.save(
      _chat,
      const ChatModelSelection(
        modelId: _pro,
        providerSlug: 'cheap/one',
        reasoningEffort: 'high',
      ),
    );
    final composer = await mount(tester);
    expect(composer.chatMode, ChatMode.custom);
    expect(composer.selectedModelId, _pro);
    expect(composer.selectedProviderSlug, 'cheap/one');
    expect(composer.reasoningEffort, 'high');
    // The account-wide mode is not touched by showing it.
    expect(await ChatModeService.load(), ChatMode.fast);
  });

  testWidgets('a model picked in the composer becomes the coworker s own', (
    tester,
  ) async {
    final composer = await mount(tester);
    expect(composer.chatMode, ChatMode.fast);

    await composer.applyModelSelection(_pro);
    await tester.pump();

    final own = await ChatModelSelectionService.instance.load(_chat);
    expect(own!.modelId, _pro);
    expect(own.providerSlug, 'cheap/one');
    expect(composer.selectedModelId, _pro);
    expect(composer.chatMode, ChatMode.custom);
    // Not written to the account-wide Custom slot or mode.
    expect(await ChatModeService.load(), ChatMode.fast);
    expect(await ChatModeService.hasStoredConfig(ChatMode.custom), isFalse);
  });

  testWidgets('a reasoning level picked in the composer is the coworker s', (
    tester,
  ) async {
    final composer = await mount(tester);
    final before = await ChatModeService.loadConfig(ChatMode.fast);

    await composer.setReasoningEffort('high');
    await tester.pump();

    final own = await ChatModelSelectionService.instance.load(_chat);
    expect(own!.modelId, before.modelId);
    expect(own.providerSlug, before.providerSlug);
    expect(own.reasoningEffort, 'high');
    expect(composer.reasoningEffort, 'high');
    expect(
      (await ChatModeService.loadConfig(ChatMode.fast)).reasoningEffort,
      before.reasoningEffort,
    );
  });

  testWidgets('Fast in a coworker s composer goes back to the app default', (
    tester,
  ) async {
    await ChatModelSelectionService.instance.save(
      _chat,
      const ChatModelSelection(modelId: _pro, providerSlug: 'cheap/one'),
    );
    final composer = await mount(tester);
    expect(composer.chatMode, ChatMode.custom);

    await composer.setChatMode(ChatMode.fast);
    await tester.pump();

    expect(await ChatModelSelectionService.instance.load(_chat), isNull);
    expect(composer.chatMode, ChatMode.fast);
    expect(
      composer.selectedModelId,
      (await ChatModeService.loadConfig(ChatMode.fast)).modelId,
    );
  });

  testWidgets('the profile dropping the own model puts the default back in '
      'an open composer', (tester) async {
    await ChatModelSelectionService.instance.save(
      _chat,
      const ChatModelSelection(modelId: _pro, providerSlug: 'cheap/one'),
    );
    final composer = await mount(tester);
    expect(composer.selectedModelId, _pro);

    await CoworkerModel.useDefault(_chat);
    await composer.syncChatScopedModel();
    await tester.pump();

    expect(composer.chatMode, ChatMode.fast);
    expect(composer.selectedModelId, isNot(_pro));
  });

  testWidgets('a plain chat keeps the account-wide model', (tester) async {
    final composer = await mount(tester, coworkerThread: false);
    expect(composer.modelSelectionChatId, isNull);

    await composer.applyModelSelection(_pro);
    await tester.pump();

    expect(await ChatModelSelectionService.instance.load(_chat), isNull);
    expect(await ChatModeService.load(), ChatMode.custom);
  });
}
