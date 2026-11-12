// CHAT-64: the host retries a failed model call itself (`heartbeat.retry`).
// The thread shows a quiet line with the wait, never a Resend.

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_run_ledger.dart';
import 'package:chuk_chat/services/agents/agents_turn_phase.dart';

void main() {
  const key = 'thread-1';
  final ledger = AgentsRunLedger.instance;

  setUp(ledger.reset);
  tearDown(ledger.reset);

  AgentsTurnStatus? statusNow() =>
      agentsTurnStatusFor(run: ledger.runFor(key), linkUp: true);

  test('the retry object of a heartbeat is read', () {
    final AgentsHostRetry? retry = AgentsHostRetry.fromPayload(<String, Object>{
      'attempt': 2,
      'in': 58.0,
      'reason': 'HTTP 503',
      'gives_up_in': 1680.0,
    });
    expect(retry?.attempt, 2);
    expect(retry?.inSeconds, 58.0);
    expect(retry?.reason, 'HTTP 503');
    expect(retry?.givesUpInSeconds, 1680.0);
    expect(AgentsHostRetry.fromPayload(null), isNull);
    expect(AgentsHostRetry.fromPayload(<String, Object>{'attempt': 1}), isNull);
  });

  test('a retrying run says the provider does not answer, with the wait', () {
    ledger.begin(key);
    ledger.heartbeat(key);
    ledger.hostPhase(
      key,
      phase: 'retrying',
      retry: const AgentsHostRetry(attempt: 1, inSeconds: 30),
    );
    final AgentsTurnStatus? status = statusNow();
    expect(status?.phase, AgentsTurnPhase.retrying);
    expect(status?.retryInSeconds, inInclusiveRange(29, 30));
    expect(
      status?.label(),
      startsWith('Provider not answering, trying again in'),
    );
    // The host keeps going alone: the line offers nothing to press.
    expect(status?.offersRetry, isFalse);
  });

  test('every beat with a smaller wait updates the line', () {
    ledger.begin(key);
    var notified = 0;
    void count() => notified++;
    ledger.addListener(count);
    addTearDown(() => ledger.removeListener(count));
    ledger.hostPhase(
      key,
      phase: 'retrying',
      retry: const AgentsHostRetry(attempt: 1, inSeconds: 30),
    );
    ledger.hostPhase(
      key,
      phase: 'retrying',
      retry: const AgentsHostRetry(attempt: 1, inSeconds: 20),
    );
    expect(notified, 2);
    expect(statusNow()?.retryInSeconds, inInclusiveRange(19, 20));
  });

  test('when the retry starts the line moves on', () {
    ledger.begin(key);
    ledger.hostPhase(
      key,
      phase: 'retrying',
      retry: const AgentsHostRetry(attempt: 1, inSeconds: 2),
    );
    ledger.hostPhase(key, phase: 'preparing');
    expect(statusNow()?.phase, AgentsTurnPhase.preparing);
    expect(ledger.runFor(key)?.hostRetry, isNull);
  });

  test('a wait of zero says it is trying again now', () {
    expect(
      agentsTurnPhaseLabel(AgentsTurnPhase.retrying, retryInSeconds: 0),
      'Provider not answering, trying again',
    );
  });
}
