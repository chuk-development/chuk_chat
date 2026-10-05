// The user's own browser inside a thread: `run_state.browser_target` and the
// `user_browser_status` push reach the end of the transcript and the header
// (docs/WIRE_CONTRACT.md, "The user's own browser", app work list 3, 5, 6).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/account_session.dart';
import 'package:chuk_chat/services/agents/agent_file_saver.dart';
import 'package:chuk_chat/services/agents/agents_chat_core.dart';
import 'package:chuk_chat/services/agents/agents_permissions_service.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/agents/agents_replay_loader.dart';
import 'package:chuk_chat/services/agents/agents_run_ledger.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/settings/verbose_service.dart';
import 'package:chuk_chat/widgets/agents_thread_view.dart';

import '../agents_permissions/permissions_fakes.dart';
import '../support/fake_relay_controller.dart';
import '../support/test_app.dart';

class _NoopSaver implements AgentFileSaver {
  @override
  Future<String> save(AgentsRelayFile file) async => '/dev/null/${file.name}';
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

Map<String, dynamic> _push({
  bool connected = true,
  bool stopped = false,
  Map<String, dynamic>? inUseBy,
}) => <String, dynamic>{
  'type': 'user_browser_status',
  'user_browser': <String, dynamic>{
    'host_listening': true,
    'installed': true,
    'browsers': <String>['chrome'],
    'connected': connected,
    'browser': 'chrome',
    'trusted_input': true,
    'in_use': inUseBy != null,
    'in_use_by': inUseBy,
    'stopped': stopped,
  },
};

void main() {
  late FakeHost host;
  late AgentsPermissionsService before;

  setUp(() async {
    debugAgentsChatCoreOverride = true;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await VerboseService.instance.setEnabled(false);
    AgentsRelayLink.instance.reset();
    AgentsRunLedger.instance.reset();
    AgentsReplayLoader.instance.reset();
    await ChatStorageService.reset();
    host = FakeHost();
    before = AgentsPermissionsService.instance;
    AgentsPermissionsService.instance = host.service();
  });

  tearDown(() async {
    AgentsPermissionsService.instance.dispose();
    AgentsPermissionsService.instance = before;
    debugAgentsChatCoreOverride = null;
    AgentsRelayLink.instance.reset();
    AgentsRunLedger.instance.reset();
    AgentsReplayLoader.instance.reset();
    await ChatStorageService.reset();
  });

  Future<FakeRelayController> pumpPaired(
    WidgetTester tester, {
    bool phone = false,
  }) async {
    final Size size = phone ? const Size(360, 800) : const Size(1400, 900);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = FakeRelayController();
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: AgentsThreadView(
            controllerBuilder: () async => controller,
            sessionSource: const _FakeSessionSource(),
            threadKey: 'thread-1',
            title: 'Ada',
            phoneLayout: phone,
            fileSaver: _NoopSaver(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    controller.set(
      const AgentsRelayState(
        phase: AgentsRelayPhase.paired,
        peerDeviceId: 'cowork-host',
      ),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(minutes: 2));
  }

  for (final bool phone in <bool>[false, true]) {
    final String layout = phone ? 'phone' : 'desktop';

    testWidgets('$layout: a run in the user browser shows the label, the '
        'push turns it into Stop and back, live', (tester) async {
      final controller = await pumpPaired(tester, phone: phone);
      AgentsRunLedger.instance.begin('thread-1');
      host.sent.clear();
      controller.emit(
        const AgentsRelayRunState(
          sessionKey: 'thread-1',
          state: 'running',
          browserTarget: kBrowserTargetUserBrowser,
        ),
      );
      await settle(tester);
      // No status yet: the thread asks the host once.
      expect(host.sent.single['type'], 'agent_permissions_get');
      expect(host.sent.single['agent_id'], 'thread-1');
      expect(find.text('Your browser'), findsOneWidget);

      AgentsPermissionsService.instance.handleUserBrowserStatus(_push());
      await settle(tester);
      expect(find.text('Your browser · Chrome'), findsOneWidget);

      AgentsPermissionsService.instance.handleUserBrowserStatus(
        _push(stopped: true),
      );
      await settle(tester);
      expect(
        find.byKey(const ValueKey<String>('agents-user-browser-stopped')),
        findsOneWidget,
      );
      expect(
        find.textContaining('tap Allow again in the add-on'),
        findsOneWidget,
      );

      AgentsPermissionsService.instance.handleUserBrowserStatus(
        _push(
          inUseBy: <String, dynamic>{
            'agent_id': 'other',
            'name': 'Crypto Desk',
          },
        ),
      );
      await settle(tester);
      expect(find.text('Crypto Desk is using your browser'), findsOneWidget);

      AgentsPermissionsService.instance.handleUserBrowserStatus(
        _push(connected: false),
      );
      await settle(tester);
      expect(find.text('Your browser is not connected'), findsOneWidget);
      expect(find.text('How to set up'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await unmount(tester);
    });
  }

  testWidgets('desktop: the screen chip says the coworker works in the user '
      'browser', (tester) async {
    final controller = await pumpPaired(tester);
    expect(find.byTooltip('No screen open right now'), findsOneWidget);
    controller.emit(
      const AgentsRelayRunState(
        sessionKey: 'thread-1',
        state: 'idle',
        browserTarget: kBrowserTargetUserBrowser,
      ),
    );
    await settle(tester);
    expect(find.byTooltip('Works in your browser'), findsOneWidget);
    // Idle and nothing wrong: no line at the end of the thread.
    expect(
      find.byKey(const ValueKey<String>('agents-user-browser-label')),
      findsNothing,
    );
    await unmount(tester);
  });

  testWidgets('a sandbox run of another thread changes nothing', (
    tester,
  ) async {
    final controller = await pumpPaired(tester);
    AgentsRunLedger.instance.begin('thread-1');
    controller.emit(
      const AgentsRelayRunState(
        sessionKey: 'thread-2',
        state: 'running',
        browserTarget: kBrowserTargetUserBrowser,
      ),
    );
    await settle(tester);
    expect(find.text('Your browser'), findsNothing);
    expect(find.byTooltip('Works in your browser'), findsNothing);
    await unmount(tester);
  });
}
