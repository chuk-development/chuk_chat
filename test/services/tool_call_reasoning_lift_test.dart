import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/tool_call_handler.dart';

void main() {
  group('trailingToolCallBlockStart', () {
    test('null when text does not end with </tool_call>', () {
      expect(
        ToolCallHandler.trailingToolCallBlockStart('just some reasoning'),
        isNull,
      );
    });

    test('null when </tool_call> exists but trailing text follows', () {
      const text =
          'thinking...\n<tool_call>{"name":"x","arguments":{}}</tool_call>\nmore text';
      expect(ToolCallHandler.trailingToolCallBlockStart(text), isNull);
    });

    test('returns start of single trailing block', () {
      const text =
          'reason text\n<tool_call>{"name":"x","arguments":{}}</tool_call>';
      final start = ToolCallHandler.trailingToolCallBlockStart(text);
      expect(start, isNotNull);
      expect(text.substring(start!), startsWith('<tool_call>'));
      expect(text.substring(start), endsWith('</tool_call>'));
    });

    test('lifts contiguous trailing run of multiple blocks', () {
      const text =
          'reason\n<tool_call>{"name":"a","arguments":{}}</tool_call>\n'
          '<tool_call>{"name":"b","arguments":{}}</tool_call>';
      final start = ToolCallHandler.trailingToolCallBlockStart(text);
      expect(start, isNotNull);
      // Both blocks must be in the lifted slice.
      final lifted = text.substring(start!);
      expect('<tool_call>'.allMatches(lifted).length, 2);
    });

    test('only lifts contiguous trailing run, not earlier disjoint block', () {
      const text =
          'first '
          '<tool_call>{"name":"a","arguments":{}}</tool_call>'
          ' some intervening prose '
          '<tool_call>{"name":"b","arguments":{}}</tool_call>';
      final start = ToolCallHandler.trailingToolCallBlockStart(text);
      expect(start, isNotNull);
      final lifted = text.substring(start!);
      expect('<tool_call>'.allMatches(lifted).length, 1);
      expect(lifted, contains('"b"'));
      expect(lifted, isNot(contains('"a"')));
    });

    test('tolerates trailing whitespace after </tool_call>', () {
      const text =
          'reason '
          '<tool_call>{"name":"x","arguments":{}}</tool_call>   \n  ';
      expect(
        ToolCallHandler.trailingToolCallBlockStart(text),
        isNotNull,
      );
    });
  });
}
