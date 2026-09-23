import 'dart:async';
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';


import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/services/agents/agent_roster_source.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart'
    show AgentsHostAgentName;
import 'package:chuk_chat/services/agents/schedule_spec.dart';
import 'package:chuk_chat/widgets/agent_avatar.dart';
import 'package:chuk_chat/widgets/agent_roster_view.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/widgets/sidebar/sidebar_chrome.dart';
import 'package:chuk_chat/widgets/brand_wordmark.dart';
import 'package:chuk_chat/services/agents/agent_read_marks.dart';
import 'package:chuk_chat/ui/expressive/agent_face.dart';

void main() {
  final DateTime now = DateTime(2026, 8, 13, 12);

  setUp(() => DesktopRosterPins.instance.reset());

  testWidgets('Chuk Chat brand has no C logo', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentRosterView(
            source: LocalAgentRosterSource(),
            onSelect: (_, _) {},
          ),
        ),
      ),
    );
    // The frozen wordmark, no separate C logo next to it.
    expect(find.byType(BrandWordmark), findsOneWidget);
    expect(find.byType(SbBrand), findsNothing);
  });

  Future<List<(String, String)>> pumpRoster(
    WidgetTester tester,
    AgentRosterSource source, {
    String? selectedAgentId,
    String? selectedThreadKey,
    VoidCallback? onAddAgent,
    VoidCallback? onOpenRooms,
    VoidCallback? onOpenSettings,
    AgentReadMarks? readMarks,
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
            onOpenRooms: onOpenRooms,
            onOpenSettings: onOpenSettings,
            readMarks: readMarks,
            now: () => now,
            onSelect: (agentId, threadKey) => picks.add((agentId, threadKey)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return picks;
  }

  testWidgets('the New menu and the account row reach their surfaces', (
    tester,
  ) async {
    var rooms = 0, settings = 0, added = 0;
    final source = LocalAgentRosterSource()..addAgent(name: 'amber-otter');
    await pumpRoster(
      tester,
      source,
      onAddAgent: () => added++,
      onOpenRooms: () => rooms++,
      onOpenSettings: () => settings++,
    );

    await tester.tap(find.byTooltip('New'));
    await tester.pumpAndSettle();
    // A desktop menu: the shortcuts are printed next to the rows.
    expect(find.text('Ctrl+N'), findsOneWidget);
    await tester.tap(find.text('Control Rooms'));
    await tester.pumpAndSettle();
    expect(find.text("Agent's browser"), findsNothing);
    await tester.tap(find.byTooltip('Settings'));
    expect((rooms, settings), (1, 1));
    // The account row itself opens settings too.
    await tester.tap(find.text('Account'));
    expect(settings, 2);
    expect(added, 0);
  });

  testWidgets('without callbacks the New menu and the account row are absent', (
    tester,
  ) async {
    await pumpRoster(tester, LocalAgentRosterSource()..addAgent(name: 'jade'));

    expect(find.byTooltip('New'), findsNothing);
    expect(find.text("Agent's browser"), findsNothing);
    expect(find.byTooltip('Settings'), findsNothing);
    expect(find.text('Account'), findsNothing);
    // The list still renders its coworker.
    expect(find.text('jade'), findsOneWidget);
  });

  testWidgets('an empty roster says so and offers onboarding', (tester) async {
    var opened = 0;
    await pumpRoster(
      tester,
      LocalAgentRosterSource(),
      onAddAgent: () => opened++,
    );

    expect(find.text('No agents yet.'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Add an agent'));
    expect(opened, 1);
  });

  testWidgets('entries show the name, the state and the last activity', (
    tester,
  ) async {
    final source = LocalAgentRosterSource(random: Random(1));
    source.ensureHostAgent('cowork-host');
    final scheduled = source.addAgent(
      name: 'amber-otter',
      brief: 'weekly news',
      schedule: ScheduleSpec.parse('every 1d'),
    );
    final busy = source.addAgent(name: 'cobalt-lynx', brief: 'watch the build');
    source.markRunning(busy.id, true);
    source.markActivity(
      busy.id,
      busy.threads.first.key,
      now.subtract(const Duration(minutes: 5)),
    );

    // Read up to now: a time, not the unread dot, is what the row shows.
    final marks = AgentReadMarks();
    // Not awaited: the write waits on a debounce timer the test never runs.
    unawaited(marks.markRead(busy.threads.first.key, when: now));
    await pumpRoster(tester, source, readMarks: marks);

    expect(find.text('cowork-host'), findsOneWidget);
    expect(find.text('amber-otter'), findsOneWidget);
    expect(find.text('cobalt-lynx'), findsOneWidget);
    // A working agent says so; the others show when they last did
    // something, and nothing at all when nothing happened yet — never a time
    // the app made up.
    Finder inRow(String id, Finder f) => find.descendant(
      of: find.byKey(ValueKey<String>('agent-tile-$id')),
      matching: f,
    );
    expect(inRow(busy.id, find.text('working')), findsOneWidget);
    expect(find.textContaining('no activity yet'), findsNothing);
    expect(inRow(scheduled.id, find.text('')), findsOneWidget);
    source.markRunning(busy.id, false);
    await tester.pumpAndSettle();
    expect(inRow(busy.id, find.text('5m')), findsOneWidget);
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

    test(
      'an added agent has one permanent thread keyed by its id, notifies once',
      () {
        final source = LocalAgentRosterSource(random: Random(5));
        var notifications = 0;
        source.addListener(() => notifications++);

        final agent = source.addAgent(name: 'amber-otter');

        // Exactly one permanent thread, and its key is the stable agent id.
        expect(source.byId(agent.id)!.threads, hasLength(1));
        expect(agent.threads.single.key, agent.id);
        expect(notifications, 1);
      },
    );

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

  group('dense rows (docs/DESIGN.md §14.3)', () {
    testWidgets('an agent row is one 36 px line with a 24 px face', (
      tester,
    ) async {
      final source = LocalAgentRosterSource(random: Random(9));
      final a = source.addAgent(name: 'amber-otter', role: 'researcher');
      await pumpRoster(tester, source);

      final Finder row = find.byKey(ValueKey<String>('agent-tile-${a.id}'));
      expect(tester.getSize(row).height, 36);
      // No second line on the desktop: the role lives in the details pane.
      expect(find.text('researcher'), findsNothing);
      expect(
        tester
            .widget<AgentFace>(
              find.descendant(of: row, matching: find.byType(AgentFace)),
            )
            .size,
        24,
      );
    });

    testWidgets('the selected row is filled and carries the accent bar', (
      tester,
    ) async {
      final source = LocalAgentRosterSource(random: Random(9));
      final a = source.addAgent(name: 'amber-otter');
      final b = source.addAgent(name: 'cobalt-lynx');
      await pumpRoster(
        tester,
        source,
        selectedAgentId: a.id,
        selectedThreadKey: a.threads.single.key,
      );
      Finder bar(String id) => find.descendant(
        of: find.byKey(ValueKey<String>('agent-tile-$id')),
        matching: find.byKey(const ValueKey<String>('roster-selected-bar')),
      );
      expect(bar(a.id), findsOneWidget);
      expect(bar(b.id), findsNothing);
      expect(tester.getSize(bar(a.id)).width, 3);
    });

    testWidgets('the "…" shows on hover only, and opens the row menu', (
      tester,
    ) async {
      final source = LocalAgentRosterSource(random: Random(9));
      final a = source.addAgent(name: 'amber-otter');
      await pumpRoster(tester, source);
      final Finder row = find.byKey(ValueKey<String>('agent-tile-${a.id}'));
      final Finder more = find.descendant(
        of: row,
        matching: find.byTooltip('More'),
      );
      expect(more, findsNothing);

      final TestGesture mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(row));
      await tester.pumpAndSettle();
      expect(more, findsOneWidget);
      await tester.tap(more);
      await tester.pumpAndSettle();
      expect(find.text('Pin'), findsOneWidget);
      expect(find.text('Hide'), findsOneWidget);
    });

    testWidgets('unread is the bold name and a dot, no count', (tester) async {
      final source = LocalAgentRosterSource(random: Random(9));
      final a = source.addAgent(name: 'amber-otter');
      source.markActivity(a.id, a.threads.single.key, now);
      final marks = AgentReadMarks();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AgentRosterView(
              source: source,
              readMarks: marks,
              now: () => now,
              onSelect: (_, _) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final Finder row = find.byKey(ValueKey<String>('agent-tile-${a.id}'));
      expect(marks.isUnread(source.byId(a.id)!), isTrue);
      expect(
        find.descendant(
          of: row,
          matching: find.byKey(const ValueKey<String>('roster-unread-dot')),
        ),
        findsOneWidget,
      );
      final Text name = tester.widget<Text>(
        find.descendant(of: row, matching: find.text('amber-otter')),
      );
      expect(name.style?.fontWeight, FontWeight.w700);
    });

    testWidgets('Pin in the context menu moves the agent to the top', (
      tester,
    ) async {
      final source = LocalAgentRosterSource(random: Random(9));
      source.addAgent(name: 'amber-otter');
      final b = source.addAgent(name: 'cobalt-lynx');
      await pumpRoster(tester, source);
      double y(String name) => tester.getCenter(find.text(name)).dy;
      expect(y('amber-otter'), lessThan(y('cobalt-lynx')));

      await tester.tap(
        find.byKey(ValueKey<String>('agent-tile-${b.id}')),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pin'));
      await tester.pumpAndSettle();
      expect(y('cobalt-lynx'), lessThan(y('amber-otter')));
      expect(
        desktopRosterOrder(
          source.visibleAgents,
          DesktopRosterPins.instance.ids,
        ).first.id,
        b.id,
      );
    });

    testWidgets('the search field filters agents by name', (tester) async {
      final source = LocalAgentRosterSource(random: Random(9));
      source.addAgent(name: 'amber-otter');
      source.addAgent(name: 'cobalt-lynx');
      await pumpRoster(tester, source);
      await tester.enterText(find.byType(TextField), 'cob');
      await tester.pumpAndSettle();
      expect(find.text('amber-otter'), findsNothing);
      expect(find.text('cobalt-lynx'), findsOneWidget);
    });

    testWidgets('folded, the roster is a rail of faces with tooltips', (
      tester,
    ) async {
      final source = LocalAgentRosterSource(random: Random(9));
      final a = source.addAgent(name: 'amber-otter');
      final picks = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 56,
              child: AgentRosterView(
                source: source,
                collapsed: true,
                onToggleCollapsed: () {},
                onSelect: (id, _) => picks.add(id),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('amber-otter'), findsNothing);
      expect(find.byTooltip('amber-otter'), findsOneWidget);
      await tester.tap(find.byKey(ValueKey<String>('rail-agent-${a.id}')));
      expect(picks, <String>[a.id]);
    });
  });

  group('delete an agent (§16.1)', () {
    testWidgets('a non-host agent offers Delete; the host agent does not', (
      tester,
    ) async {
      final source = LocalAgentRosterSource(random: Random(30));
      final host = source.ensureHostAgent('host-laptop'); // onHost = true
      final local = source.addAgent(name: 'amber-otter'); // onHost = false
      final deleted = <String>[];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AgentRosterView(
              source: source,
              now: () => DateTime(2026, 8, 22, 12),
              onSelect: (_, _) {},
              onDeleteAgent: deleted.add,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The local agent's menu has Delete. The row is scoped by its own key:
      // the tile is no longer a ListTile since the sidebar moved onto chuk's
      // chrome, but it is still exactly one row per agent.
      final localMenu = find.byKey(ValueKey<String>('agent-tile-${local.id}'));
      await tester.tap(localMenu, buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.text('Delete'), findsOneWidget);
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      // A delete asks first, in a centred dialog.
      expect(deleted, isEmpty);
      expect(find.text('Delete amber-otter?'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey<String>('agents-confirm-button')),
      );
      await tester.pumpAndSettle();
      expect(deleted, hasLength(1));

      // The host agent's menu has no Delete.
      final hostMenu = find.byKey(ValueKey<String>('agent-tile-${host.id}'));
      await tester.tap(hostMenu, buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.text('Delete'), findsNothing);
      expect(find.text('Hide'), findsOneWidget);
    });
  });

  group('rename (bead cowork-817)', () {
    testWidgets('Rename in the row menu opens chuk\'s dialog and reports the '
        'trimmed new name; the host agent can be renamed too', (tester) async {
      final source = LocalAgentRosterSource(random: Random(30));
      final host = source.ensureHostAgent('host-laptop');
      final renamed = <(String, String)>[];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AgentRosterView(
              source: source,
              now: () => DateTime(2026, 8, 22, 12),
              onSelect: (_, _) {},
              onRenameAgent: (id, name) => renamed.add((id, name)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(ValueKey<String>('agent-tile-${host.id}')),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();

      // The app's own name dialog: one filled TextField pre-filled with the
      // current name, a quiet Cancel and a filled Rename.
      expect(find.byType(CoworkerNameDialog), findsOneWidget);
      final field = find.descendant(
        of: find.byType(CoworkerNameDialog),
        matching: find.byType(TextField),
      );
      expect(tester.widget<TextField>(field).controller!.text, host.name);
      await tester.enterText(field, '  Laptop Bot  ');
      await tester.tap(find.widgetWithText(ExpressiveButton, 'Rename'));
      await tester.pumpAndSettle();

      expect(find.byType(CoworkerNameDialog), findsNothing);
      expect(renamed, [(host.id, 'Laptop Bot')]);
      // The view reports; the shell persists. The source is untouched here.
      expect(source.byId(host.id)!.name, host.name);
    });

    testWidgets('an unchanged or empty name and Cancel report nothing', (
      tester,
    ) async {
      final source = LocalAgentRosterSource(random: Random(30));
      final agent = source.addAgent(name: 'amber-otter');
      final renamed = <(String, String)>[];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AgentRosterView(
              source: source,
              now: () => DateTime(2026, 8, 22, 12),
              onSelect: (_, _) {},
              onRenameAgent: (id, name) => renamed.add((id, name)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      Future<void> openDialog() async {
        await tester.tap(
          find.byKey(ValueKey<String>('agent-tile-${agent.id}')),
          buttons: kSecondaryButton,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Rename'));
        await tester.pumpAndSettle();
      }

      final field = find.descendant(
        of: find.byType(CoworkerNameDialog),
        matching: find.byType(TextField),
      );

      // Unchanged: submit with the same name.
      await openDialog();
      await tester.tap(find.widgetWithText(ExpressiveButton, 'Rename'));
      await tester.pumpAndSettle();
      // Empty.
      await openDialog();
      await tester.enterText(field, '   ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      // Cancel.
      await openDialog();
      await tester.enterText(field, 'Other');
      await tester.tap(find.widgetWithText(ExpressiveButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(renamed, isEmpty);
      expect(find.byType(CoworkerNameDialog), findsNothing);
    });

    testWidgets('without onRenameAgent the menu has no Rename item', (
      tester,
    ) async {
      final source = LocalAgentRosterSource(random: Random(30));
      final agent = source.addAgent(name: 'amber-otter');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AgentRosterView(
              source: source,
              now: () => DateTime(2026, 8, 22, 12),
              onSelect: (_, _) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(ValueKey<String>('agent-tile-${agent.id}')),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      expect(find.text('Rename'), findsNothing);
      expect(find.text('Hide'), findsOneWidget);
    });

    test('LocalAgentRosterSource.renameAgent trims, keeps id and thread, '
        'ignores empty and unknown', () {
      final source = LocalAgentRosterSource(random: Random(30));
      final agent = source.addAgent(name: 'amber-otter');
      var notified = 0;
      source.addListener(() => notified++);

      source.renameAgent(agent.id, '  Amber Desk ');
      expect(source.byId(agent.id)!.name, 'Amber Desk');
      expect(
        source.byId(agent.id)!.threads.single.key,
        agent.threads.single.key,
      );
      expect(notified, 1);

      source.renameAgent(agent.id, '   ');
      source.renameAgent('nope', 'x');
      source.renameAgent(agent.id, 'Amber Desk');
      expect(source.byId(agent.id)!.name, 'Amber Desk');
      expect(notified, 1);
    });
  });

  group('host names (bead cowork-817, agent_list)', () {
    test('applyHostNames renames known ids, adds unknown ones, renames the '
        'host row by peer id and never deletes', () {
      final source = LocalAgentRosterSource(random: Random(30));
      final host = source.ensureHostAgent('laptop-3f2a');
      final local = source.addAgent(name: 'amber-otter');
      final untouched = source.addAgent(name: 'keep-me');
      var notified = 0;
      source.addListener(() => notified++);

      source.applyHostNames([
        const AgentsHostAgentName(
          agentId: 'host:laptop-3f2a',
          name: 'Laptop Bot',
          host: true,
        ),
        const AgentsHostAgentName(agentId: 'local:x:9:1', name: 'From Phone'),
        AgentsHostAgentName(agentId: local.id, name: 'Amber Desk'),
      ], peerDeviceId: 'laptop-3f2a');

      expect(source.byId(host.id)!.name, 'Laptop Bot');
      expect(source.byId(host.id)!.onHost, isTrue);
      expect(source.byId(local.id)!.name, 'Amber Desk');
      expect(source.byId(untouched.id)!.name, 'keep-me');
      final added = source.byId('local:x:9:1')!;
      expect(added.name, 'From Phone');
      expect(added.onHost, isFalse);
      expect(added.threads.single.key, 'local:x:9:1');
      expect(source.agents, hasLength(4));
      expect(notified, 1);
    });

    test('applyHostNames skips the host entry without a peer, ignored ids and '
        'unchanged names', () {
      final source = LocalAgentRosterSource(random: Random(30));
      final local = source.addAgent(name: 'amber-otter');
      var notified = 0;
      source.addListener(() => notified++);

      source.applyHostNames(
        [
          const AgentsHostAgentName(
            agentId: 'host:whatever',
            name: 'Bot',
            host: true,
          ),
          const AgentsHostAgentName(
            agentId: 'local:deleted:1:1',
            name: 'Ghost',
          ),
          AgentsHostAgentName(agentId: local.id, name: 'amber-otter'),
        ],
        peerDeviceId: null,
        ignore: const {'local:deleted:1:1'},
      );

      expect(source.agents.map((a) => a.id), [local.id]);
      expect(notified, 0);
    });
  });

  group('hide / unhide (§16.1)', () {
    test(
      'hiding removes an agent from the visible roster, keeps it in agents',
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
      },
    );

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

    testWidgets('the roster hides a picked agent and unhides it again', (
      tester,
    ) async {
      final source = LocalAgentRosterSource(random: Random(6));
      source.addAgent(name: 'amber-otter');
      source.addAgent(name: 'cobalt-lynx');
      await pumpRoster(tester, source);

      expect(find.text('amber-otter'), findsOneWidget);

      // Open the first row's context menu and hide it.
      await tester.tap(
        find.byKey(ValueKey<String>('agent-tile-${source.agents.first.id}')),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hide'));
      await tester.pumpAndSettle();

      expect(source.hiddenIds, hasLength(1));
      // Hidden is a folded section at the bottom: open it, then Unhide.
      expect(find.text('Hidden · 1'), findsOneWidget);
      await tester.tap(find.text('Hidden · 1'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Unhide'));
      await tester.pumpAndSettle();

      expect(source.hiddenIds, isEmpty);
      expect(find.textContaining('Hidden'), findsNothing);
    });
  });

  group('working (§16.1)', () {
    testWidgets('a row says "working" only while its agent works', (
      tester,
    ) async {
      final source = LocalAgentRosterSource(random: Random(7));
      final a = source.addAgent(name: 'amber-otter');
      source.addAgent(name: 'cobalt-lynx');
      await pumpRoster(tester, source);

      expect(find.text('working'), findsNothing);

      source.markRunning(a.id, true);
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(ValueKey<String>('agent-tile-${a.id}')),
          matching: find.text('working'),
        ),
        findsOneWidget,
      );

      source.markRunning(a.id, false);
      await tester.pumpAndSettle();
      expect(find.text('working'), findsNothing);
    });
  });

  group('AgentAvatar (§16.1)', () {
    test('the colour is stable for a seed and the monogram is the initial', () {
      expect(
        AgentAvatar.hueOf('host:cowork-host'),
        AgentAvatar.hueOf('host:cowork-host'),
      );
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
