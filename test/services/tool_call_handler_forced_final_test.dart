// Regression: a research turn on z-ai/glm-5.3-flash ran 17 passes of
// web_search/web_crawl, then showed "Sorry, I hit the tool-call safety limit"
// instead of an answer. Every pass also re-sent every ~20k-char result
// (5.8M chars over the turn).
//
// Now the limit forces a final pass with no tools and a short instruction,
// and the tool results of older rounds are shortened before each pass.

import 'dart:convert';

import 'package:chuk_chat/models/chat_stream_event.dart' show NativeToolCall;
import 'package:chuk_chat/services/tool_call_handler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  ToolLoopSession newSession(
    ToolCallHandler handler, {
    bool native = true,
    List<Map<String, dynamic>> history = const [],
  }) => handler.createSession(
    initialUserMessage: 'research this topic',
    history: history,
    accessToken: 'test-token',
    toolCallingEnabled: true,
    discoveryMode: false,
    nativeToolCalling: native,
  );

  NativeToolCall calc(String id, int n) => NativeToolCall(
    id: id,
    name: 'calculate',
    arguments: jsonEncode({'expression': '$n+1'}),
  );

  Map<String, dynamic> assistantCall(String id) => {
    'role': 'assistant',
    'content': null,
    'tool_calls': [
      {
        'id': id,
        'type': 'function',
        'function': {'name': 'web_crawl', 'arguments': '{}'},
      },
    ],
  };

  group('compactToolResultForModel', () {
    test('short results are returned unchanged', () {
      final text = 'x' * kCompactToolResultTriggerChars;
      expect(identical(compactToolResultForModel(text), text), isTrue);
    });

    test('long results keep their head and are cut only once', () {
      final once = compactToolResultForModel('y' * 20000);
      expect(once, startsWith('y' * kCompactToolResultKeepChars));
      expect(once, contains('20000 characters'));
      expect(once.length, lessThan(kCompactToolResultTriggerChars));
      expect(compactToolResultForModel(once), once);
    });

    test('the text matches the api_server copy byte for byte', () {
      // chat/tool_history.py: COMPACTED_NOTE_TEMPLATE.
      expect(
        compactToolResultForModel('z' * 5000).substring(3000),
        '\n\n[Shortened: this is an older tool result of 5000 characters. '
        'Only the first 3000 are kept here to save space.]',
      );
    });
  });

  group('compactOlderToolResults', () {
    test('older native rounds are shortened, the newest stays full', () {
      final big = 'r' * 20000;
      final history = <Map<String, dynamic>>[
        {'role': 'user', 'content': 'q'},
        assistantCall('a'),
        {'role': 'tool', 'tool_call_id': 'a', 'content': big},
        assistantCall('b'),
        {'role': 'tool', 'tool_call_id': 'b', 'content': big},
      ];
      compactOlderToolResults(history);
      expect(
        (history[2]['content'] as String).length,
        lessThan(kCompactToolResultTriggerChars),
      );
      expect(history[4]['content'], big);
      expect(history[2]['tool_call_id'], 'a');
    });

    test('a long user message is never touched', () {
      final pasted = 'p' * 20000;
      final history = <Map<String, dynamic>>[
        {'role': 'user', 'content': pasted},
        {'role': 'assistant', 'content': 'ok'},
      ];
      compactOlderToolResults(history, promptToolResultIndices: const {});
      expect(history[0]['content'], pasted);
    });

    test('entries of earlier turns are left alone', () {
      final big = 'e' * 20000;
      final history = <Map<String, dynamic>>[
        {'role': 'tool', 'tool_call_id': 'old', 'content': big},
        assistantCall('a'),
        {'role': 'tool', 'tool_call_id': 'a', 'content': 'x'},
      ];
      compactOlderToolResults(history, turnStart: 1);
      expect(history[0]['content'], big);
    });
  });

  group('the tool loop', () {
    test('the next pass carries older results shortened', () async {
      final handler = ToolCallHandler();
      final big = 'c' * 20000;
      final session = newSession(handler);
      session.history.addAll([
        {'role': 'user', 'content': 'research this topic'},
        assistantCall('crawl-1'),
        {'role': 'tool', 'tool_call_id': 'crawl-1', 'content': big},
      ]);
      session.latestUserMessage = '';

      final result = await handler.processAssistantResponse(
        session: session,
        content: '',
        reasoning: '',
        nativeToolCalls: [calc('c-1', 1)],
      );

      expect(result.shouldContinue, isTrue);
      final history = result.nextStep!.history;
      final tools = history.where((m) => m['role'] == 'tool').toList();
      expect(tools, hasLength(2));
      expect(
        (tools.first['content'] as String).length,
        lessThan(kCompactToolResultTriggerChars),
      );
      // The newest round (the calculate result) is sent in full.
      expect(tools.last['tool_call_id'], 'c-1');
      expect(tools.last['content'], isNot(contains('[Shortened')));
    });

    test('at the round limit a final pass without tools is forced', () async {
      final handler = ToolCallHandler();
      final session = newSession(handler);

      ToolLoopResult result;
      for (var i = 1; i <= kMaxToolRoundsPerTurn; i++) {
        result = await handler.processAssistantResponse(
          session: session,
          content: '',
          reasoning: '',
          nativeToolCalls: [calc('c-$i', i)],
        );
        expect(result.shouldContinue, isTrue);
      }
      expect(handler.nativeToolDefinitions(session), isNotEmpty);

      // One round over the limit: nothing runs, the answer is requested.
      result = await handler.processAssistantResponse(
        session: session,
        content: '',
        reasoning: '',
        nativeToolCalls: [calc('c-over', 99)],
      );
      expect(result.shouldContinue, isTrue);
      expect(result.nextStep!.message, kForcedFinalAnswerNote);
      expect(handler.nativeToolDefinitions(session), isEmpty);
      expect(session.toolCalls, hasLength(kMaxToolRoundsPerTurn));
      // The unrun call is not recorded, so every tool_call_id stays paired.
      final last = result.nextStep!.history.last;
      expect(last['role'], 'tool');
      expect(last['tool_call_id'], 'c-$kMaxToolRoundsPerTurn');

      // The model answers: that is the final answer, no [VERIFY] pass.
      const answer = 'Here is the summary of what I found.';
      result = await handler.processAssistantResponse(
        session: session,
        content: answer,
        reasoning: '',
      );
      expect(result.shouldContinue, isFalse);
      expect(result.finalContent, answer);
    });

    test('prompt-based models get the same forced final pass', () async {
      final handler = ToolCallHandler();
      final session = newSession(handler, native: false);

      String call(int n) =>
          '<tool_call>{"name":"calculate","arguments":'
          '{"expression":"$n+1"}}</tool_call>';

      ToolLoopResult result;
      var round = 0;
      do {
        round++;
        result = await handler.processAssistantResponse(
          session: session,
          content: call(round),
          reasoning: '',
        );
      } while (result.shouldContinue &&
          result.nextStep!.message != kForcedFinalAnswerNote &&
          round < 40);

      expect(round, kMaxToolRoundsPerTurn + 1);
      expect(result.nextStep!.message, kForcedFinalAnswerNote);

      result = await handler.processAssistantResponse(
        session: session,
        content: 'Final answer from the results.',
        reasoning: '',
      );
      expect(result.shouldContinue, isFalse);
      expect(result.finalContent, 'Final answer from the results.');
    });

    test('prompt-based tool results in history are shortened, the user '
        'question is not', () async {
      final handler = ToolCallHandler();
      final question = 'q' * 6000;
      final session = handler.createSession(
        initialUserMessage: question,
        history: const [],
        accessToken: 'test-token',
        toolCallingEnabled: true,
        discoveryMode: false,
      );

      // Round 1: the question goes to history, the result becomes `message`.
      var result = await handler.processAssistantResponse(
        session: session,
        content:
            '<tool_call>{"name":"calculate","arguments":'
            '{"expression":"1+1"}}</tool_call>',
        reasoning: '',
      );
      // Pretend the result was large, as a crawl would be.
      final bigResult = 'Tool Results:\n${'w' * 20000}';
      session.latestUserMessage = bigResult;
      session.pendingPromptToolResult = bigResult;

      // Round 2: round 1's result moves into history and is shortened.
      result = await handler.processAssistantResponse(
        session: session,
        content:
            '<tool_call>{"name":"calculate","arguments":'
            '{"expression":"2+2"}}</tool_call>',
        reasoning: '',
      );
      final users = result.nextStep!.history
          .where((m) => m['role'] == 'user')
          .map((m) => m['content'] as String)
          .toList();
      expect(users.first, question);
      expect(users[1].length, lessThan(kCompactToolResultTriggerChars));
      expect(users[1], contains('[Shortened'));
    });

    test('the driver can shut the tools before its pass budget ends', () async {
      final handler = ToolCallHandler();
      final session = newSession(handler)..finalAnswerRequested = true;

      final result = await handler.processAssistantResponse(
        session: session,
        content: '',
        reasoning: '',
        nativeToolCalls: [calc('c-1', 1)],
      );
      expect(result.shouldContinue, isTrue);
      expect(result.nextStep!.message, kForcedFinalAnswerNote);
      expect(session.toolCalls, isEmpty);
      expect(handler.nativeToolDefinitions(session), isEmpty);
    });

    test('a model that never stops asking ends with the text it wrote, '
        'not an error', () async {
      final handler = ToolCallHandler();
      final session = newSession(handler, native: false)
        ..finalAnswerRequested = true;
      const partial = 'Based on the sources so far, the answer is 42.';
      const content =
          '$partial\n<tool_call>{"name":"calculate","arguments":'
          '{"expression":"1+1"}}</tool_call>';

      ToolLoopResult result;
      var passes = 0;
      do {
        passes++;
        result = await handler.processAssistantResponse(
          session: session,
          content: content,
          reasoning: '',
        );
      } while (result.shouldContinue && passes < 10);

      expect(passes, 3);
      expect(result.finalContent, partial);
      expect(result.finalContent, isNot(contains('safety limit')));
    });
  });
}
