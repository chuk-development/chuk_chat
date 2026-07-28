import 'package:flutter_test/flutter_test.dart';
import 'package:chuk_chat/utils/tool_parser.dart';

/// Deny-by-default guard: a tool-call dialect this app does not parse must
/// never reach the user, and must still register as a tool round so the
/// malformed-protocol recovery re-prompts for `<tool_call>`.
void main() {
  group('foreign tool-call protocols are hidden from the user', () {
    const samples = <String, String>{
      'namespaced wrapper (MiniMax-style)':
          '<minimax:tool_call>\n<invoke name="web_search">\n'
              '<parameter name="query">magellan</parameter>\n</invoke>\n'
              '</minimax:tool_call>',
      'bare invoke block':
          '<invoke name="web_search">'
              '<parameter name="query">magellan</parameter></invoke>',
      'OpenAI-ish function_call tag':
          '<function_call>{"name":"web_search","arguments":{}}</function_call>',
      'plural tool_calls wrapper':
          '<tool_calls>[{"name":"web_search","arguments":{}}]</tool_calls>',
    };

    samples.forEach((label, raw) {
      test('$label is stripped from display', () {
        expect(stripToolCallBlocksForDisplay('Moment.\n\n$raw'), 'Moment.');
      });

      test('$label counts as a tool-call start marker', () {
        expect(hasToolCallStartMarker(raw), isTrue);
      });
    });

    test('Mistral [TOOL_CALLS] marker is stripped and detected', () {
      const raw = 'Einen Moment.\n[TOOL_CALLS][{"name": "web_search"}]';

      expect(stripToolCallBlocksForDisplay(raw), 'Einen Moment.');
      expect(hasToolCallStartMarker(raw), isTrue);
    });

    test('Llama <|python_tag|> marker is stripped and detected', () {
      const raw = 'Einen Moment.\n<|python_tag|>web_search.call(query="x")';

      expect(stripToolCallBlocksForDisplay(raw), 'Einen Moment.');
      expect(hasToolCallStartMarker(raw), isTrue);
    });

    test('DeepSeek full-width tool-call token is stripped', () {
      const raw = 'Einen Moment.\n<｜tool▁calls▁begin｜>';

      expect(stripToolCallBlocksForDisplay(raw), 'Einen Moment.');
      expect(hasToolCallStartMarker(raw), isTrue);
    });

    test('an unterminated foreign opener truncates the protocol tail', () {
      const raw = 'Ich schaue nach.\n\n<minimax:tool_call>\n<invoke name="web_';

      expect(stripToolCallBlocksForDisplay(raw), 'Ich schaue nach.');
    });

    test('prose after a complete foreign block survives', () {
      const raw =
          'Vorher.\n<function_call>{"name":"web_search"}</function_call>\n'
          'Nachher.';

      expect(stripToolCallBlocksForDisplay(raw), 'Vorher.\n\nNachher.');
    });
  });

  group('code spans are never mangled', () {
    test('a fenced example of a foreign protocol is kept verbatim', () {
      const raw =
          'MiniMax sendet das hier:\n\n'
          '```xml\n<minimax:tool_call>\n<invoke name="web_search" />\n'
          '</minimax:tool_call>\n```\n\n'
          'Deshalb leakt es.';

      expect(stripToolCallBlocksForDisplay(raw), raw);
      expect(hasToolCallStartMarker(raw), isFalse);
    });

    test('inline code with a foreign tag is kept', () {
      // NB: the canonical `<tool_call>` strip predates this layer and is not
      // code-aware, so it is deliberately left out of this sample.
      const raw = 'Das Format ist `<function_call>`, wir nutzen `<invoke>` nie.';

      expect(stripToolCallBlocksForDisplay(raw), raw);
    });

    test('inline code before a still-open fence stays protected', () {
      // Regression: the fence scan used to return early on an unterminated
      // fence, so inline spans earlier in the same text were never collected.
      const raw =
          'Das Format heißt `<function_call>`, Beispiel:\n\n```xml\n<invoke';

      expect(stripToolCallBlocksForDisplay(raw), raw);
      expect(hasToolCallStartMarker(raw), isFalse);
    });

    test('an unterminated fence protects the in-flight code block', () {
      const raw = 'Beispiel:\n\n```xml\n<invoke name="web_search">';

      expect(stripToolCallBlocksForDisplay(raw), raw);
      expect(hasToolCallStartMarker(raw), isFalse);
    });
  });

  group('MiniMax-M2 invoke format is parsed, not just hidden', () {
    const raw =
        '<minimax:tool_call>\n'
        '<invoke name="web_search">\n'
        '<parameter name="query">magellan weltumseglung</parameter>\n'
        '<parameter name="count">5</parameter>\n'
        '<parameter name="deep">true</parameter>\n'
        '</invoke>\n'
        '</minimax:tool_call>';

    test('name and arguments are extracted', () {
      final calls = parseToolCalls(raw);

      expect(calls, hasLength(1));
      expect(calls.first['name'], 'web_search');
      expect(calls.first['arguments'], {
        'query': 'magellan weltumseglung',
        'count': 5,
        'deep': true,
      });
    });

    test('two invokes in one wrapper both parse, in order', () {
      const two =
          '<minimax:tool_call>'
          '<invoke name="web_search"><parameter name="q">a</parameter></invoke>'
          '<invoke name="web_crawl"><parameter name="url">b</parameter></invoke>'
          '</minimax:tool_call>';

      final calls = parseToolCalls(two);

      expect(calls.map((c) => c['name']), ['web_search', 'web_crawl']);
    });

    test('hasToolCalls sees it', () {
      expect(hasToolCalls(raw), isTrue);
    });

    test('a value that merely looks literal stays a string', () {
      const tricky =
          '<invoke name="web_search">'
          '<parameter name="query">null and void</parameter>'
          '<parameter name="street">42 b</parameter>'
          '</invoke>';

      expect(parseToolCalls(tricky).first['arguments'], {
        'query': 'null and void',
        'street': '42 b',
      });
    });

    test('a preceding attribute cannot hijack the name capture', () {
      // Without a word boundary the non-greedy scan matches the tail of
      // `displayname=` and executes the wrong tool.
      const decorated =
          '<invoke displayname="Wetter" name="get_weather">'
          '<parameter displayname="Ort" name="city">Kiel</parameter>'
          '</invoke>';

      final calls = parseToolCalls(decorated);

      expect(calls.first['name'], 'get_weather');
      expect(calls.first['arguments'], {'city': 'Kiel'});
    });

    test('an example inside a code fence is never executed', () {
      const fenced =
          'So sieht das aus:\n\n```xml\n$raw\n```\n\nDeshalb der Parser.';

      expect(parseToolCalls(fenced), isEmpty);
      expect(hasToolCalls(fenced), isFalse);
    });
  });

  group('regressions', () {
    test('plain prose is untouched', () {
      const raw = 'Magellan startete 1519 mit fünf Schiffen.';

      expect(stripToolCallBlocksForDisplay(raw), raw);
      expect(hasToolCallStartMarker(raw), isFalse);
    });

    test('the canonical format still parses after the new strip layer', () {
      const raw =
          '<tool_call>{"name":"web_search","arguments":{"query":"x"}}'
          '</tool_call>';

      final calls = parseToolCalls(raw);
      expect(calls, hasLength(1));
      expect(calls.first['name'], 'web_search');
      expect(stripToolCallBlocksForDisplay(raw), isEmpty);
    });

    test('the canonical tag is not treated as a foreign dialect', () {
      // `<tool_call>` is ours; only `<minimax:tool_call>` / `<tool_calls>`
      // are foreign. A complete canonical block is removed by the canonical
      // strip, and prose around it survives either way.
      const raw =
          'Vorher.\n<tool_call>{"name":"web_search","arguments":{}}</tool_call>'
          '\nNachher.';

      expect(stripToolCallBlocksForDisplay(raw), 'Vorher.\n\nNachher.');
      expect(parseToolCalls(raw), hasLength(1));
    });

    test('foreign protocol yields no parsed calls (recovery re-prompts)', () {
      const raw = '<function_call>{"name":"web_search"}</function_call>';

      expect(parseToolCalls(raw), isEmpty);
      expect(hasToolCallStartMarker(raw), isTrue);
    });
  });
}
