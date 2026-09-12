import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/icon_finder.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cowork/pages/messenger_shell.dart';
import 'package:cowork/pages/mobile_cowork_settings_page.dart';
import 'package:cowork/pages/agent_profile_edit_page.dart';
import 'package:cowork/pages/automations_page.dart';
import 'package:cowork/widgets/chat_documents_panel.dart';
import 'package:cowork/models/stored_chat.dart';
import 'package:cowork/services/chat_storage_state.dart';
import 'package:cowork/widgets/room_create_sheet.dart';
import 'package:cowork/widgets/room_list_view.dart';
import 'package:cowork/services/account_session.dart';
import 'package:cowork/services/cowork/agent_control_source.dart';
import 'package:cowork/services/cowork/agent_roster_source.dart';
import 'package:cowork/services/cowork/cowork_pairing_store.dart';
import 'package:cowork/services/cowork/browser_presence.dart';
import 'package:cowork/services/cowork/cowork_relay_client.dart';
import 'package:cowork/widgets/agent_roster_view.dart';
import 'package:cowork/ui/expressive/motion.dart';
import 'package:cowork/widgets/browser_view_page.dart';
import 'package:cowork/models/cowork_room.dart';
import 'package:cowork/services/cowork/room_source.dart';
import 'package:cowork/services/notifications/notification_router.dart';
import 'package:cowork/platform_specific/mobile/mobile_agent_list.dart';
import 'package:cowork/platform_specific/mobile/mobile_chat_chrome.dart';
import 'package:cowork/platform_specific/mobile/mobile_chat_screen.dart';
import 'package:cowork/widgets/cowork_thread_view.dart';

import 'package:cowork/services/cowork/cowork_relay_link.dart';
import 'package:cowork/services/cowork/cowork_run_ledger.dart';

