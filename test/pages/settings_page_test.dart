import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/pages/about_page.dart';
import 'package:chuk_chat/pages/account_settings_page.dart';
import 'package:chuk_chat/pages/agent_mailbox_page.dart';
import 'package:chuk_chat/pages/settings/embedding_settings_page.dart';
import 'package:chuk_chat/pages/settings/herenow_settings_page.dart';
import 'package:chuk_chat/pages/settings_page.dart';
import 'package:chuk_chat/pages/skills_settings_page.dart';
import 'package:chuk_chat/pages/system_prompt_page.dart';
import 'package:chuk_chat/pages/theme_page.dart';
import 'package:chuk_chat/pages/tool_calling_settings_page.dart';
import 'package:chuk_chat/services/agents/agents_chat_core.dart';
import 'package:chuk_chat/widgets/floating_app_bar.dart';

import '../support/shell_config.dart';
import '../support/test_app.dart';

/// One settings page for both builds. With Agents on it is upstream
/// chuk_chat's page: the same frame, the same account row, the same sections,
/// the same rows (the "Chat" half is chuk_chat and reads them) and the same
/// sign-out, minus the onboarding replay, plus one 'Agents' section. These
/// tests hold that list in place.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    debugAgentsChatCoreOverride = true;
  });
  tearDown(() => debugAgentsChatCoreOverride = null);

  Future<void> pumpSettings(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(testApp(SettingsPage(config: testShellConfig())));
    // The imported page delays its developer-options refresh by 300 ms; let
    // that timer fire, or the binding reports it pending at teardown.
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
  }

  /// Disposes the page and drains what it started, INSIDE the test body.
  /// `addTearDown` is too late: the binding checks for pending timers at the
  /// end of the body, before teardown callbacks run, and the imported page
  /// schedules a delayed developer-options refresh on mount.
  Future<void> closeSettings(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
  }

  testWidgets('the page wears chuk_chat\'s frame', (tester) async {
    await pumpSettings(tester);

    expect(find.byType(FloatingAppBar), findsOneWidget);
    // One sign-out, not two.
    await tester.scrollUntilVisible(find.text('Logout').first, 200);
    expect(find.text('Logout'), findsOneWidget);
    await closeSettings(tester);
  });

  /// The labels the page shows, top to bottom, as far as [labels] names
  /// them. Rows the list builds lazily are reached by scrolling.
  Future<List<String>> shownInOrder(
    WidgetTester tester,
    List<String> labels,
  ) async {
    final Map<String, double> top = <String, double>{};
    for (final label in labels) {
      final Finder row = find.text(label);
      await tester.scrollUntilVisible(row.first, 200);
      if (row.evaluate().isEmpty) continue;
      // Scrolling moves every row by the same amount, so a label's offset
      // plus the distance scrolled so far is its place in the list.
      final ScrollableState scrollable = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      top[label] = tester.getTopLeft(row.first).dy + scrollable.position.pixels;
    }
    final List<String> shown = top.keys.toList()
      ..sort((a, b) => top[a]!.compareTo(top[b]!));
    return shown;
  }

  testWidgets('the page lists chuk_chat\'s rows in chuk\'s order, then the '
      'Agents section', (tester) async {
    await pumpSettings(tester);

    // The "Chat" half of the Agents build is chuk_chat: its identity and
    // memory prompt, its client tool loop and its skills are read there, so
    // every chuk row is back. The assistant row is Android only (not in a
    // unit test). The host's own skills sit in the Agents section as "Host
    // skills", apart from chuk's Skills.
    const List<String> expected = <String>[
      'Account',
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
      'System',
      'About',
    ];
    expect(await shownInOrder(tester, expected), expected);
    await closeSettings(tester);
  });

  testWidgets('the onboarding replay stays out of Agents', (tester) async {
    await pumpSettings(tester);

    // The Agents build wires no tour, so a replay has nothing to point at.
    await tester.scrollUntilVisible(find.text('About').first, 200);
    expect(find.text('Show onboarding again'), findsNothing);
    await closeSettings(tester);
  });

  testWidgets('Skills opens chuk_chat\'s skills and Host skills the host\'s',
      (tester) async {
    Future<void> open(String label, Type page, Type other) async {
      await pumpSettings(tester);
      final row = find.text(label);
      await tester.scrollUntilVisible(row.first, 200);
      await tester.tap(row.first);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(page), findsOneWidget, reason: label);
      expect(find.byType(other), findsNothing, reason: label);
      await closeSettings(tester);
    }

    await open('Skills', SkillsSettingsPage, AgentsSkillsSettingsPage);
    await open('Host skills', AgentsSkillsSettingsPage, SkillsSettingsPage);
  });

  testWidgets('AI Identity & Memory and Tool Calling open in Agents',
      (tester) async {
    Future<void> open(String label, Type page) async {
      await pumpSettings(tester);
      final row = find.text(label);
      await tester.scrollUntilVisible(row.first, 200);
      await tester.tap(row.first);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(page), findsOneWidget, reason: '$label did not open');
      await closeSettings(tester);
    }

    await open('AI Identity & Memory', SystemPromptPage);
    await open('Tool Calling', ToolCallingSettingsPage);
  });

  testWidgets('Account, Theme, here.now, Embedding and About each open',
      (tester) async {
    Future<void> open(Finder row, Type page) async {
      await pumpSettings(tester);
      // A row already on screen stays put: scrolling aligns it to the top,
      // which is under the floating header.
      if (row.hitTestable().evaluate().isEmpty) {
        await tester.scrollUntilVisible(row.first, 200);
      }
      await tester.tap(row.last);
      // Fixed frames, not pumpAndSettle: the account page shows a spinner
      // while it waits for a profile that a unit test never delivers.
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(page), findsOneWidget, reason: '$row did not open');
      await closeSettings(tester);
    }

    // chuk_chat's account row names the user; with no session that is
    // "User".
    await open(find.text('User'), AccountSettingsPage);
    await open(find.text('Theme Settings'), ThemePage);
    await open(find.text('here.now'), HereNowSettingsPage);
    await open(find.text('Embedding'), EmbeddingSettingsPage);
    await open(find.text('About'), AboutPage);
  });

  testWidgets('Mailbox opens the agent mailbox', (tester) async {
    await pumpSettings(tester);
    final Finder row = find.text('Mailbox');
    await tester.scrollUntilVisible(row.first, 200);
    await tester.tap(row.first);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    // Signed out in a unit test: the page shows why instead of a list.
    expect(find.byType(AgentMailboxPage), findsOneWidget);
    await closeSettings(tester);
  });

  testWidgets('with Agents off the page is upstream chuk_chat, without the '
      'Agents section', (tester) async {
    debugAgentsChatCoreOverride = false;
    await pumpSettings(tester);

    expect(find.text('Agents'), findsNothing);
    expect(find.text('here.now'), findsNothing);
    expect(find.text('Host skills'), findsNothing);
    expect(find.text('Mailbox'), findsNothing);
    for (final label in <String>[
      'Pricing Plans',
      'AI Identity & Memory',
      'Tool Calling',
      'Show onboarding again',
    ]) {
      await tester.scrollUntilVisible(find.text(label).first, 200);
      expect(find.text(label), findsOneWidget, reason: '$label missing');
    }
    await closeSettings(tester);
  });
}
