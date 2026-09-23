import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/automations/automations_source.dart';
import 'package:chuk_chat/services/automations/agents_automation.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';

import '../../support/fake_relay_controller.dart';

/// The shared test double, plus the two automation frames the source sends.
class FakeAutomationController extends FakeRelayController
    implements AgentsAutomationControl {
  final List<(String, String)> controls = <(String, String)>[];
  final List<String?> listRequests = <String?>[];
  Object? sendError;

  @override
  Future<void> sendAutomationControl({
    required String id,
    required String action,
  }) async {
    if (sendError != null) throw sendError!;
    controls.add((id, action));
  }

  @override
  Future<void> requestAutomationList({String? sessionKey}) async {
    if (sendError != null) throw sendError!;
    listRequests.add(sessionKey);
  }
}

AgentsAutomation automation(String id, {String session = 'thread-1', String state = 'active', double created = 1.0}) =>
    AgentsAutomation.fromPayload(<String, dynamic>{
      'id': id,
      'session_key': session,
      'kind': 'schedule',
      'name': id,
      'state': state,
      'spec': {'every': 300},
      'created_at': created,
    })!;

void main() {
  final source = AutomationsSource.instance;
  late FakeAutomationController controller;

  setUp(() {
    source.reset();
    AgentsRelayLink.instance.reset();
    controller = FakeAutomationController();
    AgentsRelayLink.instance.bind(controller);
    source.attach();
  });

  tearDown(() {
    source.reset();
    AgentsRelayLink.instance.reset();
  });

  test('an automation event lands in the map and notifies', () {
    var notified = 0;
    source.addListener(() => notified++);
    controller.emit(AgentsRelayAutomation(event: 'created', automation: automation('a1')));
    expect(notified, 1);
    expect(source.byId('a1')?.state, 'active');
    expect(source.forSession('thread-1').map((a) => a.id), ['a1']);
    expect(source.forSession('other'), isEmpty);
  });

  test('the last event wins per id; done ones leave the live list', () {
    controller.emit(AgentsRelayAutomation(event: 'created', automation: automation('a1')));
    controller.emit(AgentsRelayAutomation(event: 'paused', automation: automation('a1', state: 'paused')));
    expect(source.liveForSession('thread-1').single.isPaused, isTrue);
    controller.emit(AgentsRelayAutomation(event: 'cancelled', automation: automation('a1', state: 'done')));
    expect(source.liveForSession('thread-1'), isEmpty);
    expect(source.forSession('thread-1').single.isOver, isTrue);
  });

  test('a list reply replaces its scope and marks it listed', () {
    controller.emit(AgentsRelayAutomation(event: 'created', automation: automation('gone')));
    controller.emit(AgentsRelayAutomation(event: 'created', automation: automation('keep', session: 'other')));
    expect(source.listed('thread-1'), isFalse);
    controller.emit(AgentsRelayAutomationList(
      sessionKey: 'thread-1',
      automations: [automation('a2', created: 5), automation('a3', created: 9)],
    ));
    expect(source.listed('thread-1'), isTrue);
    expect(source.listed('other'), isFalse);
    // Newest first; the other session's row survives a scoped reply.
    expect(source.all.map((a) => a.id), ['a3', 'a2', 'keep']);
    expect(source.byId('gone'), isNull);
    controller.emit(const AgentsRelayAutomationList(automations: []));
    expect(source.all, isEmpty);
    expect(source.listed(null), isTrue);
  });

  test('refresh and control go out through the bound controller', () async {
    expect(await source.refresh(sessionKey: 'thread-1'), isTrue);
    expect(await source.refresh(), isTrue);
    expect(controller.listRequests, ['thread-1', null]);
    expect(await source.control('a1', 'pause'), isTrue);
    expect(controller.controls, [('a1', 'pause')]);
  });

  test('a controller that cannot send, or none, answers false', () async {
    controller.sendError = StateError('down');
    expect(await source.control('a1', 'cancel'), isFalse);
    expect(await source.refresh(), isFalse);
    AgentsRelayLink.instance.reset();
    expect(await source.control('a1', 'cancel'), isFalse);
    // A plain FakeRelayController has no automation frames at all.
    AgentsRelayLink.instance.bind(FakeRelayController());
    expect(await source.refresh(), isFalse);
  });

  test('one row per automation: a restarted watcher folds into its live row', () {
    AgentsAutomation watcher(String id, String state, double created) =>
        AgentsAutomation.fromPayload(<String, dynamic>{
          'id': id,
          'session_key': 'thread-1',
          'kind': 'watcher',
          'name': 'Wahlradar',
          'state': state,
          'spec': {'script_path': 'monitor.py', 'restart': true},
          'created_at': created,
        })!;
    controller.emit(AgentsRelayAutomationList(automations: [
      watcher('old', 'done', 10),
      watcher('live', 'active', 20),
      automation('s1', created: 30),
    ]));
    expect(source.all.length, 3);
    expect(source.distinct.map((a) => a.id), ['s1', 'live']);
  });

  test('two rows of one state keep the newest', () {
    AgentsAutomation twin(String id, double created) =>
        AgentsAutomation.fromPayload(<String, dynamic>{
          'id': id,
          'session_key': 'thread-1',
          'kind': 'schedule',
          'name': 'daily report',
          'state': 'done',
          'spec': {'every': 300},
          'created_at': created,
        })!;
    controller.emit(AgentsRelayAutomationList(automations: [
      twin('older', 10),
      twin('newer', 20),
    ]));
    expect(source.distinct.map((a) => a.id), ['newer']);
  });

  test('a group is named the way the rest of the app names the coworker', () {
    expect(source.coworkerName('local:brisk-heron:2:116636868'), 'brisk-heron');
    expect(source.coworkerName('host:cowork-host'), 'cowork-host');
    expect(source.coworkerName('default'), 'Default coworker');
    expect(source.coworkerName('thread-1'), 'thread-1');
    controller.emit(const AgentsRelayAgentList(agents: [
      AgentsHostAgentName(agentId: 'host:cowork-host', name: 'Ivory Lynx', host: true),
    ]));
    expect(source.coworkerName('host:cowork-host'), 'Ivory Lynx');
  });
}

