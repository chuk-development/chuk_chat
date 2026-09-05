import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cowork/pages/messenger_shell.dart';
import 'package:cowork/widgets/room_create_sheet.dart';
import 'package:cowork/widgets/room_list_view.dart';
import 'package:cowork/services/account_session.dart';
import 'package:cowork/services/cowork/agent_control_source.dart';
import 'package:cowork/services/cowork/agent_roster_source.dart';
import 'package:cowork/services/cowork/cowork_pairing_store.dart';
import 'package:cowork/services/cowork/cowork_relay_client.dart';
import 'package:cowork/widgets/agent_roster_view.dart';
import 'package:cowork/widgets/browser_view_page.dart';
import 'package:cowork/models/cowork_room.dart';
import 'package:cowork/services/cowork/room_source.dart';
import 'package:cowork/services/notifications/notification_router.dart';
import 'package:cowork/platform_specific/mobile/mobile_agent_list.dart';
import 'package:cowork/platform_specific/mobile/mobile_chat_screen.dart';
import 'package:cowork/widgets/cowork_thread_view.dart';

import 'package:cowork/services/cowork/cowork_relay_link.dart';
import 'package:cowork/services/cowork/cowork_run_ledger.dart';

import '../support/test_app.dart';

class _MemoryStore implements CoworkSecureKeyValueStore {
  final Map<String, String> map = <String, String>{};

  @override
  Future<String?> read(String key) async => map[key];

  @override
  Future<void> write(String key, String value) async => map[key] = value;

  @override
  Future<void> delete(String key) async => map.remove(key);
}

/// A controller the test drives: it can report itself paired, and it records
/// which session key each task went to.
class _FakeRelayController implements CoworkRelayController {
  final ValueNotifier<CoworkRelayState> _state =
      ValueNotifier<CoworkRelayState>(
    const CoworkRelayState(phase: CoworkRelayPhase.idle),
  );
  final StreamController<CoworkRelayInbound> _inbound =
      StreamController<CoworkRelayInbound>.broadcast();

  final List<String> sessionKeys = <String>[];

  @override
  ValueListenable<CoworkRelayState> get state => _state;

  @override
  Stream<CoworkRelayInbound> get inbound => _inbound.stream;

  @override
  Future<void> connect({
    required Uri hostUrl,
    required String pairingCode,
  }) async {}

  @override
  Future<void> reconnect({
    required Uri hostUrl,
    required CoworkStoredPairing pairing,
  }) async {
    pair();
  }

  @override
  CoworkStoredPairing? get establishedTrust => null;

  @override
  Future<void> provisionAccount(AccountSession session) async {}

  @override
  Future<void> sendTask(
    String prompt, {
    String sessionKey = 'default',
    String? modelId,
    String? providerSlug,
    String? reasoningEffort,
    bool debug = false,
    bool regenerate = false,
  }) async =>
      sessionKeys.add(sessionKey);

  final List<(String, String)> roomTasks = <(String, String)>[];
  final List<String> createdRooms = <String>[];

  @override
  Future<void> createRoom(
    String roomId,
    String name,
    List<Map<String, String>> members,
  ) async =>
      createdRooms.add(roomId);

  @override
  Future<void> sendRoomTask(String roomId, String message) async =>
      roomTasks.add((roomId, message));

  final List<String> historyRequests = <String>[];
  final List<String> deletedRooms = <String>[];

  @override
  Future<void> requestRoomHistory(String roomId) async =>
      historyRequests.add(roomId);

  @override
  Future<void> deleteRoom(String roomId) async => deletedRooms.add(roomId);

  final List<(String, String)> renamedRooms = <(String, String)>[];

  @override
  Future<void> renameRoom(String roomId, String name) async =>
      renamedRooms.add((roomId, name));

  final List<(String, String)> createdAgents = <(String, String)>[];
  final List<(String, String)> renamedAgents = <(String, String)>[];

  @override
  Future<void> createAgent(String agentId, String name) async =>
      createdAgents.add((agentId, name));

  @override
  Future<void> renameAgent(String agentId, String name) async =>
      renamedAgents.add((agentId, name));

  final List<(String, String)> removedMembers = <(String, String)>[];

  @override
  Future<void> addRoomMember(String roomId, String agentId, String handle) async {}