import '../support/test_app.dart';
import '../platform_specific/mobile/mobile_support.dart' show findId;

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
  }) async => sessionKeys.add(sessionKey);

  final List<(String, String)> roomTasks = <(String, String)>[];
  final List<String> createdRooms = <String>[];

  @override
  Future<void> createRoom(
    String roomId,
    String name,
    List<Map<String, String>> members,
  ) async => createdRooms.add(roomId);

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

  int agentListRequests = 0;

  @override
  Future<void> requestAgentList() async => agentListRequests++;

  final List<(String, String)> removedMembers = <(String, String)>[];

  @override
  Future<void> addRoomMember(
    String roomId,
    String agentId,
    String handle,
  ) async {}

  @override
  Future<void> removeRoomMember(String roomId, String agentId) async =>
      removedMembers.add((roomId, agentId));

  @override
  Future<void> requestStop({String sessionKey = 'default'}) async {}

  @override
  Future<void> requestReplay({
    String sessionKey = 'default',
    int afterId = 0,
    int beforeId = 0,
    int limit = 0,
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
  //
  // Preferences are process-wide too, and the roster is cached in them now
  // (`cowork_agent_roster_v1`, bead cowork-91pn): without this reset a shell
  // would start with the coworkers an earlier test created, which is exactly
  // the cold start the cache is for — and exactly what a test must not inherit.
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
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
    bool openSidebar = true,
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
    if (openSidebar && size.width >= 600) {
      await tester.tap(findIcon(Icons.menu_rounded));
      await tester.pumpAndSettle();
    }
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

  testWidgets(
    'a wide window starts collapsed like master; menu reveals roster',
    (tester) async {
      await pumpShell(tester, openSidebar: false);
      expect(find.byType(AgentRosterView), findsNothing);
      expect(find.byTooltip('New agent'), findsOneWidget);
      expect(find.byType(CoworkThreadView), findsOneWidget);
      await tester.tap(findIcon(Icons.menu_rounded));
      await tester.pumpAndSettle();

      expect(find.byType(AgentRosterView), findsOneWidget);
      expect(find.byType(CoworkThreadView), findsOneWidget);
      expect(threadOffstage(tester), isFalse);
      expect(find.text('Chuk Chat'), findsOneWidget);
      expect(find.text('No agents yet.'), findsOneWidget);
      // chuk's chrome, not an app bar: the hamburger at the top left and the
      // floating row at the top right.
      expect(find.byType(AppBar), findsNothing);
      expect(findIcon(Icons.menu_rounded), findsOneWidget);
      expect(find.byTooltip('Copy Debug Chat'), findsOneWidget);
      // Nothing sits on top of the chat: the connection is not the user's job.
      expect(find.textContaining('Connected to'), findsNothing);
      expect(findIcon(Icons.link_off), findsNothing);
    },
  );

  testWidgets('the four top-right actions sit in chuk\'s floating row', (
    tester,
  ) async {
    final (controller, roster) = await pumpShell(tester);
    controller.pair();
    await tester.pumpAndSettle();

    // With a coworker selected three slots are live: Agent controls, Control
    // Rooms, and Copy Debug Chat in chuk's own slot. Agent's browser waits for
    // the agent to actually open a browser (cowork-vzm).
    for (final tooltip in <String>[
      'Agent controls',
      'Control Rooms',
      'Copy Debug Chat',
    ]) {
      expect(find.byTooltip(tooltip), findsOneWidget, reason: tooltip);
    }
    // The screen target sits in the header's video-call slot now and is parked
    // until the coworker really has a screen open (cowork-vzm).
    expect(find.byTooltip("Agent's screen"), findsNothing);
    expect(find.byTooltip('No screen open right now'), findsOneWidget);
    expect(find.byTooltip('Voice call is not available yet'), findsOneWidget);
    expect(find.byType(AppBar), findsNothing);
    // The composer's "More models" way out is wired.
    final view = tester.widget<CoworkThreadView>(find.byType(CoworkThreadView));
    expect(view.onOpenModelScreen, isNotNull);
    expect(roster.agents.single.onHost, isTrue);
  });

  testWidgets('the hamburger folds the roster to the mini rail and back', (
    tester,
  ) async {
    final (controller, _) = await pumpShell(tester);
    controller.pair();
    await tester.pumpAndSettle();
    expect(find.text('Chuk Chat').hitTestable(), findsOneWidget);

    await tester.tap(findIcon(Icons.menu_rounded));
    await tester.pumpAndSettle();

    // The roster is off screen; chuk's mini rail carries the two slots. The
    // browser has no rail slot and no button yet: nothing is open.
    expect(find.text('Chuk Chat').hitTestable(), findsNothing);
    expect(find.byTooltip('New agent'), findsOneWidget);
    expect(
      find.byTooltip('Control Rooms'),
      findsNWidgets(2),
    ); // rail + top right
    expect(find.byTooltip("Agent's screen"), findsNothing);
    expect(threadOffstage(tester), isFalse);

    await tester.tap(findIcon(Icons.menu_rounded));
    await tester.pumpAndSettle();
    expect(find.text('Chuk Chat').hitTestable(), findsOneWidget);
    expect(find.byTooltip('New agent'), findsNothing);
  });

  testWidgets(
    "the coworker's screen unlocks in the header only once it opened one, "
    'and opens as a full-screen route',
    (tester) async {
      final (controller, _) = await pumpShell(tester);
      controller.pair();
      await tester.pumpAndSettle();
      expect(find.byTooltip("Agent's screen"), findsNothing);

      // History must not expose a stale browser. Explicit VNC capability does.
      controller.emit(
        const CoworkRelayTool(
          'mcp__playwright__browser_navigate',
          status: 'completed',
          replay: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip("Agent's screen"), findsNothing);
      controller.emit(
        const CoworkRelayBrowserView(status: 'opened', vncAvailable: true),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip("Agent's screen"), findsOneWidget);
      expect(find.text("Agent's screen"), findsNothing); // no sidebar row

      await tester.tap(find.byTooltip("Agent's screen"));
      // Not pumpAndSettle: the page's spinner animates until the executor's
      // `started` event, which this test never sends.
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      // The frame fills the route immediately, with a direct close control.
      expect(find.byType(BrowserViewPage), findsOneWidget);
      expect(find.widgetWithText(AppBar, 'Agent browser'), findsNothing);
      expect(
        find.byKey(const Key('browser_view_exit_fullscreen')),
        findsOneWidget,
      );
      final route = ModalRoute.of(tester.element(find.byType(BrowserViewPage)));
      expect((route as MaterialPageRoute).fullscreenDialog, isTrue);

      // A full-screen dialog closes with an X, not a back arrow.
      await tester.tap(find.byKey(const Key('browser_view_close')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(BrowserViewPage), findsNothing);

      // Finishing the run leaves the screen there: the coworker ends its turn
      // with "the browser is open, you can take it over", and that is the
      // moment the user reaches for it (bead cowork-tf1u).
      controller.emit(const CoworkRelayDone());
      await tester.pumpAndSettle();
      expect(find.byTooltip("Agent's screen"), findsOneWidget);

      // The host closing the browser is what takes it away.
      controller.emit(
        const CoworkRelayRunState(
          sessionKey: 'default',
          state: 'idle',
          browserOpen: false,
          vncAvailable: false,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip("Agent's screen"), findsNothing);
      expect(find.byTooltip('No screen open right now'), findsOneWidget);
    },
  );

  testWidgets('one socket across a wide, tablet and phone resize', (
    tester,
  ) async {
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

  testWidgets('a tapped notification selects the thread it names (WS-7)', (
    tester,
  ) async {
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

    // Re-pairing must not create a new chat or switch back to the host agent.
    controller.pair();
    await tester.pumpAndSettle();
    expect(
      tester.widget<CoworkThreadView>(threadView).threadKey,
      other.threads.single.key,
    );
    expect(roster.byId(other.id)!.threads, hasLength(1));
  });

  testWidgets('Control Rooms opens as the right panel and closes again', (
    tester,
  ) async {
    await pumpShell(tester);

    await tester.tap(find.byTooltip('Control Rooms').first);
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

  testWidgets('legacy cached sessions are preserved without a history picker', (
    tester,
  ) async {
    ChatStorageState.chatsById['default'] = StoredChat.forSidebar(
      id: 'default',
      createdAt: DateTime(2026, 8, 12),
      isStarred: false,
      title: 'Earlier conversation',
    );
    addTearDown(() => ChatStorageState.chatsById.clear());
    final (controller, _) = await pumpShell(tester);
    expect(find.text('Earlier conversation'), findsNothing);
    expect(find.text('Chat history'), findsNothing);
    controller.pair();
    await tester.pumpAndSettle();
    expect(
      tester.widget<CoworkThreadView>(threadView).threadKey,
      'host:cowork-host',
    );
    expect(ChatStorageState.chatsById.containsKey('default'), isTrue);
    await resize(tester, const Size(420, 900));
    expect(find.text('Earlier conversation'), findsNothing);
    expect(find.text('Chat history'), findsNothing);
  });

  testWidgets('unknown notification cannot open a subchat under an agent', (
    tester,
  ) async {
    final (controller, roster) = await pumpShell(tester);
    controller.pair();
    await tester.pumpAndSettle();
    final permanentKey = roster.agents.single.threads.single.key;
    NotificationRouter.instance.open(
      const NotificationTarget(sessionKey: 'unowned-legacy-session'),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<CoworkThreadView>(threadView).threadKey, permanentKey);

    // Even a stale callback with a valid agent but different session is refused.
    tester
        .widget<AgentRosterView>(find.byType(AgentRosterView))
        .onSelect(roster.agents.single.id, 'unowned-legacy-session');
    await tester.pumpAndSettle();
    expect(tester.widget<CoworkThreadView>(threadView).threadKey, permanentKey);
  });

  testWidgets('pairing lists the agent that really runs on the host', (
    tester,
  ) async {
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

  testWidgets('New agent is chuk\'s name dialog: it adds the coworker, '
      'tells the host and opens the thread', (tester) async {
    final (controller, roster) = await pumpShell(tester);

    await tester.tap(findIcon(Icons.person_add_alt));
    await tester.pumpAndSettle();
    // The app's own name dialog: one filled TextField, Cancel and Create.
    expect(find.byType(CoworkerNameDialog), findsOneWidget);
    final nameField = find.descendant(
      of: find.byType(CoworkerNameDialog),
      matching: find.byType(TextField),
    );
    expect(nameField, findsOneWidget);
    // The field is pre-filled with a suggested adjective-noun name.
    expect(tester.widget<TextField>(nameField).controller!.text, isNotEmpty);

    await tester.enterText(nameField, '  Crypto Desk ');
    await tester.tap(find.widgetWithText(ExpressiveButton, 'Create'));
    await tester.pumpAndSettle();

    expect(find.byType(CoworkerNameDialog), findsNothing);
    expect(roster.agents, hasLength(1));
    expect(roster.agents.single.name, 'Crypto Desk');
    // An app-created agent is never claimed to be installed on the host.
    expect(roster.agents.single.onHost, isFalse);
    // The host was told, so the name outlives this install.
    expect(controller.createdAgents, [
      (roster.agents.single.id, 'Crypto Desk'),
    ]);
    // Its thread is selected: the one thread view points at it, and the
    // roster lists it by name.
    final view = tester.widget<CoworkThreadView>(find.byType(CoworkThreadView));
    expect(view.threadKey, roster.agents.single.threads.single.key);
    expect(find.text('Crypto Desk'), findsWidgets);
    expect(controller.sessionKeys, isEmpty);
  });

  testWidgets('Cancel in the New agent dialog adds nothing', (tester) async {
    final (controller, roster) = await pumpShell(tester);

    await tester.tap(findIcon(Icons.person_add_alt));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ExpressiveButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(find.byType(CoworkerNameDialog), findsNothing);
    expect(roster.agents, isEmpty);
    expect(controller.createdAgents, isEmpty);
  });

  testWidgets('Rename from the row menu renames locally and on the host', (
    tester,
  ) async {
    final (controller, roster) = await pumpShell(tester);
    final agent = roster.addAgent(name: 'amber');
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(
        of: find.byKey(ValueKey<String>('agent-tile-${agent.id}')),
        matching: find.byTooltip('More'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();

    final nameField = find.descendant(
      of: find.byType(CoworkerNameDialog),
      matching: find.byType(TextField),
    );
    expect(tester.widget<TextField>(nameField).controller!.text, 'amber');
    await tester.enterText(nameField, 'Amber Desk');
    await tester.tap(find.widgetWithText(ExpressiveButton, 'Rename'));
    await tester.pumpAndSettle();

    expect(roster.byId(agent.id)!.name, 'Amber Desk');
    // The id and the thread key are untouched: a name is a label.
    expect(roster.byId(agent.id)!.threads.single.key, agent.threads.single.key);
    expect(controller.renamedAgents, [(agent.id, 'Amber Desk')]);
    expect(find.text('Amber Desk'), findsWidgets);
  });

  testWidgets('phone chat renames the selected agent locally and on the host', (
    tester,
  ) async {
    final (controller, roster) = await pumpShell(
      tester,
      size: const Size(420, 900),
    );
    controller.pair();
    await tester.pumpAndSettle();
    final agent = roster.agents.single;
    await tester.tap(find.byKey(ValueKey<String>('mobile-agent-${agent.id}')));
    await tester.pumpAndSettle();
    expect(find.byTooltip('More'), findsNothing);
    await tester.tap(findId('mobile_chat_bot_pill'));
    await tester.pumpAndSettle();
    expect(find.byType(MobileCoworkSettingsPage), findsOneWidget);
    await tester.tap(find.byTooltip('Edit coworker'));
    await tester.pumpAndSettle();
    final field = find
        .descendant(
          of: find.byType(AgentProfileEditPage),
          matching: find.byType(TextField),
        )
        .first;
    await tester.ensureVisible(field);
    await tester.enterText(field, '  Research Assistant  ');
    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await tester.pumpAndSettle();
    expect(roster.byId(agent.id)!.name, 'Research Assistant');
    expect(controller.renamedAgents, [(agent.id, 'Research Assistant')]);
    expect(roster.byId(agent.id)!.threads.single.key, agent.threads.single.key);
  });

  testWidgets('the host\'s agent_list names the host row, adds the coworkers '
      'it keeps and skips one deleted here', (tester) async {
    final (controller, roster) = await pumpShell(tester);
    controller.pair();
    await tester.pumpAndSettle();
    final hostId = roster.agents.single.id;
    // Pairing asks the host for its names once.
    expect(controller.agentListRequests, 1);
    final gone = roster.addAgent(name: 'gone-soon');
    await tester.pumpAndSettle();

    // Delete through the row menu, so the shell records the id.
    await tester.tap(
      find.descendant(
        of: find.byKey(ValueKey<String>('agent-tile-${gone.id}')),
        matching: find.byTooltip('More'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(roster.byId(gone.id), isNull);

    controller.emit(
      CoworkRelayAgentList(
        agents: [
          const CoworkHostAgentName(
            agentId: 'host:ignored',
            name: 'Laptop Bot',
            host: true,
          ),
          const CoworkHostAgentName(
            agentId: 'local:phone:2:7',
            name: 'From Phone',
          ),
          CoworkHostAgentName(agentId: gone.id, name: 'gone-soon'),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(roster.byId(hostId)!.name, 'Laptop Bot');
    expect(roster.byId('local:phone:2:7')!.name, 'From Phone');
    expect(roster.byId(gone.id), isNull);
    expect(find.text('Laptop Bot'), findsWidgets);
    expect(find.text('From Phone'), findsWidgets);
  });

  testWidgets(
    'a screen nobody confirms goes back to parked before the user taps it',
    (tester) async {
      // Bead cowork-8ptj. The host pushes `opened` / `closed` once per change,
      // so a container, an MCP server or a Chromium that goes away leaves the
      // last `true` standing. The target has to tell the truth BEFORE the tap,
      // not through the error page behind it.
      final (controller, roster) = await pumpShell(
        tester,
        size: const Size(420, 900),
      );
      controller.pair();
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(ValueKey<String>('mobile-agent-${roster.agents.single.id}')),
      );
      await tester.pumpAndSettle();
      controller.emit(
        const CoworkRelayBrowserView(status: 'opened', vncAvailable: true),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<MobileChatScreen>(find.byType(MobileChatScreen))
            .browserAvailable,
        isTrue,
      );

      await tester.pump(kBrowserPresenceFreshness + const Duration(minutes: 1));
      await tester.pumpAndSettle();
      final MobileChatScreen stale = tester.widget<MobileChatScreen>(
        find.byType(MobileChatScreen),
      );
      expect(stale.browserAvailable, isFalse);
      // Parked, not dead: the tap says what happened to the screen it offered.
      expect(stale.onOpenBrowser, isNotNull);
      stale.onOpenBrowser!();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(BrowserViewPage), findsNothing);
      expect(find.textContaining('No word about the screen'), findsOneWidget);

      // And when the host is the one that says no, the tap repeats ITS reason
      // (bead cowork-qp5i) instead of telling the user to ask for a page.
      controller.emit(
        const CoworkRelayBrowserView(status: 'opened', vncAvailable: true),
      );
      await tester.pumpAndSettle();
      controller.emit(
        const CoworkRelayBrowserView(
          status: 'error',
          message: 'could not start the VNC server',
          reason: 'vnc_start_failed',
        ),
      );
      await tester.pumpAndSettle();
      final MobileChatScreen failed = tester.widget<MobileChatScreen>(
        find.byType(MobileChatScreen),
      );
      expect(failed.browserAvailable, isFalse);
      failed.onOpenBrowser!();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.textContaining('screen server would not start'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'phone screen requires live presence and files use selected chat',
    (tester) async {
      final (controller, roster) = await pumpShell(
        tester,
        size: const Size(420, 900),
      );
      controller.pair();
      await tester.pumpAndSettle();
      final agent = roster.agents.single;
      await tester.tap(
        find.byKey(ValueKey<String>('mobile-agent-${agent.id}')),
      );
      await tester.pumpAndSettle();
      final chat = tester.widget<MobileChatScreen>(
        find.byType(MobileChatScreen),
      );
      // No screen yet: the target is parked, not dead. Tapping it says why
      // (bead cowork-egrg).
      expect(chat.browserAvailable, isFalse);
      expect(chat.onOpenBrowser, isNotNull);
      expect(findId('mobile_chat_browser'), findsOneWidget);
      expect(chat.onOpenFiles, isNotNull);
      chat.onOpenBrowser!();
      // The shell already has an "offline" snack up; ours is queued behind it.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(BrowserViewPage), findsNothing);
      expect(find.textContaining('No screen yet'), findsOneWidget);

      controller.emit(
        const CoworkRelayBrowserView(status: 'opened', vncAvailable: true),
      );
      await tester.pumpAndSettle();
      final activeChat = tester.widget<MobileChatScreen>(
        find.byType(MobileChatScreen),
      );
      // The lit target IS the announcement; nothing interrupts the reader.
      expect(activeChat.browserAvailable, isTrue);
      expect(activeChat.onOpenBrowser, isNotNull);
      expect(find.textContaining('You can take over'), findsNothing);

      controller.emit(const CoworkRelayBrowserView(status: 'closed'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<MobileChatScreen>(find.byType(MobileChatScreen))
            .browserAvailable,
        isFalse,
      );
      expect(findId('mobile_chat_browser'), findsOneWidget);
      // A callback captured before closure must not enter a dead VNC route.
      activeChat.onOpenBrowser!();
      await tester.pumpAndSettle();
      expect(find.byType(BrowserViewPage), findsNothing);
      await tester.tap(findId('mobile_chat_files'));
      await tester.pumpAndSettle();
      final explorer = tester.widget<ChatDocumentsPanel>(
        find.byType(ChatDocumentsPanel),
      );
      expect(explorer.fullPage, isTrue);
      expect(explorer.sessionKey, agent.threads.single.key);
      expect(explorer.coworkerName, agent.name);
    },
  );

  testWidgets(
    'phone profile scopes model settings and automations to its own chat',
    (tester) async {
      final (controller, roster) = await pumpShell(
        tester,
        size: const Size(420, 900),
      );
      controller.pair();
      await tester.pumpAndSettle();
      final agent = roster.agents.single;
      await tester.tap(
        find.byKey(ValueKey<String>('mobile-agent-${agent.id}')),
      );
      await tester.pumpAndSettle();
      await tester.tap(findId('mobile_chat_bot_pill'));
      await tester.pumpAndSettle();
      final profile = tester.widget<MobileCoworkSettingsPage>(
        find.byType(MobileCoworkSettingsPage),
      );
      expect(profile.chatId, agent.threads.single.key);
      profile.onAutomations();
      await tester.pumpAndSettle();
      final page = tester.widget<AutomationsPage>(find.byType(AutomationsPage));
      expect(page.sessionKey, agent.threads.single.key);
      expect(page.chatName, agent.name);
    },
  );

  testWidgets('an agent has one permanent thread and no way to open a second', (
    tester,
  ) async {
    final (controller, roster) = await pumpShell(tester);
    controller.pair();
    await tester.pumpAndSettle();

    // The "new thread" affordance is gone: one permanent session per bot.
    expect(findIcon(Icons.add_comment_outlined), findsNothing);
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

  testWidgets('a run marks the agent as working and back to waiting', (
    tester,
  ) async {
    final (controller, roster) = await pumpShell(tester);
    controller.pair();
    await tester.pumpAndSettle();

    // Run state is read off CoworkRunLedger now — the one place that knows a
    // run is in flight whether this client started it or adopted it from the
    // host's `run_state` header after a reconnect.
    final threadKey = roster.agents.single.threads.single.key;
    CoworkRunLedger.instance.begin(threadKey);
    await tester.pump();

    // Twice: the roster row's bucket label, and the header's status line under
    // the coworker's name.
    expect(find.textContaining('working'), findsNWidgets(2));

    CoworkRunLedger.instance.finish(threadKey, reason: 'finished');
    await tester.pump();

    expect(find.textContaining('working'), findsNothing);
    expect(find.textContaining('ready for a task'), findsOneWidget);
    // Idle is still reachable: the header says so where a messenger would say
    // "Active now".
    expect(find.text('Active now'), findsOneWidget);
    expect(roster.agents.single.lastActivity, isNotNull);
  });

  testWidgets(
    'the controls button opens the panel, which asks the host about this agent',
    (tester) async {
      final (controller, _) = await pumpShell(tester);
      controller.pair();
      await tester.pumpAndSettle();

      await tester.tap(findIcon(Icons.tune));
      await tester.pumpAndSettle();

      // Every block the host can fill has a heading; the schedule field and the
      // integrations list are gone, because nothing ever filled them.
      expect(find.text('MODEL'), findsOneWidget);
      expect(find.text('TOKEN USE'), findsOneWidget);
      expect(find.text('SESSION RUNTIME'), findsOneWidget);
      expect(find.text('SANDBOX'), findsOneWidget);
      expect(find.text('SKILLS'), findsOneWidget);
      expect(find.text('SCHEDULE'), findsNothing);
      expect(find.text('INTEGRATIONS'), findsNothing);
      // Nothing is paired in this test, so the panel says so instead of
      // showing a figure it does not have.
      expect(find.text('Not paired with a host.'), findsNWidgets(5));
    },
  );

  testWidgets('a 660px window keeps the desktop chat visible like master', (
    tester,
  ) async {
    final (controller, _) = await pumpShell(
      tester,
      size: const Size(660, 900),
      openSidebar: false,
    );
    controller.pair();
    await tester.pumpAndSettle();

    expect(find.text('Chuk Chat').hitTestable(), findsNothing);
    expect(threadView, findsOneWidget);
    expect(threadOffstage(tester), isFalse);
    expect(find.byType(AppBar), findsNothing);
    await tester.tap(findIcon(Icons.menu_rounded));
    await tester.pumpAndSettle();
    expect(find.text('Chuk Chat').hitTestable(), findsOneWidget);
    expect(threadOffstage(tester), isFalse);
    await tester.tap(findIcon(Icons.menu_rounded));
    await tester.pumpAndSettle();
    expect(find.text('Chuk Chat').hitTestable(), findsNothing);
    expect(threadOffstage(tester), isFalse);
  });

  testWidgets('a phone window shows the inbox, then the chat, and back again', (
    tester,
  ) async {
    // Under 600 the shell mounts the mobile layer instead: the coworker inbox,
    // and a chat screen whose chrome floats over the thread with no app bar.
    final (controller, roster) = await pumpShell(
      tester,
      size: const Size(420, 900),
    );
    controller.pair();
    await tester.pumpAndSettle();

    final agentId = roster.agents.single.id;
    expect(find.byType(MobileAgentList), findsOneWidget);
    // The inbox is a messenger home: one header row, with the All / Unread
    // switch in the middle of it and no page headline.
    expect(find.text('Agents'), findsNothing);
    expect(find.text('All'), findsOneWidget);

    await tester.tap(find.byKey(ValueKey<String>('mobile-agent-$agentId')));
    await tester.pumpAndSettle();

    // The chat is in front with its floating chrome — no app bar of its own —
    // and the back target returns to the inbox, the same flag the tablet path
    // flips. Both layers stay mounted (the chat owns the socket), so the check
    // is which one the reader can touch.
    expect(find.byType(MobileChatScreen), findsOneWidget);
    expect(find.byType(MobileChatChrome), findsOneWidget);
    expect(findId('mobile_chat_more'), findsNothing);
    final shellScaffold = tester.widget<Scaffold>(
      find
          .ancestor(
            of: find.byType(MobileChatScreen),
            matching: find.byType(Scaffold),
          )
          .first,
    );
    expect(shellScaffold.endDrawer, isNull);
    expect(shellScaffold.endDrawerEnableOpenDragGesture, isFalse);
    await tester.flingFrom(const Offset(416, 400), const Offset(-230, 0), 1200);
    await tester.pumpAndSettle();
    expect(find.byType(Drawer), findsNothing);
    // The inbox has no headline to look for any more; its search target is
    // the thing only the inbox has.
    expect(findId('mobile_home_search').hitTestable(), findsNothing);
    await tester.tap(findIcon(Icons.arrow_back_rounded).first);
    await tester.pumpAndSettle();
    expect(findId('mobile_home_search').hitTestable(), findsOneWidget);
  });

  testWidgets('the Rooms button opens the rooms screen and lists rooms', (
    tester,
  ) async {
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

    await tester.tap(find.byTooltip('Control Rooms').first);
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
    await tester.pump(
      const Duration(milliseconds: 400),
    ); // finish the transition
    expect(find.text('Message the room to start.'), findsOneWidget);
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
    await tester.tap(findIcon(Icons.send));
    await tester.pump();
    expect(controller.roomTasks, [(room.id, 'kick off')]);
  });

  testWidgets('creating a room from the shell adds it to the source', (
    tester,
  ) async {
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

    await tester.tap(find.byTooltip('Control Rooms').first);
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
    final a = rooms.addRoom(
      CoworkRoomDraft(
        name: 'A',
        members: [
          CoworkRoomMember(agentId: amberId, handle: 'amber'),
          const CoworkRoomMember(agentId: 'b', handle: 'cobalt'),
          const CoworkRoomMember(agentId: 'c', handle: 'jade'),
        ],
      ),
    );
    final b = rooms.addRoom(
      CoworkRoomDraft(
        name: 'B',
        members: [
          CoworkRoomMember(agentId: amberId, handle: 'amber'),
          const CoworkRoomMember(agentId: 'd', handle: 'onyx'),
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
          rosterSource: roster,
          roomSource: rooms,
          onSignOut: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(findIcon(Icons.menu_rounded));
    await tester.pumpAndSettle();

    // Delete amber via its roster row menu. The row is scoped by the agent's
    // own tile key: since the sidebar moved onto chuk's chrome the row is no
    // longer a ListTile, but it is still exactly one tile per agent.
    await tester.tap(
      find.descendant(
        of: find.byKey(ValueKey<String>('agent-tile-$amberId')),
        matching: findIcon(Icons.more_vert),
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

  testWidgets('removing a member from the sheet syncs removeRoomMember', (
    tester,
  ) async {
    final roster = LocalAgentRosterSource();
    final rooms = LocalRoomSource();
    // Three members, so Remove is enabled (it disables at two).
    final room = rooms.addRoom(
      const CoworkRoomDraft(
        name: 'trio',
        members: [
          CoworkRoomMember(agentId: 'a', handle: 'amber'),
          CoworkRoomMember(agentId: 'b', handle: 'cobalt'),
          CoworkRoomMember(agentId: 'c', handle: 'jade'),
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
          rosterSource: roster,
          roomSource: rooms,
          onSignOut: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Control Rooms').first);
    await tester.pumpAndSettle();
    await tester.tap(findIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Manage members'));
    await tester.pumpAndSettle();

    // Remove the first member: the room survives (3 -> 2), host told to drop it.
    await tester.tap(findIcon(Icons.remove_circle_outline).first);
    await tester.pumpAndSettle();

    expect(rooms.byId(room.id)!.members.length, 2);
    expect(controller.removedMembers, [(room.id, 'a')]);
    expect(controller.deletedRooms, isEmpty);
  });

  testWidgets(
    'a room deleted while offline is flushed to the host on connect',
    (tester) async {
      final rooms = LocalRoomSource();
      final room = rooms.addRoom(
        const CoworkRoomDraft(
          name: 'gone',
          members: [
            CoworkRoomMember(agentId: 'a', handle: 'amber'),
            CoworkRoomMember(agentId: 'b', handle: 'cobalt'),
          ],
        ),
      );
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
      await tester.tap(find.byTooltip('Control Rooms').first);
      await settle(tester);
      await tester.tap(findIcon(Icons.more_vert));
      await settle(tester);
      await tester.tap(find.text('Delete room'));
      await settle(tester);

      expect(rooms.byId(room.id), isNull);
      expect(controller.deletedRooms, isEmpty); // not sent yet — offline

      // The transport arrives: the queued delete flushes.
      gate.complete(controller);
      await tester.pumpAndSettle();
      expect(controller.deletedRooms, [room.id]);
    },
  );

  testWidgets('the top-right "Copy Debug Chat" button exports the thread', (
    tester,
  ) async {
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
            return 'debug chat copied';
          },
        ),
      ),
    );
    await tester.pump();

    expect(find.byTooltip('Copy Debug Chat'), findsOneWidget);
    await tester.tap(find.byTooltip('Copy Debug Chat'));
    await tester.pumpAndSettle();

    // Nothing is selected: no pairing, no stored roster, no remembered pick,
    // so this shell has no conversation. The export names no thread rather
    // than a made-up one — a placeholder key would mint a replay cursor and a
    // cache row for a conversation that does not exist (bead cowork-91pn).
    expect(exported, ['']);
    expect(find.text('debug chat copied'), findsOneWidget);
  });

  testWidgets('Copy Debug Chat uses the real clipboard export by default', (
    tester,
  ) async {
    String? clipboardText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboardText = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });
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
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('Copy Debug Chat'));
    await tester.pumpAndSettle();

    expect(clipboardText, isNotNull);
    final payload = jsonDecode(clipboardText!) as Map<String, dynamic>;
    expect(payload['kind'], 'cowork_full_chat_debug');
    // No coworker, so no thread — see the note on the test above.
    expect(payload['thread_key'], '');
    expect(find.text('debug chat copied'), findsOneWidget);
    expect(find.text('could not copy the chat'), findsNothing);
  });

  testWidgets('a failed "Copy Debug Chat" says so instead of staying silent', (
    tester,
  ) async {
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

    await tester.tap(find.byTooltip('Copy Debug Chat'));
    await tester.pumpAndSettle();

    expect(find.text('could not copy the chat'), findsOneWidget);
  });

  // --- where the app opens (bead cowork-8yb) ---------------------------------

  /// Pumps a shell over a roster the test built, so the remembered ids are
  /// known before the first frame.
  Future<_FakeRelayController> pumpShellOver(
    WidgetTester tester,
    LocalAgentRosterSource roster,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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
          roomSource: LocalRoomSource(),
          onSignOut: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  testWidgets('the app opens on the thread the last session left off in', (
    tester,
  ) async {
    final roster = LocalAgentRosterSource()
      ..addAgent(name: 'amber')
      ..addAgent(name: 'cobalt');
    final remembered = roster.agents.last;
    SharedPreferences.setMockInitialValues(<String, Object>{
      'cowork.last_agent_id': remembered.id,
      'cowork.last_thread_key': remembered.threads.single.key,
    });

    await pumpShellOver(tester, roster);

    expect(
      tester.widget<CoworkThreadView>(threadView).threadKey,
      remembered.threads.single.key,
    );
  });

  testWidgets('with nothing remembered the app opens the top coworker', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final roster = LocalAgentRosterSource()
      ..addAgent(name: 'amber')
      ..addAgent(name: 'cobalt');

    await pumpShellOver(tester, roster);

    // Never the empty 'default' thread: the reader lands in a real
    // conversation, the way every other messenger opens.
    expect(
      tester.widget<CoworkThreadView>(threadView).threadKey,
      roster.visibleAgents.first.threads.single.key,
    );
  });

  testWidgets('a remembered coworker that the host lists late is opened', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'cowork.last_agent_id': 'remote:jade',
      'cowork.last_thread_key': 'remote:jade',
    });
    // On the first frame the roster does not have it yet — the host sends its
    // names only after the pairing.
    final roster = LocalAgentRosterSource()..addAgent(name: 'amber');
    await pumpShellOver(tester, roster);
    final String fallback = roster.visibleAgents.first.threads.single.key;
    expect(tester.widget<CoworkThreadView>(threadView).threadKey, fallback);

    roster.applyHostNames(const <CoworkHostAgentName>[
      CoworkHostAgentName(agentId: 'remote:jade', name: 'jade'),
    ], peerDeviceId: null);
    await tester.pumpAndSettle();

    expect(
      tester.widget<CoworkThreadView>(threadView).threadKey,
      'remote:jade',
    );
  });

  testWidgets('a coworker the user picked survives the late host list', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'cowork.last_agent_id': 'remote:jade',
      'cowork.last_thread_key': 'remote:jade',
    });
    final roster = LocalAgentRosterSource()
      ..addAgent(name: 'amber')
      ..addAgent(name: 'cobalt');
    await pumpShellOver(tester, roster);
    await tester.tap(findIcon(Icons.menu_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('cobalt'));
    await tester.pumpAndSettle();
    final picked = roster.agents.last.threads.single.key;
    expect(tester.widget<CoworkThreadView>(threadView).threadKey, picked);

    roster.applyHostNames(const <CoworkHostAgentName>[
      CoworkHostAgentName(agentId: 'remote:jade', name: 'jade'),
    ], peerDeviceId: null);
    await tester.pumpAndSettle();

    // The user's own pick is never moved out from under them.
    expect(tester.widget<CoworkThreadView>(threadView).threadKey, picked);
  });

  testWidgets('nothing in the chat layer takes the focus while it is behind '
      'the inbox', (tester) async {
    // The shell keeps the thread mounted behind the coworker list, because it
    // owns the socket. If the composer takes the focus there, the soft
    // keyboard opens over the list at start-up — the bug this pins.
    final (controller, _) = await pumpShell(tester, size: const Size(420, 900));
    controller.pair();
    await tester.pumpAndSettle();

    expect(find.byType(MobileAgentList), findsOneWidget);
    expect(find.byType(MobileChatScreen, skipOffstage: false), findsOneWidget);

    final BuildContext? focused = FocusManager.instance.primaryFocus?.context;
    expect(
      focused?.findAncestorWidgetOfExactType<MobileChatScreen>(),
      isNull,
      reason: 'the offstage chat layer must not hold the focus',
    );
    expect(
      tester.testTextInput.isVisible,
      isFalse,
      reason: 'no keyboard while the coworker list is what is on screen',
    );
  });

  testWidgets('the composer rides the keyboard: a bottom view inset lifts the '
      'chat layer instead of hiding it', (tester) async {
    final (controller, roster) = await pumpShell(
      tester,
      size: const Size(420, 900),
    );
    controller.pair();
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(ValueKey<String>('mobile-agent-${roster.agents.single.id}')),
    );
    await tester.pumpAndSettle();

    final Finder chat = find.byType(MobileChatScreen);
    expect(tester.getRect(chat).bottom, 900);
    final double composerBefore = tester
        .getRect(findId('message_input'))
        .bottom;
    expect(composerBefore, lessThanOrEqualTo(900));

    // The keyboard: the platform reports it as a bottom view inset, and the
    // shell's Scaffold turns that into a shorter body. The chat layer has to
    // be laid out in THAT height — laid out at the full screen height it keeps
    // its composer under the keyboard, which is what the phone showed.
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();

    expect(
      tester.getRect(chat).bottom,
      moreOrLessEquals(600, epsilon: 1),
      reason: 'the chat layer stops above the keyboard',
    );
    expect(
      tester.getRect(findId('message_input')).bottom,
      lessThanOrEqualTo(601),
      reason: 'the composer travels up with it',
    );

    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    expect(tester.getRect(chat).bottom, 900);
    expect(
      tester.getRect(findId('message_input')).bottom,
      moreOrLessEquals(composerBefore, epsilon: 1),
    );
  });
}
