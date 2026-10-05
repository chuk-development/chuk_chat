// The user's own browser: parsing of `agent_permissions.user_browser`, the
// `user_browser_status` push and `run_state.browser_target`, and the pure
// rules for the switch subtitle and the thread notice
// (docs/WIRE_CONTRACT.md, "The user's own browser").

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/agents/agents_permissions_service.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/widgets/agents_user_browser.dart';

import 'permissions_fakes.dart';

Map<String, dynamic> _block({
  bool hostListening = true,
  bool installed = true,
  bool connected = true,
  String? browser = 'chrome',
  bool inUse = false,
  Map<String, dynamic>? inUseBy,
  bool? mine,
  bool stopped = false,
}) => <String, dynamic>{
  'host_listening': hostListening,
  'installed': installed,
  'browsers': <String>['chrome', 'brave'],
  'connected': connected,
  'browser': browser,
  'version': '0.2.0',
  'trusted_input': true,
  'in_use': inUse,
  'in_use_by': inUseBy,
  'in_use_by_this_agent': ?mine,
  'stopped': stopped,
};

Map<String, dynamic> _reply(String agentId, Map<String, dynamic> block) =>
    <String, dynamic>{
      ...permissionsReply(agentId, AgentPermissions.defaults),
      'user_browser': block,
    };

Map<String, dynamic> _push(Map<String, dynamic> block) => <String, dynamic>{
  'type': 'user_browser_status',
  'user_browser': block,
};

final AppLocalizations _en = AppLocalizations(const Locale('en'));
final AppLocalizations _de = AppLocalizations(const Locale('de'));

String _subtitle(
  UserBrowserStatus? s, {
  String agentId = 'a',
  bool heldByOther = false,
  AppLocalizations? l,
}) => userBrowserSubtitle(
  l ?? _en,
  s,
  agentId: agentId,
  heldByOther: heldByOther,
  fallback: 'fallback',
);