  @override
  Future<void> removeRoomMember(String roomId, String agentId) async =>
      removedMembers.add((roomId, agentId));

  @override
  Future<void> requestStop({String sessionKey = 'default'}) async {}

  @override
  Future<void> requestReplay({
    String sessionKey = 'default',
    int afterId = 0,
  }) async {}

  @override
  Future<void> sendRunAck(String runId) async {}

  @override
  Future<void> startBrowserView() async {}

  @override
  Future<void> stopBrowserView() async {}

  @override
  Future<void> sendBrowserData(Uint8List bytes) async {}

  @override
  Future<void> sendApprovalDecision({
    required String approvalId,
    required bool approved,
  }) async {}

  @override
  Future<void> sendSecrets({
    required Map<String, String> values,
    required int revision,
    String? requestId,
  }) async {}

  @override
  Future<void> dispose() async {
    if (!_inbound.isClosed) await _inbound.close();
    _state.dispose();
  }

  void pair() => _state.value = const CoworkRelayState(
        phase: CoworkRelayPhase.paired,
        peerDeviceId: 'cowork-host',
      );

  void emit(CoworkRelayInbound event) => _inbound.add(event);
}

class _FakeSessionSource implements AccountSessionSource {
  const _FakeSessionSource();

  @override
  AccountSession? current() => const AccountSession(
        accessToken: 'access-1',
        refreshToken: 'refresh-1',
        userId: 'user-1',
      );

  @override
  Future<AccountSession?> refresh() async => current();
}

