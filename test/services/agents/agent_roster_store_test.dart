// The cold-start half of the offline cache (bead cowork-91pn): the roster is
// a CACHE of host truth, so it must survive a restart, it must be overwritten
// wholesale by an `agent_list`, and a deleted coworker must never come back.

import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/services/agents/agent_roster_source.dart';
import 'package:chuk_chat/services/agents/agent_roster_store.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart'
    show AgentsHostAgentName;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  /// A fresh store on the same preferences — the next launch of the app.
  AgentRosterStore nextLaunch() => AgentRosterStore(prefsKey: 'roster_test_v1');

  test('the roster is on disk before the socket exists', () async {
    final first = LocalAgentRosterSource(store: nextLaunch());
    await first.load();
    first.ensureHostAgent('peer-1');
    final created = first.addAgent(name: 'amber-otter');
    await nextLaunch().flush();

    final second = LocalAgentRosterSource(store: nextLaunch());
    expect(second.agents, isEmpty);
    await second.load();

    expect(second.agents.map((a) => a.id), <String>[
      'host:peer-1',
      created.id,
    ]);
    final host = second.byId('host:peer-1')!;
    expect(host.name, 'peer-1');
    expect(host.onHost, isTrue);
    // The one permanent session per bot rides along, so selecting the
    // coworker opens the very thread the transcript is cached under.
    expect(host.threads.single.key, 'host:peer-1');
    expect(host.threads.single.title, 'General');
    expect(second.byId(created.id)!.onHost, isFalse);
  });

  test('a hidden coworker is still hidden on the next launch', () async {
    final first = LocalAgentRosterSource(store: nextLaunch());
    await first.load();
    final agent = first.addAgent(name: 'jade-lynx');
    first.hideAgent(agent.id);
    await nextLaunch().flush();

    final second = LocalAgentRosterSource(store: nextLaunch());
    await second.load();
    expect(second.hiddenIds, <String>{agent.id});
    expect(second.visibleAgents, isEmpty);
    expect(second.hiddenAgents.single.id, agent.id);
  });

  test('a received agent_list overwrites the persisted roster', () async {
    final first = LocalAgentRosterSource(store: nextLaunch());
    await first.load();
    final agent = first.addAgent(name: 'old-name');
    await nextLaunch().flush();

    final second = LocalAgentRosterSource(store: nextLaunch());
    await second.load();
    expect(second.byId(agent.id)!.name, 'old-name');

    // The host is the truth. Its list renames the coworker and adds one the
    // cache never held; the snapshot is rewritten from the result.
    second.applyHostNames(<AgentsHostAgentName>[
      AgentsHostAgentName(agentId: agent.id, name: 'host-name'),
      const AgentsHostAgentName(agentId: 'agent-2', name: 'cobalt-tern'),
    ], peerDeviceId: null);
    await nextLaunch().flush();

    final third = LocalAgentRosterSource(store: nextLaunch());
    await third.load();
    expect(third.byId(agent.id)!.name, 'host-name');
    expect(third.byId('agent-2')!.name, 'cobalt-tern');
    expect(third.agents, hasLength(2));
  });

  test('a deleted coworker does not come back', () async {
    final first = LocalAgentRosterSource(store: nextLaunch());
    await first.load();
    final agent = first.addAgent(name: 'sable-wren');
    first.removeAgent(agent.id);
    expect(first.deletedIds, contains(agent.id));
    await nextLaunch().flush();

    final second = LocalAgentRosterSource(store: nextLaunch());
    await second.load();
    expect(second.byId(agent.id), isNull);
    // The delete outlives the launch it was made in, so the shell's ignore
    // set starts with it and the host's list cannot resurrect the coworker.
    expect(second.deletedIds, contains(agent.id));
    second.applyHostNames(<AgentsHostAgentName>[
      AgentsHostAgentName(agentId: agent.id, name: 'sable-wren'),
    ], peerDeviceId: null, ignore: second.deletedIds);
    expect(second.byId(agent.id), isNull);
    expect(second.agents, isEmpty);
  });

  test('a snapshot without threads still opens a conversation', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'roster_test_v1':
          '{"agents":[{"id":"agent-9","name":"quiet-vole"}],"deleted":[]}',
    });
    final source = LocalAgentRosterSource(store: nextLaunch());
    await source.load();
    final agent = source.byId('agent-9')!;
    expect(agent.threads.single.key, 'agent-9');
  });

  test('an unreadable snapshot is an empty roster, not a crash', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'roster_test_v1': 'not json',
    });
    final source = LocalAgentRosterSource(store: nextLaunch());
    await source.load();
    expect(source.agents, isEmpty);
    expect(source.deletedIds, isEmpty);
  });

  test('a load never undoes what the pairing already put in the roster', () async {
    final first = LocalAgentRosterSource(store: nextLaunch());
    await first.load();
    first.addAgent(name: 'amber-otter');
    await nextLaunch().flush();

    // The pairing lands before the (slower) preferences read.
    final second = LocalAgentRosterSource(store: nextLaunch());
    final host = second.ensureHostAgent('peer-2');
    await second.load();
    expect(second.byId(host.id), isNotNull);
    expect(second.agents, hasLength(2));
    expect(
      second.agents.where((AgentsAgent a) => a.id == host.id),
      hasLength(1),
    );
  });
}
