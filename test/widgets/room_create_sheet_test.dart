import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/models/agents_room.dart';
import 'package:chuk_chat/widgets/room_create_sheet.dart';

AgentsAgent _agent(String id, String name, {String? role}) => AgentsAgent(
  id: id,
  name: name,
  role: role,
  threads: const <AgentsThreadInfo>[],
);

void main() {
  Future<List<AgentsRoomDraft>> pump(
    WidgetTester tester,
    List<AgentsAgent> agents, {
    VoidCallback? onCancel,
  }) async {
    final drafts = <AgentsRoomDraft>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RoomCreateSheet(
            agents: agents,
            onSubmit: drafts.add,
            onCancel: onCancel,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return drafts;
  }

  /// The form scrolls: bring the policy switch into view.
  Future<void> showSwitch(WidgetTester tester) async {
    await tester.scrollUntilVisible(
      find.text('Agents can reply to each other'),
      80,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
  }

  List<AgentsAgent> roster(int n) => [
    for (var i = 0; i < n; i++) _agent('id$i', 'agent-$i'),
  ];

  testWidgets('Create is disabled until a name and two members are set', (
    tester,
  ) async {
    await pump(tester, [_agent('a', 'amber'), _agent('b', 'cobalt')]);

    final create = find.widgetWithText(FilledButton, 'Create');
    expect(tester.widget<FilledButton>(create).onPressed, isNull);

    await tester.enterText(
      find.byKey(const ValueKey<String>('room-create-name')),
      'planning',
    );
    await tester.pumpAndSettle();
    // Name but no members: still disabled.
    expect(tester.widget<FilledButton>(create).onPressed, isNull);

    await tester.tap(find.text('amber'));
    await tester.pumpAndSettle();
    // One member: still disabled (a room of one is not a room).
    expect(tester.widget<FilledButton>(create).onPressed, isNull);

    await tester.tap(find.text('cobalt'));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(create).onPressed, isNotNull);
  });

  testWidgets('a created room carries the name and the chosen members', (
    tester,
  ) async {
    final drafts = await pump(tester, [
      _agent('a', 'amber'),
      _agent('b', 'cobalt'),
      _agent('c', 'jade'),
    ]);

    await tester.enterText(
      find.byKey(const ValueKey<String>('room-create-name')),
      'launch',
    );
    await tester.tap(find.text('amber'));
    await tester.tap(find.text('jade'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    expect(drafts, hasLength(1));
    expect(drafts.single.name, 'launch');
    expect(drafts.single.members.map((m) => m.handle).toList(), [
      'amber',
      'jade',
    ]);
    expect(drafts.single.members.first.agentId, 'a');
  });

  testWidgets('nothing is capped: seven can be chosen, and the count says so', (
    tester,
  ) async {
    // A tall window so all seven tiles are on screen at once — this is about
    // the cap, not about scrolling.
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await pump(tester, roster(7));

    for (var i = 0; i < 7; i++) {
      await tester.tap(find.text('agent-$i'));
      await tester.pumpAndSettle();
    }

    expect(find.text('7 selected'), findsOneWidget);
    // Every tile stays live — there is no ceiling to disable anything.
    for (var i = 0; i < 7; i++) {
      final tile = find.widgetWithText(CheckboxListTile, 'agent-$i');
      expect(tester.widget<CheckboxListTile>(tile).onChanged, isNotNull);
    }
  });

  testWidgets(
    'a long roster scrolls and still produces a twelve-member draft',
    (tester) async {
      // A short phone: twenty candidates cannot fit, so the member list has to
      // scroll while the name field and the actions stay put.
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final drafts = await pump(tester, roster(20));
      expect(tester.takeException(), isNull);

      await tester.enterText(find.byType(TextField).first, 'all hands');
      await tester.pumpAndSettle();

      // Twelve members, scrolling the list as the visible ones run out.
      final list = find.byType(ListView);
      for (var i = 0; i < 12; i++) {
        await tester.scrollUntilVisible(
          find.text('agent-$i'),
          60,
          scrollable: find
              .descendant(of: list, matching: find.byType(Scrollable))
              .first,
        );
        await tester.tap(find.text('agent-$i'));
        await tester.pumpAndSettle();
      }
      expect(find.text('12 selected'), findsOneWidget);

      // The Create button never scrolled away with the list.
      await tester.tap(find.widgetWithText(FilledButton, 'Create'));
      await tester.pumpAndSettle();

      expect(drafts, hasLength(1));
      expect(drafts.single.members, hasLength(12));
      expect(drafts.single.name, 'all hands');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a short roster gets no search field; a long one does', (
    tester,
  ) async {
    await pump(tester, roster(kRoomSearchThreshold));
    expect(find.text('Search agents'), findsNothing);

    await pump(tester, roster(kRoomSearchThreshold + 1));
    expect(find.text('Search agents'), findsOneWidget);
  });

  testWidgets('the search field filters the list without losing a selection', (
    tester,
  ) async {
    final drafts = await pump(tester, [
      _agent('a', 'amber'),
      _agent('b', 'cobalt'),
      _agent('c', 'jade'),
      _agent('d', 'onyx'),
      _agent('e', 'slate'),
      _agent('f', 'teal'),
      _agent('g', 'rust'),
      _agent('h', 'ochre'),
      _agent('i', 'indigo'),
    ]);

    await tester.enterText(find.byType(TextField).first, 'launch');
    await tester.tap(find.text('amber'));
    await tester.pumpAndSettle();

    // Filter amber out of sight; the selection is held on ids, not on the view.
    final search = find.widgetWithText(TextField, 'Search agents');
    await tester.enterText(search, 'jade');
    await tester.pumpAndSettle();
    expect(find.widgetWithText(CheckboxListTile, 'amber'), findsNothing);
    expect(find.widgetWithText(CheckboxListTile, 'jade'), findsOneWidget);
    expect(find.text('1 selected'), findsOneWidget);

    await tester.tap(find.widgetWithText(CheckboxListTile, 'jade'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    // Both survive, in roster order, even though only one was on screen.
    expect(drafts.single.members.map((m) => m.handle), ['amber', 'jade']);
  });

  testWidgets('a search that matches nothing says so', (tester) async {
    await pump(tester, roster(kRoomSearchThreshold + 1));
    await tester.enterText(
      find.widgetWithText(TextField, 'Search agents'),
      'nobody',
    );
    await tester.pumpAndSettle();
    expect(find.text('No agent matches that.'), findsOneWidget);
  });

  testWidgets('the agent-to-agent switch is there and defaults on', (
    tester,
  ) async {
    await pump(tester, [_agent('a', 'amber'), _agent('b', 'cobalt')]);
    await showSwitch(tester);
    expect(find.text('Agents can reply to each other'), findsOneWidget);
    expect(find.text('With this off, they only answer you.'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
  });

  testWidgets('a draft carries the switch: on by default, false once tapped', (
    tester,
  ) async {
    final drafts = await pump(tester, [
      _agent('a', 'amber'),
      _agent('b', 'cobalt'),
    ]);

    await tester.enterText(
      find.byKey(const ValueKey<String>('room-create-name')),
      'launch',
    );
    await tester.tap(find.text('amber'));
    await tester.tap(find.text('cobalt'));
    await tester.pumpAndSettle();

    await showSwitch(tester);
    await tester.tap(find.text('Agents can reply to each other'));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);

    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    expect(drafts.single.agentToAgent, isFalse);
  });

  testWidgets('an empty roster says so and cannot create', (tester) async {
    await pump(tester, const <AgentsAgent>[]);
    expect(find.text('No agents to add yet.'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey<String>('room-create-name')),
      'x',
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Create'))
          .onPressed,
      isNull,
    );
  });

  testWidgets('cancel is offered when the caller wants it', (tester) async {
    var cancelled = 0;
    await pump(tester, [_agent('a', 'amber')], onCancel: () => cancelled++);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    expect(cancelled, 1);
  });

  testWidgets('who answers: Lead picks a lead and rides in the draft with the '
      'group instructions', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final drafts = await pump(tester, [
      _agent('a', 'amber'),
      _agent('b', 'cobalt'),
    ]);

    await tester.enterText(
      find.byKey(const ValueKey<String>('room-create-name')),
      'launch',
    );
    await tester.tap(find.text('amber'));
    await tester.tap(find.text('cobalt'));
    await tester.pumpAndSettle();

    // Everyone is the default; each mode says in one line what it does.
    expect(find.text('Who answers'), findsOneWidget);
    expect(
      find.text('Every member answers, one after another.'),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('room-create-lead')),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey<String>('room-responder-lead')));
    await tester.pumpAndSettle();
    // The lead picker appears, on the first chosen member.
    expect(
      find.byKey(const ValueKey<String>('room-create-lead')),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const ValueKey<String>('room-create-instructions')),
      'ship on friday',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    expect(drafts.single.responder, AgentsRoomResponder.lead);
    expect(drafts.single.leadAgentId, 'a');
    expect(drafts.single.bulletin, 'ship on friday');
  });

  testWidgets('Only mentioned and Auto need no lead', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final drafts = await pump(tester, [
      _agent('a', 'amber'),
      _agent('b', 'cobalt'),
    ]);
    await tester.enterText(
      find.byKey(const ValueKey<String>('room-create-name')),
      'ops',
    );
    await tester.tap(find.text('amber'));
    await tester.tap(find.text('cobalt'));
    await tester.tap(
      find.byKey(const ValueKey<String>('room-responder-mentions')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    expect(drafts.single.responder, AgentsRoomResponder.mentions);
    expect(drafts.single.leadAgentId, isNull);
    expect(drafts.single.bulletin, isEmpty);
  });
}
