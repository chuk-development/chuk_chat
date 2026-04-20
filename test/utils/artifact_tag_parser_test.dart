import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/utils/artifact_tag_parser.dart';
import 'package:chuk_chat/utils/tool_parser.dart';

void main() {
  group('parseArtifactTags', () {
    test('parses a single well-formed tag', () {
      const text = '''
Intro text.
<artifact id="foo" type="technical_drawing" title="Foo">
{"a":1}
</artifact>
Trailing text.
''';

      final tags = parseArtifactTags(text);
      expect(tags, hasLength(1));
      final tag = tags.first;
      expect(tag.id, 'foo');
      expect(tag.type, 'technical_drawing');
      expect(tag.title, 'Foo');
      expect(tag.content, '{"a":1}');
      expect(tag.language, isNull);
    });

    test('defaults title to id when title attr is missing', () {
      const text = '<artifact id="bar" type="code">print(1)</artifact>';
      final tags = parseArtifactTags(text);
      expect(tags, hasLength(1));
      expect(tags.first.title, 'bar');
    });

    test('parses optional language attr', () {
      const text = '<artifact id="x" type="code" language="dart">1</artifact>';
      final tags = parseArtifactTags(text);
      expect(tags.first.language, 'dart');
    });

    test('parses multiple tags in order', () {
      const text =
          '<artifact id="a" type="code">1</artifact>'
          'middle'
          '<artifact id="b" type="code">2</artifact>';
      final tags = parseArtifactTags(text);
      expect(tags.map((t) => t.id).toList(), ['a', 'b']);
    });

    test('skips tags missing required attributes', () {
      const text =
          '<artifact id="only-id">no type</artifact>'
          '<artifact type="code">no id</artifact>'
          '<artifact id="" type="code">empty id</artifact>';
      expect(parseArtifactTags(text), isEmpty);
    });

    test('skips tags with empty body', () {
      const text = '<artifact id="foo" type="code"></artifact>';
      expect(parseArtifactTags(text), isEmpty);
    });

    test('accepts single quotes around attributes', () {
      const text = "<artifact id='foo' type='code'>body</artifact>";
      final tags = parseArtifactTags(text);
      expect(tags, hasLength(1));
      expect(tags.first.id, 'foo');
    });

    test('is case-insensitive on the tag name', () {
      const text = '<Artifact ID="foo" Type="code">body</Artifact>';
      final tags = parseArtifactTags(text);
      expect(tags, hasLength(1));
      expect(tags.first.id, 'foo');
    });

    test('ignores a partial (unclosed) tag', () {
      const text = 'before <artifact id="x" type="code">{"a":';
      expect(parseArtifactTags(text), isEmpty);
    });

    test('preserves > inside quoted attribute values', () {
      const text =
          '<artifact id="chart>1" type="code" title="a>b">body</artifact>';
      final tags = parseArtifactTags(text);
      expect(tags, hasLength(1));
      expect(tags.first.id, 'chart>1');
      expect(tags.first.title, 'a>b');
      expect(tags.first.content, 'body');
    });
  });

  group('stripArtifactTagsForDisplay', () {
    test('removes complete artifact blocks', () {
      const text =
          'Hello <artifact id="x" type="code">payload</artifact> world';
      expect(stripArtifactTagsForDisplay(text).trim(), 'Hello  world');
    });

    test('strips incomplete opening tag by default', () {
      const text = 'Hello <artifact id="x" type="code">{"a":';
      expect(stripArtifactTagsForDisplay(text), 'Hello ');
    });

    test('leaves incomplete opening tag when stripIncomplete=false', () {
      const text = 'Hello <artifact id="x" type="code">{"a":';
      expect(
        stripArtifactTagsForDisplay(text, stripIncomplete: false),
        'Hello <artifact id="x" type="code">{"a":',
      );
    });

    test('does not strip unrelated text containing <artifact literal', () {
      // Text without a real tag — plain "<artifact" word should stay.
      const text = 'I will talk about artifacts in your code.';
      expect(stripArtifactTagsForDisplay(text), text);
    });
  });

  group('stripToolCallBlocksForDisplay (artifact integration)', () {
    test('removes both tool_call and artifact blocks', () {
      const text =
          'Pre '
          '<tool_call>{"name":"x","arguments":{}}</tool_call> '
          'mid '
          '<artifact id="a" type="code">payload</artifact> '
          'post';
      final out = stripToolCallBlocksForDisplay(text);
      expect(out.contains('<tool_call>'), isFalse);
      expect(out.contains('<artifact'), isFalse);
      expect(out.contains('Pre'), isTrue);
      expect(out.contains('post'), isTrue);
    });

    test('strips partial artifact tag during streaming', () {
      const text = 'Start <artifact id="a" type="code">partial body no close';
      final out = stripToolCallBlocksForDisplay(text);
      expect(out, 'Start');
    });
  });

  group('parseArtifactTags - robustness against common AI mistakes', () {
    test('accepts curly double quotes on attributes', () {
      const text =
          '<artifact id=\u201Cfoo\u201D type=\u201Cexcalidraw\u201D>\n'
          '{"type":"excalidraw","elements":[]}\n'
          '</artifact>';
      final tags = parseArtifactTags(text);
      expect(tags, hasLength(1));
      expect(tags.first.id, 'foo');
      expect(tags.first.type, 'excalidraw');
    });

    test('accepts curly single quotes on attributes', () {
      const text =
          '<artifact id=\u2018foo\u2019 type=\u2018excalidraw\u2019>\n'
          '{"type":"excalidraw","elements":[]}\n'
          '</artifact>';
      final tags = parseArtifactTags(text);
      expect(tags, hasLength(1));
      expect(tags.first.id, 'foo');
    });

    test('strips a single ```json fence wrapping the inner content', () {
      const text =
          '<artifact id="foo" type="excalidraw">\n'
          '```json\n'
          '{"type":"excalidraw","elements":[]}\n'
          '```\n'
          '</artifact>';
      final tags = parseArtifactTags(text);
      expect(tags, hasLength(1));
      expect(tags.first.content, '{"type":"excalidraw","elements":[]}');
    });

    test('strips a plain ``` fence (no language hint)', () {
      const text =
          '<artifact id="foo" type="svg">\n'
          '```\n'
          '<svg></svg>\n'
          '```\n'
          '</artifact>';
      final tags = parseArtifactTags(text);
      expect(tags.first.content, '<svg></svg>');
    });

    test('keeps a nested code fence that is part of a larger payload', () {
      const text =
          '<artifact id="foo" type="markdown">\n'
          'Intro paragraph.\n'
          '```dart\n'
          'print(1);\n'
          '```\n'
          'Outro paragraph.\n'
          '</artifact>';
      final tags = parseArtifactTags(text);
      expect(tags.first.content.contains('```dart'), isTrue);
      expect(tags.first.content.contains('Intro paragraph'), isTrue);
    });

    test('ignores a tag whose content is only whitespace', () {
      const text =
          '<artifact id="foo" type="excalidraw">\n   \n</artifact>';
      final tags = parseArtifactTags(text);
      expect(tags, isEmpty);
    });
  });
}
