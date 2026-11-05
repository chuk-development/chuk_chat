// Preview renders of the mobile layer, written as PNGs into
// docs/screenshots/c6/ so the layout can be seen without the running app.
//
// These are goldens by mechanism only: they are (re)written with
//   flutter test test/platform_specific/mobile/mobile_preview_test.dart --update-goldens
// and compared on a plain run. Real Roboto + Material Icons are loaded from
// the SDK so the text is readable; shadows are enabled for the same reason.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/agents/agents_chat_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/platform_specific/mobile/mobile_agent_list.dart';
import 'package:chuk_chat/models/chat_message.dart' show ChatMessageStatus;
import 'package:chuk_chat/widgets/message_bubble.dart';

import 'mobile_support.dart';

// Relative to this file: test/platform_specific/mobile/ -> repo root.
const String _out = '../../../docs/screenshots/c6';

void main() {
  setUpAll(loadRealFonts);
  // A bubble reads two display preferences on mount; without a mock store the
  // plugin channel throws.
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  final DateTime now = DateTime(2026, 9, 5, 14, 30);

  List<AgentsAgent> roster() => <AgentsAgent>[
        agent(
          id: 'chief',
          name: 'Chief of Staff',
          role: 'ops',
          running: true,
          lastActivity: now.subtract(const Duration(minutes: 3)),
          threads: <AgentsThreadInfo>[
            AgentsThreadInfo(key: 'chief-1', title: 'Morning digest'),
          ],
          onHost: true,
        ),
        agent(
          id: 'slmob',
          name: 'SLMob',
          role: 'Meal prepping',
          lastActivity: now.subtract(const Duration(hours: 5)),
          threads: <AgentsThreadInfo>[
            AgentsThreadInfo(key: 's-1', title: 'Sunday mornings at 8:41 I will send the menu'),
          ],
        ),
        agent(
          id: 'design',
          name: 'Design',
          brief: 'Proposes UI directions',
          lastActivity: now.subtract(const Duration(days: 1)),
        ),
        agent(
          id: 'inbox',
          name: 'Inbox Triage',
          lastActivity: now.subtract(const Duration(days: 3)),
          threads: <AgentsThreadInfo>[
            AgentsThreadInfo(key: 'i-1', title: 'Sent to alex@example.com'),
          ],
        ),
        agent(id: 'research', name: 'UX Research', role: 'Challenges'),
      ];

  /// Neutral black/grey schemes, close to Grok Bot's look. The app's own
  /// theme service decides the real colours; the preview only avoids the
  /// purple a plain `colorSchemeSeed: Colors.black` would give.
  ThemeData mono(Brightness brightness) => ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.black,
          brightness: brightness,
          dynamicSchemeVariant: DynamicSchemeVariant.monochrome,
        ),
      );

  Future<void> shoot(WidgetTester tester, String name) async {
    // Shadows on, so the chips read as they do on a device. Restored before
    // the test ends: the binding asserts that no painting flag leaks.
    debugDisableShadows = false;
    try {
      // A fixed pump, not pumpAndSettle: the redesigned chrome carries a
      // repeating indicator while an agent is working, so the tree never
      // settles. The fake clock makes a fixed advance deterministic — long
      // enough for the list's staggered entrance to finish.
      await tester.pump(const Duration(milliseconds: 1400));
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('$_out/$name.png'),
      );
    } finally {
      debugDisableShadows = true;
    }
  }

  testWidgets('home list, light', (tester) async {
    await pumpPhone(
      tester,
      MobileAgentList(
        source: rosterWith(roster()),
        selectedAgentId: 'chief',
        onSelect: (_, _) {},
        onAddAgent: () {},
        onOpenAccount: () {},
        accountLabel: 'Sam Lee',
        now: () => now,
      ),
      theme: mono(Brightness.light),
    );
    await shoot(tester, 'preview_home_light');
  });

  testWidgets('home list, dark', (tester) async {
    await pumpPhone(
      tester,
      MobileAgentList(
        source: rosterWith(roster()),
        onSelect: (_, _) {},
        onAddAgent: () {},
        onOpenAccount: () {},
        accountLabel: 'Sam Lee',
        now: () => now,
      ),
      theme: mono(Brightness.dark),
    );
    await shoot(tester, 'preview_home_dark');
  });

  testWidgets('the message bubbles', (tester) async {
    // The Agents build draws chuk_chat's bubbles: the accent user bubble with
    // its tail, the answer straight on the page, the queued-send row.
    debugAgentsChatCoreOverride = true;
    addTearDown(() => debugAgentsChatCoreOverride = null);
    // The bubbles on their own, so the geometry can be read without the rest
    // of the chat screen.
    await pumpPhone(
      tester,
      ListView(
        padding: const EdgeInsets.fromLTRB(12, 60, 12, 24),
        children: <Widget>[
          MessageBubble(
            message: 'Morning. What is on today?',
            isUser: true,
            maxWidth: 300,
            turnStartedAt: now,
          ),
          MessageBubble(
            message: 'Three things are open, and one needs you.',
            isUser: false,
            maxWidth: 360,
            startsNewGroup: true,
            endsGroup: false,
            turnStartedAt: now,
          ),
          MessageBubble(
            message: 'I read the release notes and the two open PRs.',
            isUser: false,
            maxWidth: 360,
            startsNewGroup: false,
            endsGroup: true,
            turnStartedAt: now,
          ),
          MessageBubble(
            message: 'Ship it, and tell me when the build is green.',
            isUser: true,
            maxWidth: 300,
            turnStartedAt: now,
            status: ChatMessageStatus.pending,
          ),
          MessageBubble(
            message: 'The stream broke off before I finished.',
            isUser: false,
            maxWidth: 360,
            turnStartedAt: now,
            status: ChatMessageStatus.interrupted,
          ),
        ],
      ),
      theme: mono(Brightness.light),
    );
    await shoot(tester, 'preview_bubbles_light');
  });
}
