// CHAT-177: every agent carries the computer it lives on, the roster cache
// keeps it per agent, and the host agents of two computers do not collide.

import 'package:chuk_chat/services/agents/agent_roster_source.dart';
import 'package:chuk_chat/services/agents/agent_roster_store.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart'
    show AgentsHostAgentName;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  AgentRosterStore nextLaunch() =>
      AgentRosterStore(prefsKey: 'roster_hosts_test_v1');

  test('the computer of each agent survives a restart', () async {
    final AgentRosterStore store = nextLaunch();
    final first = LocalAgentRosterSource(store: store);
    await first.load();
    first.ensureHostAgent('cowork-host', hostId: 'pc');
    first.ensureHostAgent(
      'cowork-host',
      hostId: 'box',
      agentId: 'host:cowork-host@box',
    );
    final made = first.addAgent(name: 'amber-otter', hostId: 'box');
    await store.flush();

    final second = LocalAgentRosterSource(store: nextLaunch());
    await second.load();

    expect(second.byId('host:cowork-host')!.hostId, 'pc');
    expect(second.byId('host:cowork-host@box')!.hostId, 'box');
    // Each host agent keeps its own permanent thread.
    expect(
      second.byId('host:cowork-host@box')!.threads.single.key,
      'host:cowork-host@box',
    );
    expect(second.byId(made.id)!.hostId, 'box');
  });

  test('agents from before CHAT-177 are stamped with the one computer', () {
    final roster = LocalAgentRosterSource(store: nextLaunch());
    roster.ensureHostAgent('cowork-host');
    final old = roster.addAgent(name: 'jade-lynx');
    final boxAgent = roster.addAgent(name: 'cloud-cat', hostId: 'box');
    var notified = 0;
    roster.addListener(() => notified++);

    roster.assignHost('pc');

    expect(roster.byId('host:cowork-host')!.hostId, 'pc');
    expect(roster.byId(old.id)!.hostId, 'pc');
    // An agent that has a computer keeps it.
    expect(roster.byId(boxAgent.id)!.hostId, 'box');
    expect(notified, 1);

    roster.assignHost('pc');
    expect(notified, 1, reason: 'nothing left to stamp');
  });

  test('a host list stamps its computer on new and unstamped agents', () {
    final roster = LocalAgentRosterSource(store: nextLaunch());
    final unstamped = roster.addAgent(name: 'old-one');
    roster.applyHostNames(
      <AgentsHostAgentName>[
        AgentsHostAgentName(agentId: unstamped.id, name: 'old-one'),
        const AgentsHostAgentName(agentId: 'agent-new', name: 'New'),
        const AgentsHostAgentName(agentId: 'host', name: 'Box', host: true),
      ],
      peerDeviceId: 'cowork-host',
      hostId: 'box',
      hostAgentId: 'host:cowork-host@box',
    );

    expect(roster.byId(unstamped.id)!.hostId, 'box');
    expect(roster.byId('agent-new')!.hostId, 'box');
    // The host entry renames this computer's own agent, not the plain id.
    expect(roster.byId('host:cowork-host'), isNull);
  });

  test('the host entry names the host agent of that computer', () {
    final roster = LocalAgentRosterSource(store: nextLaunch());
    roster.ensureHostAgent('cowork-host', hostId: 'pc');
    roster.ensureHostAgent(
      'cowork-host',
      hostId: 'box',
      agentId: 'host:cowork-host@box',
    );

    roster.applyHostNames(
      const <AgentsHostAgentName>[
        AgentsHostAgentName(agentId: 'host', name: 'Cloud agent', host: true),
      ],
      peerDeviceId: 'cowork-host',
      hostId: 'box',
      hostAgentId: 'host:cowork-host@box',
    );

    expect(roster.byId('host:cowork-host@box')!.name, 'Cloud agent');
    expect(roster.byId('host:cowork-host')!.name, isNot('Cloud agent'));
  });
}
