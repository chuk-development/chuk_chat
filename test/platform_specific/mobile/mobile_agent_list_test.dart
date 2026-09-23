import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/platform_specific/mobile/mobile_agent_list.dart';
import 'package:chuk_chat/platform_specific/mobile/mobile_layout.dart';
import 'package:chuk_chat/services/agents/thread_preview_store.dart';

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
  void storeLine(String threadKey, String text, {required bool fromUser}) =>
      ThreadPreviewStore.instance.noteRows(threadKey, <Map<String, dynamic>>[
        <String, dynamic>{'role': fromUser ? 'user' : 'assistant', 'text': text},
      ]);

  testWidgets('renders one row per visible coworker with preview and time',
      (tester) async {
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
        brief: 'Proposes UI directions',
        lastActivity: now.subtract(const Duration(days: 1)),
        threads: <AgentsThreadInfo>[
          AgentsThreadInfo(key: 'render-design', title: 'default'),
        ],
      ),
      agent(
        id: 'inbox',
        name: 'Inbox Triage',
        threads: const <AgentsThreadInfo>[],
      ),
    ];
    // The working coworker has a stored line too — a live run has to outrank
    // it, or the row would report what was said before the run started.
    storeLine('render-chief', 'Digest sent', fromUser: false);

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
    expect(find.text('Chief of Staff'), findsOneWidget);
    expect(find.text('Working…'), findsOneWidget);
    expect(find.text('Digest sent'), findsNothing);
    expect(find.text('2:27 PM'), findsOneWidget);
    // No stored line, and 'default' is a placeholder rather than a title, so
    // the brief carries this row.
    expect(find.text('Design'), findsOneWidget);
    expect(find.text('Proposes UI directions'), findsOneWidget);
    expect(find.text('Yesterday'), findsOneWidget);
    // Nothing ever happened here: the line stays empty. "No activity yet"
    // under every row of a fresh install said nothing and read as an error.
    expect(find.text('Inbox Triage'), findsOneWidget);
    expect(find.text('No activity yet'), findsNothing);
    expect(
      find.descendant(
        of: findId('mobile-agent-row-inbox'),
        matching: find.text(''),
      ),
      findsOneWidget,
      reason: 'the preview line of a silent coworker is empty',
    );
    // No account target up here any more: settings has one way in, the
    // navigation bar.
    expect(find.text('SL'), findsNothing, reason: 'no account monogram');
    expect(find.text('ops'), findsOneWidget, reason: 'role tag');
    // The unread mark is a count, not a dot: one thread with something new.
    expect(
      find.descendant(
        of: findId('mobile-agent-row-chief'),
        matching: find.text('1'),
      ),
      findsOneWidget,
      reason: 'unread badge counts the threads with something new',
    );

    // A line arrives for the idle coworker: it beats the brief, and the list
    // follows the store without being rebuilt by its caller.
    storeLine('render-design', 'Ship the palette', fromUser: true);
    await tester.pump();
    expect(find.text('You: Ship the palette'), findsOneWidget);
    expect(find.text('Proposes UI directions'), findsNothing);
  });

  testWidgets('rows are a real touch target and start under the header row',
      (tester) async {
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
    expect(find.text('Agents'), findsNothing);
    expect(find.text('All'), findsOneWidget);
    // The segment carries its unread count, so the label is "Unread $n".
    expect(find.textContaining('Unread'), findsOneWidget);
  });

  testWidgets('tap opens the first thread; a coworker without threads is inert',
      (tester) async {
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

  testWidgets('search filters by name and role; closing clears it',
      (tester) async {
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

  test('mobileTimeLabel: today, yesterday, weekday, date, none', () {
    expect(mobileTimeLabel(null, now: now), '');
    expect(mobileTimeLabel(DateTime(2026, 9, 5, 9, 5), now: now), '9:05 AM');
    expect(mobileTimeLabel(DateTime(2026, 9, 5, 0, 0), now: now), '12:00 AM');
    expect(mobileTimeLabel(DateTime(2026, 9, 4, 23, 59), now: now), 'Yesterday');
    expect(mobileTimeLabel(DateTime(2026, 9, 1), now: now), 'Tue');
    expect(mobileTimeLabel(DateTime(2026, 8, 20), now: now), '20.8.');
  });

  test('accountMonogram', () {
    expect(accountMonogram(null), '');
    expect(accountMonogram('Sam Lee'), 'SL');
    expect(accountMonogram('sam.lee@example.com'), 'S');
    expect(accountMonogram('  '), '');
  });

  test('MobileAgentRow.previewOf', () {
    AgentsAgent withThread(String key, String title) => agent(
          id: 'a',
          name: 'A',
          threads: <AgentsThreadInfo>[AgentsThreadInfo(key: key, title: title)],
        );

    // A live run outranks everything, including a stored line.
    storeLine('preview-run', 'Said earlier', fromUser: false);
    expect(
      MobileAgentRow.previewOf(agent(
        id: 'a',
        name: 'A',
        running: true,
        threads: <AgentsThreadInfo>[
          AgentsThreadInfo(key: 'preview-run', title: 'Digest'),
        ],
      )),
      'Working…',
    );

    // What was actually said last beats the thread title, and the row says
    // who said it.
    storeLine('preview-them', 'Digest sent', fromUser: false);
    expect(MobileAgentRow.previewOf(withThread('preview-them', 'Digest')),
        'Digest sent');
    storeLine('preview-you', 'Ship the palette', fromUser: true);
    expect(MobileAgentRow.previewOf(withThread('preview-you', 'Digest')),
        'You: Ship the palette');

    // No stored line: the thread title.
    expect(MobileAgentRow.previewOf(withThread('preview-title', 'Digest')),
        'Digest');

    // 'default' and 'General' are placeholders, not titles, so they fall
    // through to the brief.
    expect(
      MobileAgentRow.previewOf(agent(
        id: 'a',
        name: 'A',
        brief: 'Do X',
        threads: <AgentsThreadInfo>[
          AgentsThreadInfo(key: 'preview-brief', title: 'default'),
        ],
      )),
      'Do X',
    );
    expect(
      MobileAgentRow.previewOf(agent(
        id: 'a',
        name: 'A',
        brief: 'Do X',
        threads: <AgentsThreadInfo>[
          AgentsThreadInfo(key: 'preview-brief2', title: 'General'),
        ],
      )),
      'Do X',
    );

    // Nothing to say: an empty line, not "No activity yet".
    expect(
      MobileAgentRow.previewOf(
        agent(id: 'a', name: 'A', threads: const <AgentsThreadInfo>[]),
      ),
      '',
    );
  });
}
