// The user's own browser in the UI: the "Your browser" subtitle and its live
// update, the setup card, the thread notice, the approval card's "in your
// own browser" and the parked screen chip (docs/WIRE_CONTRACT.md, "The
// user's own browser", app work list 1-6). Layout at 360 px and 1.3.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/agents/agents_permissions_service.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/widgets/agents_action_approval_card.dart';
import 'package:chuk_chat/widgets/agents_permissions/agent_permissions_section.dart';
import 'package:chuk_chat/widgets/agents_thread_header.dart';
import 'package:chuk_chat/widgets/agents_user_browser.dart';

import '../agents_permissions/permissions_fakes.dart';
import '../support/test_app.dart';

Map<String, dynamic> _block({
  bool installed = true,
  bool connected = true,
  bool inUse = false,
  Map<String, dynamic>? inUseBy,
  bool stopped = false,
}) => <String, dynamic>{
  'host_listening': true,
  'installed': installed,
  'browsers': installed ? <String>['chrome'] : <String>[],
  'connected': connected,
  'browser': connected ? 'chrome' : null,
  'version': '0.2.0',
  'trusted_input': true,
  'in_use': inUse,
  'in_use_by': inUseBy,
  'stopped': stopped,
};

Map<String, dynamic> _reply(
  String agentId,
  Map<String, dynamic> block, {
  bool userBrowser = false,
}) => <String, dynamic>{
  ...permissionsReply(
    agentId,
    AgentPermissions.defaults.copyWith(userBrowser: userBrowser),
  ),
  'user_browser': block,
};

Map<String, dynamic> _push(Map<String, dynamic> block) => <String, dynamic>{
  'type': 'user_browser_status',
  'user_browser': block,
};

Widget _localized(
  Widget child, {
  Locale locale = const Locale('en'),
  double width = 800,
  double textScale = 1,
}) => MaterialApp(
  locale: locale,
  localizationsDelegates: kTestLocalizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Builder(
    builder: (BuildContext context) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(textScale)),
      child: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: child,
            ),
          ),
        ),
      ),
    ),
  ),
);

extension on WidgetTester {
  /// The app's localisations load asynchronously: the first frame is empty.
  Future<void> pumpL(Widget widget) async {
    await pumpWidget(widget);
    await pump();
  }
}

Finder _subtitleOf(String text) => find.descendant(
  of: find.byKey(const ValueKey<String>('agent-permission-user_browser')),
  matching: find.text(text),
);

Future<(FakeHost, AgentsPermissionsService)> _section(
  WidgetTester tester, {
  Locale locale = const Locale('en'),
}) async {
  final FakeHost host = FakeHost();
  final AgentsPermissionsService service = host.service();
  addTearDown(service.dispose);
  await tester.pumpL(
    _localized(
      AgentPermissionsSection(agentId: 'a', service: service),
      locale: locale,
    ),
  );
  await tester.pump();
  return (host, service);
}

