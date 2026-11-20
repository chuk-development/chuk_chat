import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/models/agents_room.dart';
import 'package:chuk_chat/services/agents/room_source.dart';
import 'package:chuk_chat/widgets/room_details_panel.dart';

const List<AgentsAgent> _agents = <AgentsAgent>[
  AgentsAgent(id: 'a', name: 'Amber', threads: <AgentsThreadInfo>[]),
  AgentsAgent(id: 'b', name: 'Cobalt', threads: <AgentsThreadInfo>[]),
  AgentsAgent(id: 'c', name: 'Jade', threads: <AgentsThreadInfo>[]),
];

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  late LocalRoomSource source;
  late AgentsRoom room;
  late List<(String, Map<String, Object?>)> sent;
  late List<(String, AgentsRoomMember)> added;
  late List<(String, String)> removed;
  late List<(String, bool)> policies;

  Future<void> pump(WidgetTester tester) async {
    source = LocalRoomSource();
    room = source.addRoom(
      const AgentsRoomDraft(
        name: 'launch',
        members: <AgentsRoomMember>[
          AgentsRoomMember(agentId: 'a', handle: 'amber'),
          AgentsRoomMember(agentId: 'b', handle: 'cobalt'),
        ],
      ),
    );
    sent = <(String, Map<String, Object?>)>[];
    added = <(String, AgentsRoomMember)>[];
    removed = <(String, String)>[];
    policies = <(String, bool)>[];
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RoomDetailsPanel(
            source: source,
            roomId: room.id,
            agents: _agents,
            onSettingsChanged: (String id, Map<String, Object?> s) =>
                sent.add((id, s)),
            onAddMember: (String id, AgentsRoomMember m) {
              added.add((id, m));
              source.addMemberToRoom(id, m);
            },
            onRemoveMember: (String id, String agentId) =>
                removed.add((id, agentId)),
            onAgentToAgentChanged: (String id, bool on) =>
                policies.add((id, on)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('lists the members by name and offers the others', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('Amber'), findsOneWidget);
    expect(find.text('@amber'), findsOneWidget);
    expect(find.text('Cobalt'), findsOneWidget);
    // Two members: remove is off (a group of one is not a group).
    final IconButton remove = tester.widget<IconButton>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('room-details-member-a')),
        matching: find.byType(IconButton),
      ),
    );
    expect(remove.onPressed, isNull);

    await tester.tap(find.byKey(const ValueKey<String>('room-details-add-c')));
    await tester.pumpAndSettle();
    expect(added.single.$2.agentId, 'c');
    // Three now: remove works and reports the member.
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('room-details-member-a')),
        matching: find.byType(IconButton),
      ),
    );
    expect(removed, <(String, String)>[(room.id, 'a')]);
  });

  testWidgets('who answers: a mode change updates the group and sends '
      'room_settings; lead mode brings a lead', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey<String>('room-responder-lead')));
    await tester.pumpAndSettle();

    expect(source.byId(room.id)?.responder, AgentsRoomResponder.lead);
    expect(source.byId(room.id)?.leadAgentId, 'a');
    expect(sent.single.$1, room.id);
    expect(sent.single.$2, <String, Object?>{
      'responder': 'lead',
      'lead_agent_id': 'a',
    });
    expect(find.byKey(const ValueKey<String>('room-details-lead')), findsOne);

    await tester.tap(find.byKey(const ValueKey<String>('room-responder-auto')));
    await tester.pumpAndSettle();
    expect(sent.last.$2, <String, Object?>{'responder': 'auto'});
    // Auto offers the fallback member, not the lead.
    expect(
      find.byKey(const ValueKey<String>('room-details-lead')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('room-details-fallback')),
      findsOneWidget,
    );
  });

  testWidgets('the instructions and the folder are saved together', (
    tester,
  ) async {
    await pump(tester);
    final Finder save = find.byKey(const ValueKey<String>('room-details-save'));
    expect(tester.widget<FilledButton>(save).onPressed, isNull);

    await tester.enterText(
      find.byKey(const ValueKey<String>('room-details-instructions')),
      'be brief',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('room-details-workdir')),
      '~/launch',
    );
    await tester.pump();
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(sent.single.$2, <String, Object?>{
      'bulletin': 'be brief',
      'workdir': '~/launch',
    });
    expect(source.byId(room.id)?.bulletin, 'be brief');
    expect(source.byId(room.id)?.workdir, '~/launch');
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
  });

  testWidgets('the policy switch reports through its own callback', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.text('Agents can reply to each other'));
    await tester.pumpAndSettle();
    expect(policies, <(String, bool)>[(room.id, false)]);
    expect(sent, isEmpty);
  });

  testWidgets('a change from the host shows at once', (tester) async {
    await pump(tester);
    source.applyHostRooms(<AgentsRoom>[
      source.rooms.single.copyWith(bulletin: 'from host'),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('from host'), findsOneWidget);
  });
}
