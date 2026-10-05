import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/stream_phase.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_run_ledger.dart';
import 'package:chuk_chat/services/agents/agents_turn_phase.dart';

/// The live phase of an Agents turn (research item 4): every phase is read
/// from a frame the app saw, or from one it did not see.
void main() {
  const key = 'thread-1';
  final ledger = AgentsRunLedger.instance;

  setUp(ledger.reset);
  tearDown(ledger.reset);

  AgentsTurnPhase? phaseNow({bool linkUp = true, StreamPhase? stream}) =>
      agentsTurnStatusFor(
        run: ledger.runFor(key),
        linkUp: linkUp,
        streamPhase: stream,
      )?.phase;

  test('a fresh send says Sending, then Got it once the host acks', () {
    ledger.begin(key);
    expect(phaseNow(), AgentsTurnPhase.sending);
    ledger.taskSent(key, 't-1');
    expect(phaseNow(), AgentsTurnPhase.sending);
    ledger.taskAcknowledged(key, taskId: 't-1');
    expect(phaseNow(), AgentsTurnPhase.received);
  });

  test('the first heartbeat moves to Preparing and notifies at once', () {
    ledger.begin(key);
    ledger.taskSent(key, 't-1');
    ledger.taskAcknowledged(key, taskId: 't-1');
    var notified = 0;
    void count() => notified++;
    ledger.addListener(count);
    addTearDown(() => ledger.removeListener(count));

    ledger.heartbeat(key);
    expect(phaseNow(), AgentsTurnPhase.preparing);
    expect(notified, 1);
    // Later heartbeats change nothing anybody can see.
    ledger.heartbeat(key);
    expect(notified, 1);
  });

  test('an unanswered first send says the computer is not answering', () {
    ledger.begin(key);
    ledger.taskSent(
      key,
      't-1',
      at: DateTime.now().subtract(
        AgentsRunLedger.taskAckCeiling + const Duration(seconds: 1),
      ),
    );
    ledger.sweep();
    final status = agentsTurnStatusFor(run: ledger.runFor(key), linkUp: true)!;
    expect(status.phase, AgentsTurnPhase.noAnswer);
    expect(status.offersRetry, isTrue);
  });

  test('a link that is down says offline, with Retry', () {
    ledger.begin(key);
    final status = agentsTurnStatusFor(run: ledger.runFor(key), linkUp: false)!;
    expect(status.phase, AgentsTurnPhase.offline);
    expect(status.offersRetry, isTrue);
    expect(status.label(), 'Your computer is offline');
  });

  test('tokens say Writing; a tool after them says Working, not Writing', () {
    ledger.begin(key);
    ledger.touch(key);
    expect(phaseNow(stream: StreamPhase.writing), AgentsTurnPhase.writing);
    ledger.recordTool(key, const AgentsRelayTool('read_file', result: 'ok'));
    // The stream still says "writing" — its last token was text — but the
    // ledger saw the tool come after it.
    expect(phaseNow(stream: StreamPhase.writing), AgentsTurnPhase.working);
    ledger.reasoning(key, 'hmm');
    expect(phaseNow(), AgentsTurnPhase.thinking);
  });

  test('an open tool names itself', () {
    ledger.begin(key);
    ledger.openTool(key, 'web_search');
    final status = agentsTurnStatusFor(run: ledger.runFor(key), linkUp: true)!;
    expect(status.phase, AgentsTurnPhase.tool);
    expect(status.label(), 'Searching the web');
    expect(ledger.runFor(key)!.toolCalls.single.status, ToolCallStatus.running);
  });

  test('a card the run waits on outranks everything', () {
    ledger.begin(key);
    ledger.openTool(key, 'web_search');
    ledger.setWaitingForUser(key, true);
    expect(phaseNow(), AgentsTurnPhase.waitingForYou);
    ledger.setWaitingForUser(key, false);
    expect(phaseNow(), AgentsTurnPhase.tool);
  });

  test('the host phase is used when it is newer than the last output', () {
    ledger.begin(key);
    ledger.taskSent(key, 't-1');
    ledger.hostPhase(key, phase: 'queued');
    expect(phaseNow(), AgentsTurnPhase.queued);
    ledger.hostPhase(key, phase: 'preparing');
    expect(phaseNow(), AgentsTurnPhase.preparing);
    ledger.touch(key);
    expect(phaseNow(), AgentsTurnPhase.writing);
    ledger.hostPhase(
      key,
      phase: 'tool',
      tool: 'mcp__playwright__browser_click',
    );
    final status = agentsTurnStatusFor(run: ledger.runFor(key), linkUp: true)!;
    expect(status.phase, AgentsTurnPhase.tool);
    expect(status.label(), 'Browser click');
    // A phase this app does not know is not a status.
    ledger.hostPhase(key, phase: 'reticulating');
    expect(phaseNow(), AgentsTurnPhase.writing);
  });

  test('a run that never reached the host says so after it ended', () {
    ledger.begin(key);
    ledger.taskSent(key, 't-1');
    ledger.taskRejected(key, reason: 'queue_full');
    expect(phaseNow(), AgentsTurnPhase.notDelivered);
  });

  test('a run that answered leaves the wording to the stream', () {
    ledger.begin(key);
    ledger.finish(key, finalAnswer: 'hi', reason: 'finished');
    expect(phaseNow(), isNull);
  });

  test('no run at all falls back to the stream phase', () {
    expect(phaseNow(), isNull);
    expect(phaseNow(stream: StreamPhase.connecting), AgentsTurnPhase.sending);
    expect(phaseNow(stream: StreamPhase.processing), AgentsTurnPhase.preparing);
    expect(
      phaseNow(stream: StreamPhase.connecting, linkUp: false),
      AgentsTurnPhase.offline,
    );
  });

  test('a run adopted from run_state says Working until something shows', () {
    ledger.adoptRunning(key, runId: 'r-1', prompt: 'do the thing');
    // adoptRunning on a fresh key starts with no output.
    expect(phaseNow(), AgentsTurnPhase.working);
  });
}
