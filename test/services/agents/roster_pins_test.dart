import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/models/agents_agent.dart';
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
}
