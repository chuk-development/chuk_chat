import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/services/agents/agent_roster_source.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart'
    show AgentsHostAgentName;
import 'package:chuk_chat/services/agents/roster_pins.dart';

AgentsAgent _agent(String id, {DateTime? lastActivity}) => AgentsAgent(
  id: id,
  name: id,
  threads: const [],
  lastActivity: lastActivity,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    RosterPins.instance.reset();
  });

  group('RosterPins', () {
    test('a toggle pins, a second unpins', () async {
      await RosterPins.instance.load();
      expect(RosterPins.instance.isPinned('a'), isFalse);

      RosterPins.instance.toggle('a');
      expect(RosterPins.instance.isPinned('a'), isTrue);

      RosterPins.instance.toggle('a');
      expect(RosterPins.instance.isPinned('a'), isFalse);
    });

    test('pins survive a restart from the local store', () async {
      await RosterPins.instance.load();
      RosterPins.instance.toggle('a');
      RosterPins.instance.toggle('b');

      // A new instance reads the same disk. (The singleton keeps its state,
      // so the restart is modelled by resetting and loading again — the store
      // behind SharedPreferences keeps the rows.)
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('agents.roster.pinned_v1'), isNotNull);
    });

    test('an unpinned set stays an unpinned set after a restart', () async {
      await RosterPins.instance.load();
      RosterPins.instance.toggle('a');
      RosterPins.instance.toggle('a');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('agents.roster.pinned_v1'), '[]');
    });

    test('a forced load keeps the pins', () async {
      await RosterPins.instance.load();
      RosterPins.instance.toggle('a');
      // Let the unawaited local save land.
      await Future<void>.delayed(Duration.zero);

      await RosterPins.instance.load(force: true);
      expect(RosterPins.instance.isPinned('a'), isTrue);
    });
  });

  group('rosterPinOrder', () {
    test('pinned first, each group keeping the roster order', () {
      final a = _agent('a');
      final b = _agent('b');
      final c = _agent('c');
      final d = _agent('d');

      final ordered = rosterPinOrder(<AgentsAgent>[a, b, c, d], <String>{'c', 'a'});

      expect(ordered.map((x) => x.id).toList(), <String>['a', 'c', 'b', 'd']);
    });

    test('no pins is the roster order itself', () {
      final a = _agent('a');
      final b = _agent('b');
      expect(rosterPinOrder(<AgentsAgent>[b, a], <String>{}).map((x) => x.id),
          <String>['b', 'a']);
    });

    // Bead chuk_chat-41k1: the phone sorted by activity, the desktop kept
    // creation order, so the chat used last sat at the top of one and the
    // bottom of the other. Both read this one function now.
    test('unpinned rows are newest activity first, the pinned stay on top', () {
      final old = _agent('old', lastActivity: DateTime.utc(2026, 9, 1));
      final pinned = _agent('pinned', lastActivity: DateTime.utc(2026, 1, 1));
      final never = _agent('never');
      final fresh = _agent('fresh', lastActivity: DateTime.utc(2026, 10, 19));

      final ordered = rosterPinOrder(
        <AgentsAgent>[old, pinned, never, fresh],
        <String>{'pinned'},
      );

      expect(ordered.map((x) => x.id).toList(), <String>[
        'pinned',
        'fresh',
        'old',
        'never',
      ]);
    });

    test('ties keep the roster order, also for long lists', () {
      final same = DateTime.utc(2026, 10, 19);
      final agents = <AgentsAgent>[
        for (var i = 0; i < 40; i++)
          _agent('a$i', lastActivity: i.isEven ? same : null),
      ];
      final ids = rosterPinOrder(agents, <String>{}).map((x) => x.id).toList();
      expect(ids, <String>[
        for (var i = 0; i < 40; i += 2) 'a$i',
        for (var i = 1; i < 40; i += 2) 'a$i',
      ]);
    });
  });

  group('compareByLastActivity', () {
    test('newest first', () {
      final old1 = _agent('old', lastActivity: DateTime.utc(2026, 1, 1));
      final new1 = _agent('new', lastActivity: DateTime.utc(2026, 10, 19));
      expect(compareByLastActivity(new1, old1), isNegative);
      expect(compareByLastActivity(old1, new1), isPositive);
    });

    test('a chat with no activity sinks below a dated one', () {
      final fresh = _agent('fresh', lastActivity: DateTime.utc(2026, 10, 19));
      final never = _agent('never');
      expect(compareByLastActivity(never, fresh), isPositive);
      expect(compareByLastActivity(fresh, never), isNegative);
    });

    test('two without activity tie', () {
      expect(compareByLastActivity(_agent('x'), _agent('y')), 0);
    });
  });

  group('agentsMissingOnHost', () {
    AgentsHostAgentName listed(String id) =>
        AgentsHostAgentName(agentId: id, name: id);

    test('names the app-made agents the host list lacks', () {
      final mail = _agent('local:Mail:14:1');
      final known = _agent('local:saffron:15:2');
      final host = AgentsAgent(
        id: 'host:dev',
        name: 'Your computer',
        onHost: true,
        threads: const <AgentsThreadInfo>[],
      );

      final missing = agentsMissingOnHost(
        <AgentsAgent>[host, mail, known],
        <AgentsHostAgentName>[
          listed('local:saffron:15:2'),
          const AgentsHostAgentName(agentId: '', name: 'Host', host: true),
        ],
      );

      expect(missing.map((a) => a.id), <String>['local:Mail:14:1']);
    });

    test('skips the ids it is told to skip', () {
      final mail = _agent('local:Mail:14:1');
      expect(
        agentsMissingOnHost(
          <AgentsAgent>[mail],
          const <AgentsHostAgentName>[],
          skip: <String>{'local:Mail:14:1'},
        ),
        isEmpty,
      );
    });
  });
}
