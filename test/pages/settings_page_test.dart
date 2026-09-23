import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/pages/about_page.dart';
import 'package:chuk_chat/pages/account_settings_page.dart';
import 'package:chuk_chat/pages/settings/embedding_settings_page.dart';
import 'package:chuk_chat/pages/settings/herenow_settings_page.dart';
import 'package:chuk_chat/pages/settings_page.dart';
import 'package:chuk_chat/pages/theme_page.dart';
import 'package:chuk_chat/services/agents/agents_chat_core.dart';

import '../support/shell_config.dart';
import '../support/test_app.dart';

/// With Agents on, the settings hub is the Agents app's own hub: its entries,
/// its order, its large headline. These tests hold that list in place: what
/// must be reachable, and what must stay hidden because the host owns it or
/// Agents has no hosted account behind it. With Agents off the hub is
/// upstream chuk_chat's, and the last test holds that.
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

  testWidgets('the hub lists the areas Agents keeps', (tester) async {
    await pumpSettings(tester);

    // 'Account' is both a section header and a row title, so scroll on the
    // first match and assert on all of them.
    for (final label in <String>[
      'Account',
      'Agents',
      'Appearance',
      'System',
      'here.now',
      'Embedding',
      'API Keys',
    ]) {
      await tester.scrollUntilVisible(find.text(label).first, 200);
      expect(find.text(label), findsWidgets, reason: '$label missing');
    }
    await closeSettings(tester);
  });

  testWidgets('the hidden areas are really gone, not just unreachable',
      (tester) async {
    await pumpSettings(tester);

    // Hosted-only or host-owned, hidden by the section map. A row appearing
    // here again means someone re-imported chuk's list over the map.
    for (final gone in <String>[
      'Pricing & Plans',
      'Pricing Plans',
      'Sandboxes',
      'Export chats',
      'AI Identity & Memory',
      'Tool Calling',
      'GitHub',
      'Free plan',
    ]) {
      expect(find.text(gone), findsNothing, reason: '$gone should be hidden');
    }
    await closeSettings(tester);
  });

  testWidgets('the model entry is reachable and is the imported screen',
      (tester) async {
    await pumpSettings(tester);

    // Reachability only: mounting ModelSelectorPage runs upstream's initState,
    // which refreshes the Supabase session and fetches /v1/models_info, and a
    // unit test has neither. The hub is chuk's verbatim, so the entry IS
    // chuk's screen; Agents's pass-through wrapper is gone (bead cowork-acu).
    await tester.scrollUntilVisible(find.text('Model Selection').first, 200);
    expect(find.text('Model Selection'), findsOneWidget);
    await closeSettings(tester);
  });

  testWidgets('Account, Theme, here.now, Embedding and About each open',
      (tester) async {
    Future<void> open(String label, Type page, {String? rowText}) async {
      await pumpSettings(tester);
      final row = find.text(rowText ?? label);
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
      expect(find.byType(page), findsOneWidget, reason: '$label did not open');
      await closeSettings(tester);
    }

    // The Agents hub has one plain row titled "Account" under the section
    // of the same name, so the row is the last match.
    await open('Account', AccountSettingsPage);
    await open('Theme Settings', ThemePage);
    await open('here.now', HereNowSettingsPage);
    await open('Embedding', EmbeddingSettingsPage);
    await open('About', AboutPage);
  });

  testWidgets('with Agents off the hub is upstream chuk_chat, without the '
      'Agents section', (tester) async {
    debugAgentsChatCoreOverride = false;
    await pumpSettings(tester);

    expect(find.text('Agents'), findsNothing);
    expect(find.text('here.now'), findsNothing);
    await tester.scrollUntilVisible(find.text('Pricing Plans').first, 200);
    expect(find.text('Pricing Plans'), findsOneWidget);
    await closeSettings(tester);
  });
}
