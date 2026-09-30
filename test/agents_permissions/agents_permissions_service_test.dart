import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/agents/agents_permissions_service.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';

import 'permissions_fakes.dart';

void main() {
  group('AgentPermissions', () {
    test('defaults allow everything but the user browser', () {
      const AgentPermissions p = AgentPermissions.defaults;
      expect(p.sudo, isTrue);
      expect(p.network, isTrue);
      expect(p.secretsEnv, isTrue);
      expect(p.workspaceMount, AgentWorkspaceMount.rw);
      expect(p.userBrowser, isFalse);
      expect(p.toJson(), <String, dynamic>{
        'sudo': true,
        'network': true,
        'secrets_env': true,
        'workspace_mount': 'rw',
        'user_browser': false,
      });
    });

    test('fromJson reads the host set and keeps defaults for bad values', () {
      final AgentPermissions p = AgentPermissions.fromJson(<String, dynamic>{
        'sudo': false,
        'network': 'no', // wrong type: the default stays
        'workspace_mount': 'ro',
        'user_browser': true,
      });
      expect(p.sudo, isFalse);
      expect(p.network, isTrue);
      expect(p.secretsEnv, isTrue);
      expect(p.workspaceWritable, isFalse);
      expect(p.userBrowser, isTrue);
      expect(AgentPermissions.fromJson(p.toJson()), p);
    });

    test('the workspace switch maps to rw / ro on the wire', () {
      expect(AgentPermissions.wireValue('workspace_mount', true), 'rw');
      expect(AgentPermissions.wireValue('workspace_mount', false), 'ro');
      expect(AgentPermissions.wireValue('network', false), false);
      expect(
        () => AgentPermissions.wireValue('root', true),
        throwsArgumentError,
      );
    });
  });

  group('AgentsPermissionsService', () {
    test(
      'refresh sends agent_permissions_get to a host that names it',
      () async {
        final FakeHost host = FakeHost();
        final AgentsPermissionsService service = host.service();
        addTearDown(service.dispose);
        expect(await service.refresh('local:amber:1'), isTrue);
        expect(host.sent.single, <String, dynamic>{
          'type': 'agent_permissions_get',
          'agent_id': 'local:amber:1',
        });
        expect(service.isKnown('local:amber:1'), isFalse);
      },
    );

    test('nothing goes to a host that did not name the capability', () async {
      final FakeHost host = FakeHost(supported: false);
      final AgentsPermissionsService service = host.service();
      addTearDown(service.dispose);
      expect(service.supported, isFalse);
      expect(await service.refresh('a'), isFalse);
      expect(await service.setSwitch('a', 'sudo', false), isFalse);
      expect(host.sent, isEmpty);
    });

    test('refresh is false when the send fails', () async {
      final FakeHost host = FakeHost()..fail = true;
      final AgentsPermissionsService service = host.service();
      addTearDown(service.dispose);
      expect(await service.refresh('a'), isFalse);
    });

    test('a connection or capability change notifies', () {
      final FakeHost host = FakeHost(connected: false, supported: false);
      final AgentsPermissionsService service = host.service();
      addTearDown(service.dispose);
      int notified = 0;
      service.addListener(() => notified++);
      host.attach();
      host.nameCapability();
      expect(notified, 2);
      expect(service.connected && service.supported, isTrue);
    });

    test('a reply is the whole truth for that agent', () {
      final FakeHost host = FakeHost();
      final AgentsPermissionsService service = host.service();
      addTearDown(service.dispose);
      int notified = 0;
      service.addListener(() => notified++);
      service.handleFrame(
        permissionsReply(
          'a',
          AgentPermissions.defaults.copyWith(sudo: false),
          enforced: <String, bool>{'sudo': false, 'network': false},
        ),
      );
      expect(service.isKnown('a'), isTrue);
      expect(service.permissionsOf('a').sudo, isFalse);
      expect(service.appliesFromOf('a'), 'next_task');
      expect(service.isEnforced('a', 'sudo'), isFalse);
      expect(service.isEnforced('a', 'secrets_env'), isTrue);
      expect(service.isKnown('b'), isFalse);
      expect(service.permissionsOf('b'), AgentPermissions.defaults);
      expect(notified, 1);
    });

    test('an error-only reply (an unknown coworker) carries the reason', () {
      final FakeHost host = FakeHost();
      final AgentsPermissionsService service = host.service();
      addTearDown(service.dispose);
      service.handleFrame(
        permissionsReply('gone', null, error: "unknown agent 'gone'"),
      );
      expect(service.isKnown('gone'), isFalse);
      expect(service.errorOf('gone'), contains('unknown agent'));
    });

    test('other frames and malformed replies are ignored', () {
      final FakeHost host = FakeHost();
      final AgentsPermissionsService service = host.service();
      addTearDown(service.dispose);
      service.handleFrame(<String, dynamic>{'type': 'agent_list'});
      service.handleFrame(<String, dynamic>{'type': 'agent_permissions'});
      service.handleFrame(<String, dynamic>{
        'type': 'agent_permissions',
        'agent_id': 'a',
        'permissions': 'all',
      });
      expect(service.isKnown('a'), isFalse);
      expect(service.errorOf('a'), isNull);
    });

    test('setSwitch sends only the changed key and flips at once', () async {
      final FakeHost host = FakeHost();
      final AgentsPermissionsService service = host.service();
      addTearDown(service.dispose);
      service.handleFrame(permissionsReply('a', AgentPermissions.defaults));

      expect(await service.setSwitch('a', 'workspace_mount', false), isTrue);
      expect(host.sent.last, <String, dynamic>{
        'type': 'agent_permissions_set',
        'agent_id': 'a',
        'permissions': <String, dynamic>{'workspace_mount': 'ro'},
      });
      // Shown flipped before the host answers ...
      expect(service.permissionsOf('a').workspaceWritable, isFalse);
      // ... and the host's own answer is still the old one.
      expect(service.confirmedOf('a')!.workspaceWritable, isTrue);

      service.handleFrame(
        permissionsReply(
          'a',
          AgentPermissions.defaults.copyWith(
            workspaceMount: AgentWorkspaceMount.ro,
          ),
        ),
      );
      expect(service.confirmedOf('a')!.workspaceWritable, isFalse);
    });

    test(
      'a refused change comes back with the old value and the reason',
      () async {
        final FakeHost host = FakeHost();
        final AgentsPermissionsService service = host.service();
        addTearDown(service.dispose);
        service.handleFrame(permissionsReply('a', AgentPermissions.defaults));
        await service.setSwitch('a', 'network', false);
        service.handleFrame(
          permissionsReply(
            'a',
            AgentPermissions.defaults,
            error: 'could not save: OSError',
          ),
        );
        expect(service.permissionsOf('a').network, isTrue);
        expect(service.errorOf('a'), 'could not save: OSError');
      },
    );

    test('a failed send puts the switch back', () async {
      final FakeHost host = FakeHost();
      final AgentsPermissionsService service = host.service();
      addTearDown(service.dispose);
      service.handleFrame(permissionsReply('a', AgentPermissions.defaults));
      host.fail = true;
      expect(await service.setSwitch('a', 'sudo', false), isFalse);
      expect(service.permissionsOf('a').sudo, isTrue);
    });

    test('attach routes the relay sink to the service', () {
      final FakeHost host = FakeHost();
      final AgentsPermissionsService service = host.service();
      addTearDown(service.dispose);
      final void Function(Map<String, dynamic>)? before =
          AgentsRelayClient.agentPermissionsSink;
      addTearDown(() => AgentsRelayClient.agentPermissionsSink = before);
      service.attach();
      AgentsRelayClient.agentPermissionsSink!(
        permissionsReply('a', AgentPermissions.defaults),
      );
      expect(service.isKnown('a'), isTrue);
    });
  });
}
