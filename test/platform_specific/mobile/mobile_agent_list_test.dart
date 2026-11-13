import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/platform_specific/mobile/mobile_agent_list.dart';
import 'package:chuk_chat/platform_specific/mobile/mobile_layout.dart';
import 'package:chuk_chat/services/agents/thread_preview_store.dart';
import 'package:chuk_chat/ui/expressive/working_dots.dart';
import 'package:chuk_chat/utils/roster_time_label.dart';

import 'mobile_support.dart';

void main() {
  final DateTime now = DateTime(2026, 9, 5, 14, 30);

  List<AgentsAgent> sample() => <AgentsAgent>[
    agent(
      id: 'chief',
      name: 'Chief of Staff',
      role: 'ops',
      running: true,
      lastActivity: now.subtract(const Duration(minutes: 3)),
      threads: <AgentsThreadInfo>[
        AgentsThreadInfo(key: 'chief-1', title: 'Morning digest'),
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
      threads: const <AgentsThreadInfo>[],
    ),
  ];

  /// Writes one stored line for [threadKey], the way the replay loader does.
  void storeLine(
    String threadKey,
    String text, {
    required bool fromUser,
    DateTime? at,
  }) => ThreadPreviewStore.instance.noteRows(threadKey, <Map<String, dynamic>>[
    <String, dynamic>{
      'role': fromUser ? 'user' : 'assistant',
      'text': text,
      if (at != null) 'timestamp': at.toIso8601String(),
    },
  ]);

  testWidgets('a row reads like a messenger: name, last message and its time', (
    tester,
  ) async {
    // Thread keys of this test alone: the preview store is a process-wide
    // singleton, so a key shared with another test would make the result
    // depend on the order the tests run in.
    final List<AgentsAgent> roster = <AgentsAgent>[
      agent(
        id: 'chief',
        name: 'Chief of Staff',
        role: 'ops',
        running: true,
        lastActivity: now.subtract(const Duration(minutes: 3)),
        threads: <AgentsThreadInfo>[
          AgentsThreadInfo(key: 'render-chief', title: 'Morning digest'),
        ],
      ),
      agent(
        id: 'design',
        name: 'Design',
        role: 'ux',
        brief: 'Proposes UI directions',
        // A run after the last message: the row dates the message.
        lastActivity: now.subtract(const Duration(minutes: 10)),
        threads: <AgentsThreadInfo>[
          AgentsThreadInfo(key: 'render-design', title: 'default'),
        ],
      ),
      agent(
        id: 'inbox',
        name: 'Inbox Triage',
        brief: 'Sorts the mail',
        lastActivity: now.subtract(const Duration(hours: 1)),
        threads: <AgentsThreadInfo>[
          AgentsThreadInfo(key: 'render-inbox', title: 'Mail'),
        ],
      ),
    ];
    storeLine(
      'render-chief',
      '**Digest** sent',
      fromUser: false,
      at: now.subtract(const Duration(minutes: 3)),
    );
    storeLine(
      'render-design',
      'Here are two directions',
      fromUser: false,
      at: now.subtract(const Duration(days: 1)),
    );

    await pumpPhone(
      tester,
      MobileAgentList(
        source: rosterWith(roster),
        onSelect: (_, _) {},
        onAddAgent: () {},
        onOpenAccount: () {},
        accountLabel: 'Sam Lee',
        now: () => now,
      ),
    );
    Finder inRow(String id, Finder f) =>
        find.descendant(of: findId('mobile-agent-row-$id'), matching: f);

    // A running agent keeps its last message (markdown stripped) and its
    // time: no working mark, the face's animation says it (CHAT-74).
    expect(inRow('chief', find.text('Digest sent')), findsOneWidget);
    expect(find.text('Working…'), findsNothing);
    expect(inRow('chief', find.byType(WorkingDots)), findsNothing);

    // The last message and ITS time, not the brief, the role or the time of
    // the last run.
    expect(
      inRow('design', find.text('Here are two directions')),
      findsOneWidget,
    );
    expect(inRow('design', find.text('Yesterday')), findsOneWidget);
    expect(find.text('Proposes UI directions'), findsNothing);
    expect(find.text('ux'), findsNothing, reason: 'no role tag');
    expect(find.text('ops'), findsNothing, reason: 'no role tag');

    // Nothing said yet: the line stays empty and there is no time.
    expect(find.text('Sorts the mail'), findsNothing);
    expect(find.text('Mail'), findsNothing);
    expect(inRow('inbox', find.text('')), findsOneWidget);
    expect(inRow('inbox', find.text('1:30 PM')), findsNothing);

    // No account target up here any more: settings has one way in, the
    // navigation bar.
    expect(find.text('SL'), findsNothing, reason: 'no account monogram');
    // The unread mark is a count, not a dot: one thread with something new.
    expect(
      inRow('chief', find.text('1')),
      findsOneWidget,
      reason: 'unread badge counts the threads with something new',
    );

    // The user answers: the row follows the store without being rebuilt by
    // its caller, prefixed "You: ", with the new time.
    storeLine(
      'render-design',
      'Ship the palette',
      fromUser: true,
      at: now.subtract(const Duration(minutes: 1)),
    );
    await tester.pump();
    expect(inRow('design', find.text('You: Ship the palette')), findsOneWidget);
    expect(inRow('design', find.text('2:29 PM')), findsOneWidget);
  });

  testWidgets('rows are a real touch target and start under the header row', (
    tester,
  ) async {
    await pumpPhone(
      tester,
      MobileAgentList(
        source: rosterWith(sample()),
        onSelect: (_, _) {},
        now: () => now,
      ),
    );
    final Rect first = tester.getRect(findId('mobile-agent-row-chief'));
    expect(first.height, greaterThanOrEqualTo(MobileLayout.minTouchTarget));
    // The header row (58) carries the search target, the All / Unread switch
    // and the "+": the first row can only start below it, and never under the
    // status bar.
    expect(first.top, greaterThan(kPhonePadding.top + 58));
    // No page headline any more — the switch in the middle of the row says
    // what the list is showing.
    expect(find.text('Sidekicks'), findsNothing);
    expect(find.text('All'), findsOneWidget);
    // The segment carries its unread count, so the label is "Unread $n".
    expect(find.textContaining('Unread'), findsOneWidget);
  });

  testWidgets('with a header slot the row is chuk\'s bar: the slot takes the '
      'middle, search still opens and closes, All / Unread sits under it', (
    tester,
  ) async {
    await pumpPhone(
      tester,
      MobileAgentList(
        source: rosterWith(sample()),
        onSelect: (_, _) {},
        onAddAgent: () {},
        now: () => now,
        headerCenter: const SizedBox(
          key: ValueKey<String>('slot'),
          width: 120,
          height: 48,
        ),
      ),
    );
    final Rect slot = tester.getRect(
      find.byKey(const ValueKey<String>('slot')),
    );
    final Rect search = tester.getRect(findId('mobile_home_search'));
    final Rect add = tester.getRect(findId('mobile_home_add'));
    // chuk's bar: 48 px presses around 42 px chips, the slot centred
    // between the two chips (where the shell floats the Home | Agents
    // switch), all on one line under the status bar.
    expect(search.size, const Size(48, 48));
    expect(add.size, const Size(48, 48));
    expect(slot.center.dx, closeTo(kPhoneSize.width / 2, 0.5));
    expect(slot.left, greaterThan(search.right));
    expect(slot.top, kPhonePadding.top + 8);
    expect(add.right, kPhoneSize.width - 7);
    // All / Unread moved under the bar and kept its unread count segment.
    final Rect all = tester.getRect(findId('connected-group-all'));
    expect(all.top, greaterThanOrEqualTo(slot.bottom));
    expect(find.textContaining('Unread'), findsOneWidget);
    // The first row clears the filter row.
    final Rect first = tester.getRect(findId('mobile-agent-row-chief'));
    expect(first.top, greaterThanOrEqualTo(all.bottom));

    await tester.tap(findId('mobile_home_search'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('slot')), findsNothing);
    await tester.enterText(find.byType(TextField), 'ops');
    await tester.pumpAndSettle();
    expect(find.text('Design'), findsNothing);
    await tester.tap(findId('mobile_home_search_close'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('slot')), findsOneWidget);
    expect(find.text('Design'), findsOneWidget);

    // The filter still filters: an agent that never did anything has
    // nothing unread.
    expect(find.text('Inbox Triage'), findsOneWidget);
    await tester.tap(find.textContaining('Unread'));
    await tester.pumpAndSettle();
    expect(find.text('Inbox Triage'), findsNothing);
  });

  testWidgets('tap opens the first thread; an agent without threads is inert', (
    tester,
  ) async {
    final List<(String, String)> selected = <(String, String)>[];
    await pumpPhone(
      tester,
      MobileAgentList(
        source: rosterWith(sample()),
        onSelect: (id, key) => selected.add((id, key)),
        now: () => now,
      ),
    );
    await tester.tap(find.text('Chief of Staff'));
    await tester.tap(find.text('Inbox Triage'));
    await tester.pump();
    expect(selected, <(String, String)>[('chief', 'chief-1')]);
  });

  testWidgets('search filters by name and role; closing clears it', (
    tester,
  ) async {
    await pumpPhone(
      tester,
      MobileAgentList(
        source: rosterWith(sample()),
        onSelect: (_, _) {},
        now: () => now,
      ),
    );
    await tester.tap(findId('mobile_home_search'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'ops');
    await tester.pumpAndSettle();
    expect(find.text('Chief of Staff'), findsOneWidget);
    expect(find.text('Design'), findsNothing);

    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pumpAndSettle();
    expect(find.text('No agent matches.'), findsOneWidget);

    // While searching, the leading target closes the search again.
    await tester.tap(findId('mobile_home_search_close'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Design'), findsOneWidget);
  });

  testWidgets('empty roster shows the add call to action', (tester) async {
    int adds = 0;
    await pumpPhone(
      tester,
      MobileAgentList(
        source: rosterWith(const <AgentsAgent>[]),
        onSelect: (_, _) {},
        onAddAgent: () => adds++,
        now: () => now,
      ),
    );
    expect(find.text('No agents yet.'), findsOneWidget);
    await tester.tap(find.text('Add an agent'));
    expect(adds, 1);
  });

  testWidgets('the sidebar shape: a summary line instead of All / Unread, a '
      'word about a silent Sidekick, and the footer', (tester) async {
    final source = rosterWith(<AgentsAgent>[
      agent(
        id: 'sb-chief',
        name: 'Chief of Staff',
        role: 'ops',
        running: true,
        threads: <AgentsThreadInfo>[
          AgentsThreadInfo(key: 'sidebar-chief', title: 'default'),
        ],
      ),
      agent(
        id: 'sb-design',
        name: 'Design',
        brief: 'Proposes UI directions',
        threads: <AgentsThreadInfo>[
          AgentsThreadInfo(key: 'sidebar-design', title: 'default'),
        ],
      ),
      agent(
        id: 'sb-inbox',
        name: 'Inbox Triage',
        threads: <AgentsThreadInfo>[
          AgentsThreadInfo(key: 'sidebar-inbox', title: 'default'),
        ],
      ),
    ]);
    storeLine('sidebar-chief', 'Digest sent', fromUser: false, at: now);
    await pumpPhone(
      tester,
      MobileAgentList(
        source: source,
        onSelect: (_, _) {},
        now: () => now,
        headerCenter: const SizedBox(width: 120, height: 40),
        summaryLine: true,
        footer: const Text('the footer'),
      ),
    );
    await tester.pump(const Duration(seconds: 1));

    // One line counts the list; the filter is gone.
    expect(find.text('All'), findsNothing);
    expect(find.text('Unread'), findsNothing);
    final Finder summary = find.byKey(
      const ValueKey<String>('mobile_list_summary'),
    );
    expect(summary, findsOneWidget);
    expect(
      find.descendant(
        of: summary,
        matching: find.textContaining('3 Sidekicks', findRichText: true),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: summary,
        matching: find.textContaining('1 working', findRichText: true),
      ),
      findsOneWidget,
    );
    // What was said wins; a silent Sidekick says what it is for, or that it
    // is new.
    expect(find.text('Digest sent'), findsOneWidget);
    expect(find.text('ops'), findsNothing);
    expect(find.text('Proposes UI directions'), findsOneWidget);
    expect(find.text('No messages yet'), findsOneWidget);
    // The footer floats at the bottom, under the last row.
    final Rect footer = tester.getRect(find.text('the footer'));
    final Rect last = tester.getRect(find.text('Inbox Triage'));
    final Size screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(footer.bottom, lessThanOrEqualTo(screen.height));
    expect(footer.top, greaterThan(last.bottom));
  });

  testWidgets('the list follows the roster', (tester) async {
    final source = rosterWith(sample());
    await pumpPhone(
      tester,
      MobileAgentList(source: source, onSelect: (_, _) {}, now: () => now),
    );
    source.hideAgent('design');
    await tester.pump();
    expect(find.text('Design'), findsNothing);
  });

  test('rosterTimeLabel: today, yesterday, weekday, date, none', () {
    expect(rosterTimeLabel(null, now: now), '');
    expect(
      rosterTimeLabel(
        DateTime(2026, 9, 5, 9, 5),
        now: now,
        alwaysUse24HourFormat: true,
      ),
      '09:05',
    );
    expect(rosterTimeLabel(DateTime(2026, 9, 5, 9, 5), now: now), '9:05 AM');
    expect(rosterTimeLabel(DateTime(2026, 9, 5, 0, 0), now: now), '12:00 AM');
    expect(
      rosterTimeLabel(DateTime(2026, 9, 4, 23, 59), now: now),
      'Yesterday',
    );
    expect(rosterTimeLabel(DateTime(2026, 9, 1), now: now), 'Tue');
    expect(rosterTimeLabel(DateTime(2026, 8, 20), now: now), '20.8.');
  });

  test('accountMonogram', () {
    expect(accountMonogram(null), '');
    expect(accountMonogram('Sam Lee'), 'SL');
    expect(accountMonogram('sam.lee@example.com'), 'S');
    expect(accountMonogram('  '), '');
  });

  test('MobileAgentRow.previewOf is the last message and nothing else', () {
    AgentsAgent withThread(String key, String title, {bool running = false}) =>
        agent(
          id: 'a',
          name: 'A',
          brief: 'Do X',
          role: 'ops',
          running: running,
          threads: <AgentsThreadInfo>[AgentsThreadInfo(key: key, title: title)],
        );

    // A live run does not replace what was said.
    storeLine('preview-run', 'Said earlier', fromUser: false);
    expect(
      MobileAgentRow.previewOf(
        withThread('preview-run', 'Digest', running: true),
      ),
      'Said earlier',
    );
    storeLine('preview-them', 'Digest sent', fromUser: false);
    expect(
      MobileAgentRow.previewOf(withThread('preview-them', 'Digest')),
      'Digest sent',
    );
    storeLine('preview-you', 'Ship the palette', fromUser: true);
    expect(
      MobileAgentRow.previewOf(withThread('preview-you', 'Digest')),
      'You: Ship the palette',
    );
    // No stored line: empty, never the title or the brief.
    expect(MobileAgentRow.previewOf(withThread('preview-title', 'Digest')), '');
    expect(
      MobileAgentRow.previewOf(
        agent(id: 'a', name: 'A', threads: const <AgentsThreadInfo>[]),
      ),
      '',
    );
  });

  testWidgets('a long name keeps the row at 360 px and 1.3', (tester) async {
    await pumpPhone(
      tester,
      Builder(
        builder: (BuildContext context) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.3)),
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 360,
              child: MobileAgentRow(
                agent: agent(id: 'amber', name: 'Amber', role: 'Research'),
                now: DateTime(2026, 1, 5, 15),
              ),
            ),
          ),
        ),
      ),
    );
    expect(
      tester
          .renderObject<RenderParagraph>(find.text('Amber'))
          .didExceedMaxLines,
      isFalse,
    );
    expect(find.text('Research'), findsNothing, reason: 'no role tag');
    expect(tester.takeException(), isNull);
  });
}
