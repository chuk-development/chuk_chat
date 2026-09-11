import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/icon_finder.dart';

import 'package:cowork/models/cowork_room.dart';
import 'package:cowork/services/cowork/room_source.dart';
import 'package:cowork/ui/expressive/agent_face.dart';
import 'package:cowork/widgets/expressive_settings.dart';
import 'package:cowork/widgets/room_list_view.dart';

CoworkRoomMember _m(String id, String handle) =>
    CoworkRoomMember(agentId: id, handle: handle);

CoworkRoomDraft _draft(String name, int members) => CoworkRoomDraft(
  name: name,
  members: [for (var i = 0; i < members; i++) _m('id$name$i', '$name-$i')],
);

void main() {
  Future<List<String>> pump(
    WidgetTester tester,
    RoomSource source, {
    VoidCallback? onCreate,
    void Function(String)? onDelete,
    void Function(String, String)? onRename,
    void Function(String)? onManageMembers,
    String? selectedRoomId,
  }) async {
    final picks = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RoomListView(
            source: source,
            onCreate: onCreate,
            onDelete: onDelete,
            onRename: onRename,
            onManageMembers: onManageMembers,
            selectedRoomId: selectedRoomId,
            onSelect: picks.add,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return picks;
  }

  testWidgets('an empty list says so and offers New room', (tester) async {
    var created = 0;
    await pump(tester, LocalRoomSource(), onCreate: () => created++);
    expect(find.text('No rooms yet.'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'New room'));
    expect(created, 1);
  });

  testWidgets('rooms list with name and member count; tapping selects', (
    tester,
  ) async {
    final source = LocalRoomSource(random: Random(1));
    final a = source.addRoom(_draft('launch', 2));
    source.addRoom(_draft('ops', 4));
    final picks = await pump(tester, source);

    expect(find.text('launch'), findsOneWidget);
    expect(find.text('2 members'), findsOneWidget);
    expect(find.text('ops'), findsOneWidget);
    expect(find.text('4 members'), findsOneWidget);

    await tester.tap(find.text('launch'));
    expect(picks, [a.id]);
  });

  testWidgets('a room with more than three members shows a +N chip', (
    tester,
  ) async {
    final source = LocalRoomSource(random: Random(2));
    source.addRoom(_draft('big', 5)); // 3 shown + "+2"
    await pump(tester, source);
    expect(find.text('+2'), findsOneWidget);
    expect(find.text('5 members'), findsOneWidget);
  });

  testWidgets('the +N count stays legible and clear of the avatars at 1.3x', (
    tester,
  ) async {
    // A narrow phone with text scaled up: the count used to be an 8 px plaque
    // pinned on top of the third avatar, so it was both covered and unreadable.
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final source = LocalRoomSource(random: Random(21));
    source.addRoom(_draft('big', 5)); // 3 faces + "+2"

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.3)),
            child: Scaffold(
              body: RoomListView(source: source, onSelect: (_) {}),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('+2'), findsOneWidget);

    // Legible: the count is rendered at the app's label size, scaled, not at
    // the old hardcoded 8 px.
    expect(tester.getSize(find.text('+2')).height, greaterThan(12));

    // Clear of the stack: the badge shares no pixel with any avatar.
    final badge = tester.getRect(find.byType(ExpressiveBadge));
    final faces = find.byType(ExpressiveFace);
    expect(faces, findsNWidgets(3));
    for (var i = 0; i < 3; i++) {
      expect(badge.overlaps(tester.getRect(faces.at(i))), isFalse);
    }

    // The avatars themselves still step across, never stacking dead centre.
    final first = tester.getRect(faces.at(0));
    final third = tester.getRect(faces.at(2));
    expect(third.left - first.left, closeTo(40, 0.5));
    expect(first.height, closeTo(32, 0.5));
  });

  testWidgets('the create affordance is hidden when onCreate is null', (
    tester,
  ) async {
    await pump(tester, LocalRoomSource());
    expect(find.text('No rooms yet.'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'New room'), findsNothing);
    expect(findIcon(Icons.group_add_outlined), findsNothing);
  });

  testWidgets('adding a room updates the list live', (tester) async {
    final source = LocalRoomSource(random: Random(3));
    await pump(tester, source);
    expect(find.text('No rooms yet.'), findsOneWidget);

    source.addRoom(_draft('launch', 2));
    await tester.pumpAndSettle();
    expect(find.text('launch'), findsOneWidget);
  });

  testWidgets('the delete menu reports the room and no menu without onDelete', (
    tester,
  ) async {
    final source = LocalRoomSource(random: Random(8));
    final a = source.addRoom(_draft('launch', 2));
    final deleted = <String>[];

    await pump(tester, source, onDelete: deleted.add);
    await tester.tap(findIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete room'));
    await tester.pumpAndSettle();
    expect(deleted, [a.id]);
  });

  testWidgets('no delete affordance when onDelete is null', (tester) async {
    final source = LocalRoomSource(random: Random(9));
    source.addRoom(_draft('launch', 2));
    await pump(tester, source);
    expect(findIcon(Icons.more_vert), findsNothing);
  });

  testWidgets('the rename menu opens a dialog and reports the new name', (
    tester,
  ) async {
    final source = LocalRoomSource(random: Random(11));
    final a = source.addRoom(_draft('launch', 2));
    final renamed = <(String, String)>[];

    await pump(tester, source, onRename: (id, name) => renamed.add((id, name)));
    await tester.tap(findIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename room'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'launch v2');
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
    await tester.pumpAndSettle();

    expect(renamed, [(a.id, 'launch v2')]);
  });

  testWidgets('the Manage members item fires onManageMembers', (tester) async {
    final source = LocalRoomSource(random: Random(14));
    final a = source.addRoom(_draft('launch', 2));
    final managed = <String>[];
    await pump(tester, source, onManageMembers: managed.add);
    await tester.tap(findIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Manage members'));
    await tester.pumpAndSettle();
    expect(managed, [a.id]);
  });
}
