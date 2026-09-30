import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/pages/agent_profile_page.dart';
import 'package:chuk_chat/services/agents/agent_profile_store.dart';
import 'package:chuk_chat/services/agents/agent_roster_source.dart';
import 'package:chuk_chat/services/agents/agents_permissions_service.dart';
import 'package:chuk_chat/widgets/agents_permissions/agent_permissions_section.dart';
import 'package:chuk_chat/widgets/icons/icon_map.dart';

import '../support/test_app.dart';
import 'permissions_fakes.dart';

Widget _page(AgentsPermissionsService service, {String agentId = 'a'}) =>
    testApp(
      Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: AgentPermissionsSection(agentId: agentId, service: service),
        ),
      ),
    );

Switch _switch(WidgetTester tester, String key) => tester.widget<Switch>(
  find.descendant(
    of: find.byKey(ValueKey<String>('agent-permission-$key')),
    matching: find.byType(Switch),
  ),
);

Future<(FakeHost, AgentsPermissionsService)> _open(
  WidgetTester tester, {
  bool connected = true,
  bool supported = true,
}) async {
  final FakeHost host = FakeHost(connected: connected, supported: supported);
  final AgentsPermissionsService service = host.service();
  addTearDown(service.dispose);
  await tester.pumpWidget(_page(service));
  await tester.pump();
  return (host, service);
}

