import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/agents/agents_permissions_service.dart';
import 'package:chuk_chat/widgets/agents_permissions/agent_permissions_section.dart';

import '../support/test_app.dart';
import 'permissions_fakes.dart';

Map<String, dynamic> _reply({
  Map<String, String> classes = const <String, String>{
    'publish': 'ask',
    'send_external': 'allow',
    'mcp_destructive': 'ask',
    'browser_act': 'ask',
  },
  List<String> sites = const <String>['github.com', 'shop.example'],
}) => <String, dynamic>{
  ...permissionsReply('a', AgentPermissions.defaults),
  'approvals': <String, dynamic>{
    'classes': classes,
    'sites': <String, dynamic>{'browser_act': sites},
    'defaults': <String, String>{
      'publish': 'ask',
      'send_external': 'ask',
      'mcp_destructive': 'ask',
      'browser_act': 'allow',
    },
    'applies_from': 'next_action',
  },
};

Future<(FakeHost, AgentsPermissionsService)> _open(
  WidgetTester tester, {
  bool approvals = true,
}) async {
  final FakeHost host = FakeHost();
  host.capabilities.value = <String>{
    kAgentPermissionsCapability,
    if (approvals) kActionApprovalsCapability,
  };
  final AgentsPermissionsService service = host.service();
  addTearDown(service.dispose);
  await tester.pumpWidget(
    testApp(
      Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: AgentPermissionsSection(agentId: 'a', service: service),
        ),
      ),
    ),
  );
  await tester.pump();
  return (host, service);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('one row per class with Ask / Allow / Deny, the default named, '
      'the browser sites listed', (tester) async {
    final (_, service) = await _open(tester);
    service.handleFrame(_reply());
    await tester.pump();
    expect(find.text('APPROVALS'), findsOneWidget);
    for (final String title in <String>[
      'Send mail',
      'Connector changes',
      'Act in the browser',
      'Publish to the web',
    ]) {
      expect(find.text(title), findsOneWidget);
    }
    expect(
      find.byKey(const ValueKey<String>('agent-approval-mode-browser_act')),
      findsOneWidget,
    );
    expect(find.textContaining('Default: Allow'), findsOneWidget);
    expect(find.textContaining('Default: Ask'), findsNWidgets(3));
    expect(find.text('github.com'), findsOneWidget);
    expect(find.text('shop.example'), findsOneWidget);
    expect(find.text('Applies from the next action.'), findsOneWidget);
  });

  testWidgets('a choice sends approvals only, with the one class', (
    tester,
  ) async {
    final (host, service) = await _open(tester);
    service.handleFrame(_reply());
    await tester.pump();
    final Finder group = find.byKey(
      const ValueKey<String>('agent-approval-mode-send_external'),
    );
    await tester.ensureVisible(group);
    await tester.tap(find.descendant(of: group, matching: find.text('Deny')));
    await tester.pump(const Duration(milliseconds: 300));
    final Map<String, dynamic> frame = host.sent.last;
    expect(frame['type'], 'agent_permissions_set');
    expect(frame.containsKey('permissions'), isFalse);
    expect(frame['approvals'], <String, dynamic>{
      'classes': <String, String>{'send_external': 'deny'},
    });
    expect(service.approvalsOf('a')!.modeOf('send_external'), 'deny');
  });

  testWidgets('removing a site sends the list without it; a host frame '
      'replaces what is shown', (tester) async {
    final (host, service) = await _open(tester);
    service.handleFrame(_reply());
    await tester.pump();
    final Finder remove = find.byKey(
      const ValueKey<String>('agent-approval-remove-github.com'),
    );
    await tester.ensureVisible(remove);
    await tester.tap(remove);
    await tester.pump(const Duration(milliseconds: 300));
    expect(host.sent.last['approvals'], <String, dynamic>{
      'sites': <String, dynamic>{
        'browser_act': <String>['shop.example'],
      },
    });
    expect(find.text('github.com'), findsNothing);
    // A lasting answer on a card in a run: the host sends a new frame.
    service.handleFrame(_reply(sites: const <String>['shop.example', 'x.org']));
    await tester.pump();
    expect(find.text('x.org'), findsOneWidget);
  });

  testWidgets('a host without action_approvals shows no section', (
    tester,
  ) async {
    final (_, service) = await _open(tester, approvals: false);
    service.handleFrame(_reply());
    await tester.pump();
    expect(find.text('APPROVALS'), findsNothing);
  });
}
