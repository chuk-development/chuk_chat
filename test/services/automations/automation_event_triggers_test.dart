import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/automations/agents_automation.dart';
import 'package:chuk_chat/services/automations/automation_ledger.dart';
import 'package:chuk_chat/services/automations/automations_source.dart';

import 'automations_source_test.dart' show FakeAutomationController;

/// The test double plus the two frames of the create / edit sheet.
class FakeEditController extends FakeAutomationController
    implements AgentsAutomationEditControl {
  final List<Map<String, dynamic>> creates = <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> updates = <Map<String, dynamic>>[];

  @override
  Future<void> sendAutomationCreate(Map<String, dynamic> frame) async {
    if (sendError != null) throw sendError!;
    creates.add(frame);
  }

  @override
  Future<void> sendAutomationUpdate(Map<String, dynamic> frame) async {
    if (sendError != null) throw sendError!;
    updates.add(frame);
  }
}

Map<String, dynamic> row(
  String id, {
  String kind = 'watch_url',
  Map<String, dynamic>? spec,
  String notify = 'on_change',
  String? summary,
  int unchanged = 0,
}) => <String, dynamic>{
  'id': id,
  'session_key': 'thread-1',
  'kind': kind,
  'name': 'price $id',
  'state': 'active',
  'spec': spec ?? <String, dynamic>{'url': 'https://shop.example/p', 'every': 3600},
  'prompt': 'tell me the price',
  'notify': notify,
  'last_summary': ?summary,
  if (unchanged > 0) 'unchanged_count': unchanged,
  'next_fire_at': 1759700000.0,
};

