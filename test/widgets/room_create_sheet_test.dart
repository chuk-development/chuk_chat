import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cowork/models/cowork_agent.dart';
import 'package:cowork/models/cowork_room.dart';
import 'package:cowork/widgets/room_create_sheet.dart';

CoworkAgent _agent(String id, String name, {String? role}) => CoworkAgent(
      id: id,
      name: name,
      role: role,
      threads: const <CoworkThreadInfo>[],
    );

void main() {
  Future<List<CoworkRoomDraft>> pump(
    WidgetTester tester,
    List<CoworkAgent> agents, {
    VoidCallback? onCancel,
  }) async {
    final drafts = <CoworkRoomDraft>[];
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

  List<CoworkAgent> six() =>
      [for (var i = 0; i < 7; i++) _agent('id$i', 'agent-$i')];

  testWidgets('Create is disabled until a name and two members are set',
      (tester) async {
    await pump(tester, [
      _agent('a', 'amber'),
      _agent('b', 'cobalt'),
    ]);

    final create = find.widgetWithText(FilledButton, 'Create');
    expect(tester.widget<FilledButton>(create).onPressed, isNull);

    await tester.enterText(find.byType(TextField), 'planning');
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

  testWidgets('a created room carries the name and the chosen members',
      (tester) async {
    final drafts = await pump(tester, [
      _agent('a', 'amber'),
      _agent('b', 'cobalt'),
      _agent('c', 'jade'),
    ]);

    await tester.enterText(find.byType(TextField), 'launch');
    await tester.tap(find.text('amber'));
    await tester.tap(find.text('jade'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    expect(drafts, hasLength(1));
    expect(drafts.single.name, 'launch');
    expect(
      drafts.single.members.map((m) => m.handle).toList(),
      ['amber', 'jade'],
    );
    expect(drafts.single.members.first.agentId, 'a');
  });

  testWidgets('the six-member cap disables the rest', (tester) async {
    await pump(tester, six()); // 7 candidates

    // Select six.
    for (var i = 0; i < 6; i++) {
      await tester.tap(find.text('agent-$i'));
    }
    await tester.pumpAndSettle();

    expect(find.text('6/6'), findsOneWidget);

    // The seventh tile is now disabled: its checkbox onChanged is null.
    final seventh = find.widgetWithText(CheckboxListTile, 'agent-6');
    expect(tester.widget<CheckboxListTile>(seventh).onChanged, isNull);

    // A selected tile stays enabled so it can be unchecked.
    final first = find.widgetWithText(CheckboxListTile, 'agent-0');
    expect(tester.widget<CheckboxListTile>(first).onChanged, isNotNull);
  });

  testWidgets('unchecking below the cap re-enables the rest', (tester) async {
    await pump(tester, six());
    for (var i = 0; i < 6; i++) {
      await tester.tap(find.text('agent-$i'));
    }
    await tester.pumpAndSettle();
    // Uncheck one.
    await tester.tap(find.text('agent-0'));
    await tester.pumpAndSettle();

    expect(find.text('5/6'), findsOneWidget);
    final seventh = find.widgetWithText(CheckboxListTile, 'agent-6');
    expect(tester.widget<CheckboxListTile>(seventh).onChanged, isNotNull);
  });

  testWidgets('an empty roster says so and cannot create', (tester) async {
    await pump(tester, const <CoworkAgent>[]);
    expect(find.text('No coworkers to add yet.'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'x');
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
}
