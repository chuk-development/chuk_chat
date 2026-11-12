// The Chats | Agents switch: one app, two halves (bead chuk_chat-18v; Home
// was a half of its own from 2026-11-02 to 2026-11-05, and is now the first
// page of Agents).
//
// The shell tests stand light widgets in for chuk_chat's root wrapper
// (`MessengerShell.chatModeBuilder`) and for the dashboard
// (`MessengerShell.homeBuilder`). The last groups pump chuk_chat's real root
// wrappers to pin their header slot, which the plain build keeps.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/pages/agents_install_page.dart';
import 'package:chuk_chat/pages/messenger_shell.dart';
import 'package:chuk_chat/platform_specific/mobile/mobile_agent_list.dart';
import 'package:chuk_chat/platform_specific/mobile/chat_title_strip.dart';
import 'package:chuk_chat/platform_specific/mobile/mobile_top_bar.dart';
import 'package:chuk_chat/platform_specific/mobile/swipe_chat_pager.dart';
import 'package:chuk_chat/platform_specific/root_wrapper_desktop.dart';
import 'package:chuk_chat/platform_specific/root_wrapper_mobile.dart';
import 'package:chuk_chat/services/account_session.dart';
import 'package:chuk_chat/services/agents/agent_roster_source.dart';
import 'package:chuk_chat/services/agents/agents_cloud_relay.dart';
import 'package:chuk_chat/services/agents/agents_device_keys.dart';
import 'package:chuk_chat/services/agents/agents_install_flow.dart';
import 'package:chuk_chat/services/agents/agents_pairing_restore.dart';
import 'package:chuk_chat/services/agents/agents_pairing_store.dart';
import 'package:chuk_chat/services/agents/agents_pairing_uri.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/agents/agents_thread_composer.dart';
import 'package:chuk_chat/services/agents/main_agent_launcher.dart';
import 'package:chuk_chat/services/agents/roster_pins.dart';
import 'package:chuk_chat/services/agents/agents_run_ledger.dart';
import 'package:chuk_chat/services/agents/room_source.dart';
import 'package:chuk_chat/services/agents/supabase_pairing_sync.dart';
import 'package:chuk_chat/services/app_mode_service.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/notifications/notification_router.dart';
import 'package:chuk_chat/services/share/share_intent_service.dart';
import 'package:chuk_chat/widgets/agent_roster_view.dart';
import 'package:chuk_chat/widgets/agents_status_panel.dart';
import 'package:chuk_chat/widgets/agents_thread_header.dart';
import 'package:chuk_chat/widgets/agents_thread_view.dart';
import 'package:chuk_chat/widgets/app_mode_switch.dart';
import 'package:chuk_chat/widgets/brand_wordmark.dart';
import 'package:chuk_chat/widgets/sidebar/sidebar_chrome.dart' show SbChatTile;
import 'package:chuk_chat/widgets/sidebar/sidebar_common.dart'
    show kSidebarAddComputerKey, kSidebarAddComputerLabel;

import '../platform_specific/mobile/mobile_support.dart' show findId;
import '../support/icon_finder.dart';
import '../support/fake_relay_controller.dart';
import '../support/shell_config.dart';
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

/// The encrypted mirror, with nothing in it.
class _EmptyMirror extends SupabasePairingSync {
  @override
  Future<AgentsCloudPairingRead> readEncryptedPairing() async =>
      const AgentsCloudPairingRead(AgentsCloudPairingOutcome.noRecord);

  @override
  Future<bool> publishEncryptedPairing(AgentsStoredPairing pairing) async =>
      true;

  @override
  Future<void> saveEncryptedPairing(AgentsStoredPairing pairing) async {}

  @override
  Future<void> clearEncryptedPairing() async {}
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

/// Stands in for chuk_chat's root wrapper: the switch in its top bar, a
/// counter and a draft, so a test can see that its state survives a switch.
class _FakeChatHalf extends StatefulWidget {
  const _FakeChatHalf({
    required this.phone,
    required this.modeSwitch,
    this.onAddComputer,
  });

  final bool phone;
  final Widget? modeSwitch;

  /// The install entry's action; null unless the device has no computer.
  final VoidCallback? onAddComputer;

  @override
  State<_FakeChatHalf> createState() => _FakeChatHalfState();
}

class _FakeChatHalfState extends State<_FakeChatHalf> {
  int taps = 0;
  final TextEditingController draft = TextEditingController();

