// Preview renders of the mobile layer, written as PNGs into
// docs/screenshots/c6/ so the layout can be seen without the running app.
//
// These are goldens by mechanism only: they are (re)written with
//   flutter test test/platform_specific/mobile/mobile_preview_test.dart --update-goldens
// and compared on a plain run. Real Roboto + Material Icons are loaded from
// the SDK so the text is readable; shadows are enabled for the same reason.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/platform_specific/mobile/mobile_agent_list.dart';
import 'package:chuk_chat/platform_specific/mobile/mobile_chat_screen.dart';
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
      // repeating indicator while a coworker is working, so the tree never
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

  testWidgets('chat chrome over a placeholder body, light', (tester) async {
    await pumpPhone(
      tester,
      MobileChatScreen(
        agent: roster().first,
        onBack: () {},
        onOpenProfile: () {},
        onOpenBrowser: () {},
        onMore: () {},
        bodyBuilder: (context, topInset) => _PlaceholderChat(topInset: topInset),
      ),
      theme: mono(Brightness.light),
    );
    await shoot(tester, 'preview_chat_chrome_light');
  });

  testWidgets('the message bubbles', (tester) async {
    // The bubbles on their own, so the corner geometry, the colours per kind
    // and the stamp can be read without the rest of the chat screen.
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

/// Stands in for the verbatim chuk_chat phone screen in the preview: a
/// scrollable list that starts under the chrome, so the fade is visible, and
/// a bar at the bottom where the real composer sits. Nothing here ships.
class _PlaceholderChat extends StatelessWidget {
  const _PlaceholderChat({required this.topInset});

  final double topInset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.5);
    Widget bubble(String text, {required bool user}) => Align(
          alignment: user ? Alignment.centerRight : Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 300),
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 4),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: user
                    ? theme.colorScheme.primary
                    : theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Text(
                text,
                style: TextStyle(
                  color: user ? theme.colorScheme.onPrimary : null,
                  fontSize: 15,
                ),
              ),
            ),
          ),
        );
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: EdgeInsets.fromLTRB(16, topInset, 16, 16),
            children: [
              Center(child: Text('Today 4:29 PM', style: TextStyle(color: muted, fontSize: 12))),
              bubble('Hey Sam. Fresh start, I am here.', user: false),
              bubble('What is the main thing you want me on, day to day?', user: false),
              bubble('Make a meal prep for a week', user: true),
              bubble('Sunday order: rice cooker on first, chicken thighs in the oven at 200°C, broccoli and carrots on a second tray. Full quantities and the shopping list are in the file.', user: false),
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text('[ chat body = chuk_chat ChukChatUIMobile, verbatim ]',
                      style: TextStyle(color: muted, fontSize: 11)),
                ),
              ),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 22,
                  backgroundColor: theme.colorScheme.surface,
                  child: const Icon(Icons.add),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Container(
                    height: 44,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(22),
                    ),
                    alignment: Alignment.centerLeft,
                    child: Text('Ask Chief of Staff', style: TextStyle(color: muted)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