void main() {
  group('UserBrowserStatus.fromJson', () {
    test('reads every key of the contract', () {
      final UserBrowserStatus s = UserBrowserStatus.fromJson(
        _block(
          inUse: true,
          inUseBy: <String, dynamic>{
            'agent_id': 'local:desk:1:7',
            'name': 'Crypto Desk',
          },
          mine: false,
        ),
      )!;
      expect(s.hostListening, isTrue);
      expect(s.installed, isTrue);
      expect(s.browsers, <String>['chrome', 'brave']);
      expect(s.connected, isTrue);
      expect(s.browser, 'chrome');
      expect(s.version, '0.2.0');
      expect(s.trustedInput, isTrue);
      expect(s.inUse, isTrue);
      expect(s.inUseByAgentId, 'local:desk:1:7');
      expect(s.inUseByName, 'Crypto Desk');
      expect(s.inUseByThisAgent, isFalse);
      expect(s.stopped, isFalse);
      expect(s.needsSetup, isFalse);
    });

    test('a null in_use_by and missing keys keep the defaults', () {
      final UserBrowserStatus s = UserBrowserStatus.fromJson(<String, dynamic>{
        'host_listening': true,
        'in_use_by': null,
      })!;
      expect(s.installed, isFalse);
      expect(s.connected, isFalse);
      expect(s.browsers, isEmpty);
      expect(s.browser, isNull);
      expect(s.inUseByAgentId, isNull);
      expect(s.inUseByThisAgent, isNull);
      expect(s.trustedInput, isNull);
      expect(s.needsSetup, isTrue);
    });

    test('wrong types are dropped, never guessed', () {
      final UserBrowserStatus s = UserBrowserStatus.fromJson(<String, dynamic>{
        'host_listening': 'yes',
        'installed': 1,
        'browsers': <Object?>['chrome', 3, '', null],
        'browser': 42,
        'in_use_by': <String, dynamic>{'agent_id': 7, 'name': ''},
        'in_use_by_this_agent': 'no',
      })!;
      expect(s.hostListening, isFalse);
      expect(s.installed, isFalse);
      expect(s.browsers, <String>['chrome']);
      expect(s.browser, isNull);
      expect(s.inUseByAgentId, isNull);
      expect(s.inUseByName, isNull);
      expect(s.inUseByThisAgent, isNull);
    });

    test('not a map is no status', () {
      expect(UserBrowserStatus.fromJson(null), isNull);
      expect(UserBrowserStatus.fromJson('connected'), isNull);
    });

    test('a host whose broker is down needs no setup on the app side', () {
      final UserBrowserStatus s = UserBrowserStatus.fromJson(
        _block(hostListening: false, installed: false, connected: false),
      )!;
      expect(s.needsSetup, isFalse);
    });
  });

  group('run_state.browser_target', () {
    test('user_browser, sandbox, unknown and missing', () {
      expect(parseBrowserTarget('user_browser'), kBrowserTargetUserBrowser);
      expect(parseBrowserTarget('sandbox'), kBrowserTargetSandbox);
      expect(parseBrowserTarget('quantum'), kBrowserTargetSandbox);
      expect(parseBrowserTarget(null), isNull);
      expect(parseBrowserTarget(3), isNull);
    });

    test('the run state frame carries it', () {
      final AgentsRelayRunState? state = AgentsRelayRunState.fromPayload(
        <String, dynamic>{
          'type': 'run_state',
          'session_key': 'a',
          'state': 'running',
          'browser_target': 'user_browser',
        },
      );
      expect(state!.browserTarget, kBrowserTargetUserBrowser);
      expect(state.usesUserBrowser, isTrue);
      final AgentsRelayRunState? old = AgentsRelayRunState.fromPayload(
        <String, dynamic>{'session_key': 'a', 'state': 'idle'},
      );
      expect(old!.browserTarget, isNull);
      expect(old.usesUserBrowser, isFalse);
    });
  });

  group('the service', () {
    late FakeHost host;
    late AgentsPermissionsService service;

    setUp(() {
      host = FakeHost();
      service = host.service();
    });
    tearDown(() => service.dispose());

    test('a reply stores the status; an old host sends none', () {
      service.handleFrame(permissionsReply('a', AgentPermissions.defaults));
      expect(service.userBrowserStatus, isNull);
      service.handleFrame(_reply('a', _block()));
      expect(service.userBrowserStatus!.browser, 'chrome');
    });

    test('the push replaces the stored status and repaints', () {
      service.handleFrame(_reply('a', _block()));
      int notified = 0;
      service.addListener(() => notified++);
      service.handleUserBrowserStatus(_push(_block(connected: false)));
      expect(service.userBrowserStatus!.connected, isFalse);
      expect(notified, 1);
      // Not a push: ignored.
      service.handleUserBrowserStatus(<String, dynamic>{
        'type': 'agent_permissions',
        'user_browser': _block(),
      });
      expect(service.userBrowserStatus!.connected, isFalse);
      // A push with no block: ignored.
      service.handleUserBrowserStatus(<String, dynamic>{
        'type': 'user_browser_status',
      });
      expect(service.userBrowserStatus, isNotNull);
      expect(notified, 1);
    });

    test('attach routes the push from the relay to the service', () {
      final before = AgentsRelayClient.userBrowserStatusSink;
      final beforePermissions = AgentsRelayClient.agentPermissionsSink;
      addTearDown(() {
        AgentsRelayClient.userBrowserStatusSink = before;
        AgentsRelayClient.agentPermissionsSink = beforePermissions;
      });
      service.attach();
      AgentsRelayClient.userBrowserStatusSink!(_push(_block(stopped: true)));
      expect(service.userBrowserStatus!.stopped, isTrue);
    });

    test('who holds it: in_use_by first, then the reply flag', () {
      service.handleFrame(
        _reply(
          'a',
          _block(
            inUse: true,
            inUseBy: <String, dynamic>{'agent_id': 'b', 'name': 'Ada'},
            mine: false,
          ),
        ),
      );
      expect(service.userBrowserHeldByOther('a'), isTrue);
      expect(service.userBrowserHeldByOther('b'), isFalse);

      // An old reply without in_use_by: the flag decides, for that agent.
      service.handleFrame(_reply('a', _block(inUse: true, mine: false)));
      expect(service.userBrowserHeldByOther('a'), isTrue);
      expect(service.userBrowserHeldByOther('c'), isFalse);

      // A push has no flag and clears the old ones: no holder named, no
      // claim.
      service.handleUserBrowserStatus(_push(_block(inUse: true)));
      expect(service.userBrowserHeldByOther('a'), isFalse);

      service.handleUserBrowserStatus(_push(_block()));
      expect(service.userBrowserHeldByOther('a'), isFalse);
    });

    test('a dropped connection forgets the status', () {
      service.handleFrame(_reply('a', _block(stopped: true)));
      host.detach();
      expect(service.userBrowserStatus, isNull);
    });
  });

  group('the switch subtitle', () {
    UserBrowserStatus s(Map<String, dynamic> block) =>
        UserBrowserStatus.fromJson(block)!;

    test('one line per state, as the work list words it', () {
      expect(_subtitle(null), 'fallback');
      expect(
        _subtitle(s(_block(hostListening: false))),
        'Restart the Agents host to use your browser',
      );
      expect(
        _subtitle(s(_block(installed: false, connected: false))),
        'Not set up on this computer',
      );
      expect(_subtitle(s(_block(connected: false))), 'Add-on not connected');
      expect(_subtitle(s(_block(stopped: true))), 'Stopped in the browser');
      expect(_subtitle(s(_block())), 'Paired with Chrome');
      expect(_subtitle(s(_block(browser: null))), 'Paired with your browser');
      expect(
        _subtitle(
          s(
            _block(
              inUse: true,
              inUseBy: <String, dynamic>{'agent_id': 'b', 'name': 'Ada'},
            ),
          ),
          heldByOther: true,
        ),
        'Ada is using your browser',
      );
      expect(
        _subtitle(s(_block(inUse: true)), heldByOther: true),
        'Another coworker is using your browser',
      );
      expect(
        _subtitle(
          s(
            _block(
              inUse: true,
              inUseBy: <String, dynamic>{'agent_id': 'a', 'name': 'Me'},
            ),
          ),
        ),
        'Using Chrome now',
      );
    });

    test('German', () {
      expect(
        _subtitle(s(_block(connected: false)), l: _de),
        'Add-on nicht verbunden',
      );
      expect(_subtitle(s(_block()), l: _de), 'Verbunden mit Chrome');
    });

    test('browser names read as people say them', () {
      expect(userBrowserDisplayName('chrome'), 'Chrome');
      expect(userBrowserDisplayName('brave'), 'Brave');
      expect(userBrowserDisplayName('firefox'), 'Firefox');
      expect(userBrowserDisplayName('arc'), 'Arc');
    });
  });

  group('the thread notice', () {
    UserBrowserStatus s(Map<String, dynamic> block) =>
        UserBrowserStatus.fromJson(block)!;

    UserBrowserNotice? notice({
      UserBrowserStatus? status,
      bool heldByOther = false,
      String? target = kBrowserTargetUserBrowser,
      bool? permissionOn,
      bool running = false,
    }) => userBrowserNoticeFor(
      status: status,
      heldByOther: heldByOther,
      browserTarget: target,
      permissionOn: permissionOn,
      running: running,
    );

    test('a coworker without the user browser gets nothing', () {
      expect(notice(target: kBrowserTargetSandbox, running: true), isNull);
      expect(notice(target: null, permissionOn: false, running: true), isNull);
      expect(
        notice(
          target: kBrowserTargetSandbox,
          status: s(_block(stopped: true)),
          running: true,
        ),
        isNull,
      );
    });

    test('Stop, another holder, no setup, not connected', () {
      expect(
        notice(status: s(_block(stopped: true))),
        const UserBrowserNotice(UserBrowserNoticeKind.stopped),
      );
      expect(
        notice(
          status: s(
            _block(
              inUse: true,
              inUseBy: <String, dynamic>{'agent_id': 'b', 'name': 'Ada'},
            ),
          ),
          heldByOther: true,
        ),
        const UserBrowserNotice(
          UserBrowserNoticeKind.inUseByOther,
          name: 'Ada',
        ),
      );
      expect(
        notice(status: s(_block(installed: false, connected: false))),
        const UserBrowserNotice(UserBrowserNoticeKind.notSetUp),
      );
      expect(
        notice(status: s(_block(connected: false))),
        const UserBrowserNotice(UserBrowserNoticeKind.notConnected),
      );
      // Stop wins over everything else.
      expect(
        notice(
          status: s(_block(stopped: true, connected: false)),
          heldByOther: true,
        )!.kind,
        UserBrowserNoticeKind.stopped,
      );
    });

    test('a switch that is on counts before the first run_state', () {
      expect(
        notice(
          target: null,
          permissionOn: true,
          status: s(_block(stopped: true)),
        )!.kind,
        UserBrowserNoticeKind.stopped,
      );
    });

    test('the label shows only while a run is going', () {
      expect(notice(status: s(_block())), isNull);
      expect(
        notice(status: s(_block()), running: true),
        const UserBrowserNotice(UserBrowserNoticeKind.label, browser: 'chrome'),
      );
      // Switched on in the middle of a task: this run still uses the
      // sandbox.
      expect(
        notice(
          target: kBrowserTargetSandbox,
          permissionOn: true,
          status: s(_block(stopped: true)),
          running: true,
        ),
        const UserBrowserNotice(UserBrowserNoticeKind.label, sandbox: true),
      );
      expect(
        notice(running: true),
        const UserBrowserNotice(UserBrowserNoticeKind.label),
      );
    });
  });
}