void main() {
  group('AgentsAutomation event fields', () {
    test('reads notify, last result and the new kinds', () {
      final a = AgentsAutomation.fromPayload(
        row('w1', summary: 'price 129 EUR', unchanged: 3),
      )!;
      expect(a.isWatchUrl, isTrue);
      expect(a.trigger, 'page');
      expect(a.notifiesOnChange, isTrue);
      expect(a.lastSummary, 'price 129 EUR');
      expect(a.unchangedCount, 3);
      expect(a.watchedUrl, 'https://shop.example/p');
      expect(a.everySeconds, 3600);
      expect(a.specLabel, 'shop.example · every 1h');
      expect(a.toJson()['notify'], 'on_change');
      expect(a.toJson()['unchanged_count'], 3);
    });

    test('an old row reads as notify always', () {
      final a = AgentsAutomation.fromPayload(<String, dynamic>{
        'id': 's1',
        'session_key': 'k',
        'kind': 'schedule',
        'spec': {'cron': '0 9 * * 1-5'},
      })!;
      expect(a.notify, 'always');
      expect(a.trigger, 'clock');
      expect(a.scheduleText, '0 9 * * 1-5');
    });

    test('mail and schedule labels and texts', () {
      final mail = AgentsAutomation.fromPayload(
        row(
          'm1',
          kind: 'mail',
          spec: <String, dynamic>{'from': 'bank', 'subject': 'invoice'},
        ),
      )!;
      expect(mail.trigger, 'mail');
      expect(mail.mailFrom, 'bank');
      expect(mail.mailSubject, 'invoice');
      expect(mail.specLabel, 'from bank · subject "invoice"');
      final every = AgentsAutomation.fromPayload(
        row('e1', kind: 'schedule', spec: <String, dynamic>{'every': 1800}),
      )!;
      expect(every.scheduleText, 'every 30m');
      final at = AgentsAutomation.fromPayload(
        row(
          'a1',
          kind: 'schedule',
          spec: <String, dynamic>{'at': '2026-10-06T09:00'},
        ),
      )!;
      expect(at.scheduleText, 'at 2026-10-06T09:00');
      final watcher = AgentsAutomation.fromPayload(
        row(
          'x1',
          kind: 'watcher',
          spec: <String, dynamic>{'script_path': 'poll.py'},
        ),
      )!;
      expect(watcher.trigger, 'script');
      expect(watcher.scheduleText, isNull);
    });
  });

  group('frames', () {
    test('create carries kind, spec, prompt, name and notify', () {
      final frame = automationCreateFrame(
        sessionKey: 'thread-1',
        kind: 'watch_url',
        spec: automationSpecFor(
          'watch_url',
          url: ' https://a.example/x ',
          everySeconds: 900,
        ),
        prompt: ' check it ',
        name: '',
        notifyOnChange: true,
      );
      expect(frame, <String, dynamic>{
        'type': 'automation_create',
        'session_key': 'thread-1',
        'kind': 'watch_url',
        'spec': <String, dynamic>{'url': 'https://a.example/x', 'every': 900},
        'prompt': 'check it',
        'notify': 'on_change',
      });
      expect(automationSpecFor('schedule', schedule: ' every 1h '), 'every 1h');
      expect(
        automationSpecFor('mail', mailFrom: 'bank', mailSubject: ' '),
        <String, dynamic>{'from': 'bank'},
      );
    });

    test('update sends only what changed, null when nothing did', () {
      final before = AgentsAutomation.fromPayload(row('w1'))!;
      expect(
        automationUpdateFrame(
          before: before,
          spec: Map<String, dynamic>.of(before.spec),
          prompt: before.prompt,
          name: before.name,
          notifyOnChange: true,
        ),
        isNull,
      );
      final frame = automationUpdateFrame(
        before: before,
        spec: <String, dynamic>{'url': 'https://shop.example/p', 'every': 7200},
        prompt: before.prompt,
        name: before.name,
        notifyOnChange: false,
      );
      expect(frame, <String, dynamic>{
        'type': 'automation_update',
        'id': 'w1',
        'spec': <String, dynamic>{'url': 'https://shop.example/p', 'every': 7200},
        'notify': 'always',
      });
    });

    test('automation_saved reads a row or the host error', () {
      final ok = AutomationSaveResult.fromPayload(<String, dynamic>{
        'type': 'automation_saved',
        'ok': true,
        'automation': row('w9'),
      });
      expect(ok.ok, isTrue);
      expect(ok.automation!.id, 'w9');
      final bad = AutomationSaveResult.fromPayload(<String, dynamic>{
        'type': 'automation_saved',
        'ok': false,
        'error': 'every must be at least 900 seconds',
      });
      expect(bad.ok, isFalse);
      expect(bad.error, 'every must be at least 900 seconds');
    });
  });

  group('card reducer', () {
    test('result and updated events get their own lines and tag the run', () {
      final created = AgentsRelayAutomation.fromPayload(
        <String, dynamic>{...row('w1'), 'event': 'created'},
      )!;
      final call = automationCallFromRelay(null, created);
      expect(call.result, startsWith('Watching a page: '));
      final edited = AgentsRelayAutomation.fromPayload(
        <String, dynamic>{...row('w1'), 'event': 'updated'},
      )!;
      automationCallFromRelay(call, edited);
      expect(call.result, startsWith('Edited: '));
      final quiet = AgentsRelayAutomation.fromPayload(<String, dynamic>{
        ...row('w1', unchanged: 2),
        'event': 'result',
        'run_id': 'run-7',
        'changed': false,
        'summary': 'price 129 EUR',
        'reported': true,
      })!;
      expect(quiet.isQuietResult, isTrue);
      automationCallFromRelay(call, quiet);
      expect(call.result, endsWith('— price 129 EUR'));
      expect(call.result, startsWith('No change: '));
      expect(call.arguments['run_id'], 'run-7');
      expect(call.arguments['changed'], isFalse);
      expect(call.arguments['summary'], 'price 129 EUR');
      expect(call.arguments['unchanged_count'], 2);
      expect(call.status, ToolCallStatus.running);
      final unreported = AgentsRelayAutomation.fromPayload(<String, dynamic>{
        ...row('w1'),
        'event': 'result',
        'run_id': 'run-8',
        'changed': true,
        'reported': false,
      })!;
      automationCallFromRelay(call, unreported);
      expect(call.result, startsWith('Ran, no report: '));
      expect(call.arguments.containsKey('summary'), isFalse);
    });
  });

  group('AutomationsSource create / update', () {
    final source = AutomationsSource.instance;
    late FakeEditController controller;
    final savedBefore = AgentsRelayClient.automationSavedSink;
    final doneBefore = AgentsRelayClient.automationDoneSink;

    setUp(() {
      source.reset();
      AgentsRelayLink.instance.reset();
      controller = FakeEditController();
      AgentsRelayLink.instance.bind(controller);
      source.attach();
    });

    tearDown(() {
      source.reset();
      AgentsRelayLink.instance.reset();
      AgentsRelayClient.automationSavedSink = savedBefore;
      AgentsRelayClient.automationDoneSink = doneBefore;
    });

    test('create waits for automation_saved and stores the row', () async {
      final future = source.create(
        sessionKey: 'thread-1',
        kind: 'mail',
        spec: <String, dynamic>{'from': 'bank'},
        prompt: 'read it',
        notifyOnChange: true,
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.creates.single['kind'], 'mail');
      expect(controller.creates.single['notify'], 'on_change');
      AgentsRelayClient.automationSavedSink!(<String, dynamic>{
        'type': 'automation_saved',
        'ok': true,
        'automation': row('m1', kind: 'mail'),
      });
      final result = await future;
      expect(result.ok, isTrue);
      expect(source.byId('m1'), isNotNull);
    });

    test('a refusal comes back in the host words', () async {
      final future = source.update(<String, dynamic>{
        'type': 'automation_update',
        'id': 'w1',
        'spec': <String, dynamic>{'url': 'http://10.0.0.1', 'every': 900},
      });
      await Future<void>.delayed(Duration.zero);
      expect(controller.updates.single['id'], 'w1');
      AgentsRelayClient.automationSavedSink!(<String, dynamic>{
        'type': 'automation_saved',
        'ok': false,
        'error': 'the url points into a private network',
      });
      final result = await future;
      expect(result.ok, isFalse);
      expect(result.error, 'the url points into a private network');
    });

    test('no answer times out with a plain failure', () async {
      final before = AutomationsSource.saveTimeout;
      AutomationsSource.saveTimeout = const Duration(milliseconds: 10);
      addTearDown(() => AutomationsSource.saveTimeout = before);
      final result = await source.create(
        sessionKey: 'thread-1',
        kind: 'schedule',
        spec: 'every 1h',
        prompt: 'x',
      );
      expect(result.ok, isFalse);
      expect(result.error, contains('did not answer'));
    });

    test('a send error fails at once', () async {
      controller.sendError = StateError('closed');
      final result = await source.create(
        sessionKey: 'thread-1',
        kind: 'schedule',
        spec: 'every 1h',
        prompt: 'x',
      );
      expect(result.ok, isFalse);
      expect(result.error, contains('Could not reach the host'));
    });

    test('quiet runs from the live done and from the result event', () async {
      AgentsRelayClient.automationDoneSink!(<String, dynamic>{
        'type': 'done',
        'run_id': 'run-1',
        'host_notified': true,
        'automation_result': {'changed': false, 'summary': 'price 129 EUR'},
      });
      expect(source.isQuietRun('run-1'), isTrue);
      expect(source.quietRunSummary('run-1'), 'price 129 EUR');
      AgentsRelayClient.automationDoneSink!(<String, dynamic>{
        'type': 'done',
        'run_id': 'run-2',
        'automation_result': {'changed': true, 'summary': 'price 99 EUR'},
      });
      expect(source.isQuietRun('run-2'), isFalse);
      controller.emit(
        AgentsRelayAutomation.fromPayload(<String, dynamic>{
          ...row('w1'),
          'event': 'result',
          'run_id': 'run-3',
          'changed': false,
          'summary': 'same',
        })!,
      );
      await Future<void>.delayed(Duration.zero);
      expect(source.quietRunSummary('run-3'), 'same');
    });
  });
}
