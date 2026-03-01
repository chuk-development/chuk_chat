import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/utils/tool_parser.dart';

void main() {
  group('parseToolCalls', () {
    test('parses XML tool calls', () {
      const content =
          '<tool_call>{"name":"find_tools","arguments":{"query":"web search"}}</tool_call>';

      final calls = parseToolCalls(content);

      expect(calls.length, 1);
      expect(calls.first['name'], 'find_tools');
      expect(calls.first['arguments'], {'query': 'web search'});
    });

    test('parses markdown fenced tool_call blocks by default', () {
      const content =
          'I will search now.\n\n```tool_call\n{"name":"find_tools","arguments":{"query":"web search"}}\n```';

      final calls = parseToolCalls(content);

      expect(calls.length, 1);
      expect(calls.first['name'], 'find_tools');
      expect(calls.first['arguments'], {'query': 'web search'});
    });

    test('can disable markdown fenced parsing', () {
      const content =
          '```tool_call\n{"name":"find_tools","arguments":{"query":"web search"}}\n```';

      final calls = parseToolCalls(content, allowMarkdownToolCalls: false);

      expect(calls, isEmpty);
    });

    test('preserves call order for mixed XML and markdown', () {
      const content =
          '```tool_call\n{"name":"find_tools","arguments":{"query":"search"}}\n```\n<tool_call>{"name":"web_search","arguments":{"query":"latest tech"}}</tool_call>';

      final calls = parseToolCalls(content);

      expect(calls.length, 2);
      expect(calls[0]['name'], 'find_tools');
      expect(calls[1]['name'], 'web_search');
    });
  });

  group('hasToolCalls', () {
    test('detects markdown fenced tool_call blocks', () {
      const content =
          '```tool_call\n{"name":"find_tools","arguments":{"query":"weather"}}\n```';
      expect(hasToolCalls(content), isTrue);
    });
  });

  group('stripToolCallBlocksForDisplay', () {
    test('removes complete XML tool-call block from mixed text', () {
      const content =
          'Let me check. <tool_call>{"name":"find_tools","arguments":{"query":"news"}}</tool_call> Done.';

      final cleaned = stripToolCallBlocksForDisplay(content);

      expect(cleaned, 'Let me check.  Done.');
    });

    test('removes incomplete XML tool-call block from opening marker', () {
      const content =
          'Searching now... <tool_call>{"name":"web_search","arguments":{"query":"latest"}}';

      final cleaned = stripToolCallBlocksForDisplay(content);

      expect(cleaned, 'Searching now...');
    });

    test('removes incomplete fenced tool-call block from opening fence', () {
      const content =
          'Working...\n```tool_call\n{"name":"web_search","arguments":{"query":"flutter"}}';

      final cleaned = stripToolCallBlocksForDisplay(content);

      expect(cleaned, 'Working...');
    });
  });

  group('hasToolCallStartMarker', () {
    test('detects XML opening marker without closing tag', () {
      const content = '<tool_call>{"name":"find_tools"';
      expect(hasToolCallStartMarker(content), isTrue);
    });

    test('detects fenced tool_call opening marker', () {
      const content = '```tool_call\n{"name":"find_tools"}';
      expect(hasToolCallStartMarker(content), isTrue);
    });
  });
}