void main() {
  group('"Your browser" in the permissions', () {
    testWidgets('the subtitle follows the host, and the push repaints it', (
      tester,
    ) async {
      final (_, AgentsPermissionsService service) = await _section(tester);
      // Before the host said anything: the plain explanation.
      expect(
        _subtitleOf('Use the browser add-on on your computer.'),
        findsOneWidget,
      );

      service.handleFrame(_reply('a', _block()));
      await tester.pump();
      expect(_subtitleOf('Paired with Chrome'), findsOneWidget);

      service.handleUserBrowserStatus(_push(_block(connected: false)));
      await tester.pump();
      expect(_subtitleOf('Add-on not connected'), findsOneWidget);

      service.handleUserBrowserStatus(
        _push(_block(installed: false, connected: false)),
      );
      await tester.pump();
      expect(_subtitleOf('Not set up on this computer'), findsOneWidget);

      service.handleUserBrowserStatus(_push(_block(stopped: true)));
      await tester.pump();
      expect(_subtitleOf('Stopped in the browser'), findsOneWidget);

      service.handleUserBrowserStatus(
        _push(
          _block(
            inUse: true,
            inUseBy: <String, dynamic>{'agent_id': 'b', 'name': 'Ada'},
          ),
        ),
      );
      await tester.pump();
      expect(_subtitleOf('Ada is using your browser'), findsOneWidget);
    });

    testWidgets('German subtitle', (tester) async {
      final (_, AgentsPermissionsService service) = await _section(
        tester,
        locale: const Locale('de'),
      );
      service.handleFrame(_reply('a', _block()));
      await tester.pump();
      expect(_subtitleOf('Verbunden mit Chrome'), findsOneWidget);
    });

    testWidgets('the setup card shows only with the switch on and the add-on '
        'missing; Check again asks the host', (tester) async {
      final (FakeHost host, AgentsPermissionsService service) = await _section(
        tester,
      );
      const Key card = ValueKey<String>('agents-user-browser-setup');

      // Switch off: no card, even with nothing set up.
      service.handleFrame(
        _reply('a', _block(installed: false, connected: false)),
      );
      await tester.pump();
      expect(find.byKey(card), findsNothing);

      // Switch on, nothing set up: the card with the three steps.
      service.handleFrame(
        _reply(
          'a',
          _block(installed: false, connected: false),
          userBrowser: true,
        ),
      );
      await tester.pump();
      expect(find.byKey(card), findsOneWidget);
      expect(find.text('Set up your browser'), findsOneWidget);
      expect(find.text(kUserBrowserSetupCommand), findsOneWidget);
      expect(find.textContaining('chrome://extensions'), findsOneWidget);
      expect(find.textContaining('Reload the add-on'), findsOneWidget);
      // No host address, port or socket wording.
      expect(find.textContaining('WebSocket'), findsNothing);
      expect(find.textContaining('ws://'), findsNothing);

      // Set up, not connected: other words, same steps.
      service.handleUserBrowserStatus(_push(_block(connected: false)));
      await tester.pump();
      expect(find.text('Your browser is not connected'), findsOneWidget);

      host.sent.clear();
      final Finder check = find.byKey(
        const ValueKey<String>('agents-user-browser-check'),
      );
      await tester.ensureVisible(check);
      await tester.pump();
      await tester.tap(check);
      await tester.pump();
      expect(host.sent.single['type'], 'agent_permissions_get');
      expect(host.sent.single['agent_id'], 'a');

      // Connected: the card goes away by itself.
      service.handleUserBrowserStatus(_push(_block()));
      await tester.pump();
      expect(find.byKey(card), findsNothing);
    });

    testWidgets('the copy button puts the command on the clipboard', (
      tester,
    ) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall call) async {
          if (call.method == 'Clipboard.setData') {
            copied =
                (call.arguments as Map<Object?, Object?>)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpL(
        _localized(
          AgentsUserBrowserSetupCard(
            status: UserBrowserStatus.fromJson(
              _block(installed: false, connected: false),
            )!,
            onCheckAgain: () {},
          ),
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('agents-user-browser-copy')),
      );
      await tester.pump();
      expect(copied, kUserBrowserSetupCommand);
      expect(find.text('Command copied'), findsOneWidget);
    });
  });

  group('the thread notice', () {
    Future<void> pumpNotice(
      WidgetTester tester,
      UserBrowserNotice notice, {
      VoidCallback? onSetUp,
      Locale locale = const Locale('en'),
    }) => tester.pumpL(
      _localized(
        AgentsUserBrowserNoticeView(notice: notice, onSetUp: onSetUp),
        locale: locale,
      ),
    );

    testWidgets('each kind says its sentence', (tester) async {
      await pumpNotice(
        tester,
        const UserBrowserNotice(UserBrowserNoticeKind.stopped),
      );
      expect(
        find.text(
          'You stopped this in your browser. Send a new task, or tap Allow '
          'again in the add-on.',
        ),
        findsOneWidget,
      );

      await pumpNotice(
        tester,
        const UserBrowserNotice(
          UserBrowserNoticeKind.inUseByOther,
          name: 'Crypto Desk',
        ),
      );
      expect(find.text('Crypto Desk is using your browser'), findsOneWidget);

      await pumpNotice(
        tester,
        const UserBrowserNotice(UserBrowserNoticeKind.label, browser: 'chrome'),
      );
      expect(find.text('Your browser · Chrome'), findsOneWidget);

      await pumpNotice(
        tester,
        const UserBrowserNotice(UserBrowserNoticeKind.label, sandbox: true),
      );
      expect(find.text('Sandbox browser'), findsOneWidget);

      await pumpNotice(
        tester,
        const UserBrowserNotice(UserBrowserNoticeKind.stopped),
        locale: const Locale('de'),
      );
      expect(
        find.textContaining('Du hast das in deinem Browser'),
        findsOneWidget,
      );
    });

    testWidgets('"How to set up" opens the steps only for a missing add-on', (
      tester,
    ) async {
      int opened = 0;
      await pumpNotice(
        tester,
        const UserBrowserNotice(UserBrowserNoticeKind.stopped),
        onSetUp: () => opened++,
      );
      expect(find.text('How to set up'), findsNothing);

      await pumpNotice(
        tester,
        const UserBrowserNotice(UserBrowserNoticeKind.notConnected),
        onSetUp: () => opened++,
      );
      expect(find.text('Your browser is not connected'), findsOneWidget);
      await tester.tap(find.text('How to set up'));
      expect(opened, 1);

      await pumpNotice(
        tester,
        const UserBrowserNotice(UserBrowserNoticeKind.notSetUp),
        onSetUp: () => opened++,
      );
      expect(
        find.text('Your browser is not set up on this computer'),
        findsOneWidget,
      );
    });

    testWidgets('the setup sheet follows the service', (tester) async {
      final FakeHost host = FakeHost();
      final AgentsPermissionsService service = host.service();
      addTearDown(service.dispose);
      service.handleFrame(
        _reply('a', _block(installed: false, connected: false)),
      );
      await tester.pumpL(
        _localized(
          Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () => showUserBrowserSetupSheet(
                context,
                agentId: 'a',
                service: service,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Set up your browser'), findsOneWidget);
      service.handleUserBrowserStatus(_push(_block(connected: false)));
      await tester.pump();
      expect(find.text('Your browser is not connected'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey<String>('agents-user-browser-check')),
      );
      await tester.pump();
      expect(host.sent.last['type'], 'agent_permissions_get');
    });
  });

  group('the approval card', () {
    AgentsRelayApprovalRequest request(Map<String, dynamic> details) =>
        AgentsRelayApprovalRequest(
          approvalId: 'ap-1',
          action: 'action_approval',
          path: '',
          name: '',
          fileCount: 0,
          totalBytes: 0,
          baseUrl: '',
          public: false,
          sessionKey: 'a',
          actionClass: 'browser_act',
          options: const <String>['once', 'always_this_site', 'deny'],
          summary: 'Open github.com',
          site: 'github.com',
          details: details,
        );

    testWidgets('says "In your own browser" and shows the address', (
      tester,
    ) async {
      await tester.pumpL(
        _localized(
          AgentsActionApprovalCard(
            request: request(const <String, dynamic>{
              'browser': 'user_browser',
              'browser_tool': 'browser_navigate',
              'url': 'https://github.com/pulls',
            }),
            coworkerName: 'Ada',
            onSelect: (_) {},
          ),
        ),
      );
      expect(find.text('In your own browser'), findsOneWidget);
      expect(find.text('Open github.com'), findsOneWidget);
      expect(find.textContaining('https://github.com/pulls'), findsOneWidget);
      expect(find.textContaining('github.com'), findsWidgets);
      expect(
        find.byKey(
          const ValueKey<String>('agents-approval-option-always_this_site'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a sandbox card does not say it', (tester) async {
      await tester.pumpL(
        _localized(
          AgentsActionApprovalCard(
            request: request(const <String, dynamic>{
              'browser_tool': 'browser_click',
              'element': 'Save',
            }),
            coworkerName: 'Ada',
            onSelect: (_) {},
          ),
        ),
      );
      expect(find.text('In your own browser'), findsNothing);
    });

    testWidgets('German', (tester) async {
      await tester.pumpL(
        _localized(
          AgentsActionApprovalCard(
            request: request(const <String, dynamic>{
              'browser': 'user_browser',
              'url': 'https://github.com',
            }),
            coworkerName: 'Ada',
            onSelect: (_) {},
          ),
          locale: const Locale('de'),
        ),
      );
      expect(find.text('In deinem eigenen Browser'), findsOneWidget);
    });
  });

  testWidgets('the screen chip of a coworker in the user browser stays '
      'parked and says why', (tester) async {
    await tester.pumpL(
      _localized(
        const SizedBox(
          height: 120,
          child: AgentsThreadHeader(
            showScreenTarget: true,
            usesUserBrowser: true,
          ),
        ),
      ),
    );
    expect(find.byTooltip('Works in your browser'), findsOneWidget);
    await tester.tap(find.byTooltip('Works in your browser'));
    await tester.pump();
    expect(
      find.text(
        'This coworker works in your own browser. There is no screen to show '
        'here.',
      ),
      findsOneWidget,
    );
  });

  group('360 px at 1.3', () {
    Future<void> layout(WidgetTester tester, Widget child) async {
      tester.view.physicalSize = const Size(360, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpL(_localized(child, width: 360, textScale: 1.3));
      await tester.pump();
      expect(tester.takeException(), isNull);
    }

    testWidgets('the setup card', (tester) async {
      await layout(
        tester,
        AgentsUserBrowserSetupCard(
          status: UserBrowserStatus.fromJson(
            _block(installed: false, connected: false),
          )!,
          onCheckAgain: () {},
        ),
      );
    });

    testWidgets('every notice, German too', (tester) async {
      for (final Locale locale in const <Locale>[Locale('en'), Locale('de')]) {
        tester.view.physicalSize = const Size(360, 1400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpL(
          _localized(
            Column(
              children: <Widget>[
                for (final UserBrowserNotice n in const <UserBrowserNotice>[
                  UserBrowserNotice(UserBrowserNoticeKind.stopped),
                  UserBrowserNotice(
                    UserBrowserNoticeKind.inUseByOther,
                    name: 'A coworker with a long name',
                  ),
                  UserBrowserNotice(UserBrowserNoticeKind.notSetUp),
                  UserBrowserNotice(UserBrowserNoticeKind.notConnected),
                  UserBrowserNotice(
                    UserBrowserNoticeKind.label,
                    browser: 'chrome',
                  ),
                ])
                  AgentsUserBrowserNoticeView(notice: n, onSetUp: () {}),
              ],
            ),
            locale: locale,
            width: 360,
            textScale: 1.3,
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull, reason: '$locale');
        // The coworker's name is never cut.
        expect(
          find.textContaining('A coworker with a long name'),
          findsOneWidget,
        );
      }
    });
  });

  // ── browser resume ──
  group('"Allow again" from the app', () {
    Future<(FakeHost, AgentsPermissionsService)> resumable(
      WidgetTester tester, {
      bool capability = true,
    }) async {
      final (FakeHost host, AgentsPermissionsService service) = await _section(
        tester,
      );
      if (capability) {
        host.capabilities.value = const <String>{
          kAgentPermissionsCapability,
          kUserBrowserResumeCapability,
        };
      }
      service.handleFrame(_reply('a', _block(stopped: true), userBrowser: true));
      await tester.pump();
      return (host, service);
    }

    const Key button = ValueKey<String>('agents-user-browser-allow-again');

    test('the service sends the frame only to a host that names it', () async {
      final FakeHost host = FakeHost();
      final AgentsPermissionsService service = host.service();
      addTearDown(service.dispose);
      expect(service.userBrowserResumeSupported, isFalse);
      expect(await service.resumeUserBrowser(), isFalse);
      expect(host.sent, isEmpty);

      host.capabilities.value = const <String>{kUserBrowserResumeCapability};
      expect(await service.resumeUserBrowser(), isTrue);
      expect(host.sent.last, <String, dynamic>{'type': 'user_browser_resume'});
      expect(service.resumingUserBrowser, isTrue);
      // A second tap while the host has not answered sends nothing.
      expect(await service.resumeUserBrowser(), isFalse);
      expect(host.sent, hasLength(1));
      // The host's answer ends the wait and replaces the status.
      service.handleUserBrowserStatus(_push(_block()));
      expect(service.resumingUserBrowser, isFalse);
      expect(service.userBrowserStatus!.stopped, isFalse);
      expect(service.lastResumeError, isNull);
      expect(await service.resumeAnswer, isNull);
      // An answer with an error (no block) ends the wait too, and hands the
      // host's reason to the tap that asked.
      expect(await service.resumeUserBrowser(), isTrue);
      final Future<String?> answer = service.resumeAnswer;
      service.handleUserBrowserStatus(<String, dynamic>{
        'type': 'user_browser_status',
        'error': 'user browser not enabled',
      });
      expect(service.resumingUserBrowser, isFalse);
      expect(service.lastResumeError, 'user browser not enabled');
      expect(await answer, 'user browser not enabled');
      // The stored status is not touched by the refusal.
      expect(service.userBrowserStatus!.stopped, isFalse);
      // A new request forgets the old reason.
      expect(await service.resumeUserBrowser(), isTrue);
      expect(service.lastResumeError, isNull);
      service.handleUserBrowserStatus(_push(_block()));
      expect(service.lastResumeError, isNull);
      // A send that fails is no wait.
      host.fail = true;
      expect(await service.resumeUserBrowser(), isFalse);
      expect(service.resumingUserBrowser, isFalse);
    });

    testWidgets('under the switch: shown while stopped, sends the frame', (
      tester,
    ) async {
      final (FakeHost host, AgentsPermissionsService service) =
          await resumable(tester);
      expect(_subtitleOf('Stopped in the browser'), findsOneWidget);
      expect(find.byKey(button), findsOneWidget);
      await tester.tap(find.byKey(button));
      await tester.pump();
      expect(
        host.sent.where((p) => p['type'] == 'user_browser_resume'),
        hasLength(1),
      );
      service.handleUserBrowserStatus(_push(_block()));
      await tester.pump();
      expect(find.byKey(button), findsNothing);
      expect(_subtitleOf('Paired with Chrome'), findsOneWidget);
    });

    testWidgets('a refusal from the host shows its reason', (tester) async {
      final (_, AgentsPermissionsService service) = await resumable(tester);
      await tester.tap(find.byKey(button));
      await tester.pump();
      service.handleUserBrowserStatus(<String, dynamic>{
        'type': 'user_browser_status',
        'error': 'user browser not enabled',
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.text('Could not allow it again: user browser not enabled'),
        findsOneWidget,
      );
      // Still stopped: the button stays for another try.
      expect(find.byKey(button), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('no button for a host that does not name the capability', (
      tester,
    ) async {
      await resumable(tester, capability: false);
      expect(_subtitleOf('Stopped in the browser'), findsOneWidget);
      expect(find.byKey(button), findsNothing);
    });

    testWidgets('a failed send says so', (tester) async {
      final (FakeHost host, _) = await resumable(tester);
      host.fail = true;
      await tester.tap(find.byKey(button));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.text('Could not reach your computer. Try again.'),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('the Stop notice: button and sentence only with a callback', (
      tester,
    ) async {
      int taps = 0;
      await tester.pumpL(
        _localized(
          AgentsUserBrowserNoticeView(
            notice: const UserBrowserNotice(UserBrowserNoticeKind.stopped),
            onAllowAgain: () => taps++,
          ),
        ),
      );
      expect(
        find.text(
          'You stopped this in your browser. Tap Allow again, or send a new '
          'task.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(button));
      expect(taps, 1);

      // Busy: the tap does nothing.
      await tester.pumpL(
        _localized(
          AgentsUserBrowserNoticeView(
            notice: const UserBrowserNotice(UserBrowserNoticeKind.stopped),
            onAllowAgain: () => taps++,
            allowAgainBusy: true,
          ),
        ),
      );
      await tester.tap(find.byKey(button));
      expect(taps, 1);

      // Another kind never shows it.
      await tester.pumpL(
        _localized(
          AgentsUserBrowserNoticeView(
            notice: const UserBrowserNotice(UserBrowserNoticeKind.notSetUp),
            onAllowAgain: () => taps++,
          ),
        ),
      );
      expect(find.byKey(button), findsNothing);
    });

    testWidgets('360 px at 1.3, German', (tester) async {
      tester.view.physicalSize = const Size(360, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpL(
        _localized(
          AgentsUserBrowserNoticeView(
            notice: const UserBrowserNotice(UserBrowserNoticeKind.stopped),
            onAllowAgain: () {},
          ),
          locale: const Locale('de'),
          width: 360,
          textScale: 1.3,
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('Wieder erlauben'), findsOneWidget);
    });
  });
  // ── end browser resume ──
}