  @override
  void dispose() {
    draft.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: <Widget>[
            SizedBox(
              height: 48,
              child: Center(
                child: widget.modeSwitch ?? const SizedBox.shrink(),
              ),
            ),
            Text(widget.phone ? 'chuk phone chat' : 'chuk desktop chat'),
            Text('taps $taps'),
            if (widget.onAddComputer != null)
              TextButton(
                key: const ValueKey<String>('fake-add-computer'),
                onPressed: widget.onAddComputer,
                child: const Text('Add your computer'),
              ),
            TextButton(
              onPressed: () => setState(() => taps++),
              child: const Text('tap'),
            ),
            SizedBox(
              width: 200,
              child: TextField(
                key: const ValueKey<String>('fake-chuk-draft'),
                controller: draft,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Stands in for the dashboard: a counter, so a test can see that Home keeps
/// its state across a switch.
class _FakeHome extends StatefulWidget {
  const _FakeHome();

  @override
  State<_FakeHome> createState() => _FakeHomeState();
}

class _FakeHomeState extends State<_FakeHome> {
  int taps = 0;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Text('home stand-in'),
          Text('home taps $taps'),
          TextButton(
            onPressed: () => setState(() => taps++),
            child: const Text('home tap'),
          ),
        ],
      ),
    );
  }
}

const Size kPhone = Size(360, 800);

/// Where chuk's phone wrapper puts a header slot on a 360 px phone with a
/// 24 px status bar: right of its first chip.
const Rect kSwitchOnPhone = Rect.fromLTWH(
  10 + 42 + 8,
  24 + 8,
  AppModeSwitch.width,
  AppModeSwitch.boxHeight,
);

/// A phone wide enough for the "Add your computer" panel an unpaired device
/// shows in Agents (the test font runs wider than the real one).
const Size kWidePhone = Size(412, 800);
const EdgeInsets kPhoneInsets = EdgeInsets.only(top: 24);

void main() {
  late AgentsStoredPairing record;

  setUpAll(() async {
    final hostKey = await AgentsDeviceKeys.generate();
    record = AgentsStoredPairing(
      hostUrl: Uri.parse('wss://api.chuk.chat/v2/relay/ws?cw_device=host-1'),
      channelId: 'chan-1',
      channelKey: Uint8List.fromList(List<int>.generate(32, (i) => i)),
      peerDeviceId: 'host-1',
      peerPublicKey: await hostKey.extractPublicKey(),
    );
  });

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    AgentsRelayLink.instance.reset();
    AgentsRunLedger.instance.reset();
    RosterPins.instance.reset();
    MainAgentLauncher.instance.reset();
    AgentsThreadComposer.reset();
    ChatStorageService.selectedChatId = null;
  });
  tearDown(() {
    AgentsRelayLink.instance.reset();
    AgentsRunLedger.instance.reset();
    NotificationRouter.instance.reset();
    RosterPins.instance.reset();
    MainAgentLauncher.instance.reset();
    AgentsThreadComposer.reset();
    ChatStorageService.selectedChatId = null;
  });

  /// How often the shell asked for a transport: the thread view builds one
  /// per mount, so this counts mounts of the socket owner.
  int controllerBuilds = 0;
  setUp(() => controllerBuilds = 0);

  /// The pairing store and the transport of the last [pumpShell].
  late AgentsPairingStore lastStore;
  FakeRelayController? lastController;

