// The Chat | Agents switch: one app, two halves (bead chuk_chat-18v).
//
// The shell tests stand a light widget in for chuk_chat's own root wrapper
// (`MessengerShell.chatModeBuilder`): the real one starts the whole chat
// stack. The last group pumps the real `RootWrapperMobile` to pin its header
// slot, and that the plain build still draws the title pill.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/pages/messenger_shell.dart';
import 'package:chuk_chat/platform_specific/mobile/mobile_agent_list.dart';
import 'package:chuk_chat/platform_specific/mobile/mobile_nav_bar.dart';
import 'package:chuk_chat/platform_specific/root_wrapper_desktop.dart';
import 'package:chuk_chat/platform_specific/root_wrapper_mobile.dart';
import 'package:chuk_chat/services/account_session.dart';
import 'package:chuk_chat/services/agents/agent_roster_source.dart';
import 'package:chuk_chat/services/agents/agents_device_keys.dart';
import 'package:chuk_chat/services/agents/agents_pairing_restore.dart';
import 'package:chuk_chat/services/agents/agents_pairing_store.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/agents/agents_run_ledger.dart';
import 'package:chuk_chat/services/agents/room_source.dart';
import 'package:chuk_chat/services/agents/supabase_pairing_sync.dart';
import 'package:chuk_chat/services/app_mode_service.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/notifications/notification_router.dart';
import 'package:chuk_chat/widgets/agent_roster_view.dart';
import 'package:chuk_chat/widgets/agents_thread_header.dart';
import 'package:chuk_chat/widgets/agents_thread_view.dart';
import 'package:chuk_chat/widgets/app_mode_switch.dart';
import 'package:chuk_chat/widgets/brand_wordmark.dart';

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

/// Stands in for chuk_chat's root wrapper: a top bar shaped like chuk's (a
/// 42 px chip, then the switch left-aligned in the rest of a 48 px row), a
/// counter and a draft, so a test can see that its state survives a switch.
class _FakeChatHalf extends StatefulWidget {
  const _FakeChatHalf({required this.phone, required this.modeSwitch});