/// Pump a few frames without waiting for the tree to go quiet.
///
/// The imported chat screen keeps an animation running while a run is in
/// flight (the streaming indicator), so `pumpAndSettle` never returns once a
/// run is on the ledger. A bounded pump is what a test wants there anyway: it
/// asserts on a state, not on the end of every animation.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  // The relay link, the run ledger and the replay loader are process-wide
  // singletons; a test must not inherit the previous one's run.
  setUp(() {
    CoworkRelayLink.instance.reset();
    CoworkRunLedger.instance.reset();
  });
  tearDown(() {
    CoworkRelayLink.instance.reset();
    CoworkRunLedger.instance.reset();
    NotificationRouter.instance.reset();
  });

  /// How often the shell asked for a transport. The thread view builds its
  /// controller once per mount, so this is the mount count of the socket owner.
  int controllerBuilds = 0;
  setUp(() => controllerBuilds = 0);

  Future<(_FakeRelayController, LocalAgentRosterSource)> pumpShell(
    WidgetTester tester, {
    Size size = const Size(1200, 800),
    CoworkPairingStore? store,
    AgentControlSource? controlSource,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = _FakeRelayController();
    final roster = LocalAgentRosterSource();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: kTestLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MessengerShell(
          relayControllerBuilder: () async {
            controllerBuilds++;
            return controller;
          },
          sessionSource: const _FakeSessionSource(),
          pairingStore: store ?? CoworkPairingStore(backend: _MemoryStore()),
          rosterSource: roster,
          controlSource: controlSource,
          onSignOut: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (controller, roster);
  }

  /// The one thread view, wherever the layout put it. `skipOffstage: false`
  /// because chuk's compact mode and the phone inbox keep it mounted but off
  /// stage, and that is exactly what these tests assert.
  final Finder threadView = find.byType(CoworkThreadView, skipOffstage: false);

  /// Whether the one thread view is currently off stage (chuk's compact mode
  /// hides the chat under the open sidebar; it is never unmounted).
  bool threadOffstage(WidgetTester tester) {
    final offstage = find.ancestor(
      of: threadView,
      matching: find.byType(Offstage, skipOffstage: false),
    );
    return tester.widget<Offstage>(offstage.first).offstage;
  }

  /// Resizes the window and lets the layout settle.
  Future<void> resize(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    await tester.pumpAndSettle();
  }

  testWidgets('a wide window shows the roster next to the thread', (tester) async {
    await pumpShell(tester);

    expect(find.byType(AgentRosterView), findsOneWidget);
    expect(find.byType(CoworkThreadView), findsOneWidget);
    expect(threadOffstage(tester), isFalse);
    expect(find.text('Coworkers'), findsOneWidget);
    expect(find.text('No coworkers yet.'), findsOneWidget);
    // chuk's chrome, not an app bar: the hamburger at the top left and the
    // floating row at the top right.
    expect(find.byType(AppBar), findsNothing);
    expect(find.byIcon(Icons.menu_rounded), findsOneWidget);
    expect(find.byTooltip('Copy full chat'), findsOneWidget);
    // Nothing sits on top of the chat: the connection is not the user's job.
    expect(find.textContaining('Connected to'), findsNothing);
    expect(find.byIcon(Icons.link_off), findsNothing);
  });

  testWidgets('the four top-right actions sit in chuk\'s floating row',
      (tester) async {
    final (controller, roster) = await pumpShell(tester);
    controller.pair();
    await tester.pumpAndSettle();

    // With a coworker selected three slots are live: Agent controls, Control
    // Rooms, and Copy full chat in chuk's own slot. Agent's browser waits for
    // the agent to actually open a browser (cowork-vzm).
    for (final tooltip in <String>[
      'Agent controls',
      'Control Rooms',
      'Copy full chat',
    ]) {
      expect(find.byTooltip(tooltip), findsOneWidget, reason: tooltip);
    }
    expect(find.byTooltip("Agent's browser"), findsNothing);
    expect(find.byType(AppBar), findsNothing);
    // The composer's "More models" way out is wired.
    final view = tester.widget<CoworkThreadView>(find.byType(CoworkThreadView));
    expect(view.onOpenModelScreen, isNotNull);
    expect(roster.agents.single.onHost, isTrue);
  });

  testWidgets('the hamburger folds the roster to the mini rail and back',
      (tester) async {
    final (controller, _) = await pumpShell(tester);
    controller.pair();
    await tester.pumpAndSettle();
    expect(find.text('Coworkers').hitTestable(), findsOneWidget);

    await tester.tap(find.byIcon(Icons.menu_rounded));
    await tester.pumpAndSettle();

    // The roster is off screen; chuk's mini rail carries the two slots. The
    // browser has no rail slot and no button yet: nothing is open.
    expect(find.text('Coworkers').hitTestable(), findsNothing);
    expect(find.byTooltip('New coworker'), findsOneWidget);
    expect(find.byTooltip('Control Rooms'), findsNWidgets(2)); // rail + top right
    expect(find.byTooltip("Agent's browser"), findsNothing);
    expect(threadOffstage(tester), isFalse);

    await tester.tap(find.byIcon(Icons.menu_rounded));
    await tester.pumpAndSettle();
    expect(find.text('Coworkers').hitTestable(), findsOneWidget);
    expect(find.byTooltip('New coworker'), findsNothing);
  });

  testWidgets("Agent's browser appears top right only once the agent opened one, "
      'and opens as a full-screen route', (tester) async {
    final (controller, _) = await pumpShell(tester);
    controller.pair();
    await tester.pumpAndSettle();
    expect(find.byTooltip("Agent's browser"), findsNothing);

    // The agent navigates somewhere: the Playwright MCP tool frame (live or
    // replayed) is the signal. One button, top right, nowhere else.
    controller.emit(
      const CoworkRelayTool(
        'mcp__playwright__browser_navigate',
        status: 'completed',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip("Agent's browser"), findsOneWidget);
    expect(find.text("Agent's browser"), findsNothing); // no sidebar row

    await tester.tap(find.byTooltip("Agent's browser"));
    await tester.pumpAndSettle();
    // A route with its own app bar, not a side panel next to the chat.
    expect(find.byType(BrowserViewPage), findsOneWidget);
    expect(find.widgetWithText(AppBar, 'Agent browser'), findsOneWidget);
    final route = ModalRoute.of(tester.element(find.byType(BrowserViewPage)));
    expect((route as MaterialPageRoute).fullscreenDialog, isTrue);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(BrowserViewPage), findsNothing);

    // The agent closes the browser: the button goes away again.
    controller.emit(
      const CoworkRelayTool(
        'mcp__playwright__browser_close',
        status: 'completed',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip("Agent's browser"), findsNothing);
  });

  testWidgets('one socket across a wide, tablet and phone resize', (tester) async {
    final (controller, _) = await pumpShell(tester);
    controller.pair();
    await tester.pumpAndSettle();
    expect(controllerBuilds, 1);

    // The thread view moves between chuk\'s desktop stack and the phone layer;
    // it is never rebuilt, so the transport is built exactly once.
    await resize(tester, const Size(660, 900));
    expect(threadView, findsOneWidget);
    await resize(tester, const Size(420, 900));
    expect(threadView, findsOneWidget);
    await resize(tester, const Size(1200, 800));
    expect(threadView, findsOneWidget);
    expect(controllerBuilds, 1);
  });

  testWidgets('a tapped notification selects the thread it names (WS-7)',
      (tester) async {
    // Two coworkers; the host's thread is selected on pairing, the other one
    // is what the toast names.
    final (controller, roster) = await pumpShell(tester);
    controller.pair();
    await tester.pumpAndSettle();
    final other = roster.addAgent(name: 'jade-heron');
    await tester.pumpAndSettle();
    expect(
      tester.widget<CoworkThreadView>(threadView).threadKey,
      roster.agents.first.threads.single.key,
    );

    NotificationRouter.instance.open(
      NotificationTarget(sessionKey: other.threads.single.key),
    );
    await tester.pumpAndSettle();

    expect(
      tester.widget<CoworkThreadView>(threadView).threadKey,
      other.threads.single.key,
    );
    // Taken, not left pending: a second shell would not re-open it.
    expect(NotificationRouter.instance.pending.value, isNull);
  });

  testWidgets('Control Rooms opens as the right panel and closes again',
      (tester) async {
    await pumpShell(tester);

    await tester.tap(find.byTooltip('Control Rooms'));
    await tester.pumpAndSettle();

    expect(find.byType(RoomListView), findsOneWidget);
    expect(find.byTooltip('Close'), findsOneWidget);
    // The chat stays mounted next to the panel.
    expect(find.byType(CoworkThreadView), findsOneWidget);
    expect(threadOffstage(tester), isFalse);

    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(RoomListView), findsNothing);
  });

  testWidgets('pairing lists the agent that really runs on the host',
      (tester) async {
    final (controller, roster) = await pumpShell(tester);

    controller.pair();
    await tester.pumpAndSettle();

    // Named after the host's own device id, and marked as living there.
    expect(find.text('cowork-host'), findsWidgets);
    expect(roster.agents.single.onHost, isTrue);
    // One permanent thread, keyed by the stable agent id.
    expect(roster.agents.single.threads, hasLength(1));
    expect(roster.agents.single.threads.single.key, roster.agents.single.id);
  });

  testWidgets('New coworker is chuk\'s name dialog: it adds the coworker, '
      'tells the host and opens the thread', (tester) async {
    final (controller, roster) = await pumpShell(tester);

    await tester.tap(find.byIcon(Icons.person_add_alt));
    await tester.pumpAndSettle();
    // chuk's rename-dialog shape: an AlertDialog with one TextField.
    expect(find.byType(AlertDialog), findsOneWidget);
    final nameField = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    expect(nameField, findsOneWidget);
    // The field is pre-filled with a suggested adjective-noun name.
    expect(tester.widget<TextField>(nameField).controller!.text, isNotEmpty);

    await tester.enterText(nameField, '  Crypto Desk ');
    await tester.tap(find.widgetWithText(TextButton, 'Create'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(roster.agents, hasLength(1));
    expect(roster.agents.single.name, 'Crypto Desk');
    // An app-created agent is never claimed to be installed on the host.
    expect(roster.agents.single.onHost, isFalse);
    // The host was told, so the name outlives this install.
    expect(controller.createdAgents,
        [(roster.agents.single.id, 'Crypto Desk')]);
    // Its thread is selected: the one thread view points at it, and the
    // roster lists it by name.
    final view = tester.widget<CoworkThreadView>(find.byType(CoworkThreadView));
    expect(view.threadKey, roster.agents.single.threads.single.key);
    expect(find.text('Crypto Desk'), findsWidgets);
    expect(controller.sessionKeys, isEmpty);
  });

  testWidgets('Cancel in the New coworker dialog adds nothing', (tester) async {
    final (controller, roster) = await pumpShell(tester);

    await tester.tap(find.byIcon(Icons.person_add_alt));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(roster.agents, isEmpty);
    expect(controller.createdAgents, isEmpty);
  });

  testWidgets('Rename from the row menu renames locally and on the host',
      (tester) async {
    final (controller, roster) = await pumpShell(tester);
    final agent = roster.addAgent(name: 'amber');
    await tester.pumpAndSettle();

    await tester.tap(find.descendant(
      of: find.byKey(ValueKey<String>('agent-tile-${agent.id}')),
      matching: find.byTooltip('More'),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();

    final nameField = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    expect(tester.widget<TextField>(nameField).controller!.text, 'amber');
    await tester.enterText(nameField, 'Amber Desk');
    await tester.tap(find.widgetWithText(TextButton, 'Rename'));
    await tester.pumpAndSettle();

    expect(roster.byId(agent.id)!.name, 'Amber Desk');
    // The id and the thread key are untouched: a name is a label.
    expect(roster.byId(agent.id)!.threads.single.key, agent.threads.single.key);
    expect(controller.renamedAgents, [(agent.id, 'Amber Desk')]);
    expect(find.text('Amber Desk'), findsWidgets);
  });

  testWidgets('an agent has one permanent thread and no way to open a second',
      (tester) async {
    final (controller, roster) = await pumpShell(tester);
    controller.pair();
    await tester.pumpAndSettle();

    // The "new thread" affordance is gone: one permanent session per bot.
    expect(find.byIcon(Icons.add_comment_outlined), findsNothing);
    expect(roster.agents.single.threads, hasLength(1));
    final stableKey = roster.agents.single.id;
    expect(roster.agents.single.threads.single.key, stableKey);

    // The shell's whole job here is to point one thread view at that one key.
    // Everything downstream of it — the imported composer, the transport
    // adapter, the executor session — reads the key from these two places, and
    // both are asserted end to end in cowork_thread_view_test /
    // websocket_chat_service_test.
    final view = tester.widget<CoworkThreadView>(find.byType(CoworkThreadView));
    expect(view.threadKey, stableKey);
    expect(CoworkRelayLink.instance.sessionKey.value, stableKey);
    // Still exactly one thread: there is no way to open a second.
    expect(roster.agents.single.threads, hasLength(1));
  });

  testWidgets('a run marks the agent as working and back to waiting',
      (tester) async {
    final (controller, roster) = await pumpShell(tester);
    controller.pair();
    await tester.pumpAndSettle();

    // Run state is read off CoworkRunLedger now — the one place that knows a
    // run is in flight whether this client started it or adopted it from the
    // host's `run_state` header after a reconnect.
    final threadKey = roster.agents.single.threads.single.key;
    CoworkRunLedger.instance.begin(threadKey);
    await tester.pump();

    expect(find.textContaining('working'), findsOneWidget);

    CoworkRunLedger.instance.finish(threadKey, reason: 'finished');
    await tester.pump();

    expect(find.textContaining('working'), findsNothing);
    expect(find.textContaining('waiting'), findsOneWidget);
    expect(roster.agents.single.lastActivity, isNotNull);
  });

  testWidgets('the controls button opens the panel, which reports what is missing',
      (tester) async {
    final (controller, _) = await pumpShell(tester);
    controller.pair();
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();

    // The default source reports every block as not connected.
    expect(find.text('Not connected yet'), findsNWidgets(6));
    expect(find.text('TOKEN USE'), findsOneWidget);
    expect(find.text('SESSION RUNTIME'), findsOneWidget);
    expect(find.text('SCHEDULE'), findsOneWidget);
    expect(find.text('SKILLS'), findsOneWidget);
    expect(find.text('INTEGRATIONS'), findsOneWidget);
  });

  testWidgets('a schedule set in the panel lands on the agent', (tester) async {
    final (controller, roster) = await pumpShell(tester);
    controller.pair();
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Schedule'), 'every 6h');
    await tester.tap(find.widgetWithText(FilledButton, 'Set'));
    await tester.pumpAndSettle();

    expect(roster.agents.single.schedule!.source, 'every 6h');
  });

  testWidgets('a tablet window shows the roster first, then the thread',
      (tester) async {
    // 660: narrower than the 720 compact breakpoint, wider than the 600 phone
    // one — chuk's compact mode: the open sidebar covers the chat.
    final (controller, _) = await pumpShell(tester, size: const Size(660, 900));
    controller.pair();
    await tester.pumpAndSettle();

    // The roster is on screen; the thread is mounted but off stage behind it.
    expect(find.text('Coworkers').hitTestable(), findsOneWidget);
    expect(threadView, findsOneWidget);
    expect(threadOffstage(tester), isTrue);
    expect(find.byType(AppBar), findsNothing);

    await tester.tap(find.text('cowork-host').first);
    await tester.pumpAndSettle();

    // Picking a coworker folds the sidebar: the thread comes forward, and the
    // hamburger is the way back to the roster.
    expect(threadOffstage(tester), isFalse);
    expect(find.text('Coworkers').hitTestable(), findsNothing);
    await tester.tap(find.byIcon(Icons.menu_rounded));
    await tester.pumpAndSettle();
    expect(find.text('Coworkers').hitTestable(), findsOneWidget);
    expect(threadOffstage(tester), isTrue);
  });

  testWidgets('a phone window shows the inbox, then the chat, and back again',
      (tester) async {
    // Under 600 the shell mounts the mobile layer instead: the coworker inbox,
    // and a chat screen whose chrome floats over the thread with no app bar.
    final (controller, roster) =
        await pumpShell(tester, size: const Size(420, 900));
    controller.pair();
    await tester.pumpAndSettle();

    final agentId = roster.agents.single.id;
    expect(find.byType(MobileAgentList), findsOneWidget);
    expect(find.byType(AppBar), findsNothing);

    await tester.tap(find.byKey(ValueKey<String>('mobile-agent-$agentId')));
    await tester.pumpAndSettle();

    // The chat is in front, still with no app bar, and the back chip returns
    // to the inbox — the same flag the tablet path flips.
    expect(find.byType(MobileChatScreen), findsOneWidget);
    expect(find.byType(AppBar), findsNothing);
    await tester.tap(find.byIcon(Icons.arrow_back_ios_new_rounded));
    await tester.pumpAndSettle();
    expect(find.byType(MobileAgentList), findsOneWidget);
    expect(find.byType(MobileChatScreen), findsNothing);
  });

  testWidgets('the Rooms button opens the rooms screen and lists rooms',
      (tester) async {
    final rooms = LocalRoomSource();
    final room = rooms.addRoom(
      const CoworkRoomDraft(
        name: 'launch',
        members: [
          CoworkRoomMember(agentId: 'a', handle: 'amber'),
          CoworkRoomMember(agentId: 'b', handle: 'cobalt'),
        ],
      ),
    );
    final controller = _FakeRelayController();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: kTestLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MessengerShell(
          relayControllerBuilder: () async => controller,
          sessionSource: const _FakeSessionSource(),
          pairingStore: CoworkPairingStore(backend: _MemoryStore()),
          rosterSource: LocalAgentRosterSource(),
          roomSource: rooms,
          onSignOut: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Control Rooms'));
    await tester.pumpAndSettle();

    // The room list is the right panel (chuk's Workspaces slot); at 800 px
    // the sidebar folds to make room for it.
    expect(find.byType(RoomListView), findsOneWidget);
    expect(find.text('Rooms'), findsWidgets);
    expect(find.text('launch'), findsOneWidget);
    expect(find.text('2 members'), findsOneWidget);

    // Opening a room shows its thread as its own route, over the shell. The fake controller is live (the thread
    // view handed it up), so the room streams over that same socket. The room
    // renders a running spinner, so advance frames with pump, not pumpAndSettle.
    await tester.tap(find.text('launch'));
    await tester.pump(); // start the route
    await tester.pump(const Duration(milliseconds: 400)); // finish the transition
    expect(
      find.text('Message the room to start.'),
      findsOneWidget,
    );
    // Opening the room re-syncs it to the host (idempotent) and asks for its
    // stored history.
    expect(controller.historyRequests, [room.id]);
    expect(controller.createdRooms, contains(room.id));

    // A room_turn for this room streams into the open page.
    controller.emit(
      CoworkRelayRoomTurn(
        roomId: room.id,
        round: 1,
        agentId: 'a',
        handle: 'amber',
        text: 'ship it',
      ),
    );
    await tester.pump();
    // "@amber" appears both in the member strip and the turn, so assert on the
    // unique turn text.
    expect(find.text('@amber'), findsWidgets);
    expect(find.text('ship it'), findsOneWidget);

    // The composer routes to sendRoomTask with the room id.
    await tester.enterText(find.byType(TextField).last, 'kick off');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
    expect(controller.roomTasks, [(room.id, 'kick off')]);
  });

  testWidgets('creating a room from the shell adds it to the source',
      (tester) async {
    final rooms = LocalRoomSource();
    final roster = LocalAgentRosterSource()
      ..addAgent(name: 'amber')
      ..addAgent(name: 'cobalt');
    final controller = _FakeRelayController();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: kTestLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MessengerShell(
          relayControllerBuilder: () async => controller,
          sessionSource: const _FakeSessionSource(),
          pairingStore: CoworkPairingStore(backend: _MemoryStore()),
          rosterSource: roster,
          roomSource: rooms,
          onSignOut: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Control Rooms'));
    await tester.pumpAndSettle();
    // Empty -> the New room button is offered.
    await tester.tap(find.widgetWithText(FilledButton, 'New room'));
    await tester.pumpAndSettle();

    // Scope to the sheet: the room list is a panel next to the chat now, so
    // the chat's own field is on stage too.
    await tester.enterText(
      find.descendant(
        of: find.byType(RoomCreateSheet),
        matching: find.byType(TextField),
      ),
      'planning',
    );
    // The roster lists the same names; pick the members inside the sheet.
    Finder inSheet(String name) => find.descendant(
          of: find.byType(RoomCreateSheet),
          matching: find.text(name),
        );
    await tester.tap(inSheet('amber'));
    await tester.tap(inSheet('cobalt'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    expect(rooms.rooms, hasLength(1));
    expect(rooms.rooms.single.name, 'planning');
    // The room was pushed to the host so a later message can drive it.
    expect(controller.createdRooms, [rooms.rooms.single.id]);
    // Back on the rooms list, the new room shows.
    expect(find.text('planning'), findsOneWidget);
  });

  testWidgets('deleting an agent syncs its rooms to the host', (tester) async {
    final roster = LocalAgentRosterSource()..addAgent(name: 'amber');
    final amberId = roster.agents.single.id; // local agent -> Delete offered
    final rooms = LocalRoomSource();
    // Room A survives amber's removal (3 -> 2); room B is deleted (2 -> 1).
    final a = rooms.addRoom(CoworkRoomDraft(name: 'A', members: [
      CoworkRoomMember(agentId: amberId, handle: 'amber'),
      const CoworkRoomMember(agentId: 'b', handle: 'cobalt'),
      const CoworkRoomMember(agentId: 'c', handle: 'jade'),
    ]));
    final b = rooms.addRoom(CoworkRoomDraft(name: 'B', members: [
      CoworkRoomMember(agentId: amberId, handle: 'amber'),
      const CoworkRoomMember(agentId: 'd', handle: 'onyx'),
    ]));
    final controller = _FakeRelayController();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: kTestLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MessengerShell(
          relayControllerBuilder: () async => controller,
          sessionSource: const _FakeSessionSource(),
          pairingStore: CoworkPairingStore(backend: _MemoryStore()),
          rosterSource: roster,
          roomSource: rooms,
          onSignOut: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Delete amber via its roster row menu. The row is scoped by the agent's
    // own tile key: since the sidebar moved onto chuk's chrome the row is no
    // longer a ListTile, but it is still exactly one tile per agent.
    await tester.tap(
      find.descendant(
        of: find.byKey(ValueKey<String>('agent-tile-$amberId')),
        matching: find.byIcon(Icons.more_vert),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    // Room B fell below two members -> deleted on the host; room A survived ->
    // amber removed from it on the host.
    expect(controller.deletedRooms, [b.id]);
    expect(controller.removedMembers, [(a.id, amberId)]);
    expect(rooms.byId(b.id), isNull);
    expect(rooms.byId(a.id)!.members.length, 2);
  });

  testWidgets('removing a member from the sheet syncs removeRoomMember',
      (tester) async {
    final roster = LocalAgentRosterSource();
    final rooms = LocalRoomSource();
    // Three members, so Remove is enabled (it disables at two).
    final room = rooms.addRoom(const CoworkRoomDraft(name: 'trio', members: [
      CoworkRoomMember(agentId: 'a', handle: 'amber'),
      CoworkRoomMember(agentId: 'b', handle: 'cobalt'),
      CoworkRoomMember(agentId: 'c', handle: 'jade'),
    ]));
    final controller = _FakeRelayController();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: kTestLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MessengerShell(
          relayControllerBuilder: () async => controller,
          sessionSource: const _FakeSessionSource(),
          pairingStore: CoworkPairingStore(backend: _MemoryStore()),
          rosterSource: roster,
          roomSource: rooms,
          onSignOut: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Control Rooms'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Manage members'));
    await tester.pumpAndSettle();

    // Remove the first member: the room survives (3 -> 2), host told to drop it.
    await tester.tap(find.byIcon(Icons.remove_circle_outline).first);
    await tester.pumpAndSettle();

    expect(rooms.byId(room.id)!.members.length, 2);
    expect(controller.removedMembers, [(room.id, 'a')]);
    expect(controller.deletedRooms, isEmpty);
  });

  testWidgets('a room deleted while offline is flushed to the host on connect',
      (tester) async {
    final rooms = LocalRoomSource();
    final room = rooms.addRoom(const CoworkRoomDraft(name: 'gone', members: [
      CoworkRoomMember(agentId: 'a', handle: 'amber'),
      CoworkRoomMember(agentId: 'b', handle: 'cobalt'),
    ]));
    final controller = _FakeRelayController();
    // The transport is not ready yet: its builder waits on this completer, so
    // _controller.value stays null and a delete must be queued.
    final gate = Completer<CoworkRelayController>();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: kTestLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MessengerShell(
          relayControllerBuilder: () => gate.future,
          sessionSource: const _FakeSessionSource(),
          pairingStore: CoworkPairingStore(backend: _MemoryStore()),
          rosterSource: LocalAgentRosterSource(),
          roomSource: rooms,
          onSignOut: () {},
        ),
      ),
    );
    await tester.pump();

    // Delete the room while offline (via the room panel's menu). Bounded
    // pumps: the thread view animates while its transport is still pending,
    // and the panel sits next to it now instead of behind a route that muted
    // its ticker.
    await tester.tap(find.byTooltip('Control Rooms'));
    await settle(tester);
    await tester.tap(find.byIcon(Icons.more_vert));
    await settle(tester);
    await tester.tap(find.text('Delete room'));
    await settle(tester);

    expect(rooms.byId(room.id), isNull);
    expect(controller.deletedRooms, isEmpty); // not sent yet — offline

    // The transport arrives: the queued delete flushes.
    gate.complete(controller);
    await tester.pumpAndSettle();
    expect(controller.deletedRooms, [room.id]);
  });

  testWidgets('the top-right "Copy full chat" button exports the thread',
      (tester) async {
    final List<String> exported = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: kTestLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MessengerShell(
          relayControllerBuilder: () async => _FakeRelayController(),
          sessionSource: const _FakeSessionSource(),
          pairingStore: CoworkPairingStore(backend: _MemoryStore()),
          rosterSource: LocalAgentRosterSource(),
          roomSource: LocalRoomSource(),
          onSignOut: () {},
          chatDebugExport: (threadKey) async {
            exported.add(threadKey);
            return 'full chat copied';
          },
        ),
      ),
    );
    await tester.pump();

    expect(find.byTooltip('Copy full chat'), findsOneWidget);
    await tester.tap(find.byTooltip('Copy full chat'));
    await tester.pumpAndSettle();

    expect(exported, ['default']);
    expect(find.text('full chat copied'), findsOneWidget);
  });

  testWidgets('a failed "Copy full chat" says so instead of staying silent',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: kTestLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MessengerShell(
          relayControllerBuilder: () async => _FakeRelayController(),
          sessionSource: const _FakeSessionSource(),
          pairingStore: CoworkPairingStore(backend: _MemoryStore()),
          rosterSource: LocalAgentRosterSource(),
          roomSource: LocalRoomSource(),
          onSignOut: () {},
          chatDebugExport: (threadKey) async => throw StateError('no cache'),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('Copy full chat'));
    await tester.pumpAndSettle();

    expect(find.text('could not copy the chat'), findsOneWidget);
  });
}
