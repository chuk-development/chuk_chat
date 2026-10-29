import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/pages/desktop_settings_modal.dart';
import 'package:chuk_chat/pages/skills_settings_page.dart';
import 'package:chuk_chat/pages/system_prompt_page.dart';
import 'package:chuk_chat/pages/tool_calling_settings_page.dart';
import 'package:chuk_chat/services/agents/agents_chat_core.dart';
import 'package:chuk_chat/widgets/settings_list_view.dart';

import '../support/shell_config.dart';
import '../support/test_app.dart';

/// The desktop settings modal lists the same destinations as the phone's
/// SettingsPage. The "Chat" half of the Agents build is chuk_chat, so that
/// build keeps every chuk destination, leaves out only the onboarding replay
/// (it wires no tour) and adds one 'Agents' group, which holds the host's own
/// skills as "Host skills". The rarely used rows sit in one closed
/// "Advanced" fold (docs/SETTINGS_ORDER.md). These tests hold both lists in
/// place.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });
  tearDown(() => debugAgentsChatCoreOverride = null);

  Future<void> pumpModal(
    WidgetTester tester, {
    required bool agents,
    bool advanced = true,
    String? initialSectionId,
  }) async {
    debugAgentsChatCoreOverride = agents;
    // Wide enough for the rail + pane layout, not the compact drill-down.
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: DesktopSettingsModal(
            config: testShellConfig(),
            initialSectionId: initialSectionId,
          ),
        ),
      ),
    );
    // Fixed frames, not pumpAndSettle: the account page it opens on shows a
    // spinner while it waits for a profile that a unit test never delivers.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    if (advanced) {
      // The rarely used rows sit in the rail's closed "Advanced" fold (bead
      // chuk_chat-pjom).
      final Finder toggle = find.byKey(const ValueKey('settings_advanced'));
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  /// Disposes the modal and drains what the hosted pages started, inside the
  /// test body (see test/pages/settings_page_test.dart, closeSettings).
  Future<void> closeModal(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
  }

  /// The rail: the first settings list in the modal. The pane on its right
  /// hosts pages with lists of their own.
  Finder inRail(String label) => find.descendant(
    of: find.byType(SettingsListView).first,
    matching: find.text(label),
  );

  /// The labels of [labels] that the rail shows, top to bottom. The rail lays
  /// every row out up front, so a row below the fold still has a place.
  List<String> railOrder(WidgetTester tester, List<String> labels) {
    final Map<String, double> top = <String, double>{};
    for (final String label in labels) {
      final Finder row = inRail(label);
      if (row.evaluate().isEmpty) continue;
      top[label] = tester.getTopLeft(row.first).dy;
    }
    return top.keys.toList()..sort((a, b) => top[a]!.compareTo(top[b]!));
  }

  const List<String> everyLabel = <String>[
    'Account',
    'Account Settings',
    'Pricing Plans',
    'AI & Chat',
    'Model Selection',
    'AI Identity & Memory',
    'Tool Calling',
    'Connectors',
    'Skills',
    'GitHub',
    'Agents',
    'here.now',
    'Embedding',
    'API Keys',
    'Mailbox',
    'Automations',
    'Host skills',
    'Appearance',
    'Theme Settings',
    'Customization',
    'Advanced',
    'Tools & skills',
    'System',
    'Show onboarding again',
    'About',
  ];

  testWidgets('the rail shows only the main rows; Advanced holds the rest, '
      'closed', (tester) async {
    await pumpModal(tester, agents: true, advanced: false);

    expect(railOrder(tester, everyLabel), <String>[
      'Account',
      'Account Settings',
      'Pricing Plans',
      'AI & Chat',
      'Model Selection',
      'AI Identity & Memory',
      'Connectors',
      'Appearance',
      'Theme Settings',
      'Customization',
      'Advanced',
      'About',
    ]);
    await closeModal(tester);
  });

  testWidgets('a search finds a row inside the closed fold', (tester) async {
    await pumpModal(tester, agents: true, advanced: false);
    expect(inRail('Tool Calling'), findsNothing);

    await tester.enterText(find.byType(TextField).first, 'tool');
    await tester.pump();
    expect(inRail('Tool Calling'), findsOneWidget);
    expect(inRail('Advanced'), findsOneWidget);

    // The fold's own name lists all of it.
    await tester.enterText(find.byType(TextField).first, 'advanced');
    await tester.pump();
    expect(inRail('Host skills'), findsOneWidget);
    expect(inRail('GitHub'), findsOneWidget);
    await closeModal(tester);
  });

  testWidgets('opening on a page inside the fold starts with it open',
      (tester) async {
    await pumpModal(
      tester,
      agents: true,
      advanced: false,
      initialSectionId: 'tools',
    );
    expect(inRail('Tool Calling'), findsOneWidget);
    expect(find.byType(ToolCallingSettingsPage), findsOneWidget);
    await closeModal(tester);
  });

  testWidgets('with Agents on the rail keeps chuk\'s destinations in chuk\'s '
      'order, then the Agents group', (tester) async {
    await pumpModal(tester, agents: true);

    expect(railOrder(tester, everyLabel), <String>[
      'Account',
      'Account Settings',
      'Pricing Plans',
      'AI & Chat',
      'Model Selection',
      'AI Identity & Memory',
      'Connectors',
      'Appearance',
      'Theme Settings',
      'Customization',
      'Advanced',
      'Tools & skills',
      'Tool Calling',
      'Skills',
      'GitHub',
      'Agents',
      'here.now',
      'Embedding',
      'API Keys',
      'Mailbox',
      'Automations',
      'Host skills',
      'About',
    ]);
    await closeModal(tester);
  });

  testWidgets('with Agents off the rail is upstream chuk_chat\'s',
      (tester) async {
    await pumpModal(tester, agents: false);

    expect(railOrder(tester, everyLabel), <String>[
      'Account',
      'Account Settings',
      'Pricing Plans',
      'AI & Chat',
      'Model Selection',
      'AI Identity & Memory',
      'Connectors',
      'Appearance',
      'Theme Settings',
      'Customization',
      'Advanced',
      'Tools & skills',
      'Tool Calling',
      'Skills',
      'GitHub',
      'System',
      'Show onboarding again',
      'About',
    ]);
    await closeModal(tester);
  });

  testWidgets('with Agents on each chuk row opens its own page, and Host '
      'skills opens the host\'s', (tester) async {
    Future<void> open(String label, Type page, {Type? notPage}) async {
      await pumpModal(tester, agents: true);
      final Finder row = inRail(label);
      await tester.ensureVisible(row);
      await tester.pump();
      await tester.tap(row);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(page), findsOneWidget, reason: '$label did not open');
      if (notPage != null) {
        expect(find.byType(notPage), findsNothing, reason: label);
      }
      await closeModal(tester);
    }

    await open('AI Identity & Memory', SystemPromptPage);
    await open('Tool Calling', ToolCallingSettingsPage);
    await open(
      'Skills',
      SkillsSettingsPage,
      notPage: AgentsSkillsSettingsPage,
    );
    await open(
      'Host skills',
      AgentsSkillsSettingsPage,
      notPage: SkillsSettingsPage,
    );
  });
}
