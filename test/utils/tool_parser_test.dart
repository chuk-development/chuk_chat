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

    test('strips bare "<" lines sandwiched between prose in a multi-pass turn',
        () {
      // A finalised Kimi multiplex turn (text → toolCall → text → …) leaks one
      // bare `<` per section *between* prose blocks, not just at the end — so
      // the end-anchored trailing strip misses them. Each lone-`<` line must go
      // while the prose on either side stays intact.
      const content =
          'Gute Funde schon. Ich grabe tiefer.\n\n<\n<\n<\n\nJa, gibt es.';

      final cleaned = stripToolCallBlocksForDisplay(content);

      expect(cleaned, 'Gute Funde schon. Ich grabe tiefer.\n\nJa, gibt es.');
    });

    test('preserves a mid-text "<" used as a less-than sign', () {
      const content = 'Wenn a < b dann gilt das.';

      final cleaned = stripToolCallBlocksForDisplay(content);

      expect(cleaned, 'Wenn a < b dann gilt das.');
    });

    test('strips an echoed <previous_tool_results> block (doubled opener)', () {
      // The model echoes the scaffolding tag the app feeds it, sometimes with
      // a `<<` opener, and the real reply follows the block.
      const content =
          '<<previous_tool_results>\n'
          '[generate_image] args: {"model":"turbo"} | result: ok\n'
          '</previous_tool_results>\n\n'
          'Turbo zieht durch. Bild ist da.';

      final cleaned = stripToolCallBlocksForDisplay(content);

      expect(cleaned, 'Turbo zieht durch. Bild ist da.');
    });

    test('truncates a dangling <previous_tool_results> opener mid-stream', () {
      const content = 'Reply text\n\n<previous_tool_results>\n[generate_image]';

      final cleaned = stripToolCallBlocksForDisplay(content);

      expect(cleaned, 'Reply text');
    });

    test('preserves prose mentioning previous tool results without tags', () {
      const content = 'I will reuse previous tool results here.';

      final cleaned = stripToolCallBlocksForDisplay(content);

      expect(cleaned, 'I will reuse previous tool results here.');
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
