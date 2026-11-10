// Native tool rounds: truncated replies (B5), duplicate call ids (B8),
// rejected calls in a mixed round (B15), the tool pairing check before each
// request (item 22) and tool_choice on the forced final pass (B16).

import 'dart:convert';

import 'package:chuk_chat/models/chat_stream_event.dart' show NativeToolCall;
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/services/tool_call_handler.dart';
import 'package:chuk_chat/services/tool_pairing_validator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  ToolLoopSession newSession(ToolCallHandler handler) => handler.createSession(
    initialUserMessage: 'what is 2+2 and 3+3',
    history: const [],
    accessToken: 'test-token',
    toolCallingEnabled: true,
    discoveryMode: false,
    nativeToolCalling: true,
  );

  NativeToolCall calc(String id, String expression) => NativeToolCall(
    id: id,
    name: 'calculate',
    arguments: jsonEncode({'expression': expression}),
  );

  List<Map<String, dynamic>> toolCallsOf(Map<String, dynamic> message) =>
      (message['tool_calls'] as List).cast<Map<String, dynamic>>();

  test(
    'B5: a reply cut at the token limit runs none of its tool calls',
    () async {
      final handler = ToolCallHandler();
      final session = newSession(handler);

      final result = await handler.processAssistantResponse(
        session: session,
        content: 'Let me calculate',
        reasoning: '',
        turnSignals: ToolTurnSignals.fromMeta({'finish_reason': 'length'}),
        // The second call's JSON was cut by the limit.
        nativeToolCalls: [
          calc('c-1', '2+2'),
          const NativeToolCall(
            id: 'c-2',
            name: 'calculate',
            arguments: '{"expression": "3+',
          ),
        ],
      );

      expect(result.shouldContinue, isTrue);
      expect(session.toolCalls, isEmpty, reason: 'nothing ran');
      expect(
        result.nextStep!.message,
        contains('None of those calls were run'),
      );
      final history = result.nextStep!.history;
      expect(history.where((m) => m['role'] == 'tool'), isEmpty);
      expect(history.any((m) => m['tool_calls'] != null), isFalse);
      expect(session.truncatedCompletionRecoveryAttempts, 1);
    },
  );

  test(
    'a complete native round still runs when finish_reason is tool_calls',
    () async {
      final handler = ToolCallHandler();
      final session = newSession(handler);
      final result = await handler.processAssistantResponse(
        session: session,
        content: '',
        reasoning: '',
        turnSignals: ToolTurnSignals.fromMeta({'finish_reason': 'tool_calls'}),
        nativeToolCalls: [calc('c-1', '2+2')],
      );
      expect(result.shouldContinue, isTrue);
      expect(session.toolCalls.single.status, ToolCallStatus.completed);
    },
  );

  test(
    'B8: two calls with one id in a round both run under unique ids',
    () async {
      final handler = ToolCallHandler();
      final session = newSession(handler);

      final result = await handler.processAssistantResponse(
        session: session,
        content: '',
        reasoning: '',
        nativeToolCalls: [calc('dup', '2+2'), calc('dup', '3+3')],
      );

      expect(result.shouldContinue, isTrue);
      expect(session.toolCalls.map((c) => c.id), <String>['dup', 'dup_2']);
      expect(
        session.toolCalls.every((c) => c.status == ToolCallStatus.completed),
        isTrue,
      );
      expect(session.toolCalls[0].result, contains('4'));
      expect(session.toolCalls[1].result, contains('6'));

      final history = result.nextStep!.history;
      final assistant = history.lastWhere((m) => m['tool_calls'] != null);
      expect(toolCallsOf(assistant).map((c) => c['id']), <String>[
        'dup',
        'dup_2',
      ]);
      final results = history.where((m) => m['role'] == 'tool').toList();
      expect(results.map((m) => m['tool_call_id']), <String>['dup', 'dup_2']);
      expect(results[1]['content'], contains('6'));
    },
  );

  test('B8: an id that repeats in the next round gets a suffix', () async {
    final handler = ToolCallHandler();
    final session = newSession(handler);

    await handler.processAssistantResponse(
      session: session,
      content: '',
      reasoning: '',
      nativeToolCalls: [calc('call_0', '2+2')],
    );
    final second = await handler.processAssistantResponse(
      session: session,
      content: '',
      reasoning: '',
      nativeToolCalls: [calc('call_0', '3+3')],
    );

    expect(session.toolCalls.map((c) => c.id), <String>['call_0', 'call_0_2']);
    final ids = second.nextStep!.history
        .where((m) => m['role'] == 'tool')
        .map((m) => m['tool_call_id'])
        .toList();
    expect(ids, <String>['call_0', 'call_0_2']);
  });

  test('B8: a call with no id gets one', () async {
    final handler = ToolCallHandler();
    final session = newSession(handler);
    final result = await handler.processAssistantResponse(
      session: session,
      content: '',
      reasoning: '',
      nativeToolCalls: [calc('', '2+2')],
    );
    final assistant = result.nextStep!.history.lastWhere(
      (m) => m['tool_calls'] != null,
    );
    final id = toolCallsOf(assistant).single['id'] as String;
    expect(id, isNotEmpty);
    expect(
      result.nextStep!.history.last['tool_call_id'],
      id,
      reason: 'the result id matches the id the model sees',
    );
  });

  test(
    'B15: a rejected call in a mixed round is reported to the model',
    () async {
      final handler = ToolCallHandler();
      final session = newSession(handler);

      final result = await handler.processAssistantResponse(
        session: session,
        content: '',
        reasoning: '',
        nativeToolCalls: [
          const NativeToolCall(
            id: 'bad-1',
            name: 'no_such_tool',
            arguments: '{}',
          ),
          calc('ok-1', '2+2'),
        ],
      );

      expect(result.shouldContinue, isTrue);
      final history = result.nextStep!.history;
      final assistant = history.lastWhere((m) => m['tool_calls'] != null);
      // Both calls, in the order the model wrote them.
      expect(toolCallsOf(assistant).map((c) => c['id']), <String>[
        'bad-1',
        'ok-1',
      ]);
      final results = history.where((m) => m['role'] == 'tool').toList();
      expect(results.map((m) => m['tool_call_id']), <String>['bad-1', 'ok-1']);
      expect(results[0]['content'], startsWith('Rejected: '));
      expect(results[1]['content'], contains('4'));
      // The UI row of the rejected call carries the same id.
      expect(
        session.toolCalls.firstWhere((c) => c.name == 'no_such_tool').id,
        'bad-1',
      );
    },
  );

  test('item 22: the next request carries a repaired tool pairing', () async {
    final handler = ToolCallHandler();
    final session = newSession(handler);
    session.history.addAll([
      {'role': 'user', 'content': 'earlier'},
      // An orphan result and an unanswered call from an earlier turn.
      {'role': 'tool', 'tool_call_id': 'ghost', 'content': 'stale'},
      {
        'role': 'assistant',
        'content': null,
        'tool_calls': [
          {
            'id': 'lost',
            'type': 'function',
            'function': {'name': 'calculate', 'arguments': '{}'},
          },
        ],
      },
    ]);

    final result = await handler.processAssistantResponse(
      session: session,
      content: '',
      reasoning: '',
      nativeToolCalls: [calc('c-1', '2+2')],
    );

    final history = result.nextStep!.history;
    expect(history.any((m) => m['tool_call_id'] == 'ghost'), isFalse);
    final lost = history.firstWhere((m) => m['tool_call_id'] == 'lost');
    expect(lost['content'], kUnansweredToolCallResult);
  });

  test('B16: shut tools keep tools[] and send tool_choice none', () {
    final handler = ToolCallHandler();
    final session = newSession(handler);
    final before = handler.nativeToolDefinitions(session);
    expect(before, isNotEmpty);
    expect(ToolCallHandler.nativeToolChoice(session), isNull);

    session.finalAnswerRequested = true;
    expect(
      jsonEncode(handler.nativeToolDefinitions(session)),
      jsonEncode(before),
      reason: 'the same tools[] keeps the prompt cache prefix',
    );
    expect(ToolCallHandler.nativeToolChoice(session), 'none');
  });
}
