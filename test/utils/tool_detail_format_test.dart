// What a tool's arguments and result look like when the reader opens a step.

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/utils/tool_detail_format.dart';

void main() {
  group('json', () {
    test('a one-line result is indented', () {
      const raw =
          '{"job":{"id":"e43ba948","status":"success",'
          '"result":{"generated_designs":[{"candidate_id":"dg-0e72"}]}}}';

      final body = classifyToolBody(raw);

      expect(body.kind, ToolBodyKind.json);
      expect(body.text, contains('\n'));
      expect(body.text, contains('    "status": "success"'));
    });

    test('an array counts too', () {
      final body = classifyToolBody('[{"a":1},{"b":2}]');
      expect(body.kind, ToolBodyKind.json);
    });

    test('a bare number is a number, not a document', () {
      expect(classifyToolBody('42').kind, ToolBodyKind.text);
      expect(classifyToolBody('"hello"').kind, ToolBodyKind.text);
      expect(classifyToolBody('true').kind, ToolBodyKind.text);
    });

    test('a truncated result is left as it came', () {
      // Tool results are cut at a length limit, which lands mid-object.
      const cut = '{"designs":[{"url":"https://example.com/a","thumb';
      expect(classifyToolBody(cut).kind, ToolBodyKind.text);
    });

    test('prose that opens with a brace is not json', () {
      const prose = '{not json, just a sentence that starts oddly}';
      expect(classifyToolBody(prose).kind, ToolBodyKind.text);
    });

    test('json wins over the markdown inside it', () {
      const raw = '{"query":"**Presentation Brief**\\n* **Title**: How it works"}';
      expect(classifyToolBody(raw).kind, ToolBodyKind.json);
    });
  });

  group('markdown', () {
    test('a brief with headings and bullets is rendered', () {
      const raw = '''
**Presentation Brief**
* **Title**: How the Internet Works
* **Key Messages**: device, DNS, server
''';

      final body = classifyToolBody(raw);

      expect(body.kind, ToolBodyKind.markdown);
      expect(body.text, raw);
    });

    test('one marker on its own is not enough', () {
      // A lone asterisk is a wildcard as often as it is emphasis.
      expect(classifyToolBody('search for *.dart files').kind,
          ToolBodyKind.text);
      expect(
        classifyToolBody('the value is 3 * 4 and nothing else').kind,
        ToolBodyKind.text,
      );
    });

    test('a plain sentence stays plain', () {
      expect(
        classifyToolBody('Berlin, Germany').kind,
        ToolBodyKind.text,
      );
    });

    test('an empty body stays empty', () {
      expect(classifyToolBody('').kind, ToolBodyKind.text);
      expect(classifyToolBody('   ').kind, ToolBodyKind.text);
    });
  });
}
