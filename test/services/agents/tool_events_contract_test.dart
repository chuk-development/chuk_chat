// The app side of docs/WIRE_CONTRACT.md "Tool events and timestamps" (beads
// cowork-b45 / cowork-al2): how a `tool` frame decodes, how it maps to the
// renderer's ToolCall, and that an old host's frame still works.

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_run_ledger.dart';

void main() {
  const sessionKey = 'thread-1';
  final ledger = AgentsRunLedger.instance;

  setUp(ledger.reset);

  /// A frame as a current host sends it (tool_events.py).
  Map<String, dynamic> currentHostFrame() => <String, dynamic>{
        'type': 'tool',
        'name': 'run_command',
        'call_id': 'call_7',
        'arguments': <String, dynamic>{'command': 'ls /tmp', 'timeout': 30},
        'command': 'ls /tmp',
        'result': '{"exit_code":0,"stdout":"a\\nb","stderr":"","timed_out":false}',
        'exit_code': 0,
        'stdout': 'a\nb',
        'stderr': '',
        'timed_out': false,
        'status': 'completed',
        'started_at': 1757040001.25,
        'completed_at': 1757040003.75,
        'duration_ms': 2500,
      };

  test('a current host frame decodes its arguments, clock and verdict', () {
    final event = AgentsRelayTool.fromPayload(currentHostFrame());

    expect(event.name, 'run_command');
    expect(event.callId, 'call_7');
    expect(event.argumentMap, <String, dynamic>{'command': 'ls /tmp', 'timeout': 30});
    expect(event.arguments, 'ls /tmp');
    expect(event.result, contains('"exit_code":0'));
    expect(event.detail, 'a\nb');
    expect(event.failed, isFalse);
    expect(event.startedAt, isNotNull);
    expect(event.completedAt!.difference(event.startedAt!),
        const Duration(milliseconds: 2500));
  });

  test("the host's error verdict wins even with exit code 0", () {
    final frame = currentHostFrame()
      ..['status'] = 'error'
      ..['result'] = '{"ok":false,"error":"write failed"}';
    final event = AgentsRelayTool.fromPayload(frame);
    expect(event.failed, isTrue);
    expect(toolCallFromRelay(event).status, ToolCallStatus.error);
  });

  test('a tool with no shell result keeps its object arguments and text', () {
    final event = AgentsRelayTool.fromPayload(<String, dynamic>{
      'type': 'tool',
      'name': 'web_search',
      'arguments': <String, dynamic>{'query': 'flutter timelines'},
      'result': '1. Timelines\n   https://example.com/t',
      'status': 'completed',
      'started_at': 10.0,
      'completed_at': 12.0,
    });
    final call = toolCallFromRelay(event);
    expect(call.name, 'web_search');
    expect(call.arguments, <String, dynamic>{'query': 'flutter timelines'});
    expect(call.result, '1. Timelines\n   https://example.com/t');
    expect(call.status, ToolCallStatus.completed);
    expect(call.elapsed, const Duration(seconds: 2));
  });

  test('an old host frame (command + stdout, no clock) still maps', () {
    final now = DateTime(2026, 9, 5, 4);
    final event = AgentsRelayTool.fromPayload(<String, dynamic>{
      'type': 'tool',
      'name': 'run_command',
      'command': 'ls /nope',
      'exit_code': 2,
      'stdout': '',
      'stderr': 'ls: /nope: No such file',
      'timed_out': false,
    });
    final call = toolCallFromRelay(event, now: now);
    expect(call.arguments, <String, dynamic>{'command': 'ls /nope', 'exit_code': 2});
    expect(call.status, ToolCallStatus.error);
    expect(call.result, 'ls: /nope: No such file');
    expect(call.startedAt, now);
    expect(call.completedAt, now);
  });

  test('the ledger records a frame exactly as the mapping says', () {
    ledger.begin(sessionKey);
    final event = AgentsRelayTool.fromPayload(currentHostFrame());
    final recorded = ledger.recordTool(sessionKey, event);
    final mapped = toolCallFromRelay(event);

    expect(ledger.runFor(sessionKey)!.toolCalls, <ToolCall>[recorded]);
    expect(recorded.toJson(), mapped.toJson());
  });

  test('a frame for an already open line fills it instead of stacking', () {
    ledger.begin(sessionKey);
    final open = ledger.openTool(
      sessionKey,
      'run_command',
      arguments: 'ls /tmp',
      callId: 'call_7',
    );
    final event = AgentsRelayTool.fromPayload(currentHostFrame());
    final closed = ledger.recordTool(sessionKey, event);

    expect(identical(open, closed), isTrue);
    expect(ledger.runFor(sessionKey)!.toolCalls, hasLength(1));
    expect(closed.status, ToolCallStatus.completed);
    expect(closed.arguments['timeout'], 30);
    expect(closed.completedAt, event.completedAt);
  });

  test('a frame with another call id never fills an open line of that name',
      () {
    ledger.begin(sessionKey);
    final other = ledger.openTool(
      sessionKey,
      'run_command',
      arguments: 'sleep 60',
      callId: 'call_6',
    );
    final event = AgentsRelayTool.fromPayload(currentHostFrame());
    final recorded = ledger.recordTool(sessionKey, event);

    expect(identical(other, recorded), isFalse);
    expect(other.status, ToolCallStatus.running);
    expect(ledger.runFor(sessionKey)!.toolCalls, hasLength(2));
    expect(recorded.id, 'call_7');
  });

  test('without a host id an open line of the same name is filled', () {
    ledger.begin(sessionKey);
    final open = ledger.openTool(sessionKey, 'run_command', arguments: 'ls');
    final frame = currentHostFrame()..remove('call_id');
    final closed = ledger.recordTool(
      sessionKey,
      AgentsRelayTool.fromPayload(frame),
    );
    expect(identical(open, closed), isTrue);
  });

  test('finish keeps the host clock and the run rows', () {
    ledger.begin(sessionKey);
    final started = DateTime(2026, 9, 5, 4, 0, 0);
    final finished = DateTime(2026, 9, 5, 4, 0, 26);
    ledger.finish(
      sessionKey,
      reason: 'finished',
      startedAt: started,
      finishedAt: finished,
      firstMid: 3,
      lastMid: 9,
    );
    final run = ledger.runFor(sessionKey)!;
    expect(run.workedFor, const Duration(seconds: 26));
    expect(run.hostStamped, isTrue);
    expect(run.firstMid, 3);
    expect(run.lastMid, 9);
  });

  test('a run the host never stamped reports no measured length', () {
    ledger.begin(sessionKey);
    ledger.finish(sessionKey, reason: 'finished');
    expect(ledger.runFor(sessionKey)!.workedFor, isNull);
  });
}
