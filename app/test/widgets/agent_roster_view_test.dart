import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cowork/models/cowork_agent.dart';
import 'package:cowork/services/cowork/agent_roster_source.dart';
import 'package:cowork/services/cowork/schedule_spec.dart';
import 'package:cowork/widgets/agent_avatar.dart';
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
    test('the host agent is added once with one thread keyed by its id', () {
      final source = LocalAgentRosterSource();
      final first = source.ensureHostAgent('cowork-host');
      final again = source.ensureHostAgent('cowork-host');

      expect(source.agents, hasLength(1));
      expect(first.id, again.id);
      expect(first.onHost, isTrue);
      // One permanent session per bot: the session key is the stable agent id.
      expect(first.threads.single.key, first.id);
    });

    test('an app-created agent is not claimed to be on the host', () {
      final source = LocalAgentRosterSource(random: Random(4));
      final agent = source.addAgent(name: 'amber-otter', brief: 'do a thing');

      expect(agent.onHost, isFalse);
      expect(agent.brief, 'do a thing');
      expect(agent.threads, hasLength(1));
      expect(agent.activity, AgentActivity.waiting);
    });

    test('an added agent has one permanent thread keyed by its id, notifies once',
        () {
      final source = LocalAgentRosterSource(random: Random(5));
      var notifications = 0;
      source.addListener(() => notifications++);

      final agent = source.addAgent(name: 'amber-otter');

      // Exactly one permanent thread, and its key is the stable agent id.
      expect(source.byId(agent.id)!.threads, hasLength(1));
      expect(agent.threads.single.key, agent.id);
      expect(notifications, 1);
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

  group('SESSIONS | BOTS tabs (§16.1)', () {
    testWidgets('Bots is the default; Sessions lists threads most-recent first',
        (tester) async {
      final source = LocalAgentRosterSource(random: Random(11));
      final a = source.addAgent(name: 'amber-otter');
      final b = source.addAgent(name: 'cobalt-lynx');
      // Give each a distinct thread activity time.
      source.markActivity(a.id, a.threads.first.key, DateTime(2026, 8, 13, 9));
      source.markActivity(b.id, b.threads.first.key, DateTime(2026, 8, 13, 11));
      final picks = await pumpRoster(tester, source);

      // Default tab: Bots. The activity-dot subtitle from a bot row is present.
      expect(find.text('waiting · 3h ago'), findsWidgets);

      // Switch to Sessions.
      await tester.tap(find.text('Sessions'));
      await tester.pumpAndSettle();

      // Both threads listed, each labelled "General · <when>".
      expect(find.textContaining('General · '), findsNWidgets(2));

      // The two agent names appear; the most recent (cobalt-lynx, 11:00) is
      // above the older (amber-otter, 09:00).
      final cobaltY = tester.getTopLeft(find.text('cobalt-lynx')).dy;
      final amberY = tester.getTopLeft(find.text('amber-otter')).dy;
      expect(cobaltY, lessThan(amberY));

      // Tapping a session selects that agent's thread.
      await tester.tap(find.text('amber-otter'));
      expect(picks.last.$1, a.id);
      expect(picks.last.$2, a.threads.first.key);
    });

    testWidgets('an empty Sessions tab says so', (tester) async {
      final source = LocalAgentRosterSource(random: Random(12));
      await pumpRoster(tester, source);
      await tester.tap(find.text('Sessions'));
      await tester.pumpAndSettle();
      expect(find.text('No conversations yet.'), findsOneWidget);
    });
  });

  group('role (§16.1)', () {
    testWidgets('a role shows under the name; no role means no extra line',
        (tester) async {
      final source = LocalAgentRosterSource(random: Random(9));
      source.addAgent(name: 'amber-otter', role: 'researcher');
      source.addAgent(name: 'cobalt-lynx');
      await pumpRoster(tester, source);

      expect(find.text('researcher'), findsOneWidget);
      // The second agent has no role, so only the one label exists.
      expect(find.text('amber-otter'), findsOneWidget);
      expect(find.text('cobalt-lynx'), findsOneWidget);
    });
  });

  group('delete an agent (§16.1)', () {
    testWidgets('a non-host agent offers Delete; the host agent does not',
        (tester) async {
      final source = LocalAgentRosterSource(random: Random(30));
      source.ensureHostAgent('host-laptop'); // onHost = true
      source.addAgent(name: 'amber-otter'); // local, onHost = false
      final deleted = <String>[];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AgentRosterView(
              source: source,
              now: () => DateTime(2026, 8, 22, 12),
              onSelect: (_, __) {},
              onDeleteAgent: deleted.add,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The local agent's menu has Delete.
      final localMenu = find.descendant(
        of: find.widgetWithText(ListTile, 'amber-otter'),
        matching: find.byIcon(Icons.more_vert),
      );
      await tester.tap(localMenu);
      await tester.pumpAndSettle();
      expect(find.text('Delete'), findsOneWidget);
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(deleted, hasLength(1));

      // The host agent's menu has no Delete.
      final hostMenu = find.descendant(
        of: find.widgetWithText(ListTile, 'host-laptop'),
        matching: find.byIcon(Icons.more_vert),
      );
      await tester.tap(hostMenu);
      await tester.pumpAndSettle();
      expect(find.text('Delete'), findsNothing);
      expect(find.text('Hide'), findsOneWidget);
    });
  });

  group('hide / unhide (§16.1)', () {
    test('hiding removes an agent from the visible roster, keeps it in agents',
        () {
      final source = LocalAgentRosterSource(random: Random(3));
      final a = source.addAgent(name: 'amber-otter');
      source.addAgent(name: 'cobalt-lynx');

      var notified = 0;
      source.addListener(() => notified++);

      source.hideAgent(a.id);
      expect(notified, 1);
      expect(source.hiddenIds, contains(a.id));
      expect(source.visibleAgents.map((e) => e.name), ['cobalt-lynx']);
      expect(source.hiddenAgents.map((e) => e.name), ['amber-otter']);
      // The agent itself is untouched — hiding is a view preference.
      expect(source.byId(a.id), isNotNull);
      expect(source.agents, hasLength(2));

      source.unhideAgent(a.id);
      expect(notified, 2);
      expect(source.hiddenIds, isEmpty);
      expect(source.visibleAgents, hasLength(2));
    });

    test('hiding an unknown or already-hidden id does not notify', () {
      final source = LocalAgentRosterSource(random: Random(4));
      final a = source.addAgent(name: 'amber-otter');
      var notified = 0;
      source.addListener(() => notified++);

      source.hideAgent('nope');
      expect(notified, 0);

      source.hideAgent(a.id);
      expect(notified, 1);
      source.hideAgent(a.id); // already hidden
      expect(notified, 1);
    });

    test('removing a hidden agent drops the hidden mark', () {
      final source = LocalAgentRosterSource(random: Random(5));
      final a = source.addAgent(name: 'amber-otter');
      source.hideAgent(a.id);
      expect(source.hiddenIds, contains(a.id));
      source.removeAgent(a.id);
      expect(source.hiddenIds, isEmpty);
    });

    testWidgets('the roster hides a picked agent and unhides it again',
        (tester) async {
      final source = LocalAgentRosterSource(random: Random(6));
      source.addAgent(name: 'amber-otter');
      source.addAgent(name: 'cobalt-lynx');
      await pumpRoster(tester, source);

      expect(find.text('amber-otter'), findsOneWidget);

      // Open the first row's menu and hide it.
      await tester.tap(find.byIcon(Icons.more_vert).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hide'));
      await tester.pumpAndSettle();

      expect(source.hiddenIds, hasLength(1));
      expect(find.text('Hidden (1)'), findsOneWidget);

      // Expand the hidden section and unhide.
      await tester.tap(find.text('Hidden (1)'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Unhide'));
      await tester.pumpAndSettle();

      expect(source.hiddenIds, isEmpty);
      expect(find.text('Hidden (1)'), findsNothing);
    });
  });

  group('active now strip (§16.1)', () {
    testWidgets('shows the working agents and nothing when none work',
        (tester) async {
      final source = LocalAgentRosterSource(random: Random(7));
      final a = source.addAgent(name: 'amber-otter');
      source.addAgent(name: 'cobalt-lynx');
      await pumpRoster(tester, source);

      expect(find.text('Active now'), findsNothing);

      source.markRunning(a.id, true);
      await tester.pumpAndSettle();
      expect(find.text('Active now'), findsOneWidget);

      source.markRunning(a.id, false);
      await tester.pumpAndSettle();
      expect(find.text('Active now'), findsNothing);
    });
  });

  group('AgentAvatar (§16.1)', () {
    test('the colour is stable for a seed and the monogram is the initial', () {
      expect(AgentAvatar.hueOf('host:cowork-host'),
          AgentAvatar.hueOf('host:cowork-host'));
      expect(AgentAvatar.monogramOf('amber-otter'), 'A');
      expect(AgentAvatar.monogramOf('  '), '?');
      expect(AgentAvatar.monogramOf(''), '?');
    });

    test('different seeds generally differ in hue', () {
      final hues = {
        for (final s in ['a', 'b', 'c', 'amber-otter', 'cobalt-lynx'])
          AgentAvatar.hueOf(s),
      };
      // Not a guarantee of no collision ever, but five distinct short seeds
      // must not all fold to one hue.
      expect(hues.length, greaterThan(1));
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
