import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/pages/agent_model_page.dart';
import 'package:chuk_chat/pages/mobile_agents_settings_page.dart';
import 'package:chuk_chat/services/agents/agent_profile_store.dart';
import 'package:chuk_chat/services/agents/agent_roster_source.dart';
import 'package:chuk_chat/services/agents/agent_model.dart';
import 'package:chuk_chat/services/chat_model_selection_service.dart';
import 'package:chuk_chat/services/model_capabilities_service.dart';
import 'package:chuk_chat/services/settings/mobile_chat_preferences.dart';
import 'package:chuk_chat/widgets/agent_model_tile.dart';
import 'package:chuk_chat/widgets/floating_app_bar.dart';
import 'package:chuk_chat/widgets/settings_list_view.dart';

import '../support/kv_cache_test_env.dart';
import '../support/test_app.dart';

void main() {
  late LocalAgentRosterSource source;
  late AgentProfileStore profiles;
  late MobileChatPreferences preferences;
  late Map<String, int> taps;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    source = LocalAgentRosterSource(
      seed: [const AgentsAgent(id: 'alex', name: 'Alex', threads: [])],
    );
    profiles = AgentProfileStore();
    preferences = MobileChatPreferences();
    taps = {};
  });
  tearDown(() {
    source.dispose();
    profiles.dispose();
    preferences.dispose();
  });

  void tap(String key) =>
      taps.update(key, (value) => value + 1, ifAbsent: () => 1);

  Widget page({bool optional = false, String? chatId}) =>
      MobileAgentsSettingsPage(
        agentId: 'alex',
        chatId: chatId,
        source: source,
        profiles: profiles,
        preferences: preferences,
        onEdit: () => tap('profile'),
        onControls: () => tap('host'),
        onModel: () => tap('model'),
        onAutomations: () => tap('automations'),
        onSkills: () => tap('skills'),
        onConnectors: () => tap('connectors'),
        onSecrets: () => tap('secrets'),
        onRooms: () => tap('rooms'),
        onSettings: () => tap('settings'),
        onDocuments: optional ? () => tap('files') : null,
        onCopyChat: optional ? () => tap('export') : null,
        onBrowser: optional ? () => tap('browser') : null,
        onDelete: optional ? () => tap('delete') : null,
        onChat: () => tap('chat'),
      );

  Future<void> smallPhone(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(testApp(child));
    await tester.pumpAndSettle();
  }

  Future<void> reveal(WidgetTester tester, String label) async {
    await tester.scrollUntilVisible(
      find.text(label),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
  }

  Future<void> revealControl(WidgetTester tester, Finder finder) async {
    // The settings list builds every row up front, so a row below the
    // viewport already exists; existence alone is not visibility.
    for (
      var attempts = 0;
      finder.hitTestable().evaluate().isEmpty && attempts < 40;
      attempts++
    ) {
      await tester.drag(find.byType(SettingsListView), const Offset(0, -160));
      await tester.pumpAndSettle();
    }
    expect(finder.hitTestable(), findsOneWidget);
  }

  /// The switch inside a keyed switch row.
  Finder switchOf(Finder row) =>
      find.descendant(of: row, matching: find.byType(Switch));

  /// The page pushed over a starting route, so it has somewhere to go back to.
  Widget pushed({bool optional = false}) => Builder(
    builder: (context) => Scaffold(
      body: TextButton(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => page(optional: optional)),
        ),
        child: const Text('Open settings'),
      ),
    ),
  );

  testWidgets('quiet defaults and persisted switches fit a small phone', (
    tester,
  ) async {
    // Keep the serialized writer in the widget test's async zone.
    preferences.dispose();
    preferences = MobileChatPreferences();
    await smallPhone(tester, page());
    // The messenger-typography switch is gone: the chat draws chuk_chat's
    // type, so the switch had nothing left to change.
    expect(find.text('Messenger typography'), findsNothing);
    for (final id in ['mobile_show_thinking', 'mobile_show_activity']) {
      final finder = find.byKey(ValueKey(id));
      await revealControl(tester, finder);
      expect(tester.widget<Switch>(switchOf(finder)).value, isFalse);
      await tester.tap(finder);
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(switchOf(finder)).value, isTrue);
    }
    final stored = await SharedPreferences.getInstance();
    expect(stored.getBool(MobileChatPreferences.reasoningKey), isTrue);
    expect(stored.getBool(MobileChatPreferences.activityKey), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'destinations call the supplied actions and optional actions hide',
    (tester) async {
      await smallPhone(tester, page());
      expect(find.text('Shared files'), findsNothing);
      expect(find.text('Open screen'), findsNothing);
      expect(find.text('Remove agent'), findsNothing);
      // In page order: what the agent is, what it may do, its computer,
      // the app.
      for (final entry in {
        'Profile & preferences': 'profile',
        'Model': 'model',
        'Skills': 'skills',
        'Connected apps': 'connectors',
        'API keys': 'secrets',
        'Schedules & automations': 'automations',
        'Host & activity': 'host',
        'Control rooms': 'rooms',
        'Account & app settings': 'settings',
      }.entries) {
        final row = find.byKey(ValueKey('settings_${entry.key}'));
        await revealControl(tester, row);
        await tester.tap(row);
        await tester.pumpAndSettle();
        expect(taps[entry.value], 1);
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'removal requires confirmation and returns before calling deletion',
    (tester) async {
      await smallPhone(tester, pushed(optional: true));
      await tester.tap(find.text('Open settings'));
      await tester.pumpAndSettle();
      await reveal(tester, 'Remove agent');
      await tester.tap(find.text('Remove agent'));
      await tester.pumpAndSettle();
      expect(find.text('Remove Alex?'), findsOneWidget);
      expect(taps['delete'], isNull);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(taps['delete'], isNull);
      await tester.tap(find.text('Remove agent'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(taps['delete'], 1);
      expect(find.text('Open settings'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'live roster names refresh and removed agents get a useful state',
    (tester) async {
      await smallPhone(tester, page());
      source.renameAgent('alex', 'Renamed agent');
      await tester.pumpAndSettle();
      expect(find.text('Renamed agent'), findsOneWidget);
      source.removeAgent('alex');
      await tester.pumpAndSettle();
      expect(
        find.text('This agent is no longer in your list.'),
        findsOneWidget,
      );
      expect(find.byType(Switch), findsNothing);
    },
  );

  testWidgets(
    'every destination is one row, in the fixed order, and Chat returns',
    (tester) async {
      await smallPhone(tester, pushed(optional: true));
      await tester.tap(find.text('Open settings'));
      await tester.pumpAndSettle();
      // No quick-action strip that repeats the rows below it.
      for (final label in ['Files', 'Schedules']) {
        expect(find.byTooltip(label), findsNothing);
      }
      // No messenger channel.
      expect(find.textContaining('Telegram'), findsNothing);
      final List<String> order = <String>[
        'settings_Profile & preferences',
        'settings_Model',
        'settings_Permissions',
        'settings_Skills',
        'settings_Connected apps',
        'settings_Mail',
        'settings_Host & activity',
        'settings_Open screen',
        'settings_Documents & artifacts',
        'settings_Hide',
        'settings_Remove',
      ];
      double last = double.negativeInfinity;
      for (final String key in order) {
        final Finder row = find.byKey(ValueKey(key));
        expect(row, findsOneWidget, reason: key);
        final double top = tester.getTopLeft(row).dy;
        expect(top, greaterThan(last), reason: key);
        last = top;
      }
      for (final entry in {
        'settings_Open screen': 'browser',
        'settings_Documents & artifacts': 'files',
      }.entries) {
        final row = find.byKey(ValueKey(entry.key));
        await revealControl(tester, row);
        await tester.tap(row);
        await tester.pumpAndSettle();
        expect(taps[entry.value], 1);
      }
      await tester.tap(find.byTooltip('Edit agent'));
      await tester.pumpAndSettle();
      expect(taps['profile'], 1);
      await tester.drag(find.byType(SettingsListView), const Offset(0, 4000));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings_Chat')));
      await tester.pumpAndSettle();
      expect(taps['chat'], 1);
      expect(find.text('Open settings'), findsOneWidget);
    },
  );

  testWidgets('Hide takes the agent off the list and closes the page', (
    tester,
  ) async {
    await smallPhone(tester, pushed());
    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('settings_Hide'));
    await revealControl(tester, row);
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(source.visibleAgents.any((a) => a.id == 'alex'), isFalse);
    expect(find.text('Open settings'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the settings header keeps back and edit reachable while the '
      'contact scrolls under it', (tester) async {
    await smallPhone(tester, pushed());
    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();
    expect(find.byType(FloatingAppBar), findsOneWidget);
    expect(find.text('Alex'), findsOneWidget);
    await tester.drag(find.byType(SettingsListView), const Offset(0, -420));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Back').hitTestable(), findsOneWidget);
    expect(find.byTooltip('Edit agent').hitTestable(), findsOneWidget);
    await tester.tap(find.byTooltip('Edit agent'));
    await tester.pumpAndSettle();
    expect(taps['profile'], 1);
  });

  testWidgets('320px large text keeps hero, actions and all sections usable', (
    tester,
  ) async {
    await smallPhone(
      tester,
      MediaQuery(
        data: const MediaQueryData(
          size: Size(320, 640),
          textScaler: TextScaler.linear(2),
        ),
        child: page(optional: true),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.byTooltip('Edit agent').hitTestable(), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('settings_Chat'))).height,
      greaterThanOrEqualTo(48),
    );
    await reveal(tester, 'Remove agent');
    expect(find.text('Remove agent').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('an agent with a thread', () {
    late Directory kv;
    setUp(() async {
      ChatModelSelectionService.instance.clearMemoryForTesting();
      AgentModel.debugCatalogue = () async =>
          const <AgentCatalogueModel>[
            AgentCatalogueModel(
              id: 'z-ai/glm-5.3-flash',
              name: 'Z.ai: GLM 5.3 Flash',
              providers: <AgentProvider>[
                AgentProvider(
                  slug: 'fireworks/serverless',
                  name: 'Fireworks',
                ),
              ],
            ),
          ];
      kv = await useTempKvCache();
      await ModelCapabilitiesService.initialize();
    });
    tearDown(() async {
      AgentModel.debugCatalogue = null;
      await disposeTempKvCache(kv);
    });

    testWidgets('the model row says it follows the app default and opens the '
        'agent s model page, not the shell action', (tester) async {
      await smallPhone(tester, page(chatId: 'host:alex'));
      final Finder row = find.byKey(const ValueKey('settings_Model'));
      expect(row, findsOneWidget);
      expect(tester.widget(row), isA<AgentModelTile>());
      expect(
        find.descendant(
          of: row,
          matching: find.text('App default (Fast) · Fireworks · Reasoning low'),
        ),
        findsOneWidget,
      );
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(find.byType(AgentModelPage), findsOneWidget);
      expect(taps['model'], isNull);
    });
  });

  // UI audit 2026-10-05, item 6: the page was English inside a German app.
  testWidgets('German: rows and headers are localised; the '
      'row keys stay the English ids', (tester) async {
    tester.view.physicalSize = const Size(360, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('de'),
        localizationsDelegates: kTestLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: page(optional: true),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Profil & Einstellungen'), findsOneWidget);
    expect(find.text('Host & Aktivität'), findsOneWidget);
    expect(find.text('Sein Rechner'), findsOneWidget);
    expect(find.text('Was er darf'), findsOneWidget);
    expect(find.text('Profile & preferences'), findsNothing);
    expect(
      find.byKey(const ValueKey('settings_Profile & preferences')),
      findsOneWidget,
    );
    expect(find.byTooltip('Agent bearbeiten'), findsOneWidget);
  });
}
