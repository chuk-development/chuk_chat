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

    test('parses legacy direct XML tool tags like fetch_image', () {
      const content =
          '<fetch_image>{"url":"https://example.com/image.jpg"}</fetch_image>';

      final calls = parseToolCalls(content);

      expect(calls.length, 1);
      expect(calls.first['name'], 'fetch_image');
      expect(calls.first['arguments'], {
        'url': 'https://example.com/image.jpg',
      });
    });
  });

  group('hasToolCalls', () {
    test('detects markdown fenced tool_call blocks', () {
      const content =
          '```tool_call\n{"name":"find_tools","arguments":{"query":"weather"}}\n```';
      expect(hasToolCalls(content), isTrue);
    });

    test('detects legacy direct XML tool tags', () {
      const content =
          '<fetch_image>{"url":"https://example.com/x.jpg"}</fetch_image>';
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

    test('removes complete legacy direct XML tool tag from mixed text', () {
      const content =
          'Hier ist ein Bild:\n<fetch_image>{"url":"https://example.com/x.jpg"}</fetch_image>\nDanke.';

      final cleaned = stripToolCallBlocksForDisplay(content);

      expect(cleaned, 'Hier ist ein Bild:\n\nDanke.');
    });

    test(
      'removes incomplete legacy direct XML tool tag from opening marker',
      () {
        const content =
            'Suche Bild...\n<fetch_image>{"url":"https://example.com/x.jpg"}';

        final cleaned = stripToolCallBlocksForDisplay(content);

        expect(cleaned, 'Suche Bild...');
      },
    );

    test('strips Kimi <|tool_calls_section_begin|> special token', () {
      const content = 'Ich suche das nach.\n<|tool_calls_section_begin|>';

      final cleaned = stripToolCallBlocksForDisplay(content);

      expect(cleaned, 'Ich suche das nach.');
    });

    test('strips a dangling lone "<" left at the end of a tool round', () {
      const content = 'Ich schaue das nach.\n<';

      final cleaned = stripToolCallBlocksForDisplay(content);

      expect(cleaned, 'Ich schaue das nach.');
    });

    test('reduces a content that is only "<" to empty', () {
      expect(stripToolCallBlocksForDisplay('<'), '');
    });

    test('strips multiple dangling "<" leaked by a multi-section multiplex', () {
      // Kimi can leak one bare `<` per tool-call section, producing a trailing
      // run like `…\n\n<\n<`. The whole run must go, not just the last `<`.
      const content = 'Hunyuan läuft extern, nicht E2E-verschlüsselt.\n\n<\n<';

      final cleaned = stripToolCallBlocksForDisplay(content);

      expect(cleaned, 'Hunyuan läuft extern, nicht E2E-verschlüsselt.');
    });

    test('preserves a mid-text "<" used as a less-than sign', () {
      const content = 'Wenn a < b dann gilt das.';

      final cleaned = stripToolCallBlocksForDisplay(content);

      expect(cleaned, 'Wenn a < b dann gilt das.');
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

    test('detects legacy direct XML tool start marker', () {
      const content = '<fetch_image>{"url":"https://example.com/a.jpg"}';
      expect(hasToolCallStartMarker(content), isTrue);
    });
  });
}