void main() {
  test('every switch draws a HugeIcon from the app set', () {
    expect(
      kAgentPermissionSpecs.map((s) => s.key).toList(),
      AgentPermissions.keys,
    );
    for (final AgentPermissionSpec spec in kAgentPermissionSpecs) {
      expect(hugeIconFor(spec.icon), isNotNull, reason: spec.key);
    }
  });

  testWidgets('one switch per permission, each with its one-line reason', (
    tester,
  ) async {
    await _open(tester);
    for (final AgentPermissionSpec spec in kAgentPermissionSpecs) {
      expect(find.text(spec.title), findsOneWidget);
      expect(find.text(spec.explanation), findsOneWidget);
    }
    expect(find.byType(Switch), findsNWidgets(5));
    expect(find.text('PERMISSIONS'), findsOneWidget);
    // The internet switch covers the host-side web tools too.
    expect(find.text('Sandbox and web tools.'), findsOneWidget);
  });

  testWidgets('asks the host on open and waits for it with the switches off', (
    tester,
  ) async {
    final (FakeHost host, _) = await _open(tester);
    expect(host.sent.single['type'], 'agent_permissions_get');
    expect(host.sent.single['agent_id'], 'a');
    expect(find.text('Asking the host…'), findsOneWidget);
    for (final String key in AgentPermissions.keys) {
      expect(_switch(tester, key).onChanged, isNull);
    }
    await tester.pump(const Duration(seconds: 11));
    expect(find.textContaining('did not answer'), findsOneWidget);
  });

  testWidgets('an old host is never asked, and the section says why', (
    tester,
  ) async {
    final (FakeHost host, _) = await _open(tester, supported: false);
    expect(host.sent, isEmpty);
    await tester.pump(const Duration(seconds: 11));
    expect(find.textContaining('does not manage permissions'), findsOneWidget);
    expect(host.sent, isEmpty);
  });

  testWidgets('a host that names the capability late is asked then', (
    tester,
  ) async {
    final (FakeHost host, _) = await _open(tester, supported: false);
    expect(host.sent, isEmpty);
    host.nameCapability();
    await tester.pump();
    expect(host.sent.single['type'], 'agent_permissions_get');
  });

  testWidgets('the host answer turns on every switch but the user browser', (
    tester,
  ) async {
    final (_, AgentsPermissionsService service) = await _open(tester);
    service.handleFrame(permissionsReply('a', AgentPermissions.defaults));
    await tester.pump();

    expect(_switch(tester, 'sudo').value, isTrue);
    expect(_switch(tester, 'network').value, isTrue);
    expect(_switch(tester, 'secrets_env').value, isTrue);
    expect(_switch(tester, 'workspace_mount').value, isTrue);
    expect(_switch(tester, 'user_browser').value, isFalse);
    expect(_switch(tester, 'sudo').onChanged, isNotNull);
    expect(find.text(kPermissionsAppliesLine), findsOneWidget);
    expect(find.textContaining('next task'), findsOneWidget);
  });

  testWidgets('a switch this host does not enforce is greyed and says so', (
    tester,
  ) async {
    final (_, AgentsPermissionsService service) = await _open(tester);
    service.handleFrame(
      permissionsReply(
        'a',
        AgentPermissions.defaults,
        enforced: <String, bool>{
          'sudo': false,
          'network': false,
          'secrets_env': true,
          'workspace_mount': false,
          'user_browser': true,
        },
      ),
    );
    await tester.pump();
    expect(_switch(tester, 'sudo').onChanged, isNull);
    expect(_switch(tester, 'secrets_env').onChanged, isNotNull);
    expect(find.text(kPermissionNotEnforced), findsNWidgets(3));
  });

  testWidgets('a tap sends the change and the host reply is drawn', (
    tester,
  ) async {
    final (FakeHost host, AgentsPermissionsService service) = await _open(
      tester,
    );
    service.handleFrame(permissionsReply('a', AgentPermissions.defaults));
    await tester.pump();

    await tester.tap(
      find.byKey(const ValueKey<String>('agent-permission-network')),
    );
    await tester.pump();
    expect(host.sent.last, <String, dynamic>{
      'type': 'agent_permissions_set',
      'agent_id': 'a',
      'permissions': <String, dynamic>{'network': false},
    });
    expect(_switch(tester, 'network').value, isFalse);

    service.handleFrame(
      permissionsReply('a', AgentPermissions.defaults.copyWith(network: false)),
    );
    await tester.pump();
    expect(_switch(tester, 'network').value, isFalse);
  });

  testWidgets('another device changed it: the broadcast reply redraws', (
    tester,
  ) async {
    final (_, AgentsPermissionsService service) = await _open(tester);
    service.handleFrame(permissionsReply('a', AgentPermissions.defaults));
    await tester.pump();
    service.handleFrame(
      permissionsReply('a', AgentPermissions.defaults.copyWith(sudo: false)),
    );
    await tester.pump();
    expect(_switch(tester, 'sudo').value, isFalse);
  });

  testWidgets('a refused change shows the reason and the kept value', (
    tester,
  ) async {
    final (_, AgentsPermissionsService service) = await _open(tester);
    service.handleFrame(
      permissionsReply(
        'a',
        AgentPermissions.defaults,
        error: 'could not save: OSError',
      ),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('agent-permissions-error')),
      findsOneWidget,
    );
    expect(find.textContaining('could not save'), findsOneWidget);
    expect(_switch(tester, 'sudo').value, isTrue);
  });

  testWidgets('an unknown coworker shows the host reason, nothing editable', (
    tester,
  ) async {
    final (_, AgentsPermissionsService service) = await _open(tester);
    service.handleFrame(
      permissionsReply('a', null, error: "unknown agent 'a'"),
    );
    await tester.pump();
    expect(find.textContaining('unknown agent'), findsOneWidget);
    expect(_switch(tester, 'sudo').onChanged, isNull);
  });

  testWidgets('offline, then the host attaches: the section asks again', (
    tester,
  ) async {
    final (FakeHost host, AgentsPermissionsService service) = await _open(
      tester,
      connected: false,
    );
    await tester.pump();
    expect(find.textContaining('Not connected to the host'), findsOneWidget);
    expect(_switch(tester, 'network').onChanged, isNull);
    expect(host.sent, isEmpty);

    host.attach();
    await tester.pump();
    expect(host.sent.single['type'], 'agent_permissions_get');
    service.handleFrame(permissionsReply('a', AgentPermissions.defaults));
    await tester.pump();
    expect(_switch(tester, 'network').onChanged, isNotNull);
  });

  testWidgets('a failed send does not stick: the next attach retries', (
    tester,
  ) async {
    final (FakeHost host, AgentsPermissionsService service) = await _open(
      tester,
    );
    service.handleFrame(permissionsReply('a', AgentPermissions.defaults));
    await tester.pump();
    host.fail = true;
    await tester.tap(
      find.byKey(const ValueKey<String>('agent-permission-sudo')),
    );
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Not connected to the host'), findsWidgets);

    host.fail = false;
    host.detach();
    host.attach();
    await tester.pump();
    expect(host.sent.last['type'], 'agent_permissions_get');
    service.handleFrame(permissionsReply('a', AgentPermissions.defaults));
    await tester.pump();
    expect(find.text(kPermissionsAppliesLine), findsOneWidget);
    expect(_switch(tester, 'sudo').onChanged, isNotNull);
    await tester.pump(const Duration(seconds: 3)); // the toast
  });

  testWidgets('fits a 360 px phone at 1.3 text scale', (tester) async {
    tester.view.physicalSize = const Size(360, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final FakeHost host = FakeHost();
    final AgentsPermissionsService service = host.service();
    addTearDown(service.dispose);
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(360, 1400),
          textScaler: TextScaler.linear(1.3),
        ),
        child: _page(service),
      ),
    );
    await tester.pump();
    service.handleFrame(permissionsReply('a', AgentPermissions.defaults));
    await tester.pump();
    expect(tester.takeException(), isNull);
    for (final AgentPermissionSpec spec in kAgentPermissionSpecs) {
      expect(find.text(spec.title), findsOneWidget);
    }
  });

  testWidgets('the agent profile shows the section for that coworker', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final FakeHost host = FakeHost();
    final AgentsPermissionsService before = AgentsPermissionsService.instance;
    AgentsPermissionsService.instance = host.service();
    addTearDown(() {
      AgentsPermissionsService.instance.dispose();
      AgentsPermissionsService.instance = before;
    });
    final AgentProfileStore store = AgentProfileStore();
    final LocalAgentRosterSource source = LocalAgentRosterSource(
      seed: <AgentsAgent>[
        const AgentsAgent(id: 'alex', name: 'Alex', threads: []),
      ],
    );
    addTearDown(store.dispose);
    addTearDown(source.dispose);

    await tester.pumpWidget(
      testApp(
        AgentProfilePage(agentId: 'alex', source: source, profiles: store),
      ),
    );
    await tester.pump();

    expect(find.byType(AgentPermissionsSection), findsOneWidget);
    expect(host.sent.single, <String, dynamic>{
      'type': 'agent_permissions_get',
      'agent_id': 'alex',
    });
    // Leave no answer timer behind.
    await tester.pumpWidget(const SizedBox());
  });
}
