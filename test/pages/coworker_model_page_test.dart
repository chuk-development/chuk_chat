import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/pages/coworker_model_page.dart';
import 'package:chuk_chat/services/agents/agent_control_source.dart';
import 'package:chuk_chat/services/agents/coworker_model.dart';
import 'package:chuk_chat/services/chat_model_selection_service.dart';
import 'package:chuk_chat/services/model_capabilities_service.dart';
import 'package:chuk_chat/ui/expressive/connected_group.dart';

import '../support/kv_cache_test_env.dart';

const String _chat = 'host:alex';

const List<CoworkerCatalogueModel> _catalogue = <CoworkerCatalogueModel>[
  CoworkerCatalogueModel(
    id: 'z-ai/glm-5.3-flash',
    name: 'Z.ai: GLM 5.3 Flash',
    providers: <CoworkerProvider>[
      CoworkerProvider(
        slug: 'fireworks/serverless',
        name: 'Fireworks',
        promptPrice: 0.0000002,
        completionPrice: 0.0000008,
        contextLength: 131072,
      ),
      CoworkerProvider(
        slug: 'runanywhere/serverless',
        name: 'RunAnywhere',
        promptPrice: 0.0000001,
        completionPrice: 0.0000004,
        contextLength: 131072,
      ),
    ],
  ),
  CoworkerCatalogueModel(
    id: 'deepseek/deepseek-v4-pro-0813',
    name: 'DeepSeek: V4 Pro',
    providers: <CoworkerProvider>[
      CoworkerProvider(
        slug: 'fireworks/serverless',
        name: 'Fireworks',
        promptPrice: 0.0000005,
        completionPrice: 0.000002,
      ),
    ],
  ),
];

Future<void> _pump(
  WidgetTester tester, {
  AgentControlSource? source,
  Size size = const Size(420, 900),
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: size,
          textScaler: TextScaler.linear(textScale),
        ),
        child: CoworkerModelPage(
          chatId: _chat,
          coworkerName: 'Alex',
          controlSource: source,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  late Directory kv;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    ChatModelSelectionService.instance.clearMemoryForTesting();
    CoworkerModel.debugCatalogue = () async => _catalogue;
    // The mode store reads the capability cache before it answers. Warm it
    // here, in the real zone: a testWidgets body never drains real disk IO.
    kv = await useTempKvCache();
    await ModelCapabilitiesService.initialize();
  });
  tearDown(() async {
    CoworkerModel.debugCatalogue = null;
    await disposeTempKvCache(kv);
  });

  testWidgets('a coworker with no model of its own says it follows the app '
      'default, and picking a provider gives it its own', (tester) async {
    await _pump(tester);

    expect(find.text('App default · Fast'), findsOneWidget);
    expect(find.textContaining('follows the app default'), findsOneWidget);
    expect(find.text('Use the app default'), findsNothing);
    // The provider list names providers and prices, never raw slugs.
    expect(find.text('RunAnywhere'), findsOneWidget);
    expect(find.text('Cheapest'), findsOneWidget);
    expect(find.textContaining('runanywhere/serverless'), findsNothing);

    await _tapVisible(
      tester,
      find.byKey(
        const ValueKey<String>('coworker_provider_runanywhere/serverless'),
      ),
    );

    final own = await ChatModelSelectionService.instance.load(_chat);
    expect(own, isNotNull);
    expect(own!.modelId, 'z-ai/glm-5.3-flash');
    expect(own.providerSlug, 'runanywhere/serverless');
    expect(own.reasoningEffort, 'low');
    expect(find.text('Own choice for Alex'), findsOneWidget);
    expect(find.text('via RunAnywhere · Reasoning low'), findsOneWidget);
    expect(
      find.text('Next message: GLM 5.3 Flash via RunAnywhere'),
      findsOneWidget,
    );
  });

  testWidgets('the reasoning level is the coworker s own', (tester) async {
    await _pump(tester);
    final Finder group = find.byKey(
      const ValueKey<String>('coworker_reasoning'),
    );
    await tester.scrollUntilVisible(
      group,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(tester.widget<ConnectedGroup>(group).labels, <String>[
      'Off',
      'Low',
      'High',
    ]);
    await tester.tap(find.descendant(of: group, matching: find.text('High')));
    await tester.pumpAndSettle();

    final own = await ChatModelSelectionService.instance.load(_chat);
    expect(own!.reasoningEffort, 'high');
    expect(own.modelId, 'z-ai/glm-5.3-flash');
    expect(own.providerSlug, 'fireworks/serverless');
  });

  testWidgets('a model picked on the page starts on its cheapest provider', (
    tester,
  ) async {
    await _pump(tester);
    await _tapVisible(
      tester,
      find.byKey(
        const ValueKey<String>('coworker_model_deepseek/deepseek-v4-pro-0813'),
      ),
    );
    final own = await ChatModelSelectionService.instance.load(_chat);
    expect(own!.modelId, 'deepseek/deepseek-v4-pro-0813');
    expect(own.providerSlug, 'fireworks/serverless');
  });

  testWidgets('use the app default drops the own model', (tester) async {
    await ChatModelSelectionService.instance.save(
      _chat,
      const ChatModelSelection(
        modelId: 'deepseek/deepseek-v4-pro-0813',
        providerSlug: 'fireworks/serverless',
        reasoningEffort: 'high',
      ),
    );
    await _pump(tester);
    expect(find.text('Own choice for Alex'), findsOneWidget);

    await _tapVisible(
      tester,
      find.byKey(const ValueKey<String>('coworker_model_use_default')),
    );

    expect(await ChatModelSelectionService.instance.load(_chat), isNull);
    expect(find.text('App default · Fast'), findsOneWidget);
  });

  testWidgets('the last run is shown, and a change not yet run says when it '
      'applies', (tester) async {
    await ChatModelSelectionService.instance.save(
      _chat,
      const ChatModelSelection(
        modelId: 'z-ai/glm-5.3-flash',
        providerSlug: 'runanywhere/serverless',
        reasoningEffort: 'low',
      ),
    );
    final source = FakeAgentControlSource(
      initial: const AgentControlSnapshot(
        model: ControlAvailable<AgentModelChoice>(
          AgentModelChoice(
            id: 'z-ai/glm-5.3-flash',
            provider: 'fireworks/serverless',
            reasoningEffort: 'low',
          ),
        ),
      ),
    );
    addTearDown(source.dispose);
    await _pump(tester, source: source);

    expect(source.refreshed, <String>[_chat]);
    expect(find.text('Last run'), findsOneWidget);
    expect(
      find.text(
        'GLM 5.3 Flash via Fireworks · low\n'
        'Your change applies from the next message.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('fits a 360 px phone at 1.3 text scale', (tester) async {
    await _pump(tester, size: const Size(360, 740), textScale: 1.3);
    expect(tester.takeException(), isNull);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -2000));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
