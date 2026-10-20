// The finish notification must not preview an older answer (CodeRabbit,
// 2026-10-20): the last answer row counts only when it belongs to this run,
// and a stopped run shows no answer.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/chat_message.dart';
import 'package:chuk_chat/services/agents/agents_run_cost.dart';
import 'package:chuk_chat/widgets/agents_thread_view.dart';

ChatMessage _answer(String text, {String? runId}) {
  final call = runMetaCall(runId: runId);
  return ChatMessage(
    role: 'assistant',
    text: text,
    toolCalls: call == null ? null : jsonEncode(<Object>[call.toJson()]),
  );
}

String? _pick({
  String? finalAnswer,
  String? runId = 'run-2',
  bool stopped = false,
  required List<ChatMessage> rows,
}) => AgentsThreadViewState.answerForNotification(
  finalAnswer: finalAnswer,
  runId: runId,
  stopped: stopped,
  rows: rows,
);

void main() {
  final List<ChatMessage> older = <ChatMessage>[
    ChatMessage(role: 'user', text: 'first'),
    _answer('old answer', runId: 'run-1'),
  ];

  test('the run final answer wins', () {
    expect(_pick(finalAnswer: 'new answer', rows: older), 'new answer');
  });

  test('an answer row of an earlier run is not shown', () {
    expect(_pick(rows: older), isNull);
  });

  test('an answer row without run meta is not shown', () {
    expect(
      _pick(rows: <ChatMessage>[ChatMessage(role: 'assistant', text: 'x')]),
      isNull,
    );
  });

  test('the answer row of this run is shown', () {
    final rows = <ChatMessage>[...older, _answer('this run', runId: 'run-2')];
    expect(_pick(rows: rows), 'this run');
  });

  test('no run id: no fallback', () {
    final rows = <ChatMessage>[...older, _answer('this run', runId: 'run-2')];
    expect(_pick(runId: null, rows: rows), isNull);
  });

  test('a stopped run shows no answer', () {
    final rows = <ChatMessage>[...older, _answer('this run', runId: 'run-2')];
    expect(_pick(stopped: true, rows: rows), isNull);
    expect(_pick(stopped: true, finalAnswer: 'partial', rows: rows), isNull);
  });
}
