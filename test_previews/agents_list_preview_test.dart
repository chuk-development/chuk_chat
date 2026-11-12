// A preview harness outside test/: the test-only members are meant here.
// ignore_for_file: invalid_use_of_visible_for_testing_member

// Headless renders of the agent list: the phone inbox (MobileAgentList) and
// the desktop roster (AgentRosterView), the REAL widgets with realistic data.
//
// Not under test/, so a plain `flutter test` skips it. Run:
//   flutter test test_previews/agents_list_preview_test.dart \
//     --update-goldens --dart-define=PREVIEW_STAGE=after
// The PNGs land in _scratch/agents_ui/<stage>/ (gitignored scratch).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/platform_specific/mobile/mobile_agent_list.dart';
import 'package:chuk_chat/services/agents/agent_read_marks.dart';
import 'package:chuk_chat/services/agents/roster_pins.dart';
import 'package:chuk_chat/services/agents/thread_preview_store.dart';
import 'package:chuk_chat/widgets/agent_roster_view.dart';
import 'package:chuk_chat/widgets/sidebar/sidebar_chrome.dart';

import '../test/platform_specific/mobile/mobile_support.dart';
import '../test/support/test_app.dart';

// Relative to this file: test_previews/ -> repo root.
const String _root = '../_scratch/agents_ui';
const String _stage = String.fromEnvironment(
  'PREVIEW_STAGE',
  defaultValue: 'after',
);

final DateTime now = DateTime(2026, 11, 12, 14, 30);

/// The roster the renders show. Every agent but one has a last message.
List<AgentsAgent> roster() => <AgentsAgent>[
  agent(
    id: 'chief',
    name: 'Chief of Staff',
    role: 'ops',
    running: true,
    brief: 'Runs the morning digest',
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
    // A run after the last message: the row still dates the message.
    lastActivity: now.subtract(const Duration(minutes: 40)),
    threads: <AgentsThreadInfo>[
      AgentsThreadInfo(key: 's-1', title: 'Sunday menu'),
    ],
  ),
  agent(
    id: 'design',
    name: 'Design',
    brief: 'Proposes UI directions',
    lastActivity: now.subtract(const Duration(hours: 2)),
    threads: <AgentsThreadInfo>[AgentsThreadInfo(key: 'd-1', title: 'default')],
  ),
  agent(
    id: 'inbox',
    name: 'Inbox Triage',
    lastActivity: now.subtract(const Duration(days: 3)),
    threads: <AgentsThreadInfo>[
      AgentsThreadInfo(key: 'i-1', title: 'Sent to alex@example.com'),
    ],
  ),
  agent(
    id: 'finance',
    name: 'Finance',
    role: 'Bookkeeping',
    lastActivity: now.subtract(const Duration(days: 12)),
    threads: <AgentsThreadInfo>[AgentsThreadInfo(key: 'f-1', title: 'default')],
  ),
  agent(
    id: 'research',
    name: 'UX Research',
    role: 'Challenges',
    brief: 'Challenges every assumption',
  ),
];

/// The last line of each thread, as the replay loader would note it.
void seedPreviews() {
  void note(String key, String sender, String text, DateTime at) =>
      ThreadPreviewStore.instance.noteRows(key, <Map<String, dynamic>>[
        <String, dynamic>{
          'sender': sender,
          'text': text,
          'timestamp': at.toIso8601String(),
        },
      ]);
  note(
    'chief-1',
    'agent',
    '**Three things** are open today, one needs you.',
    now.subtract(const Duration(minutes: 3)),
  );
  note(
    's-1',
    'user',
    'Make it vegetarian this week',
    now.subtract(const Duration(hours: 5)),
  );
  note(
    'd-1',
    'agent',
    'Here are two directions for the onboarding card: a calm one and a bold one.',
    DateTime(2026, 11, 11, 18, 2),
  );
  note(
    'i-1',
    'agent',
    'Archived 14 newsletters. Two invoices wait for you.',
    DateTime(2026, 11, 9, 8, 15),
  );
  note(
    'f-1',
    'user',
    'Thanks, file it under `Q3`',
    DateTime(2026, 10, 31, 16, 40),
  );
}

ThemeData mono(Brightness brightness) => ThemeData(
  colorScheme: ColorScheme.fromSeed(
    seedColor: Colors.black,
    brightness: brightness,
    dynamicSchemeVariant: DynamicSchemeVariant.monochrome,
  ),
);

Future<void> shoot(WidgetTester tester, String path) async {
  debugDisableShadows = false;
  try {
    await tester.pump(const Duration(milliseconds: 1400));
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('$_root/$path'),
    );
  } finally {
    debugDisableShadows = true;
  }
}

/// Everything read except Chief of Staff and Inbox Triage, so the render
/// shows both the quiet and the unread row.
AgentReadMarks readMarks() {
  final AgentReadMarks marks = AgentReadMarks();
  for (final String key in <String>['s-1', 'd-1', 'f-1', 'research-main']) {
    marks.markRead(key, when: now);
  }
  return marks;
}

Widget phoneList() => MobileAgentList(
  source: rosterWith(roster()),
  readMarks: readMarks(),
  selectedAgentId: 'chief',
  onSelect: (_, _) {},
  onAddAgent: () {},
  onOpenAccount: () {},
  accountLabel: 'Sam Lee',
  now: () => now,
);

Future<void> pumpDesktop(WidgetTester tester, Brightness brightness) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  debugSbChatTimeOfDayOverride = null;
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: kTestLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      debugShowCheckedModeBanner: false,
      theme: mono(brightness),
      home: Scaffold(
        body: Row(
          children: <Widget>[
            SizedBox(
              width: 320,
              child: AgentRosterView(
                source: rosterWith(roster()),
                selectedAgentId: 'slmob',
                readMarks: readMarks(),
                onSelect: (_, _) {},
                onAddAgent: () {},
                accountLabel: 'Sam Lee',
                now: () => now,
              ),
            ),
            const Expanded(child: SizedBox()),
          ],
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  setUpAll(loadRealFonts);
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    RosterPins.instance.reset();
    seedPreviews();
  });

  testWidgets('phone list, light', (tester) async {
    await pumpPhone(tester, phoneList(), theme: mono(Brightness.light));
    await shoot(tester, '$_stage/list_phone_light.png');
  });

  testWidgets('phone list, dark', (tester) async {
    await pumpPhone(tester, phoneList(), theme: mono(Brightness.dark));
    await shoot(tester, '$_stage/list_phone_dark.png');
  });

  testWidgets('desktop roster, light', (tester) async {
    await pumpDesktop(tester, Brightness.light);
    await shoot(tester, '$_stage/list_desktop_light.png');
  });
}
