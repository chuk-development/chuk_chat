// The Agents desktop layout: chuk's sidebar as the roster, the resizable
// roster and details pane, the row menu, the centred dialogs and the keyboard.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/models/agents_room.dart';
import 'package:chuk_chat/pages/messenger_shell.dart';
import 'package:chuk_chat/platform_specific/mobile/mobile_chat_chrome.dart';
import 'package:chuk_chat/services/account_session.dart';
import 'package:chuk_chat/services/agents/agent_control_source.dart';
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
import 'package:chuk_chat/widgets/room_create_sheet.dart';
import 'package:chuk_chat/widgets/coworker_template_picker.dart';
import 'package:chuk_chat/widgets/sidebar/sidebar_chrome.dart';

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

/// A host that answers the panel's first look and then fails a refresh.
class _FailingRefreshSource extends FakeAgentControlSource {
  bool failNext = false;

  @override
  Future<void> refresh(String sessionKey) async {
    if (failNext) throw StateError('host said: secret-detail-123');
    return super.refresh(sessionKey);
  }
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

// ── polish ──
/// A host link whose `agent_create` send fails.
class _FailingCreateController extends FakeRelayController {
  @override
  Future<void> createAgent(
    String agentId,
    String name, {
    Map<String, Object?>? template,
  }) async {
    throw StateError('socket closed');
  }
}
// ── end polish ──

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
    AgentControlSource? controlSource,
    FakeRelayController Function()? relayController, // polish
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
          relayControllerBuilder: () async =>
              relayController?.call() ?? FakeRelayController(),
          sessionSource: const _Session(),
          pairingStore: AgentsPairingStore(backend: _MemoryStore()),
          rosterSource: roster,
          roomSource: roomSource,
          controlSource: controlSource,
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

