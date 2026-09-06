import 'package:flutter_test/flutter_test.dart';

import 'package:cowork/utils/lenient_json.dart';

void main() {
  group('stripTrailingCommas', () {
    test('drops a comma before a closing brace or bracket', () {
      expect(stripTrailingCommas('{"a":[1,2,],}'), '{"a":[1,2]}');
    });

    test('leaves a comma inside a string alone', () {
      const source = '{"caption":"A,}","b":1,}';
      expect(stripTrailingCommas(source), '{"caption":"A,}","b":1}');
    });

    test('survives an escaped quote in a string', () {
      const source = r'{"t":"say \"hi\",}","n":1,}';
      expect(stripTrailingCommas(source), r'{"t":"say \"hi\",}","n":1}');
    });

    test('keeps structural commas', () {
      expect(stripTrailingCommas('{"a":1,"b":2}'), '{"a":1,"b":2}');
    });
  });

  group('tryDecodeLenientJsonObject', () {
    test('reads a fenced body with a trailing comma', () {
      final decoded = tryDecodeLenientJsonObject(
        '```json\n{"type":"bar","labels":["a"],}\n```',
      );

      expect(decoded?['type'], 'bar');
    });

    test('keeps a comma that belongs to the text', () {
      final decoded = tryDecodeLenientJsonObject('{"caption":"A,}","v":1,}');

      expect(decoded?['caption'], 'A,}');
      expect(decoded?['v'], 1);
    });

    test('returns null for text that is not JSON', () {
      expect(tryDecodeLenientJsonObject('not json'), isNull);
      expect(tryDecodeLenientJsonObject('[1,2]'), isNull);
    });
  });
}
