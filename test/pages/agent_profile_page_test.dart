import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/pages/agent_profile_page.dart';
import 'package:chuk_chat/pages/coworker_model_page.dart';
import 'package:chuk_chat/services/agents/agent_profile_store.dart';
import 'package:chuk_chat/services/agents/agent_roster_source.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/agents/coworker_model.dart';
import 'package:chuk_chat/services/chat_model_selection_service.dart';
import 'package:chuk_chat/services/model_capabilities_service.dart';
import 'package:chuk_chat/ui/expressive/agent_face.dart';

import '../support/fake_relay_controller.dart';
import '../support/kv_cache_test_env.dart';
import '../support/test_app.dart';

void main() {
  // The page runs under chuk's floating header. The header band grows by the
  // status bar, so the face must clear the band at every status-bar height,
  // not only at the zero a test gets by default.
  for (final double statusBar in <double>[0, 24, 48]) {
    testWidgets('the floating header does not cover the face with a '
        '${statusBar.toInt()} px status bar', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = FakeViewPadding(top: statusBar);
      tester.view.viewPadding = FakeViewPadding(top: statusBar);
      addTearDown(tester.view.reset);
      final store = AgentProfileStore();
      final source = LocalAgentRosterSource(
        seed: <AgentsAgent>[
          const AgentsAgent(id: 'alex', name: 'Alex', threads: []),
        ],
      );
      addTearDown(store.dispose);
      addTearDown(source.dispose);

      await tester.pumpWidget(
        testApp(
          AgentProfilePage(agentId: 'alex', source: source, profiles: store),
        ),
      );
      await tester.pumpAndSettle();

      final Rect header = tester.getRect(find.byType(AppBar));
      final Rect face = tester.getRect(find.byType(AgentFace));
      expect(header.bottom, 62 + statusBar);
      expect(face.top, greaterThanOrEqualTo(header.bottom));
      expect(tester.takeException(), isNull);
    });
  }

  group('model', () {
    late Directory kv;
    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      ChatModelSelectionService.instance.clearMemoryForTesting();
      CoworkerModel.debugCatalogue = () async =>
          const <CoworkerCatalogueModel>[
            CoworkerCatalogueModel(
              id: 'z-ai/glm-5.3-flash',
              name: 'Z.ai: GLM 5.3 Flash',
              providers: <CoworkerProvider>[
                CoworkerProvider(
                  slug: 'runanywhere/serverless',
                  name: 'RunAnywhere',
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

    testWidgets('the profile names what the coworker runs on and opens its '
        'model page', (tester) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await ChatModelSelectionService.instance.save(
        'host:alex',
        const ChatModelSelection(
          modelId: 'z-ai/glm-5.3-flash',
          providerSlug: 'runanywhere/serverless',
          reasoningEffort: 'low',
        ),
      );
      final store = AgentProfileStore();
      final source = LocalAgentRosterSource(
        seed: <AgentsAgent>[
          const AgentsAgent(
            id: 'alex',
            name: 'Alex',
            threads: <AgentsThreadInfo>[
              AgentsThreadInfo(key: 'host:alex', title: 'General'),
            ],
          ),
        ],
      );
      addTearDown(store.dispose);
      addTearDown(source.dispose);

      await tester.pumpWidget(
        testApp(
          AgentProfilePage(agentId: 'alex', source: source, profiles: store),
        ),
      );
      await tester.pumpAndSettle();

      final Finder tile = find.byKey(
        const ValueKey<String>('agent_profile_model'),
      );
      expect(tile, findsOneWidget);
      expect(
        find.descendant(
          of: tile,
          matching: find.text('RunAnywhere · Reasoning low'),
        ),
        findsOneWidget,
      );
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(find.byType(CoworkerModelPage), findsOneWidget);
    });

    testWidgets('a coworker without a thread shows no model row', (
      tester,
    ) async {
      final store = AgentProfileStore();
      final source = LocalAgentRosterSource(
        seed: <AgentsAgent>[
          const AgentsAgent(id: 'alex', name: 'Alex', threads: []),
        ],
      );
      addTearDown(store.dispose);
      addTearDown(source.dispose);
      await tester.pumpWidget(
        testApp(
          AgentProfilePage(agentId: 'alex', source: source, profiles: store),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('agent_profile_model')),
        findsNothing,
      );
    });
  });

  // Bead chuk_chat-89vl: the row said "it lives in this app only" for a
  // coworker created in the app that the host keeps and runs (Wahlradar).
  group('runs on the host', () {
    const String localId = 'local:brisk-heron:2:116636868';
    late FakeRelayController controller;

    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      AgentsRelayLink.instance.reset();
      controller = FakeRelayController();
    });

    tearDown(() async {
      AgentsRelayLink.instance.reset();
      await controller.dispose();
    });

    void paired() {
      controller.set(
        const AgentsRelayState(
          phase: AgentsRelayPhase.paired,
          peerDeviceId: 'laptop',
        ),
      );
      AgentsRelayLink.instance.bind(controller);
    }

    Future<String> hostRow(WidgetTester tester, AgentsAgent agent) async {
      tester.view.physicalSize = const Size(400, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final store = AgentProfileStore();
      final source = LocalAgentRosterSource(seed: <AgentsAgent>[agent]);
      addTearDown(store.dispose);
      addTearDown(source.dispose);
      await tester.pumpWidget(
        testApp(
          AgentProfilePage(agentId: agent.id, source: source, profiles: store),
        ),
      );
      await tester.pumpAndSettle();
      final Finder row = find.byKey(
        const ValueKey<String>('agent_profile_host'),
      );
      expect(row, findsOneWidget);
      return find
          .descendant(of: row, matching: find.byType(Text))
          .evaluate()
          .map((Element e) => (e.widget as Text).data ?? '')
          .join(' | ');
    }

    AgentsAgent wahlradar({bool knownToHost = false}) => AgentsAgent(
      id: localId,
      name: 'Wahlradar',
      knownToHost: knownToHost,
      threads: const <AgentsThreadInfo>[
        AgentsThreadInfo(key: localId, title: 'General'),
      ],
    );

    testWidgets('an app-made coworker the host keeps runs on the host', (
      tester,
    ) async {
      paired();
      final String text = await hostRow(tester, wahlradar(knownToHost: true));
      expect(text, contains('runs on the paired host'));
      expect(text, isNot(contains('this app only')));
    });

    testWidgets('the host offline is said, not "app only"', (tester) async {
      // No controller bound: the link is down.
      final String text = await hostRow(tester, wahlradar(knownToHost: true));
      expect(text, contains('offline right now'));
      expect(text, isNot(contains('this app only')));
    });

    testWidgets('a link that is not paired counts as offline', (tester) async {
      AgentsRelayLink.instance.bind(controller); // idle, not paired
      final String text = await hostRow(tester, wahlradar());
      expect(text, contains('Not confirmed'));
      expect(text, isNot(contains('this app only')));
    });

    testWidgets('"this app only" only while the host is up and does not '
        'know it', (tester) async {
      paired();
      final String text = await hostRow(tester, wahlradar());
      expect(text, contains('lives in this app only'));
    });

    testWidgets('the row follows the link going down', (tester) async {
      paired();
      expect(
        await hostRow(tester, wahlradar(knownToHost: true)),
        contains('runs on the paired host'),
      );
      controller.set(const AgentsRelayState(phase: AgentsRelayPhase.closed));
      await tester.pumpAndSettle();
      expect(find.textContaining('offline right now'), findsOneWidget);
    });

    test('the host listing a coworker marks it as known to the host', () {
      final source = LocalAgentRosterSource(seed: <AgentsAgent>[wahlradar()]);
      addTearDown(source.dispose);
      source.applyHostNames(
        const <AgentsHostAgentName>[
          AgentsHostAgentName(agentId: localId, name: 'Wahlradar'),
        ],
        peerDeviceId: 'laptop',
      );
      final AgentsAgent agent = source.byId(localId)!;
      expect(agent.knownToHost, isTrue);
      expect(agent.runsOnHost, isTrue);
      // Still not the host's own coworker: delete stays available.
      expect(agent.onHost, isFalse);
    });

    test('a host run marks the coworker as known to the host', () {
      final source = LocalAgentRosterSource(seed: <AgentsAgent>[wahlradar()]);
      addTearDown(source.dispose);
      var notified = 0;
      source.addListener(() => notified++);
      source.markKnownToHost(localId);
      source.markKnownToHost(localId);
      expect(source.byId(localId)!.runsOnHost, isTrue);
      expect(notified, 1);
    });
  });
}
