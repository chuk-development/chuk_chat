import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/services/automations/automation_ledger.dart';
import 'package:chuk_chat/services/automations/agents_automation.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';

/// The wire shapes of docs/WIRE_CONTRACT.md, "Automations", as the host
/// sends them: an `automation` event, an `automation_list` reply.
Map<String, dynamic> eventPayload({
  String event = 'created',
  String id = 'ab12cd34',
  String state = 'active',
  String kind = 'schedule',
  Map<String, dynamic> spec = const {'every': 300},
  int fireCount = 0,
  String? runId,
  String? reason,
  bool replay = false,
  int? mid,
}) =>
    <String, dynamic>{
      'type': 'automation',
      'event': event,
      'id': id,
      'session_key': 'thread-1',
      'kind': kind,
      'name': 'inbox check',
      'spec': spec,
      'prompt': 'check the inbox',
      'state': state,
      'next_fire_at': 1788600000.5,
      'last_fired_at': 1788599700,
      'fire_count': fireCount,
      'suppressed_count': 2,
      'created_at': 1788599000,
      'at': 1788599700.25,
      'run_id': ?runId,
      'reason': ?reason,
      if (replay) 'replay': true,
      'mid': ?mid,
    };

void main() {
  group('AgentsAutomation.fromPayload', () {
    test('reads every field the host sends', () {
      final a = AgentsAutomation.fromPayload(eventPayload())!;
      expect(a.id, 'ab12cd34');
      expect(a.sessionKey, 'thread-1');
      expect(a.kind, 'schedule');
      expect(a.name, 'inbox check');
      expect(a.state, 'active');
      expect(a.spec, {'every': 300});
      expect(a.prompt, 'check the inbox');
      expect(a.nextFireAt,
          DateTime.fromMillisecondsSinceEpoch(1788600000500));
      expect(a.lastFiredAt,
          DateTime.fromMillisecondsSinceEpoch(1788599700000));
      expect(a.fireCount, 0);
      expect(a.suppressedCount, 2);
      expect(a.createdAt, DateTime.fromMillisecondsSinceEpoch(1788599000000));
      expect(a.isSchedule, isTrue);
      expect(a.isActive, isTrue);
      expect(a.isOver, isFalse);
      expect(a.lastError, isNull);
      expect(a.logPath, isNull);
    });

    test('a watcher carries its log path and a failed one its error', () {
      final a = AgentsAutomation.fromPayload(<String, dynamic>{
        ...eventPayload(kind: 'watcher', state: 'failed',
            spec: {'script_path': 'poll.py', 'restart': true}),
        'last_error': 'exit code 3',
        'log_path': '.agents/automations/ab12cd34.log',
      })!;
      expect(a.isWatcher, isTrue);
      expect(a.isOver, isTrue);
      expect(a.lastError, 'exit code 3');
      expect(a.logPath, '.agents/automations/ab12cd34.log');
      expect(a.specLabel, 'watch poll.py');
    });

    test('drops a payload without id or session', () {
      expect(AgentsAutomation.fromPayload({'type': 'automation'}), isNull);
      expect(AgentsAutomation.fromPayload({'id': 'x'}), isNull);
    });

    test('specLabel reads every spec shape', () {
      AgentsAutomation withSpec(Map<String, dynamic> spec) =>
          AgentsAutomation.fromPayload(eventPayload(spec: spec))!;
      expect(withSpec({'every': 300}).specLabel, 'every 5m');
      expect(withSpec({'every': 7200}).specLabel, 'every 2h');
      expect(withSpec({'every': 86400}).specLabel, 'every 1d');
      expect(withSpec({'every': 90}).specLabel, 'every 90s');
      expect(withSpec({'cron': '0 9 * * 1-5'}).specLabel, 'cron 0 9 * * 1-5');
      expect(withSpec({'at': 'not a date'}).specLabel, 'at not a date');
      expect(withSpec({'at': '2030-01-02T03:04:00+00:00'}).specLabel,
          startsWith('at 2030-01-0'));
    });

    test('toJson round-trips through fromPayload', () {
      final a = AgentsAutomation.fromPayload(eventPayload())!;
      final again = AgentsAutomation.fromPayload(a.toJson())!;
      expect(again, a);
      expect(again.nextFireAt, a.nextFireAt);
    });
  });

  group('AgentsRelayAutomation.fromPayload', () {
    test('wraps the automation with the event, run and reason', () {
      final e = AgentsRelayAutomation.fromPayload(
        eventPayload(event: 'fired', runId: 'run-9', reason: 'new video',
            fireCount: 1, replay: true, mid: 42),
      )!;
      expect(e.event, 'fired');
      expect(e.runId, 'run-9');
      expect(e.reason, 'new video');
      expect(e.replay, isTrue);
      expect(e.mid, 42);
      expect(e.at, DateTime.fromMillisecondsSinceEpoch(1788599700250));
      expect(e.automation.fireCount, 1);
    });

    test('a live event has no replay and no mid; no event name reads updated',
        () {
      final e = AgentsRelayAutomation.fromPayload(
        <String, dynamic>{...eventPayload()}..remove('event'),
      )!;
      expect(e.event, 'updated');
      expect(e.replay, isFalse);
      expect(e.mid, isNull);
      expect(e.runId, isNull);
    });

    test('a payload naming no automation is dropped', () {
      expect(AgentsRelayAutomation.fromPayload({'type': 'automation'}), isNull);
    });
  });

  group('AgentsRelayAutomationList.fromPayload', () {
    test('reads the entries and the scope', () {
      final list = AgentsRelayAutomationList.fromPayload(<String, dynamic>{
        'type': 'automation_list',
        'session_key': 'thread-1',
        'automations': [
          eventPayload(),
          eventPayload(id: 'ffff0000', kind: 'watcher'),
          {'garbage': true},
        ],
      });
      expect(list.sessionKey, 'thread-1');
      expect(list.automations.map((a) => a.id), ['ab12cd34', 'ffff0000']);
    });

    test('no scope and no entries is the whole host, empty', () {
      final list = AgentsRelayAutomationList.fromPayload({'type': 'automation_list'});
      expect(list.sessionKey, isNull);
      expect(list.automations, isEmpty);
    });
  });

  group('automationCallFromRelay', () {
    AgentsRelayAutomation relay(Map<String, dynamic> payload) =>
        AgentsRelayAutomation.fromPayload(payload)!;

    test('opens one running line and updates it in place, last event wins',
        () {
      final created = automationCallFromRelay(null, relay(eventPayload()));
      expect(created.name, 'automation');
      expect(created.status, ToolCallStatus.running);
      expect(created.arguments['id'], 'ab12cd34');
      expect(created.arguments['spec'], 'every 5m');
      expect(created.result, 'Scheduled: inbox check (every 5m)');

      final fired = automationCallFromRelay(
        created,
        relay(eventPayload(event: 'fired', runId: 'run-1', reason: 'due',
            fireCount: 1)),
      );
      expect(identical(fired, created), isTrue);
      expect(fired.arguments['event'], 'fired');
      expect(fired.arguments['run_id'], 'run-1');
      expect(fired.arguments['fire_count'], 1);
      expect(fired.result, 'Fired: inbox check (every 5m) — due');
      expect(fired.status, ToolCallStatus.running);
    });

    test('a cancelled automation closes the line, a failed one errors it', () {
      final cancelled = automationCallFromRelay(
        null,
        relay(eventPayload(event: 'cancelled', state: 'done')),
      );
      expect(cancelled.status, ToolCallStatus.completed);
      expect(cancelled.completedAt,
          DateTime.fromMillisecondsSinceEpoch(1788599700250));
      expect(cancelled.result, 'Cancelled: inbox check (every 5m)');

      final failed = automationCallFromRelay(
        null,
        relay(<String, dynamic>{
          ...eventPayload(event: 'failed', state: 'failed', kind: 'watcher',
              spec: {'script_path': 'poll.py'}),
          'last_error': 'crashed 11 times',
        }),
      );
      expect(failed.status, ToolCallStatus.error);
      expect(failed.result, 'Failed: inbox check (watch poll.py) — crashed 11 times');
    });

    test('every event has a line of text', () {
      for (final event in ['created', 'fired', 'paused', 'resumed', 'cancelled', 'failed', 'done', 'odd']) {
        final text = automationEventText(relay(eventPayload(event: event)));
        expect(text, isNotEmpty, reason: event);
        expect(text, contains('inbox check'));
      }
      expect(
        automationEventText(relay(eventPayload(kind: 'watcher', spec: {'script_path': 'w.py'}))),
        'Watcher started: inbox check (watch w.py)',
      );
    });
  });
}