  /// Pumps the shell. [paired] seeds a stored pairing (the default half with
  /// nothing remembered); [mode] injects the mode state; [withChat] adds the
  /// Chats half.
  Future<LocalAgentRosterSource> pumpShell(
    WidgetTester tester, {
    Size size = kPhone,
    bool paired = true,
    bool withChat = true,
    AppModeService? mode,
    AgentsStoredPairing? trustOnConnect,
    AgentsInstallClaimWaiter? installClaimWaiter,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.view.padding = FakeViewPadding(top: kPhoneInsets.top);
    tester.view.viewPadding = FakeViewPadding(top: kPhoneInsets.top);
    addTearDown(tester.view.reset);

    final AgentsPairingStore store = AgentsPairingStore(
      backend: _MemoryStore(),
      cloudSync: _EmptyMirror(),
    );
    if (paired) await store.savePairing(record);
    lastStore = store;
    final LocalAgentRosterSource roster = LocalAgentRosterSource();
    await tester.pumpWidget(
      testApp(
        MessengerShell(
          relayControllerBuilder: () async {
            controllerBuilds++;
            return lastController = FakeRelayController()
              ..trustOnConnect = trustOnConnect;
          },
          installClaimWaiter: installClaimWaiter,
          sessionSource: const _Session(),
          pairingStore: store,
          rosterSource: roster,
          roomSource: LocalRoomSource(),
          onSignOut: () {},
          appMode: mode,
          pairingRestoreBuilder: (store, session, onRestored) =>
              AgentsPairingRestore(
                store: store,
                sessionSource: session,
                onRestored: onRestored,
                authChanges: const Stream<Never>.empty(),
                hasEncryptionKey: () => true,
                sleep: (_) => Completer<void>().future,
              ),
          chatModeBuilder: withChat
              ? (
                  context, {
                  required phone,
                  required modeSwitch,
                  required onAddComputer,
                }) => _FakeChatHalf(
                  phone: phone,
                  modeSwitch: modeSwitch,
                  onAddComputer: onAddComputer,
                )
              : null,
          homeBuilder: (_) => const _FakeHome(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return roster;
  }

  /// The switch on screen. Both halves hold one; only the half in front is
  /// on stage.
  Finder onStageSwitch() => find.byType(AppModeSwitch);

  Future<void> pick(WidgetTester tester, String label) async {
    await tester.tap(
      find.descendant(of: onStageSwitch(), matching: find.text(label)),
    );
    await tester.pumpAndSettle();
  }

  AppMode shownMode(WidgetTester tester) =>
      tester.widget<AppModeSwitch>(onStageSwitch()).mode;

  final Finder threadView = find.byType(AgentsThreadView, skipOffstage: false);
  final Finder home = find.text('home stand-in');
  final Finder rosterHome = find.byKey(const ValueKey<String>('roster-home'));

  /// The conversation on stage: the thread view, not hidden behind Home or
  /// the other half.
  final Finder conversation = find.byType(AgentsThreadView);

  /// On a phone: picks the switch's Home segment. Home is no swipe page.
  Future<void> pickHome(WidgetTester tester) => pick(tester, 'Home');

  group('AppModeSwitch', () {
    testWidgets('Chats on the left, Agents on the right; a press picks', (
      tester,
    ) async {
      final List<AppMode> picked = <AppMode>[];
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: Center(
              child: AppModeSwitch(mode: AppMode.agents, onChanged: picked.add),
            ),
          ),
        ),
      );
      // The localisation delegates load asynchronously; the first frame is
      // empty.
      await tester.pump();
      final Rect chats = tester.getRect(find.text('Chats'));
      final Rect agents = tester.getRect(find.text('Sidekicks'));
      expect(chats.center.dx, lessThan(agents.center.dx));
      // The strip is the chips' 42, in a 48 px box a finger can hit.
      expect(tester.getSize(find.byType(AppModeSwitch)).height, 48);

      await tester.tap(find.text('Sidekicks'));
      await tester.pump();
      expect(picked, isEmpty, reason: 'the half in front is not picked again');
      await tester.tap(find.text('Chats'));
      await tester.pump();
      expect(picked, <AppMode>[AppMode.chats]);
    });

    testWidgets('German labels: Chats | Agenten', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('de'),
          localizationsDelegates: kTestLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Center(
              child: AppModeSwitch(mode: AppMode.agents, onChanged: (_) {}),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Chats'), findsOneWidget);
      expect(find.text('Agenten'), findsOneWidget);
    });
  });

  group('phone', () {
    testWidgets('a paired device opens on Agents: the conversation, the '
        'switch Home | Chats | Agents fixed at the top centre', (tester) async {
      await pumpShell(tester);
      expect(shownMode(tester), AppMode.agents);
      expect(conversation, findsOneWidget);
      expect(home, findsNothing, reason: 'Home is a segment, not in front');
      final AppModeSwitch modeSwitch = tester.widget(onStageSwitch());
      expect(modeSwitch.onHome, isNotNull);
      expect(modeSwitch.home, isFalse);
      final Rect homeLabel = tester.getRect(
        find.descendant(of: onStageSwitch(), matching: find.text('Home')),
      );
      final Rect chatsLabel = tester.getRect(
        find.descendant(of: onStageSwitch(), matching: find.text('Chats')),
      );
      final Rect agentsLabel = tester.getRect(
        find.descendant(of: onStageSwitch(), matching: find.text('Sidekicks')),
      );
      expect(homeLabel.center.dx, lessThan(chatsLabel.center.dx));
      expect(chatsLabel.center.dx, lessThan(agentsLabel.center.dx));
      final Rect bar = tester.getRect(onStageSwitch());
      expect(bar.center.dx, closeTo(kPhone.width / 2, 0.5));
      expect(bar.top, kPhoneInsets.top + 8);
      expect(bar.height, AppModeSwitch.boxHeight);
      expect(find.byType(MobileAgentList, skipOffstage: false), findsNothing);
      expect(find.text('chuk phone chat'), findsNothing);
      expect(threadView, findsOneWidget);
    });

    testWidgets('Home is the switch\'s first segment: it shows Home in the '
        'Agents half, with no strip and a still pager; Agents leaves it', (
      tester,
    ) async {
      await pumpShell(tester);
      // The swipe never reaches Home: the agent is the only page.
      await tester.fling(
        find.byType(SwipeChatPager),
        const Offset(300, 0),
        1000,
      );
      await tester.pumpAndSettle();
      expect(home, findsNothing);
      expect(conversation, findsOneWidget);
      expect(
        tester
            .widget<ChatTitleStrip>(find.byType(ChatTitleStrip))
            .entries
            .map((SwipeChatEntry e) => e.id),
        isNot(contains(AgentsHalfPage.homeId)),
      );

      await pickHome(tester);
      expect(home, findsOneWidget);
      expect(conversation, findsNothing);
      expect(shownMode(tester), AppMode.agents);
      expect(tester.widget<AppModeSwitch>(onStageSwitch()).home, isTrue);
      expect(onStageSwitch(), findsOneWidget);
      expect(
        tester.widget<MobileTopBar>(find.byType(MobileTopBar)).strip,
        isNull,
      );
      expect(find.byType(ChatTitleStrip), findsNothing);
      expect(
        tester.widget<SwipeChatPager>(find.byType(SwipeChatPager)).enabled,
        isFalse,
      );
      // A swipe on Home goes nowhere.
      await tester.fling(home, const Offset(-300, 0), 1000);
      await tester.pumpAndSettle();
      expect(home, findsOneWidget);

      await pick(tester, 'Sidekicks');
      expect(home, findsNothing);
      expect(conversation, findsOneWidget);
      expect(shownMode(tester), AppMode.agents);
      expect(tester.widget<AppModeSwitch>(onStageSwitch()).home, isFalse);
      expect(find.byType(ChatTitleStrip), findsOneWidget);
      expect(
        tester.widget<SwipeChatPager>(find.byType(SwipeChatPager)).enabled,
        isTrue,
      );
    });

    testWidgets('Home from Chats brings the Agents half with Home in front', (
      tester,
    ) async {
      await pumpShell(tester);
      await pick(tester, 'Chats');
      expect(find.text('chuk phone chat'), findsOneWidget);
      expect(tester.widget<AppModeSwitch>(onStageSwitch()).home, isFalse);

      await pickHome(tester);
      expect(shownMode(tester), AppMode.agents);
      expect(find.text('chuk phone chat'), findsNothing);
      expect(home, findsOneWidget);
      expect(tester.widget<AppModeSwitch>(onStageSwitch()).home, isTrue);
    });

    testWidgets('Chats: chuk\'s chat in front; the choice is remembered', (
      tester,
    ) async {
      await pumpShell(tester);
      await pick(tester, 'Chats');
      expect(find.text('chuk phone chat'), findsOneWidget);
      expect(conversation, findsNothing, reason: 'behind');
      expect(shownMode(tester), AppMode.chats);
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(AppModeService.prefsKey), 'chats');

      await pick(tester, 'Sidekicks');
      expect(find.text('chuk phone chat'), findsNothing);
      expect(conversation, findsOneWidget);
      expect(prefs.getString(AppModeService.prefsKey), 'agents');
    });

    for (final Size size in <Size>[kPhone, const Size(1200, 800)]) {
      testWidgets('${size.width.toInt()} px: a tap on the switch shows the '
          'other half on the very next frame, with no transition', (
        tester,
      ) async {
        await pumpShell(tester, size: size);
        final bool phone = size == kPhone;
        final Finder chuk = find.text(
          phone ? 'chuk phone chat' : 'chuk desktop chat',
        );
        final Rect screen = Offset.zero & size;

        /// Every ancestor of [target] that could paint a transition.
        void expectNoTransitionAbove(Finder target) {
          for (final Opacity o in tester.widgetList<Opacity>(
            find.ancestor(of: target, matching: find.byType(Opacity)),
          )) {
            expect(o.opacity, 1, reason: 'a fade on the half');
          }
          for (final Transform t in tester.widgetList<Transform>(
            find.ancestor(of: target, matching: find.byType(Transform)),
          )) {
            expect(t.transform.isIdentity(), isTrue, reason: 'a move/scale');
          }
        }

        await tester.tap(
          find.descendant(of: onStageSwitch(), matching: find.text('Chats')),
        );
        await tester.pump();
        // One frame: Chats is on stage, whole, and Agents is gone.
        expect(chuk, findsOneWidget);
        expect(conversation, findsNothing);
        expectNoTransitionAbove(chuk);
        expect(shownMode(tester), AppMode.chats);
        final Rect switchAt = tester.getRect(onStageSwitch());
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.getRect(onStageSwitch()), switchAt);
        expect(screen.contains(tester.getCenter(chuk)), isTrue);
        await tester.pumpAndSettle();

        await tester.tap(
          find.descendant(
            of: onStageSwitch(),
            matching: find.text('Sidekicks'),
          ),
        );
        await tester.pump();
        expect(conversation, findsOneWidget);
        expect(chuk, findsNothing);
        expectNoTransitionAbove(conversation);
        expect(shownMode(tester), AppMode.agents);
        expect(threadView, findsOneWidget);
        expect(controllerBuilds, 1);
      }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
    }

    testWidgets('both halves and Home keep their state; one socket owner', (
      tester,
    ) async {
      await pumpShell(tester);
      expect(controllerBuilds, 1);
      await pickHome(tester);
      await tester.tap(find.text('home tap'));
      await tester.pump();

      await pick(tester, 'Chats');
      await tester.tap(find.text('tap'));
      await tester.enterText(
        find.byKey(const ValueKey<String>('fake-chuk-draft')),
        'half a thought',
      );
      await tester.pump();
      expect(find.text('taps 1'), findsOneWidget);

      // Home kept its state behind the switch.
      await pickHome(tester);
      expect(find.text('home taps 1'), findsOneWidget);
      await pick(tester, 'Sidekicks');
      expect(conversation, findsOneWidget);

      await pick(tester, 'Chats');
      expect(find.text('taps 1'), findsOneWidget);
      expect(find.text('half a thought'), findsOneWidget);
      expect(threadView, findsOneWidget);
      expect(controllerBuilds, 1);
    });

    testWidgets('a remembered "chat" (older builds) opens Chats', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        AppModeService.prefsKey: 'chat',
      });
      await pumpShell(tester);
      expect(find.text('chuk phone chat'), findsOneWidget);
      expect(shownMode(tester), AppMode.chats);
    });

