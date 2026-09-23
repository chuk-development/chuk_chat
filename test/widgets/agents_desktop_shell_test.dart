// The Agents desktop layout (docs/DESIGN.md §14): three docked panes, the
// resizable roster and details pane, the context menu, the desktop menus,
// the centred dialogs and the keyboard.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/models/agents_room.dart';
import 'package:chuk_chat/pages/messenger_shell.dart';
import 'package:chuk_chat/services/account_session.dart';
import 'package:chuk_chat/services/agents/agent_roster_source.dart';
import 'package:chuk_chat/services/agents/agents_pairing_store.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/agents/agents_run_ledger.dart';
import 'package:chuk_chat/services/agents/room_source.dart';
import 'package:chuk_chat/services/notifications/notification_router.dart';
import 'package:chuk_chat/widgets/agent_roster_view.dart';
import 'package:chuk_chat/widgets/agents_desktop/desktop_dialog.dart';
import 'package:chuk_chat/widgets/agents_desktop/desktop_metrics.dart';
import 'package:chuk_chat/widgets/agents_desktop/quick_switcher.dart';
import 'package:chuk_chat/widgets/agents_thread_view.dart';
import 'package:chuk_chat/widgets/menu_tile_group.dart';
import 'package:chuk_chat/widgets/room_create_sheet.dart';

import '../support/fake_relay_controller.dart';
import '../support/test_app.dart';

class _MemoryStore implements AgentsSecureKeyValueStore {
  final Map<String, String> map = <String, String>{};
  @override
  Future<String?> read(String key) async => map[key];
  @override
  Future<void> write(String key, String value) async => map[key] = value;
  @override
  Future<void> delete(String key) async => map.remove(key);
}

