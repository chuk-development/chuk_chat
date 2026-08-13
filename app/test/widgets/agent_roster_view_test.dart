import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cowork/models/cowork_agent.dart';
import 'package:cowork/services/cowork/agent_roster_source.dart';
import 'package:cowork/services/cowork/schedule_spec.dart';
import 'package:cowork/widgets/agent_roster_view.dart';

void main() {
  final DateTime now = DateTime(2026, 8, 13, 12);

  Future<List<(String, String)>> pumpRoster(
    WidgetTester tester,
    AgentRosterSource source, {
    String? selectedAgentId,
    String? selectedThreadKey,
    VoidCallback? onAddAgent,
  }) async {
    final picks = <(String, String)>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentRosterView(
            source: source,
            selectedAgentId: selectedAgentId,
            selectedThreadKey: selectedThreadKey,
            onAddAgent: onAddAgent,
            now: () => now,
            onSelect: (agentId, threadKey) => picks.add((agentId, threadKey)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return picks;
  }

  testWidgets('an empty roster says so and offers onboarding', (tester) async {
    var opened = 0;
    await pumpRoster(
      tester,
      LocalAgentRosterSource(),
      onAddAgent: () => opened++,
    );

    expect(find.text('No coworkers yet.'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Add an agent'));
    expect(opened, 1);
  });

  testWidgets('entries show the name, the state and the last activity',
      (tester) async {
    final source = LocalAgentRosterSource(random: Random(1));
    source.ensureHostAgent('cowork-host');
    final scheduled = source.addAgent(
      name: 'amber-otter',
      brief: 'weekly news',
      schedule: ScheduleSpec.parse('every 1d'),
    );
    final busy = source.addAgent(name: 'cobalt-lynx', brief: 'watch the build');
    source.markRunning(busy.id, true);
    source.markActivity(busy.id, busy.threads.first.key,
        now.subtract(const Duration(minutes: 5)));

    await pumpRoster(tester, source);

    expect(find.text('cowork-host'), findsOneWidget);
    expect(find.text('amber-otter'), findsOneWidget);
    expect(find.text('cobalt-lynx'), findsOneWidget);
    // The host agent has seen nothing yet: it says so, it does not show a time.
    expect(find.textContaining('waiting · no activity yet'), findsOneWidget);
    expect(find.textContaining('working · 5m ago'), findsOneWidget);
    expect(find.textContaining('scheduled · no activity yet'), findsOneWidget);
    expect(scheduled.activity, AgentActivity.scheduled);
  });

  testWidgets('picking an agent reports its first thread', (tester) async {
    final source = LocalAgentRosterSource(random: Random(2));
    final agent = source.addAgent(name: 'amber-otter', brief: 'x');
    final picks = await pumpRoster(tester, source);

    await tester.tap(find.text('amber-otter'));
    await tester.pumpAndSettle();

    expect(picks, <(String, String)>[(agent.id, agent.threads.first.key)]);
  });

  testWidgets('a second thread is listed and switches the selection',
      (tester) async {
    final source = LocalAgentRosterSource(random: Random(3));
    final agent = source.addAgent(name: 'amber-otter', brief: 'x');
    final second = source.addThread(agent.id, title: 'Invoices');

    final picks = await pumpRoster(
      tester,
      source,
      selectedAgentId: agent.id,
      selectedThreadKey: agent.threads.first.key,
    );

    // The selected agent shows its threads.
    expect(find.text('General'), findsOneWidget);
    expect(find.text('Invoices'), findsOneWidget);

    await tester.tap(find.text('Invoices'));
    await tester.pumpAndSettle();

    expect(picks.last, (agent.id, second.key));
  });

  group('lastActivityLabel', () {
    test('never invents a time', () {
      expect(lastActivityLabel(null, now: now), 'no activity yet');
      expect(
        lastActivityLabel(now.subtract(const Duration(seconds: 5)), now: now),
        'just now',
      );
      expect(
        lastActivityLabel(now.subtract(const Duration(minutes: 5)), now: now),
        '5m ago',
      );
      expect(
        lastActivityLabel(now.subtract(const Duration(hours: 3)), now: now),
        '3h ago',
      );
      expect(
        lastActivityLabel(now.subtract(const Duration(days: 2)), now: now),
        '2d ago',
      );
    });
  });

  group('LocalAgentRosterSource', () {
    test('the host agent is added once and keeps the default session key', () {
      final source = LocalAgentRosterSource();
      final first = source.ensureHostAgent('cowork-host');
      final again = source.ensureHostAgent('cowork-host');

      expect(source.agents, hasLength(1));
      expect(first.id, again.id);
      expect(first.onHost, isTrue);
      // `default` is what the executor falls back to, so the first thread must
      // be exactly that key.
      expect(first.threads.single.key, 'default');
    });

    test('an app-created agent is not claimed to be on the host', () {
      final source = LocalAgentRosterSource(random: Random(4));
      final agent = source.addAgent(name: 'amber-otter', brief: 'do a thing');

      expect(agent.onHost, isFalse);
      expect(agent.brief, 'do a thing');
      expect(agent.threads, hasLength(1));
      expect(agent.activity, AgentActivity.waiting);
    });

    test('threads get distinct keys and notify listeners', () {
      final source = LocalAgentRosterSource(random: Random(5));
      var notifications = 0;
      source.addListener(() => notifications++);

      final agent = source.addAgent(name: 'amber-otter');
      final a = source.addThread(agent.id);
      final b = source.addThread(agent.id, title: 'Invoices');

      expect(a.key, isNot(b.key));
      expect(b.title, 'Invoices');
      expect(source.byId(agent.id)!.threads, hasLength(3));
      expect(notifications, 3);
    });

    test('markRunning drives the activity, markActivity the timestamps', () {
      final source = LocalAgentRosterSource(random: Random(6));
      final agent = source.addAgent(name: 'amber-otter');
      final key = agent.threads.first.key;

      source.markRunning(agent.id, true);
      expect(source.byId(agent.id)!.activity, AgentActivity.working);

      final when = DateTime(2026, 8, 13, 11, 30);
      source.markActivity(agent.id, key, when);
      expect(source.byId(agent.id)!.lastActivity, when);
      expect(source.byId(agent.id)!.threads.first.lastActivity, when);

      source.markRunning(agent.id, false);
      expect(source.byId(agent.id)!.activity, AgentActivity.waiting);
    });

    test('a schedule set in the app lands on the agent', () {
      final source = LocalAgentRosterSource(random: Random(7));
      final agent = source.addAgent(name: 'amber-otter');
      source.setSchedule(agent.id, ScheduleSpec.parse('0 9 * * *'));

      expect(source.byId(agent.id)!.schedule!.source, '0 9 * * *');
      expect(source.byId(agent.id)!.activity, AgentActivity.scheduled);
    });

    test('an unknown agent id is ignored, not fatal', () {
      final source = LocalAgentRosterSource();
      source.markRunning('nope', true);
      source.markActivity('nope', 'default', DateTime(2026));
      source.setSchedule('nope', ScheduleSpec.parse('every 5m'));
      source.removeAgent('nope');
      expect(source.agents, isEmpty);
    });
  });

  group('AgentNameGenerator', () {
    test('gives adjective-noun names and avoids the ones already taken', () {
      const generator = AgentNameGenerator();
      final name = generator.next();
      expect(name.split('-'), hasLength(2));
      expect(AgentNameGenerator.adjectives, contains(name.split('-').first));
      expect(AgentNameGenerator.nouns, contains(name.split('-').last));

      final taken = <String>{};
      for (var i = 0; i < 20; i++) {
        final fresh = generator.next(taken: taken);
        expect(taken.contains(fresh), isFalse);
        taken.add(fresh);
      }
    });
  });
}
