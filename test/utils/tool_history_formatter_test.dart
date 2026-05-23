import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/utils/tool_history_formatter.dart';

void main() {
  group('formatAssistantContent', () {
    test('returns plain text when no tool calls', () {
      final result = formatAssistantContent({
        'sender': 'ai',
        'text': 'Hello world',
      });

      expect(result, 'Hello world');
    });

    test('returns null for "Thinking..." placeholder', () {
      final result = formatAssistantContent({
        'sender': 'ai',
        'text': 'Thinking...',
      });

      expect(result, isNull);
    });

    test('returns null when text is empty and no tool calls', () {
      final result = formatAssistantContent({
        'sender': 'ai',
        'text': '   ',
      });

      expect(result, isNull);
    });

    test('prepends <previous_tool_results> when tool calls exist', () {
      final toolCallsJson = jsonEncode([
        {
          'id': 'call_1',
          'name': 'web_search',
          'arguments': {'query': 'foo bar'},
          'result': 'Some search output',
          'status': 'completed',
        }
      ]);

      final result = formatAssistantContent({
        'sender': 'ai',
        'text': 'Final answer',
        'toolCalls': toolCallsJson,
      });

      expect(result, contains('<previous_tool_results>'));
      expect(result, contains('[web_search]'));
      expect(result, contains('"query":"foo bar"'));
      expect(result, contains('Some search output'));
      expect(result, contains('Final answer'));
      // Tool block must come before final text so the model reads context first.
      expect(
        result!.indexOf('<previous_tool_results>'),
        lessThan(result.indexOf('Final answer')),
      );
    });

    test('skips tool calls with status != completed/error', () {
      final toolCallsJson = jsonEncode([
        {
          'name': 'web_search',
          'arguments': {'query': 'foo'},
          'result': 'partial',
          'status': 'running',
        }
      ]);

      final result = formatAssistantContent({
        'sender': 'ai',
        'text': 'Answer',
        'toolCalls': toolCallsJson,
      });

      expect(result, 'Answer');
      expect(result, isNot(contains('<previous_tool_results>')));
    });

    test('skips tool calls without result', () {
      final toolCallsJson = jsonEncode([
        {
          'name': 'web_search',
          'arguments': {'query': 'foo'},
          'status': 'completed',
        }
      ]);

      final result = formatAssistantContent({
        'sender': 'ai',
        'text': 'Answer',
        'toolCalls': toolCallsJson,
      });

      expect(result, 'Answer');
      expect(result, isNot(contains('<previous_tool_results>')));
    });

    test('includes error-status tool calls', () {
      final toolCallsJson = jsonEncode([
        {
          'name': 'web_search',
          'arguments': {'query': 'foo'},
          'result': 'Network failed',
          'status': 'error',
        }
      ]);

      final result = formatAssistantContent({
        'sender': 'ai',
        'text': 'Could not fetch',
        'toolCalls': toolCallsJson,
      });

      expect(result, contains('Network failed'));
    });

    test('truncates oversized results', () {
      final longResult = 'x' * 6000;
      final toolCallsJson = jsonEncode([
        {
          'name': 'web_search',
          'arguments': {'query': 'foo'},
          'result': longResult,
          'status': 'completed',
        }
      ]);

      final result = formatAssistantContent({
        'sender': 'ai',
        'text': 'Answer',
        'toolCalls': toolCallsJson,
      });

      expect(result, contains('[truncated]'));
      expect(result!.length, lessThan(longResult.length + 1000));
    });

    test('includes reasoning when includeReasoning=true', () {
      final result = formatAssistantContent(
        {
          'sender': 'ai',
          'text': 'Final',
          'reasoning': 'Step by step thought',
        },
        includeReasoning: true,
      );

      expect(result, contains('<thinking>'));
      expect(result, contains('Step by step thought'));
      expect(result, contains('Final'));
    });

    test('handles malformed toolCalls JSON gracefully', () {
      final result = formatAssistantContent({
        'sender': 'ai',
        'text': 'Answer',
        'toolCalls': 'not valid json',
      });

      expect(result, 'Answer');
    });

    test('skips tool block when includeToolResults=false', () {
      final toolCallsJson = jsonEncode([
        {
          'name': 'web_search',
          'arguments': {'query': 'foo'},
          'result': 'should not appear',
          'status': 'completed',
        }
      ]);

      final result = formatAssistantContent(
        {
          'sender': 'ai',
          'text': 'Final',
          'toolCalls': toolCallsJson,
        },
        includeToolResults: false,
      );

      expect(result, 'Final');
      expect(result, isNot(contains('previous_tool_results')));
      expect(result, isNot(contains('should not appear')));
    });

    test('caps total chars across many tool calls', () {
      final calls = <Map<String, dynamic>>[];
      for (int i = 0; i < 10; i++) {
        calls.add({
          'name': 'web_search',
          'arguments': {'query': 'q$i'},
          'result': 'a' * 3000,
          'status': 'completed',
        });
      }

      final result = formatAssistantContent({
        'sender': 'ai',
        'text': 'Final',
        'toolCalls': jsonEncode(calls),
      });

      expect(result, contains('further tool results omitted'));
    });
  });
}