class _Session implements AccountSessionSource {
  const _Session();
  @override
  AccountSession? current() => const AccountSession(
    accessToken: 'access-1',
    refreshToken: 'refresh-1',
    userId: 'user-1',
  );
  @override
  Future<AccountSession?> refresh() async => current();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    AgentsRelayLink.instance.reset();
    AgentsRunLedger.instance.reset();
    DesktopRosterPins.instance.reset();
  });
  tearDown(() {
    AgentsRelayLink.instance.reset();
    AgentsRunLedger.instance.reset();
    NotificationRouter.instance.reset();
    DesktopRosterPins.instance.reset();
  });

  /// A 1400 × 900 window with [agents] coworkers and [rooms].
  Future<(LocalAgentRosterSource, LocalRoomSource)> pumpDesktop(
    WidgetTester tester, {
    List<String> agents = const <String>['amber', 'cobalt', 'jade'],
    LocalRoomSource? rooms,
    Size size = const Size(1400, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final LocalAgentRosterSource roster = LocalAgentRosterSource();
    for (final String name in agents) {
      roster.addAgent(name: name);
    }
    final LocalRoomSource roomSource = rooms ?? LocalRoomSource();
    await tester.pumpWidget(
      testApp(
        MessengerShell(
          relayControllerBuilder: () async => FakeRelayController(),
          sessionSource: const _Session(),
          pairingStore: AgentsPairingStore(backend: _MemoryStore()),
          rosterSource: roster,
          roomSource: roomSource,
          onSignOut: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    // The shell writes its pane layout when it goes away. Let that write land
    // inside this test, not in the next one's fresh preferences.
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });
    return (roster, roomSource);
  }

  Future<void> shortcut(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    bool shift = false,
  }) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(key);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  String selectedThread(WidgetTester tester) => tester
      .widget<AgentsThreadView>(
        find.byType(AgentsThreadView, skipOffstage: false),
      )
      .threadKey;

  Rect rosterRect(WidgetTester tester) =>
      tester.getRect(find.byType(AgentRosterView));
  final Finder dialogBox = find.byKey(
    const ValueKey<String>('agents-desktop-dialog-box'),
  );
  final Finder rightPane = find.byKey(
    const ValueKey<String>('desk-right-pane'),
  );

  group('panes (§14.1)', () {
    testWidgets('roster, thread and details sit side by side, hairlines '
        'between', (tester) async {
      await pumpDesktop(tester);

      final Rect roster = rosterRect(tester);
      final Rect thread = tester.getRect(find.byType(AgentsThreadView));
      expect(roster.left, 0);
      expect(roster.width, kDeskRosterDefault);
      // One hairline between the panes.
      expect(thread.left, roster.right + 1);
      expect(thread.right, 1400);
      expect(rightPane, findsNothing);

      await shortcut(tester, LogicalKeyboardKey.period);
      final Rect pane = tester.getRect(rightPane);
      expect(pane.width, kDeskDetailsDefault);
      expect(pane.right, 1400);
      // It pushes the thread; it does not cover it.
      expect(
        tester.getRect(find.byType(AgentsThreadView)).right,
        pane.left - 1,
      );
      expect(find.byType(Drawer), findsNothing);
    });

    testWidgets('dragging the roster border resizes it within 220–360', (
      tester,
    ) async {
      await pumpDesktop(tester);
      final Finder handle = find.byKey(
        const ValueKey<String>('desk-roster-resize'),
      );

      await tester.drag(handle, const Offset(60, 0));
      await tester.pumpAndSettle();
      expect(rosterRect(tester).width, kDeskRosterDefault + 60);

      await tester.drag(handle, const Offset(400, 0));
      await tester.pumpAndSettle();
      expect(rosterRect(tester).width, kDeskRosterMax);

      await tester.drag(handle, const Offset(-600, 0));
      await tester.pumpAndSettle();
      expect(rosterRect(tester).width, kDeskRosterMin);
    });

    testWidgets('dragging the details border resizes it within 300–420', (
      tester,
    ) async {
      await pumpDesktop(tester);
      await shortcut(tester, LogicalKeyboardKey.period);
      final Finder handle = find.byKey(
        const ValueKey<String>('desk-details-resize'),
      );

      await tester.drag(handle, const Offset(-50, 0));
      await tester.pumpAndSettle();
      expect(tester.getSize(rightPane).width, kDeskDetailsDefault + 50);

      await tester.drag(handle, const Offset(-400, 0));
      await tester.pumpAndSettle();
      expect(tester.getSize(rightPane).width, kDeskDetailsMax);

      await tester.drag(handle, const Offset(400, 0));
      await tester.pumpAndSettle();
      expect(tester.getSize(rightPane).width, kDeskDetailsMin);
    });

    testWidgets('the details toggle in the title bar opens and closes the '
        'pane, and shows its state', (tester) async {
      await pumpDesktop(tester);

      await tester.tap(find.byTooltip('Details (Ctrl+.)'));
      await tester.pumpAndSettle();
      expect(rightPane, findsOneWidget);
      expect(find.text('Details'), findsOneWidget);
      expect(find.text('MODEL'), findsOneWidget);

      await tester.tap(find.byTooltip('Details (Ctrl+.)'));
      await tester.pumpAndSettle();
      expect(rightPane, findsNothing);

      // The pane's own close button and Esc close it too.
      await shortcut(tester, LogicalKeyboardKey.period);
      await tester.tap(find.byTooltip('Close (Esc)'));
      await tester.pumpAndSettle();
      expect(rightPane, findsNothing);
      await shortcut(tester, LogicalKeyboardKey.period);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(rightPane, findsNothing);
    });

    testWidgets('pane widths and the open details pane come back on the next '
        'launch', (tester) async {
      await pumpDesktop(tester);
      await tester.drag(
        find.byKey(const ValueKey<String>('desk-roster-resize')),
        const Offset(40, 0),
      );
      await shortcut(tester, LogicalKeyboardKey.period);
      // Written once the reader stops dragging.
      await tester.pump(const Duration(seconds: 1));

      await tester.pumpWidget(const SizedBox.shrink());
      await pumpDesktop(tester);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      expect(rosterRect(tester).width, kDeskRosterDefault + 40);
      expect(rightPane, findsOneWidget);
    });
  });

  group('roster (§14.3)', () {
    testWidgets('a right click opens the context menu: desktop menu, 32 px '
        'rows, radius 12', (tester) async {
      final (roster, _) = await pumpDesktop(tester);
      final String id = roster.agents[1].id;

      await tester.tap(
        find.byKey(ValueKey<String>('agent-tile-$id')),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();

      for (final String label in <String>[
        'Profile',
        'Rename',
        'Pin',
        'Hide',
        'Delete',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(
        tester
            .getSize(
              find.ancestor(
                of: find.text('Rename'),
                matching: find.byType(MenuActionRow),
              ),
            )
            .height,
        kMenuDenseRowHeight,
      );
      final MenuTileGroup group = tester.widget<MenuTileGroup>(
        find.byType(MenuTileGroup),
      );
      expect(group.outerRadius, kMenuDenseOuterRadius);
      // Nothing was selected by the right click.
      expect(selectedThread(tester), roster.agents.first.threads.single.key);
    });

    testWidgets('the row "…" shows on hover only', (tester) async {
      final (roster, _) = await pumpDesktop(tester);
      final Finder row = find.byKey(
        ValueKey<String>('agent-tile-${roster.agents[2].id}'),
      );
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
      await mouse.moveTo(const Offset(700, 450));
      await tester.pumpAndSettle();
      expect(more, findsNothing);
    });

    testWidgets('Delete asks in a centred dialog before it removes', (
      tester,
    ) async {
      final (roster, _) = await pumpDesktop(tester);
      final String id = roster.agents[1].id;
      await tester.tap(
        find.byKey(ValueKey<String>('agent-tile-$id')),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(find.byType(AgentsDesktopDialog), findsOneWidget);
      expect(
        tester.getSize(dialogBox).width,
        lessThanOrEqualTo(kDeskDialogMaxWidth + 1),
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(roster.byId(id), isNotNull);
    });
  });

  group('keyboard (§14.7)', () {
    testWidgets('Ctrl+1 … Ctrl+9 open the n-th agent in the roster', (
      tester,
    ) async {
      final (roster, _) = await pumpDesktop(tester);

      await shortcut(tester, LogicalKeyboardKey.digit3);
      expect(selectedThread(tester), roster.agents[2].threads.single.key);
      await shortcut(tester, LogicalKeyboardKey.digit2);
      expect(selectedThread(tester), roster.agents[1].threads.single.key);
      // Past the end: nothing moves.
      await shortcut(tester, LogicalKeyboardKey.digit9);
      expect(selectedThread(tester), roster.agents[1].threads.single.key);
    });

    testWidgets('Ctrl+K opens the quick switcher; typing filters, Enter '
        'opens', (tester) async {
      final (roster, _) = await pumpDesktop(tester);

      await shortcut(tester, LogicalKeyboardKey.keyK);
      expect(find.byType(QuickSwitcher), findsOneWidget);
      expect(tester.getSize(find.byType(QuickSwitcher)).width, greaterThan(0));
      await tester.enterText(
        find.byKey(const ValueKey<String>('quick-switcher-field')),
        'ja',
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(QuickSwitcher),
          matching: find.text('jade'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(QuickSwitcher),
          matching: find.text('amber'),
        ),
        findsNothing,
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.byType(QuickSwitcher), findsNothing);
      expect(selectedThread(tester), roster.agents[2].threads.single.key);
    });

    testWidgets('the arrows move the switcher highlight and Esc closes it', (
      tester,
    ) async {
      final (roster, _) = await pumpDesktop(tester);
      await shortcut(tester, LogicalKeyboardKey.keyK);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(selectedThread(tester), roster.agents[1].threads.single.key);

      await shortcut(tester, LogicalKeyboardKey.keyK);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(QuickSwitcher), findsNothing);
      expect(selectedThread(tester), roster.agents[1].threads.single.key);
    });

    testWidgets('Ctrl+N opens the new-agent dialog, Ctrl+Shift+N the new-room '
        'dialog — centred, never a sheet', (tester) async {
      await pumpDesktop(tester);

      await shortcut(tester, LogicalKeyboardKey.keyN);
      expect(find.byType(CoworkerNameDialog), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      await shortcut(tester, LogicalKeyboardKey.keyN, shift: true);
      expect(find.byType(RoomCreateSheet), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byType(AgentsDesktopDialog), findsOneWidget);
      final Rect dialog = tester.getRect(dialogBox);
      expect(dialog.width, lessThanOrEqualTo(kDeskDialogMaxWidth + 1));
      expect(dialog.center.dx, moreOrLessEquals(700, epsilon: 1));
    });

    testWidgets('Ctrl+B folds the roster to the rail and back', (tester) async {
      await pumpDesktop(tester);
      await shortcut(tester, LogicalKeyboardKey.keyB);
      expect(rosterRect(tester).width, kDeskRailWidth);
      await shortcut(tester, LogicalKeyboardKey.keyB);
      expect(rosterRect(tester).width, kDeskRosterDefault);
    });
  });

  group('rooms', () {
    testWidgets('a room opens in the centre pane; the thread stays mounted '
        'behind it, Esc closes the room', (tester) async {
      final LocalRoomSource rooms = LocalRoomSource();
      final AgentsRoom room = rooms.addRoom(
        const AgentsRoomDraft(
          name: 'launch',
          members: <AgentsRoomMember>[
            AgentsRoomMember(agentId: 'a', handle: 'amber'),
            AgentsRoomMember(agentId: 'b', handle: 'cobalt'),
          ],
        ),
      );
      await pumpDesktop(tester, rooms: rooms);

      await tester.tap(find.byKey(ValueKey<String>('room-tile-${room.id}')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byTooltip('Close room (Esc)'), findsOneWidget);
      expect(
        find.byType(AgentsThreadView, skipOffstage: false),
        findsOneWidget,
      );
      expect(find.byType(AgentsThreadView), findsNothing); // off stage
      // The room's row is the selected one now.
      expect(
        find.descendant(
          of: find.byKey(ValueKey<String>('room-tile-${room.id}')),
          matching: find.byKey(const ValueKey<String>('roster-selected-bar')),
        ),
        findsOneWidget,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byTooltip('Close room (Esc)'), findsNothing);
      expect(find.byType(AgentsThreadView), findsOneWidget);
    });
  });

  testWidgets('a phone-sized window builds none of the desktop panes', (
    tester,
  ) async {
    await pumpDesktop(tester, size: const Size(412, 900));
    expect(find.byType(AgentRosterView), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('desk-roster-resize')),
      findsNothing,
    );
    expect(find.byType(MenuDensity), findsNothing);
  });
}
