import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cowork/models/cowork_agent.dart';
import 'package:cowork/platform_specific/mobile/mobile_agent_list.dart';
import 'package:cowork/platform_specific/mobile/mobile_layout.dart';

import 'mobile_support.dart';

void main() {
  final DateTime now = DateTime(2026, 9, 5, 14, 30);

  List<CoworkAgent> sample() => <CoworkAgent>[
        agent(
          id: 'chief',
          name: 'Chief of Staff',
          role: 'ops',
          running: true,
          lastActivity: now.subtract(const Duration(minutes: 3)),
          threads: <CoworkThreadInfo>[
            CoworkThreadInfo(key: 'chief-1', title: 'Morning digest'),
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
          threads: const <CoworkThreadInfo>[],
        ),
      ];

  testWidgets('renders one row per visible coworker with preview and time',
      (tester) async {
    await pumpPhone(
      tester,
      MobileAgentList(
        source: rosterWith(sample()),
        onSelect: (_, _) {},
        onAddAgent: () {},
        onOpenAccount: () {},
        accountLabel: 'Sam Lee',
        now: () => now,
      ),
    );
    expect(find.text('Chief of Staff'), findsOneWidget);
    expect(find.text('Working…'), findsOneWidget);
    expect(find.text('2:27 PM'), findsOneWidget);
    expect(find.text('Design'), findsOneWidget);
    expect(find.text('Proposes UI directions'), findsOneWidget);
    expect(find.text('Yesterday'), findsOneWidget);
    expect(find.text('Inbox Triage'), findsOneWidget);
    expect(find.text('No activity yet'), findsOneWidget);
    expect(find.text('SL'), findsOneWidget, reason: 'account monogram');
    expect(find.text('ops'), findsOneWidget, reason: 'role tag');
  });

  testWidgets('rows are at least 48 dp and the first row starts under the bar',
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
    expect(first.top, kPhonePadding.top + MobileLayout.barHeight);
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
    expect(find.text('No coworker matches.'), findsOneWidget);

    await tester.tap(findId('mobile_home_search'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Design'), findsOneWidget);
  });

  testWidgets('empty roster shows the add call to action', (tester) async {
    int adds = 0;
    await pumpPhone(
      tester,
      MobileAgentList(
        source: rosterWith(const <CoworkAgent>[]),
        onSelect: (_, _) {},
        onAddAgent: () => adds++,
        now: () => now,
      ),
    );
    expect(find.text('No coworkers yet.'), findsOneWidget);
    await tester.tap(find.text('Add a coworker'));
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

  test('MobileHomeBar.monogramOf', () {
    expect(MobileHomeBar.monogramOf(null), '');
    expect(MobileHomeBar.monogramOf('Sam Lee'), 'SL');
    expect(MobileHomeBar.monogramOf('sam.lee@example.com'), 'S');
    expect(MobileHomeBar.monogramOf('  '), '');
  });

  test('MobileAgentRow.previewOf', () {
    expect(MobileAgentRow.previewOf(agent(id: 'a', name: 'A', running: true)),
        'Working…');
    expect(
      MobileAgentRow.previewOf(agent(
        id: 'a',
        name: 'A',
        threads: <CoworkThreadInfo>[CoworkThreadInfo(key: 'k', title: 'Digest')],
      )),
      'Digest',
    );
    expect(MobileAgentRow.previewOf(agent(id: 'a', name: 'A', brief: 'Do X')),
        'Do X');
    expect(MobileAgentRow.previewOf(agent(id: 'a', name: 'A')), 'No activity yet');
  });
}