  final bool phone;
  final Widget modeSwitch;

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
      body: Stack(
        children: <Widget>[
          Positioned.fill(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(widget.phone ? 'chuk phone chat' : 'chuk desktop chat'),
                  Text('taps $taps'),
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
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
                child: SizedBox(
                  height: 48,
                  child: Row(
                    children: <Widget>[
                      const SizedBox(width: 42, height: 42),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: widget.modeSwitch,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

const Size kPhone = Size(360, 800);

/// Where the switch sits on a 360 px phone with a 24 px status bar, over
/// chuk's chat and over the inbox alike.
const Rect kSwitchOnPhone = Rect.fromLTWH(
  10 + 42 + 8,
  24 + 8,
  AppModeSwitch.width,
  AppModeSwitch.boxHeight,
);

/// A phone wide enough for the "Add your computer" panel an unpaired device
/// shows behind the inbox (the test font runs wider than the real one).
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
    ChatStorageService.selectedChatId = null;
  });
  tearDown(() {
    AgentsRelayLink.instance.reset();
    AgentsRunLedger.instance.reset();
    NotificationRouter.instance.reset();
    ChatStorageService.selectedChatId = null;
  });

  /// How often the shell asked for a transport: the thread view builds one
  /// per mount, so this counts mounts of the socket owner.
  int controllerBuilds = 0;
  setUp(() => controllerBuilds = 0);

  /// Pumps the shell with a Chat half. [paired] seeds a stored pairing (the
  /// default half with nothing remembered); [mode] injects the mode state.
  Future<LocalAgentRosterSource> pumpShell(
    WidgetTester tester, {
    Size size = kPhone,
    bool paired = true,
    AppModeService? mode,
    bool withChat = true,
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
    final LocalAgentRosterSource roster = LocalAgentRosterSource();
    await tester.pumpWidget(
      testApp(
        MessengerShell(
          relayControllerBuilder: () async {
            controllerBuilds++;
            return FakeRelayController();
          },
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
              ? (context, {required phone, required modeSwitch}) =>
                    _FakeChatHalf(phone: phone, modeSwitch: modeSwitch)
              : null,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return roster;
  }

  /// The switch on screen. Both halves may hold one; only the half in front
  /// is on stage.
  Finder onStageSwitch() => find.byType(AppModeSwitch);

  Future<void> pick(WidgetTester tester, String label) async {
    await tester.tap(
      find.descendant(of: onStageSwitch(), matching: find.text(label)),
    );
    await tester.pumpAndSettle();
  }

  final Finder threadView = find.byType(AgentsThreadView, skipOffstage: false);

  group('AppModeSwitch', () {
    testWidgets('Chat on the left, Agents on the right; a press picks', (
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
      final Rect chat = tester.getRect(find.text('Chat'));
      final Rect agents = tester.getRect(find.text('Agents'));
      expect(chat.center.dx, lessThan(agents.center.dx));
      // The strip is the chips' 42, in a 48 px box a finger can hit.
      expect(tester.getSize(find.byType(AppModeSwitch)).height, 48);

      await tester.tap(find.text('Agents'));
      await tester.pump();
      expect(picked, isEmpty, reason: 'the half in front is not picked again');
      await tester.tap(find.text('Chat'));
      await tester.pump();
      expect(picked, <AppMode>[AppMode.chat]);
    });
  });

  group('phone', () {
    testWidgets('Agents: the switch sits in the inbox header, All / Unread in '
        'a compact row under it', (tester) async {
      await pumpShell(tester);

      expect(find.byType(MobileAgentList), findsOneWidget);
      final Rect bar = tester.getRect(onStageSwitch());
      final Rect search = tester.getRect(findId('mobile_home_search'));
      final Rect add = tester.getRect(findId('mobile_home_add'));
      // [search] [Chat | Agents] [+], on one line.
      expect(search.right, lessThanOrEqualTo(bar.left));
      expect(bar.right, lessThanOrEqualTo(add.left));
      expect(bar.center.dy, closeTo(search.center.dy, 0.5));
      expect(bar.center.dy, closeTo(add.center.dy, 0.5));

      // All / Unread still works, below the bar and left-aligned.
      final Rect all = tester.getRect(findId('connected-group-all'));
      expect(all.top, greaterThanOrEqualTo(bar.bottom));
      expect(all.left, lessThan(bar.left));
      expect(find.textContaining('Unread'), findsOneWidget);
      // The switch leads with the half in front.
      expect(
        tester.widget<AppModeSwitch>(onStageSwitch()).mode,
        AppMode.agents,
      );
      // chuk's floating bar: 10 px in, a 42 px chip, 8 px, then the switch;
      // 8 px under the status bar, in a 48 px row.
      expect(bar, kSwitchOnPhone);
    });

    testWidgets('Chat: chuk\'s chat in front, the switch on the same pixels, '
        'no navigation pill', (tester) async {
      await pumpShell(tester);
      final Rect inAgents = tester.getRect(onStageSwitch());

      await pick(tester, 'Chat');

      expect(find.text('chuk phone chat'), findsOneWidget);
      expect(find.byType(MobileAgentList), findsNothing, reason: 'off stage');
      expect(find.byType(MobileAgentList, skipOffstage: false), findsOneWidget);
      expect(find.byType(MobileNavBar), findsNothing, reason: 'Agents only');
      final Rect inChat = tester.getRect(onStageSwitch());
      expect(inChat, inAgents);
      expect(tester.widget<AppModeSwitch>(onStageSwitch()).mode, AppMode.chat);
    });

    testWidgets('both halves stay mounted and keep their state', (
      tester,
    ) async {
      await pumpShell(tester);
      expect(controllerBuilds, 1);

      // Agents: pick the Unread filter.
      await tester.tap(find.textContaining('Unread'));
      await tester.pumpAndSettle();

      await pick(tester, 'Chat');
      await tester.tap(find.text('tap'));
      await tester.enterText(
        find.byKey(const ValueKey<String>('fake-chuk-draft')),
        'half a thought',
      );
      await tester.pump();
      expect(find.text('taps 1'), findsOneWidget);

      await pick(tester, 'Agents');
      expect(find.byType(MobileAgentList), findsOneWidget);
      // The inbox kept its filter: the Unread segment is still the one on.
      final Semantics unread = tester.widget<Semantics>(
        findId('connected-group-unread'),
      );
      expect(unread.properties.selected, isTrue);

      await pick(tester, 'Chat');
      expect(find.text('taps 1'), findsOneWidget);
      expect(find.text('half a thought'), findsOneWidget);

      // One socket owner the whole time.
      expect(threadView, findsOneWidget);
      expect(controllerBuilds, 1);
    });

    testWidgets('the choice is remembered for the next launch', (
      tester,
    ) async {
      await pumpShell(tester);
      await pick(tester, 'Chat');
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(AppModeService.prefsKey), 'chat');

      // A new shell on a paired device still opens where the user left.
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpShell(tester);
      expect(find.text('chuk phone chat'), findsOneWidget);
    });

    testWidgets('with nothing remembered: Agents with a pairing, Chat '
        'without', (tester) async {
      await pumpShell(tester, paired: true);
      expect(find.byType(MobileAgentList), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await pumpShell(tester, paired: false, size: kWidePhone);
      expect(find.text('chuk phone chat'), findsOneWidget);
      expect(find.byType(MobileAgentList), findsNothing);
      // The thread view is still there behind it: it owns the socket.
      expect(threadView, findsOneWidget);
    });

    testWidgets('without a Chat half there is no switch, and All / Unread '
        'stays in the header row', (tester) async {
      await pumpShell(
        tester,
        withChat: false,
        paired: false,
        size: kWidePhone,
      );
      expect(find.byType(AppModeSwitch), findsNothing);
      expect(find.byType(MobileAgentList), findsOneWidget);
      final Rect all = tester.getRect(findId('connected-group-all'));
      final Rect search = tester.getRect(findId('mobile_home_search'));
      expect(all.center.dy, closeTo(search.center.dy, 0.5));
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
      await pick(tester, 'Chat');
      expect(tester.takeException(), isNull);
    });
  });

  group('desktop', () {
    /// The rect of the switch's painted strip, not its 48 px box.
    Rect strip(WidgetTester tester) {
      final Rect box = tester.getRect(onStageSwitch());
      final double inset = (AppModeSwitch.boxHeight - AppModeSwitch.height) / 2;
      return Rect.fromLTRB(box.left, box.top + inset, box.right, box.bottom - inset);
    }

    for (final Size size in <Size>[
      const Size(1200, 800),
      const Size(800, 700),
      const Size(640, 700),
    ]) {
      testWidgets('${size.width.toInt()} px: the switch floats top centre and '
          'clears the thread\'s buttons', (tester) async {
        await pumpShell(tester, size: size);

        final Rect sw = strip(tester);
        // On the line of the 40 px chrome buttons.
        expect(sw.center.dy, closeTo(16 + 20, 1));
        // Nothing of the thread's floating row under it.
        final Finder buttons = find.descendant(
          of: find.byType(AgentsThreadHeader),
          matching: find.byType(Tooltip),
        );
        expect(buttons, findsWidgets);
        for (final Element e in buttons.evaluate()) {
          final Rect r = tester.getRect(find.byWidget(e.widget));
          expect(r.overlaps(sw), isFalse, reason: 'overlaps $r');
        }
        // Clear of the roster (or its rail).
        final Rect roster = tester.getRect(find.byType(AgentRosterView));
        expect(sw.left, greaterThanOrEqualTo(roster.right));
        expect(sw.right, lessThanOrEqualTo(size.width));
        // A Linux window: the thread draws its desktop row at every width.
      }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
    }

    testWidgets('Chat: chuk\'s desktop in front; the thread stays mounted', (
      tester,
    ) async {
      await pumpShell(tester, size: const Size(1200, 800));
      await pick(tester, 'Chat');
      expect(find.text('chuk desktop chat'), findsOneWidget);
      expect(threadView, findsOneWidget);
      expect(controllerBuilds, 1);

      await pick(tester, 'Agents');
      expect(find.text('chuk desktop chat'), findsNothing);
      expect(find.byType(AgentsThreadView), findsOneWidget);
      expect(controllerBuilds, 1);
    });

    testWidgets('the details pane on a narrow window gives the switch a line '
        'of its own', (tester) async {
      await pumpShell(tester, size: const Size(800, 700));
      // The host's coworker is selected once the fake relay pairs.
      await tester.tap(find.byTooltip('Details (Ctrl+.)'));
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

      await pick(tester, 'Chat');
      // chuk's chat opens a chat of its own.
      ChatStorageService.selectedChatId = '11111111-2222-3333-4444-555555555555';
      await tester.pump();
      // The Agents thread, behind it, reconnects and points it at itself.
      ChatStorageService.selectedChatId = threadKey;
      await tester.pump();
      expect(
        ChatStorageService.selectedChatId,
        '11111111-2222-3333-4444-555555555555',
        reason: 'the half in front keeps its chat',
      );

      await pick(tester, 'Agents');
      // A thread is selected once the roster has one; the pointer follows it.
      final String? agentsPointer = ChatStorageService.selectedChatId;
      expect(agentsPointer, isNot('11111111-2222-3333-4444-555555555555'));

      await pick(tester, 'Chat');
      expect(
        ChatStorageService.selectedChatId,
        '11111111-2222-3333-4444-555555555555',
        reason: 'chuk\'s chat comes back with its half',
      );
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

    Future<void> pumpWrapper(WidgetTester tester, {Widget? headerCenter}) async {
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

    testWidgets('a header slot takes the pill\'s place; copy and new chat '
        'stay at 360 px', (tester) async {
      await pumpWrapper(
        tester,
        headerCenter: AppModeSwitch(mode: AppMode.chat, onChanged: (_) {}),
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
      // The same pixels the switch takes over the Agents inbox.
      expect(sw, kSwitchOnPhone);
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
            headerCenter: AppModeSwitch(mode: AppMode.chat, onChanged: (_) {}),
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
