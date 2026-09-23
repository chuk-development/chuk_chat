import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/agents/agents_replay_loader.dart';
import 'package:chuk_chat/services/agents/agents_run_ledger.dart';
import 'package:chuk_chat/services/storage/chat_origin.dart';

import '../../support/fake_relay_controller.dart';

/// A run that ends with nothing must END — visibly (bead cowork-gnr8).
///
/// The live evidence: run `d1d4ede1`, `state: finished`, `reason: interrupted`,
/// empty answer, never acknowledged. The thread kept the working dots and the
/// stop target for six minutes, because nothing on the app side closed the run
/// the ledger was still drawing.
///
/// The three guarantees pinned here are the three ways a run can end without an
/// answer: a terminal arrives, the host says the run is gone, or nothing at all
/// comes back.
void main() {
  // These tests model the Agents build: Agents threads take the Agents
  // store and queue (ChatOrigin). Tests run with FEATURE_AGENTS off.
  ChatOrigin.agentsEnabled = true;
  TestWidgetsFlutterBinding.ensureInitialized();

  const sessionKey = 'host:cowork-host';
  final ledger = AgentsRunLedger.instance;
  final loader = AgentsReplayLoader.instance;
  late FakeRelayController controller;

  final Duration ceiling = AgentsRunLedger.ceiling;
  final Duration ceilingGrace = AgentsRunLedger.ceilingGrace;
  final Duration stopGrace = AgentsRunLedger.stopGrace;
  final Duration idleHeaderGrace = AgentsRunLedger.idleHeaderGrace;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      kReplayRepeatRepairKey: true,
    });
    ledger.reset();
    loader.reset();
    AgentsRelayLink.instance.reset();
    await ChatStorageService.reset();
    controller = FakeRelayController();
    AgentsRelayLink.instance.bind(controller);
    AgentsRelayLink.instance.sessionKey.value = sessionKey;
    loader.attach();
  });

  tearDown(() async {
    AgentsRunLedger.ceiling = ceiling;
    AgentsRunLedger.ceilingGrace = ceilingGrace;
    AgentsRunLedger.stopGrace = stopGrace;
    AgentsRunLedger.idleHeaderGrace = idleHeaderGrace;
    ledger.reset();
    loader.reset();
    AgentsRelayLink.instance.reset();
    await ChatStorageService.reset();
  });

  group('a terminal that carries no answer', () {
    test('ends the run and says it was stopped', () {
      ledger.begin(sessionKey);
      expect(ledger.isRunning(sessionKey), isTrue);

      // What the host sent for run d1d4ede1.
      ledger.finish(sessionKey, reason: 'interrupted', finalAnswer: '');

      final run = ledger.runFor(sessionKey)!;
      expect(ledger.isRunning(sessionKey), isFalse, reason: 'the dots stop');
      expect(run.outcome, AgentsRunOutcome.stopped);
      expect(run.endedWithoutAnswer, isTrue);
      expect(
        agentsRunEndNotice(run.outcome!),
        'Stopped. No answer was written.',
      );
    });

    test('an error terminal reads as a failure, not as a stop', () {
      ledger.begin(sessionKey);
      ledger.finish(sessionKey, reason: 'failed');
      final run = ledger.runFor(sessionKey)!;
      expect(run.outcome, AgentsRunOutcome.failed);
      expect(agentsRunEndNotice(run.outcome!), contains('failed'));
    });

    test('a run that answered leaves no line behind', () {
      ledger.begin(sessionKey);
      ledger.finish(sessionKey, reason: 'finished', finalAnswer: 'here it is');
      final run = ledger.runFor(sessionKey)!;
      expect(run.outcome, AgentsRunOutcome.answered);
      expect(run.endedWithoutAnswer, isFalse);
      expect(agentsRunEndNotice(run.outcome!), isNull);
    });

    test('a streamed answer with no final_answer field still answered', () {
      ledger.begin(sessionKey);
      ledger.touch(sessionKey); // a token arrived
      ledger.finish(sessionKey, reason: 'finished');
      expect(ledger.runFor(sessionKey)!.outcome, AgentsRunOutcome.answered);
      expect(ledger.runFor(sessionKey)!.endedWithoutAnswer, isFalse);
    });

    test('a stop with no terminal at all still ends the run', () {
      ledger.begin(sessionKey);
      ledger.stopRequested(sessionKey);
      final asked = DateTime.now();

      ledger.sweep(now: asked.add(AgentsRunLedger.stopGrace * 0.5));
      expect(ledger.isRunning(sessionKey), isTrue, reason: 'still in grace');

      ledger.sweep(now: asked.add(AgentsRunLedger.stopGrace * 2));

      expect(ledger.isRunning(sessionKey), isFalse);
      expect(ledger.runFor(sessionKey)!.outcome, AgentsRunOutcome.stopped);
    });
  });

  group('reconnect', () {
    test('an idle host header clears a run this client started', () {
      AgentsRunLedger.idleHeaderGrace = Duration.zero;
      ledger.begin(sessionKey);
      expect(ledger.isRunning(sessionKey), isTrue);

      // The `run_state` header of the replay the app asks for on reconnect.
      ledger.reconcile(sessionKey, hostRunning: false);

      expect(ledger.isRunning(sessionKey), isFalse);
      expect(ledger.runFor(sessionKey)!.outcome, AgentsRunOutcome.lost);
    });

    test('a task submitted a moment ago survives a stale idle header', () {
      ledger.begin(sessionKey);
      ledger.reconcile(sessionKey, hostRunning: false);
      expect(
        ledger.isRunning(sessionKey),
        isTrue,
        reason: 'the header was computed before the task reached the host',
      );
    });

    test('a running host header keeps the run alive', () {
      AgentsRunLedger.idleHeaderGrace = Duration.zero;
      ledger.begin(sessionKey);
      ledger.reconcile(sessionKey, hostRunning: true);
      expect(ledger.isRunning(sessionKey), isTrue);
    });

    test('the replay header reconciles through the loader', () async {
      AgentsRunLedger.idleHeaderGrace = Duration.zero;
      ledger.begin(sessionKey);

      loader.expect(sessionKey, afterId: 0);
      controller.emit(
        const AgentsRelayRunState(sessionKey: sessionKey, state: 'idle'),
      );
      await _drain();

      expect(ledger.isRunning(sessionKey), isFalse);
    });
  });

  group('the ceiling', () {
    test('a silent run is asked about, then declared lost', () {
      final asked = <String>[];
      ledger.onRunSilent = asked.add;
      final start = DateTime.now();
      ledger.begin(sessionKey);

      // Still inside the ceiling: nothing is asked and nothing is accused.
      ledger.sweep(now: start.add(AgentsRunLedger.ceiling * 0.5));
      expect(asked, isEmpty);
      expect(ledger.isRunning(sessionKey), isTrue);

      // Past the ceiling: ask the host before accusing it.
      final probe = start.add(AgentsRunLedger.ceiling * 1.1);
      ledger.sweep(now: probe);
      expect(asked, <String>[sessionKey]);
      expect(ledger.isRunning(sessionKey), isTrue);

      // Nothing answered within the grace: the app lost the run.
      ledger.sweep(now: probe.add(AgentsRunLedger.ceilingGrace * 1.1));
      expect(ledger.isRunning(sessionKey), isFalse);
      expect(ledger.runFor(sessionKey)!.outcome, AgentsRunOutcome.lost);
      expect(
        agentsRunEndNotice(ledger.runFor(sessionKey)!.outcome!),
        'Lost this run. No answer came back.',
      );
      expect(asked, hasLength(1), reason: 'asked once, not once per tick');
    });

    test('a run that keeps working is never declared lost', () {
      final start = DateTime.now();
      ledger.begin(sessionKey);
      var clock = start;
      for (var i = 0; i < 6; i++) {
        clock = clock.add(AgentsRunLedger.ceiling * 0.5);
        ledger.touch(sessionKey);
        ledger.sweep(now: clock);
      }
      expect(ledger.isRunning(sessionKey), isTrue);
    });

    test('a host that answers the probe revives the run', () {
      final start = DateTime.now();
      ledger.begin(sessionKey);
      ledger.sweep(now: start.add(AgentsRunLedger.ceiling * 1.1));
      expect(ledger.runFor(sessionKey)!.probedAt, isNotNull);

      // The `run_state: running` header of the replay the probe asked for.
      ledger.reconcile(sessionKey, hostRunning: true);
      expect(ledger.runFor(sessionKey)!.probedAt, isNull);

      ledger.sweep(now: start.add(AgentsRunLedger.ceiling * 1.2));
      expect(ledger.isRunning(sessionKey), isTrue);
    });

    test('a terminal takes the run out of the sweep', () {
      var asked = 0;
      ledger.onRunSilent = (_) => asked++;
      final start = DateTime.now();
      ledger.begin(sessionKey);
      ledger.finish(sessionKey, reason: 'finished', finalAnswer: 'done');
      ledger.sweep(now: start.add(AgentsRunLedger.ceiling * 10));
      expect(asked, 0);
      expect(ledger.runFor(sessionKey)!.outcome, AgentsRunOutcome.answered);
    });
  });

  group('the line in the thread', () {
    test('a replayed stop terminal leaves the same line', () async {
      loader.expect(sessionKey, afterId: 0);
      controller
        ..emit(const AgentsRelayRunState(sessionKey: sessionKey, state: 'idle'))
        ..emit(const AgentsRelayUser('do the thing', mid: 1))
        ..emit(
          const AgentsRelayDone(reason: 'interrupted', replay: true, runId: 'r'),
        )
        ..emit(const AgentsRelayDone(reason: 'replay', replay: true));
      await _drain();

      final rows = _rowsFor(sessionKey);
      expect(rows, hasLength(2));
      expect(rows[1]['role'], 'ai');
      expect(rows[1]['text'], 'Stopped. No answer was written.');
      expect(
        rows[1]['status'],
        'interrupted',
        reason: 'the bubble offers to ask again',
      );
    });

    test('a replayed answer is never overwritten by a line', () async {
      loader.expect(sessionKey, afterId: 0);
      controller
        ..emit(const AgentsRelayUser('do the thing', mid: 1))
        ..emit(const AgentsRelayDelta('half an answer', replay: true, mid: 2))
        ..emit(const AgentsRelayDone(reason: 'interrupted', replay: true))
        ..emit(const AgentsRelayDone(reason: 'replay', replay: true));
      await _drain();

      final rows = _rowsFor(sessionKey);
      expect(rows[1]['text'], 'half an answer');
    });

    test('the live line is appended once, not on every reconcile', () async {
      await ChatStorageService.saveChat(<Map<String, dynamic>>[
        <String, dynamic>{'sender': 'user', 'text': 'do the thing'},
      ], chatId: sessionKey);

      await loader.appendNotice(sessionKey, 'Stopped. No answer was written.');
      await loader.appendNotice(sessionKey, 'Stopped. No answer was written.');

      final rows = _rowsFor(sessionKey);
      expect(rows, hasLength(2));
      expect(rows.last['text'], 'Stopped. No answer was written.');
      expect(rows.last['status'], 'interrupted');
    });
  });
}

List<Map<String, dynamic>> _rowsFor(String session) {
  final chat = ChatStorageService.getChatById(session);
  if (chat == null || !chat.isFullyLoaded) return const [];
  return chat.messages.map((m) => m.toJson()).toList();
}

Future<void> _drain() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
