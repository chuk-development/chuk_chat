// The one settings pattern (docs/DESIGN.md §2): every settings surface is a
// FloatingPageScaffold page; a phone pushes it, a desktop window shows it in
// the settings modal, with the modal's close chip in the page's own header.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/pages/mobile_agents_settings_page.dart';
import 'package:chuk_chat/pages/settings/herenow_settings_page.dart';
import 'package:chuk_chat/services/agents/agent_profile_store.dart';
import 'package:chuk_chat/services/agents/agent_roster_source.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/settings/mobile_chat_preferences.dart';
import 'package:chuk_chat/widgets/floating_app_bar.dart';
import 'package:chuk_chat/widgets/settings_surface.dart';

import '../support/test_app.dart';

const Size _phone = Size(390, 844);
const Size _desk = Size(1400, 900);

void main() {
  late LocalAgentRosterSource source;
  late AgentProfileStore profiles;
  late MobileChatPreferences prefs;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    AgentsRelayLink.instance.reset();
    source = LocalAgentRosterSource(
      seed: <AgentsAgent>[
        AgentsAgent(
          id: 'amber',
          name: 'Amber',
          threads: <AgentsThreadInfo>[
            AgentsThreadInfo(key: 'amber-main', title: 'General'),
          ],
        ),
      ],
    );
    profiles = AgentProfileStore();
    prefs = MobileChatPreferences();
  });
  tearDown(() {
    source.dispose();
    profiles.dispose();
    prefs.dispose();
    AgentsRelayLink.instance.reset();
  });

  Widget agentSettings() {
    void noop() {}
    return MobileAgentsSettingsPage(
      agentId: 'amber',
      source: source,
      profiles: profiles,
      preferences: prefs,
      onEdit: noop,
      onControls: noop,
      onModel: noop,
      onAutomations: noop,
      onSkills: noop,
      onConnectors: noop,
      onSecrets: noop,
      onRooms: noop,
      onSettings: noop,
      onChat: noop,
    );
  }

  /// Pumps a window of [size] and opens [page] the one way.
  Future<BuildContext> open(
    WidgetTester tester,
    Size size,
    WidgetBuilder page,
  ) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    late BuildContext context;
    await tester.pumpWidget(
      testApp(
        Builder(
          builder: (BuildContext c) {
            context = c;
            return const Scaffold(body: Text('behind'));
          },
        ),
      ),
    );
    await tester.pump();
    openSettingsSurface(context, page);
    await tester.pumpAndSettle();
    return context;
  }

  for (final (String name, WidgetBuilder page) in <(String, WidgetBuilder)>[
    ('per-agent settings', (_) => agentSettings()),
    ('Agents section page (here.now)', (_) => const HereNowSettingsPage()),
  ]) {
    testWidgets('$name: a full page with the settings header on a phone', (
      WidgetTester tester,
    ) async {
      await open(tester, _phone, page);
      expect(find.byType(FloatingPageScaffold), findsOneWidget);
      expect(find.byType(FloatingAppBar), findsOneWidget);
      expect(find.byType(SettingsModalFrame), findsNothing);
      // The page is pushed: the header shows the back chip.
      expect(find.byTooltip('Back'), findsOneWidget);
    });

    testWidgets('$name: in the settings modal on a desktop window', (
      WidgetTester tester,
    ) async {
      await open(tester, _desk, page);
      expect(find.byType(SettingsModalFrame), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(SettingsModalFrame),
          matching: find.byType(FloatingPageScaffold),
        ),
        findsOneWidget,
      );
      // The first page of the modal has nowhere to go back to; its header
      // ends in the modal's close chip, which closes the modal.
      expect(find.byTooltip('Back'), findsNothing);
      final Finder close = find.byKey(
        const ValueKey<String>('settings-surface-close'),
      );
      expect(close, findsOneWidget);
      await tester.tap(close);
      await tester.pumpAndSettle();
      expect(find.byType(SettingsModalFrame), findsNothing);
      expect(find.text('behind'), findsOneWidget);
    });
  }

  testWidgets('a page opened from inside the modal stays in the modal', (
    WidgetTester tester,
  ) async {
    final BuildContext outside = await open(
      tester,
      _desk,
      (_) => agentSettings(),
    );
    final BuildContext inside = tester.element(
      find.byType(MobileAgentsSettingsPage),
    );
    openSettingsSurface(inside, (_) => const HereNowSettingsPage());
    await tester.pumpAndSettle();
    expect(find.byType(SettingsModalFrame), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(SettingsModalFrame),
        matching: find.byType(HereNowSettingsPage),
      ),
      findsOneWidget,
    );
    // Pushed inside: back chip and close chip, one header.
    expect(find.byTooltip('Back'), findsOneWidget);

    // An open from outside (the shell's context) also lands in the open
    // modal; two panels never stack.
    openSettingsSurface(outside, (_) => agentSettings());
    await tester.pumpAndSettle();
    expect(find.byType(SettingsModalFrame), findsOneWidget);

    closeSettingsModals();
    await tester.pumpAndSettle();
    expect(find.byType(SettingsModalFrame), findsNothing);
  });
}