  group('panes', () {
    testWidgets('roster, thread and details sit side by side', (
      tester,
    ) async {
      await pumpDesktop(tester);

      final Rect roster = rosterRect(tester);
      final Rect thread = tester.getRect(find.byType(AgentsThreadView));
      expect(roster.left, 0);
      expect(roster.width, kDesktopSidebarWidth);
      // No hairline: the panel colour changes at the border, as at chuk's
      // sidebar.
      expect(thread.left, roster.right);
      expect(thread.right, 1400);
      expect(rightPane, findsNothing);

      await shortcut(tester, LogicalKeyboardKey.period);
      final Rect pane = tester.getRect(rightPane);
      expect(pane.width, kDeskDetailsDefault);
      expect(pane.right, 1400);
      // It pushes the thread; it does not cover it. Its left border is its
      // own, as chuk's artifact panel's is.
      expect(tester.getRect(find.byType(AgentsThreadView)).right, pane.left);
      expect(find.byType(Drawer), findsNothing);
    });

    testWidgets('the roster is exactly as wide as the chat sidebar and has '
        'no resize handle', (tester) async {
      await pumpDesktop(tester);
      expect(rosterRect(tester).width, kDesktopSidebarWidth);
      expect(
        find.byKey(const ValueKey<String>('desk-roster-resize')),
        findsNothing,
      );
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

    testWidgets('Details in the header\'s "…" menu, and a tap on the '
        'coworker, open and close the pane', (tester) async {
      await pumpDesktop(tester);

      Future<void> details() async {
        await tester.tap(find.byTooltip('More actions'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Details (Ctrl+.)'));
        await tester.pumpAndSettle();
      }

      await details();
      expect(rightPane, findsOneWidget);
      expect(find.text('Details'), findsOneWidget);
      // The first page: the coworker's screen and its routines.
      expect(
        find.descendant(
          of: rightPane,
          matching: find.byKey(const ValueKey<String>('details-screen')),
        ),
        findsOneWidget,
      );
      expect(find.text('Routines'), findsOneWidget);
      expect(find.text('MODEL'), findsNothing);

      await details();
      expect(rightPane, findsNothing);

      // The coworker pill at the left of the header is the same toggle.
      await tester.tap(find.byType(AgentChromePill));
      await tester.pumpAndSettle();
      expect(rightPane, findsOneWidget);
      await tester.tap(find.byType(AgentChromePill));
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

    testWidgets('the details width and the open details pane come back on '
        'the next launch', (tester) async {
      await pumpDesktop(tester);
      await shortcut(tester, LogicalKeyboardKey.period);
      await tester.drag(
        find.byKey(const ValueKey<String>('desk-details-resize')),
        const Offset(-40, 0),
      );
      // Written once the reader stops dragging.
      await tester.pump(const Duration(seconds: 1));

      await tester.pumpWidget(const SizedBox.shrink());
      await pumpDesktop(tester);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      expect(tester.getSize(rightPane).width, kDeskDetailsDefault + 40);
      expect(rightPane, findsOneWidget);
    });
  });

  /// The gear in the details pane's header: the Settings page.
  Future<void> openDetailsSettings(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey<String>('desk-details-settings')));
    await tester.pumpAndSettle();
  }

  testWidgets('the gear opens the Settings page, the back arrow returns, and '
      'another coworker starts on the first page', (tester) async {
    final (roster, _) = await pumpDesktop(tester);
    await shortcut(tester, LogicalKeyboardKey.period);
    final String shown = tester
        .widget<Text>(
          find.byKey(const ValueKey<String>('details-screen-caption')),
        )
        .data!;
    expect(shown, endsWith("'s screen"));

    await openDetailsSettings(tester);
    expect(find.text('Settings'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('details-screen')), findsNothing);
    expect(
      find.descendant(
        of: rightPane,
        matching: find.byKey(const ValueKey<String>('details-face')),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('details-settings-group')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey<String>('desk-details-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('details-screen')), findsOneWidget);

    // Settings open, then another coworker: its pane starts on page one.
    await openDetailsSettings(tester);
    final String other = roster.agents
        .firstWhere((a) => "${a.name}'s screen" != shown)
        .id;
    await tester.tap(find.byKey(ValueKey<String>('agent-tile-$other')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('details-screen')), findsOneWidget);

    // Back to the first coworker: its Settings page is not remembered.
    final String first = roster.agents
        .firstWhere((a) => "${a.name}'s screen" == shown)
        .id;
    await tester.tap(find.byKey(ValueKey<String>('agent-tile-$first')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('details-screen')), findsOneWidget);

    // Closing the pane forgets the page too.
    await openDetailsSettings(tester);
    await shortcut(tester, LogicalKeyboardKey.period);
    await shortcut(tester, LogicalKeyboardKey.period);
    expect(find.byKey(const ValueKey<String>('details-screen')), findsOneWidget);
  });

  testWidgets('the Settings page is a profile: the name field renames the '
      'coworker, the technical details are folded', (tester) async {
    final (roster, _) = await pumpDesktop(tester);
    await shortcut(tester, LogicalKeyboardKey.period);
    await openDetailsSettings(tester);

    final Finder name = find.descendant(
      of: rightPane,
      matching: find.byKey(const ValueKey<String>('details-name-field')),
    );
    expect(name, findsOneWidget);
    final String shown = tester.widget<TextField>(name).controller!.text;
    final String id = roster.agents.firstWhere((a) => a.name == shown).id;
    expect(
      find.descendant(
        of: rightPane,
        matching: find.byKey(const ValueKey<String>('details-role-field')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: rightPane,
        matching: find.byKey(const ValueKey<String>('details-brief-field')),
      ),
      findsOneWidget,
    );
    expect(find.text('Technical details'), findsOneWidget);
    expect(find.text('SANDBOX'), findsNothing);

    await tester.enterText(name, 'steady-kestrel');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(roster.byId(id)?.name, 'steady-kestrel');

    await tester.tap(
      find.byKey(const ValueKey<String>('details-technical-toggle')),
    );
    await tester.pumpAndSettle();
    expect(find.text('SANDBOX'), findsOneWidget);
  });

  testWidgets('a failing Refresh in the details pane says so, without the '
      'error text', (tester) async {
    final _FailingRefreshSource source = _FailingRefreshSource();
    await pumpDesktop(tester, controlSource: source);
    await shortcut(tester, LogicalKeyboardKey.period);
    await openDetailsSettings(tester);

    source.failNext = true;
    await tester.tap(
      find.descendant(of: rightPane, matching: find.byTooltip('Refresh')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      find.textContaining('Could not refresh the details'),
      findsOneWidget,
    );
    expect(find.textContaining('secret-detail-123'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  group('roster', () {
    testWidgets("a right click opens chuk's row menu and selects nothing", (
      tester,
    ) async {
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
        'Hide',
        'Delete',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      // chuk's popup menu, the one its sidebar opens on a chat.
      expect(
        find.ancestor(
          of: find.text('Rename'),
          matching: find.byType(PopupMenuItem<VoidCallback>),
        ),
        findsOneWidget,
      );
      // Nothing was selected by the right click.
      expect(selectedThread(tester), roster.agents.first.threads.single.key);
    });

    testWidgets("the row's pin shows on hover only", (tester) async {
      final (roster, _) = await pumpDesktop(tester);
      final Finder row = find.byKey(
        ValueKey<String>('agent-tile-${roster.agents[2].id}'),
      );
      final Finder pin = find.ancestor(
        of: find.descendant(of: row, matching: find.byTooltip('Pin')),
        matching: find.byType(AnimatedOpacity),
      );
      expect(tester.widget<AnimatedOpacity>(pin).opacity, 0);
      final TestGesture mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(row));
      await tester.pumpAndSettle();
      expect(tester.widget<AnimatedOpacity>(pin).opacity, 1);
      await mouse.moveTo(const Offset(700, 450));
      await tester.pumpAndSettle();
      expect(tester.widget<AnimatedOpacity>(pin).opacity, 0);
    });

    testWidgets("Delete asks in chuk's delete dialog before it removes", (
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

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Delete cobalt?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(roster.byId(id), isNotNull);
    });
  });

  group('keyboard', () {
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
      // ── templates ──: the template picker, in the centred desktop dialog.
      expect(find.byType(CoworkerTemplatePicker), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byType(AgentsDesktopDialog), findsOneWidget);
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

    // ── polish ── bead chuk_chat-az1g
    testWidgets('a failed agent_create names the coworker in the SnackBar', (
      tester,
    ) async {
      await pumpDesktop(tester, relayController: _FailingCreateController.new);

      await shortcut(tester, LogicalKeyboardKey.keyN);
      await tester.tap(find.byKey(const ValueKey<String>('tpl-research')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey<String>('tpl-name')),
        'Scout',
      );
      await tester.tap(find.byKey(const ValueKey<String>('tpl-create')));
      await tester.pumpAndSettle();

      expect(
        find.text('Could not create Scout on your computer.'),
        findsOneWidget,
      );
      expect(find.text('Not connected to the host'), findsNothing);
    });
    // ── end polish ──

    testWidgets('Ctrl+B folds the roster to the rail and back', (tester) async {
      await pumpDesktop(tester);
      await shortcut(tester, LogicalKeyboardKey.keyB);
      expect(rosterRect(tester).width, kDeskRailWidth);
      await shortcut(tester, LogicalKeyboardKey.keyB);
      expect(rosterRect(tester).width, kDesktopSidebarWidth);
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
        tester
            .widget<SbChatTile>(
              find.byKey(ValueKey<String>('room-tile-${room.id}')),
            )
            .selected,
        isTrue,
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
  });
}
