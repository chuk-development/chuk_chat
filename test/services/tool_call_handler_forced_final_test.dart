// Regression: a research turn on z-ai/glm-5.3-flash ran 17 passes of
// web_search/web_crawl, then showed "Sorry, I hit the tool-call safety limit"
// instead of an answer. Every pass also re-sent every ~20k-char result
// (5.8M chars over the turn).
//
// Now the limit forces a final pass with no tools and a short instruction.
// Tool results are capped once, when they first go into the history, and
// never changed after that (prompt cache).

import 'dart:convert';

import 'package:chuk_chat/models/chat_stream_event.dart' show NativeToolCall;
import 'package:chuk_chat/services/prompt_cache/prompt_context.dart';
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

  group('capToolResultForModel', () {
    test('short results are returned unchanged', () {
      final text = 'x' * 5000;
      expect(identical(capToolResultForModel(text), text), isTrue);
    });

    test('long results keep head and tail and are cut only once', () {
      final text = '${'h' * 10000}${'t' * 10000}';
      final once = capToolResultForModel(text);
      expect(once, startsWith('h' * kToolResultHeadCodePoints));
      expect(once, endsWith('t' * kToolResultTailCodePoints));
      expect(once, contains(kToolResultPrunedMarker));
      expect(capToolResultForModel(once), once);
    });

    test('counts code points, never splits a surrogate pair', () {
      final text = '😀' * 8000;
      final once = capToolResultForModel(text);
      final head = once.substring(0, once.indexOf(kToolResultPrunedMarker));
      expect(head.runes.length, kToolResultHeadCodePoints);
      expect(head.runes.every((r) => r == 0x1F600), isTrue);
    });
  });

  group('the tool loop', () {
    test('a sent tool result is never changed on a later pass', () async {
      // Older rounds used to be shortened once a newer round existed, which
      // changed the history between passes: a prompt cache miss on
      // everything after it.
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
      expect(tools.first['content'], big);
      expect(tools.last['tool_call_id'], 'c-1');
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
      // Shut tools keep tools[] (prompt cache) and send tool_choice none.
      expect(handler.nativeToolDefinitions(session), isNotEmpty);
      expect(ToolCallHandler.nativeToolChoice(session), 'none');
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

    test('prompt-based tool results stay as they were sent', () async {
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
      final firstResult = result.nextStep!.message;

      // Round 2: round 1's result moves into history unchanged.
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
      expect(users[1], firstResult.trim());
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
      // Shut tools keep tools[] (prompt cache) and send tool_choice none.
      expect(handler.nativeToolDefinitions(session), isNotEmpty);
      expect(ToolCallHandler.nativeToolChoice(session), 'none');
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
