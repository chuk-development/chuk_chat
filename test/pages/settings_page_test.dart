import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/pages/about_page.dart';
import 'package:chuk_chat/pages/account_settings_page.dart';
import 'package:chuk_chat/pages/settings/embedding_settings_page.dart';
import 'package:chuk_chat/pages/settings/herenow_settings_page.dart';
import 'package:chuk_chat/pages/settings_page.dart';
import 'package:chuk_chat/pages/skills_settings_page.dart';
import 'package:chuk_chat/pages/theme_page.dart';
import 'package:chuk_chat/services/agents/agents_chat_core.dart';
import 'package:chuk_chat/widgets/floating_app_bar.dart';

import '../support/shell_config.dart';
import '../support/test_app.dart';

/// One settings page for both builds. With Agents on it is upstream
/// chuk_chat's page: the same frame, the same account row, the same sections
/// and the same sign-out, minus the rows that do nothing there, plus one
/// 'Agents' section. These tests hold that list in place.
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

  testWidgets('the page lists chuk_chat\'s sections and the Agents section',
      (tester) async {
    await pumpSettings(tester);

    for (final label in <String>[
      'Account',
      'Pricing Plans',
      'AI & Chat',
      'Model Selection',
      'Skills',
      'GitHub',
      'Agents',
      'here.now',
      'Embedding',
      'API Keys',
      'Automations',
      'Appearance',
      'System',
      'About',
    ]) {
      await tester.scrollUntilVisible(find.text(label).first, 200);
      expect(find.text(label), findsWidgets, reason: '$label missing');
    }
    await closeSettings(tester);
  });

  testWidgets('the rows that do nothing in Agents are left out',
      (tester) async {
    await pumpSettings(tester);

    // The host owns the system prompt and runs every tool; the onboarding
    // tour walks chuk_chat's own screens.
    for (final gone in <String>[
      'AI Identity & Memory',
      'Tool Calling',
      'Show onboarding again',
    ]) {
      expect(find.text(gone), findsNothing, reason: '$gone should be hidden');
    }
    await closeSettings(tester);
  });

  testWidgets('Skills opens the host\'s skills in Agents', (tester) async {
    await pumpSettings(tester);

    final row = find.text('Skills');
    await tester.scrollUntilVisible(row.first, 200);
    await tester.tap(row.first);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(AgentsSkillsSettingsPage), findsOneWidget);
    expect(find.byType(SkillsSettingsPage), findsNothing);
    await closeSettings(tester);
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

  testWidgets('with Agents off the page is upstream chuk_chat, without the '
      'Agents section', (tester) async {
    debugAgentsChatCoreOverride = false;
    await pumpSettings(tester);

    expect(find.text('Agents'), findsNothing);
    expect(find.text('here.now'), findsNothing);
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
