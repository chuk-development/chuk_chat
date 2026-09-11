import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cowork/models/cowork_agent.dart';
import 'package:cowork/pages/mobile_cowork_settings_page.dart';
import 'package:cowork/services/cowork/agent_profile_store.dart';
import 'package:cowork/services/cowork/agent_roster_source.dart';
import 'package:cowork/services/settings/mobile_chat_preferences.dart';

import '../support/test_app.dart';

void main() {
  late LocalAgentRosterSource source;
  late AgentProfileStore profiles;
  late MobileChatPreferences preferences;
  late Map<String, int> taps;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    source = LocalAgentRosterSource(
      seed: [const CoworkAgent(id: 'alex', name: 'Alex', threads: [])],
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

  Widget page({bool optional = false}) => MobileCoworkSettingsPage(
    agentId: 'alex',
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
    // Sliver sections can already be mounted below the viewport; existence
    // alone is not visibility, especially while the contact hero collapses.
    for (
      var attempts = 0;
      finder.hitTestable().evaluate().isEmpty && attempts < 40;
      attempts++
    ) {
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -160));
      await tester.pumpAndSettle();
    }
    expect(finder.hitTestable(), findsOneWidget);
  }

  testWidgets('quiet defaults and persisted switches fit a small phone', (
    tester,
  ) async {
    // Keep the serialized writer in the widget test's async zone.
    preferences.dispose();
    preferences = MobileChatPreferences();
    await smallPhone(tester, page());
    for (final id in ['mobile_show_thinking', 'mobile_show_activity']) {
      final finder = find.byKey(ValueKey(id));
      await revealControl(tester, finder);
      expect(tester.widget<Switch>(finder).value, isFalse);
      await tester.tap(finder);
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(finder).value, isTrue);
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
      expect(find.text('Remove coworker'), findsNothing);
      for (final entry in {
        'Profile & preferences': 'profile',
        'Host & activity': 'host',
        'Model': 'model',
        'Schedules & automations': 'automations',
        'Skills': 'skills',
        'Connected apps': 'connectors',
        'API keys': 'secrets',
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
      await smallPhone(
        tester,
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => page(optional: true)),
              ),
              child: const Text('Open settings'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open settings'));
      await tester.pumpAndSettle();
      await reveal(tester, 'Remove coworker');
      await tester.tap(find.text('Remove coworker'));
      await tester.pumpAndSettle();
      expect(find.text('Remove Alex?'), findsOneWidget);
      expect(taps['delete'], isNull);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(taps['delete'], isNull);
      await tester.tap(find.text('Remove coworker'));
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
      source.renameAgent('alex', 'Renamed coworker');
      await tester.pumpAndSettle();
      expect(find.text('Renamed coworker'), findsOneWidget);
      source.removeAgent('alex');
      await tester.pumpAndSettle();
      expect(
        find.text('This coworker is no longer in your list.'),
        findsOneWidget,
      );
      expect(find.byType(Switch), findsNothing);
    },
  );

  testWidgets(
    'reference quick actions call real destinations and Chat returns',
    (tester) async {
      await smallPhone(
        tester,
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => page(optional: true)),
              ),
              child: const Text('Open settings'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open settings'));
      await tester.pumpAndSettle();
      for (final entry in {
        'Model': 'model',
        'Files': 'files',
        'Schedules': 'automations',
        'Skills': 'skills',
      }.entries) {
        await tester.tap(find.byTooltip(entry.key));
        await tester.pumpAndSettle();
        expect(taps[entry.value], 1);
      }
      await tester.tap(find.byTooltip('Edit coworker'));
      await tester.pumpAndSettle();
      expect(taps['profile'], 1);
      await tester.tap(find.byTooltip('Chat'));
      await tester.pumpAndSettle();
      expect(taps['chat'], 1);
      expect(find.text('Open settings'), findsOneWidget);
    },
  );

  testWidgets('contact hero collapses while back and edit stay reachable', (
    tester,
  ) async {
    await smallPhone(tester, page());
    final expanded = tester.getSize(find.byType(FlexibleSpaceBar)).height;
    expect(expanded, 300);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -420));
    await tester.pumpAndSettle();
    final collapsed = tester.getSize(find.byType(FlexibleSpaceBar)).height;
    expect(collapsed, lessThan(expanded));
    expect(find.byTooltip('Back').hitTestable(), findsOneWidget);
    expect(find.byTooltip('Edit coworker').hitTestable(), findsOneWidget);
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
    expect(find.byTooltip('Edit coworker').hitTestable(), findsOneWidget);
    for (final label in ['Model', 'Files', 'Schedules', 'Skills']) {
      expect(
        tester.getSize(find.byTooltip(label)).width,
        greaterThanOrEqualTo(48),
      );
    }
    await reveal(tester, 'Remove coworker');
    expect(find.text('Remove coworker').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