    testWidgets('a remembered "home" (the dashboard half) opens Agents', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        AppModeService.prefsKey: 'home',
      });
      await pumpShell(tester);
      expect(conversation, findsOneWidget);
      expect(shownMode(tester), AppMode.agents);
    });

    // Without a Chats half there is no switch, so no Home segment, and Home
    // is no swipe page any more. _buildPhoneBody's PopScope is the way left:
    // Android back on an agent shows Home.
    testWidgets('without a Chats half there is no switch; Android back is '
        'the way to Home', (tester) async {
      await pumpShell(tester, withChat: false);
      expect(find.byType(AppModeSwitch), findsNothing);
      expect(conversation, findsOneWidget);
      await tester.fling(
        find.byType(SwipeChatPager),
        const Offset(300, 0),
        1000,
      );
      await tester.pumpAndSettle();
      expect(home, findsNothing, reason: 'Home is not a swipe away');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(home, findsOneWidget);
      expect(find.byType(ChatTitleStrip), findsNothing);
    });

    testWidgets('a 360 px phone at 1.3 text fits the header without overflow', (
      tester,
    ) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpShell(tester);
      expect(tester.takeException(), isNull);
      final Rect bar = tester.getRect(onStageSwitch());
      expect(bar.left, greaterThanOrEqualTo(0));
      expect(bar.right, lessThanOrEqualTo(kPhone.width));
      await pick(tester, 'Chats');
      expect(tester.takeException(), isNull);
    });
  });

  group('no computer', () {
    final Finder statusAddComputer = find.byKey(
      AgentsStatusPanel.addComputerKey,
    );
    final Finder chatAddComputer = find.byKey(
      const ValueKey<String>('fake-add-computer'),
    );

    testWidgets('no pairing: Chats in front with the install entry; the '
        'switch reaches Agents and its "Add your computer"', (tester) async {
      await pumpShell(tester, paired: false, size: kWidePhone);
      expect(find.text('chuk phone chat'), findsOneWidget);
      expect(shownMode(tester), AppMode.chats);
      expect(chatAddComputer, findsOneWidget);
      // The Agents half is mounted behind it: it owns the socket.
      expect(threadView, findsOneWidget);

      await pick(tester, 'Sidekicks');
      expect(find.byType(AgentsStatusPanel), findsOneWidget);
      expect(statusAddComputer, findsOneWidget);
    });

    testWidgets('a pairing: no install entry in chuk\'s chats', (tester) async {
      await pumpShell(tester);
      await pick(tester, 'Chats');
      expect(chatAddComputer, findsNothing);
    });

    testWidgets('"Add your computer" in Agents opens the install page, which '
        'pairs on the live thread view', (tester) async {
      final List<AgentsPairingInvite> claimed = <AgentsPairingInvite>[];
      await pumpShell(
        tester,
        paired: false,
        size: kWidePhone,
        trustOnConnect: record,
        installClaimWaiter:
            (
              AgentsPairingInvite invite, {
              required DateTime deadline,
              required AgentsClaimCancel cancel,
            }) async {
              claimed.add(invite);
              return 'host-1';
            },
      );
      expect(controllerBuilds, 1);
      await pick(tester, 'Sidekicks');
      await tester.tap(statusAddComputer);
      await tester.pumpAndSettle();

      expect(claimed, hasLength(1));
      expect(find.byType(AgentsInstallPage), findsNothing);
      expect(await lastStore.loadPairing(), isNotNull);
      expect(controllerBuilds, 1);
      expect(shownMode(tester), AppMode.agents);
    });

    testWidgets('the install entry in chuk\'s chats pairs and brings Agents '
        'to the front', (tester) async {
      await pumpShell(
        tester,
        paired: false,
        size: kWidePhone,
        trustOnConnect: record,
        installClaimWaiter: (
          AgentsPairingInvite invite, {
          required DateTime deadline,
          required AgentsClaimCancel cancel,
        }) async => 'host-1',
      );
      await tester.tap(chatAddComputer);
      await tester.pumpAndSettle();
      expect(await lastStore.loadPairing(), isNotNull);
      expect(shownMode(tester), AppMode.agents);
      expect(chatAddComputer, findsNothing);
    });
  });

  group('desktop', () {
    /// The rect of the switch's painted strip, not its 48 px box.
    Rect strip(WidgetTester tester) {
      final Rect box = tester.getRect(onStageSwitch());
      final double inset = (AppModeSwitch.boxHeight - AppModeSwitch.height) / 2;
      return Rect.fromLTRB(
        box.left,
        box.top + inset,
        box.right,
        box.bottom - inset,
      );
    }

    final Finder agentTile = find.byWidgetPredicate(
      (Widget w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('agent-tile-'),
    );

    for (final Size size in <Size>[
      const Size(1200, 800),
      const Size(800, 700),
      const Size(640, 700),
    ]) {
      testWidgets('${size.width.toInt()} px: the switch floats top centre and '
          'clears the thread\'s buttons', (tester) async {
        await pumpShell(tester, size: size);
        expect(shownMode(tester), AppMode.agents);
        // Two segments on the desktop: Chats | Agents, no Home.
        expect(tester.widget<AppModeSwitch>(onStageSwitch()).onHome, isNull);
        expect(
          find.descendant(of: onStageSwitch(), matching: find.text('Home')),
          findsNothing,
        );

        final Rect sw = strip(tester);
        expect(sw.center.dy, closeTo(16 + 20, 1));
        expect(
          sw.center.dy,
          AgentsThreadHeader.rowTop + AgentsThreadHeader.chipBox / 2,
        );
        final Finder buttons = find.descendant(
          of: find.byType(AgentsThreadHeader),
          matching: find.byType(Tooltip),
        );
        expect(buttons, findsWidgets);
        for (final Element e in buttons.evaluate()) {
          final Rect r = tester.getRect(find.byWidget(e.widget));
          expect(r.overlaps(sw), isFalse, reason: 'overlaps $r');
        }
        final Rect roster = tester.getRect(find.byType(AgentRosterView));
        expect(sw.left, greaterThanOrEqualTo(roster.right));
        expect(sw.right, lessThanOrEqualTo(size.width));
      }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
    }

    testWidgets('the roster\'s "Home" row sits above the main agent; Home '
        'takes the centre pane and a pick leaves it', (tester) async {
      await pumpShell(tester, size: const Size(1200, 800));
      expect(home, findsNothing);
      expect(rosterHome, findsOneWidget);
      expect(agentTile, findsWidgets);
      expect(
        tester.getRect(rosterHome).top,
        lessThan(tester.getRect(agentTile.first).top),
      );

      await tester.tap(rosterHome);
      await tester.pumpAndSettle();
      expect(home, findsOneWidget);
      expect(shownMode(tester), AppMode.agents);
      final Rect roster = tester.getRect(find.byType(AgentRosterView));
      final Rect homeRect = tester.getRect(
        find.byKey(const ValueKey<String>('desk-home')),
      );
      expect(homeRect.left, greaterThanOrEqualTo(roster.right));
      expect(find.byType(AgentsThreadView), findsNothing, reason: 'off stage');
      expect(threadView, findsOneWidget);
      // Home sits under the switch's row.
      expect(
        tester.getRect(home).top,
        greaterThan(tester.getRect(onStageSwitch()).bottom),
      );
      final SbChatTile homeRow = tester.widget<SbChatTile>(rosterHome);
      expect(homeRow.selected, isTrue);

      await tester.tap(agentTile.first);
      await tester.pumpAndSettle();
      expect(home, findsNothing);
      expect(find.byType(AgentsThreadView), findsOneWidget);
      expect(tester.widget<SbChatTile>(rosterHome).selected, isFalse);
      expect(controllerBuilds, 1);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('Chats: chuk\'s desktop in front; the thread stays mounted', (
      tester,
    ) async {
      await pumpShell(tester, size: const Size(1200, 800));
      await pick(tester, 'Chats');
      expect(find.text('chuk desktop chat'), findsOneWidget);
      expect(find.byType(AgentRosterView), findsNothing, reason: 'behind');
      expect(threadView, findsOneWidget);
      expect(controllerBuilds, 1);

      await pick(tester, 'Sidekicks');
      expect(find.text('chuk desktop chat'), findsNothing);
      expect(find.byType(AgentsThreadView), findsOneWidget);
      expect(controllerBuilds, 1);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('the details pane on a narrow window gives the switch a line '
        'of its own', (tester) async {
      await pumpShell(tester, size: const Size(800, 700));
      await tester.tap(find.byTooltip('More actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Details (Ctrl+.)'));
      await tester.pumpAndSettle();

      final Rect sw = strip(tester);
      final Rect header = tester.getRect(find.byType(AgentsThreadHeader));
      expect(header.top, greaterThanOrEqualTo(sw.bottom));
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
  });

  group('the shared chat pointer', () {
    testWidgets('belongs to the half in front', (tester) async {
      final LocalAgentRosterSource roster = await pumpShell(tester);
      final String threadKey = roster.addAgent(name: 'Amber').threads.first.key;
      await tester.pumpAndSettle();

      await pick(tester, 'Chats');
      // chuk's chat opens a chat of its own.
      ChatStorageService.selectedChatId =
          '11111111-2222-3333-4444-555555555555';
      await tester.pump();
      // The Agents thread, behind it, reconnects and points it at itself.
      ChatStorageService.selectedChatId = threadKey;
      await tester.pump();
      expect(
        ChatStorageService.selectedChatId,
        '11111111-2222-3333-4444-555555555555',
        reason: 'the half in front keeps its chat',
      );

      await pick(tester, 'Sidekicks');
      final String? agentsPointer = ChatStorageService.selectedChatId;
      expect(agentsPointer, isNot('11111111-2222-3333-4444-555555555555'));

      await pick(tester, 'Chats');
      expect(
        ChatStorageService.selectedChatId,
        '11111111-2222-3333-4444-555555555555',
        reason: 'chuk\'s chat comes back with its half',
      );
    });
  });

  group('share sheet', () {
    tearDown(ShareIntentService.instance.resetForTest);

    testWidgets('a share picked on an agent opens its thread with the text '
        'in the composer, not sent', (tester) async {
      final AppModeService mode = AppModeService(initial: AppMode.chats)
        ..show(AppMode.chats);
      addTearDown(mode.dispose);
      final LocalAgentRosterSource roster = await pumpShell(tester, mode: mode);
      final AgentsAgent other = roster.addAgent(name: 'Cobalt');
      await tester.pumpAndSettle();

      ShareIntentService.instance.incoming.value = SharedContent(
        text: 'what does it say?',
        agentId: other.id,
      );
      await tester.pumpAndSettle();

      expect(ShareIntentService.instance.incoming.value, isNull);
      expect(mode.value, AppMode.agents);
      final bool inComposer = find
          .byWidgetPredicate(
            (Widget w) =>
                w is EditableText && w.controller.text == 'what does it say?',
            skipOffstage: false,
          )
          .evaluate()
          .isNotEmpty;
      expect(inComposer, isTrue);
      expect(
        AgentsThreadComposer.takePrefill(other.threads.first.key),
        isNull,
        reason: 'the thread screen took it',
      );
      expect(lastController!.tasks, isEmpty, reason: 'nothing was sent');
      // The share sheet is Android only.
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  });

  group('main agent', () {
    testWidgets('the launcher opens the main agent with the text in its '
        'composer, not sent, from Home', (tester) async {
      final AppModeService mode = AppModeService();
      addTearDown(mode.dispose);
      final LocalAgentRosterSource roster = await pumpShell(tester, mode: mode);
      final AgentsAgent host = roster.visibleAgents.first;
      final AgentsAgent other = roster.addAgent(name: 'Cobalt');
      RosterPins.instance.setMainAgent(other.id);
      await tester.pumpAndSettle();
      // The open thread is the host's, right of the main agent: Android back
      // is the one step to Home from any agent.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(home, findsOneWidget);

      MainAgentLauncher.instance.openWithPrompt('log 10 push-ups');
      await tester.pumpAndSettle();

      expect(MainAgentLauncher.instance.requests.value, isNull);
      expect(mode.value, AppMode.agents);
      expect(home, findsNothing, reason: 'the conversation is in front');
      expect(find.byType(AgentsThreadView), findsOneWidget);
      // The chosen main agent, not the first one.
      expect(host.id, isNot(other.id));
      final String threadKey = other.threads.first.key;
      final bool inComposer = find
          .byWidgetPredicate(
            (Widget w) =>
                w is EditableText && w.controller.text == 'log 10 push-ups',
            skipOffstage: false,
          )
          .evaluate()
          .isNotEmpty;
      // Either the chat screen took it, or it waits for that thread's screen.
      expect(
        inComposer || AgentsThreadComposer.takePrefill(threadKey) != null,
        isTrue,
      );
      expect(lastController!.tasks, isEmpty, reason: 'nothing was sent');
      // The launch is not a choice of where to land next time.
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(AppModeService.prefsKey), isNull);
    });

    testWidgets('the launcher brings Agents in front of chuk\'s chats', (
      tester,
    ) async {
      final AppModeService mode = AppModeService(initial: AppMode.chats)
        ..show(AppMode.chats);
      addTearDown(mode.dispose);
      await pumpShell(tester, mode: mode);
      expect(find.text('chuk phone chat'), findsOneWidget);

      MainAgentLauncher.instance.openWithPrompt('');
      await tester.pumpAndSettle();

      expect(mode.value, AppMode.agents);
      expect(find.byType(AgentsThreadView), findsOneWidget);
      expect(lastController!.tasks, isEmpty);
    });

    testWidgets('a computer whose roster has no agent at all gets one, '
        'named "Assistant"', (tester) async {
      final LocalAgentRosterSource roster = await pumpShell(tester);
      for (final AgentsAgent a in roster.agents.toList()) {
        roster.removeAgent(a.id);
      }
      await tester.pumpAndSettle();
      expect(roster.agents, isEmpty);

      lastController!.emit(
        const AgentsRelayAgentList(agents: <AgentsHostAgentName>[]),
      );
      await tester.pumpAndSettle();

      expect(roster.agents, hasLength(1));
      expect(roster.agents.single.name, 'Assistant');

      // Once per session: an empty roster again does not make a second one.
      roster.removeAgent(roster.agents.single.id);
      lastController!.emit(
        const AgentsRelayAgentList(agents: <AgentsHostAgentName>[]),
      );
      await tester.pumpAndSettle();
      expect(roster.agents, isEmpty);
    });

    testWidgets('an empty cache before the host listed creates nothing', (
      tester,
    ) async {
      final LocalAgentRosterSource roster = await pumpShell(tester);
      for (final AgentsAgent a in roster.agents.toList()) {
        roster.removeAgent(a.id);
      }
      await tester.pumpAndSettle();
      expect(roster.agents, isEmpty);
    });
  });

  group('RootWrapperMobile', () {
    /// The wordmarks on screen. The sidebar holds one too, parked off the
    /// left edge until it is opened.
    int wordmarksOnScreen(WidgetTester tester) => find
        .byType(BrandWordmark)
        .evaluate()
        .map((Element e) => tester.getRect(find.byWidget(e.widget)))
        .where((Rect r) => r.left >= 0 && r.right <= kPhone.width)
        .length;

    Future<void> pumpWrapper(
      WidgetTester tester, {
      Widget? headerCenter,
    }) async {
      tester.view.physicalSize = kPhone;
      tester.view.devicePixelRatio = 1;
      tester.view.padding = FakeViewPadding(top: kPhoneInsets.top);
      tester.view.viewPadding = FakeViewPadding(top: kPhoneInsets.top);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        testApp(
          RootWrapperMobile(
            config: testShellConfig(),
            headerCenter: headerCenter,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }

    Future<void> drain(WidgetTester tester) async {
      // The wrapper schedules deferred work at 2 s and 8 s.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 9));
    }

    testWidgets('without a header slot it draws the title pill, as chuk_chat '
        'does', (tester) async {
      await pumpWrapper(tester);
      expect(wordmarksOnScreen(tester), 1);
      expect(find.byType(AppModeSwitch), findsNothing);
      expect(findId('copy_debug_chat_button'), findsOneWidget);
      expect(findId('new_chat_button'), findsOneWidget);
      await drain(tester);
    });

    testWidgets('the install entry is a sidebar row, only when asked for', (
      tester,
    ) async {
      tester.view.physicalSize = kPhone;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        testApp(
          RootWrapperMobile(config: testShellConfig(), onAddComputer: () {}),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.byKey(kSidebarAddComputerKey, skipOffstage: false),
        findsOneWidget,
      );
      await drain(tester);

      await pumpWrapper(tester);
      expect(
        find.byKey(kSidebarAddComputerKey, skipOffstage: false),
        findsNothing,
      );
      await drain(tester);
    });

    testWidgets('a header slot takes the pill\'s place; copy and new chat '
        'stay at 360 px', (tester) async {
      await pumpWrapper(
        tester,
        headerCenter: AppModeSwitch(mode: AppMode.chats, onChanged: (_) {}),
      );
      expect(wordmarksOnScreen(tester), 0);
      expect(find.byType(AppModeSwitch), findsOneWidget);
      final Rect sw = tester.getRect(find.byType(AppModeSwitch));
      final Rect menu = tester.getRect(findId('menu_button'));
      final Rect copy = tester.getRect(findId('copy_debug_chat_button'));
      final Rect add = tester.getRect(findId('new_chat_button'));
      expect(menu.right, lessThanOrEqualTo(sw.left));
      expect(sw.right, lessThanOrEqualTo(copy.left));
      expect(copy.right, lessThanOrEqualTo(add.left));
      expect(add.right, lessThanOrEqualTo(kPhone.width));
      expect(sw, kSwitchOnPhone);
      expect(tester.takeException(), isNull);
      await drain(tester);
    });
    testWidgets('an open chat shows its title pill in place of the header '
        'slot', (tester) async {
      tester.view.physicalSize = kPhone;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        testApp(
          RootWrapperMobile(
            config: testShellConfig(),
            headerCenter: AppModeSwitch(mode: AppMode.chats, onChanged: (_) {}),
            selectedChatIdReader: () => 'open-chat',
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(AppModeSwitch), findsNothing);
      // The chat has no stored title, so the pill shows the wordmark.
      expect(wordmarksOnScreen(tester), 1);
      expect(tester.takeException(), isNull);
      await drain(tester);
    });
  });

  group('RootWrapperDesktop', () {
    testWidgets('a header slot floats top centre, on the line of the chrome '
        'buttons, clear of the menu and the copy button', (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        testApp(
          RootWrapperDesktop(
            config: testShellConfig(),
            headerCenter: AppModeSwitch(mode: AppMode.chats, onChanged: (_) {}),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final Rect sw = tester.getRect(find.byType(AppModeSwitch));
      expect(sw.center.dx, closeTo(600, 0.5));
      expect(sw.center.dy, closeTo(16 + 20, 0.5));
      final Rect copy = tester.getRect(find.byTooltip('Copy full chat'));
      expect(sw.right, lessThan(copy.left));
      final Rect menu = tester.getRect(findIcon(Icons.menu_rounded).first);
      expect(sw.left, greaterThan(menu.right));
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 9));
    });

    testWidgets('the install entry sits in the folded rail, and only when '
        'asked for', (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      int taps = 0;
      await tester.pumpWidget(
        testApp(
          RootWrapperDesktop(
            config: testShellConfig(),
            onAddComputer: () => taps++,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byTooltip(kSidebarAddComputerLabel), findsOneWidget);
      await tester.tap(find.byTooltip(kSidebarAddComputerLabel));
      await tester.pump();
      expect(taps, 1);

      // The plain build passes nothing and draws nothing.
      await tester.pumpWidget(
        testApp(RootWrapperDesktop(config: testShellConfig())),
      );
      await tester.pump();
      expect(find.byTooltip(kSidebarAddComputerLabel), findsNothing);
      expect(
        find.byKey(kSidebarAddComputerKey, skipOffstage: false),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 9));
    });

    testWidgets('an open chat hides the header slot; a new chat shows it', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      String? chatId = 'open-chat';
      final GlobalKey<State<StatefulWidget>> wrapperKey = GlobalKey();
      await tester.pumpWidget(
        testApp(
          RootWrapperDesktop(
            key: wrapperKey,
            config: testShellConfig(),
            headerCenter: AppModeSwitch(mode: AppMode.chats, onChanged: (_) {}),
            selectedChatIdReader: () => chatId,
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(AppModeSwitch), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('root-desktop-header-center')),
        findsNothing,
      );

      chatId = null;
      // ignore: invalid_use_of_protected_member
      wrapperKey.currentState!.setState(() {});
      await tester.pump();
      expect(find.byType(AppModeSwitch), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 9));
    });

    testWidgets('without a header slot nothing floats there', (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        testApp(RootWrapperDesktop(config: testShellConfig())),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey<String>('root-desktop-header-center')),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 9));
    });
  });
}
