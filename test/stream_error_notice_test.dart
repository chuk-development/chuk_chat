import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:chuk_chat/utils/stream_error_notice.dart';

void main() {
  group('stripStreamErrorNotice', () {
    test('drops the connection notice on its own', () {
      expect(stripStreamErrorNotice(kConnectionErrorNotice), '');
    });

    test('drops the notice glued in front of a real answer', () {
      const String body = '$kConnectionErrorNotice**Step 5 Preview:**\n\n- 600B';
      expect(stripStreamErrorNotice(body), '**Step 5 Preview:**\n\n- 600B');
    });

    test('drops the notice twice over, as a second failure leaves it', () {
      const String body =
          '$kConnectionErrorNotice\n\n$kConnectionErrorNotice\n\nreal answer';
      expect(stripStreamErrorNotice(body), 'real answer');
    });

    test('drops the notice in the wrapped form desktop stores', () {
      expect(
        stripStreamErrorNotice('Error: $kConnectionErrorNotice'),
        '',
      );
      expect(
        stripStreamErrorNotice('half an answer\n\nError: $kConnectionErrorNotice'),
        'half an answer',
      );
    });

    test('keeps an answer that only talks about an error', () {
      const String body = 'The server returned an error and that is fine.';
      expect(stripStreamErrorNotice(body), body);
    });

    test('leaves a generic Error: line alone', () {
      // An answer may legitimately end on one, and rewriting it would change
      // what the model said.
      const String body = 'half an answer\n\nError: invalid syntax';
      expect(stripStreamErrorNotice(body), body);
    });
  });

  group('stripStreamErrorNoticeFromBlocksJson', () {
    test('removes a text block that only held the notice', () {
      final String blocks = jsonEncode(<Map<String, dynamic>>[
        {'type': 'text', 'text': kConnectionErrorNotice},
        {'type': 'reasoning', 'text': 'thinking'},
        {'type': 'text', 'text': 'the answer'},
      ]);
      final String? out = stripStreamErrorNoticeFromBlocksJson(blocks);
      final List<dynamic> decoded = jsonDecode(out!) as List<dynamic>;
      expect(decoded.length, 2);
      expect((decoded.first as Map)['type'], 'reasoning');
      expect((decoded.last as Map)['text'], 'the answer');
    });

    test('returns null when nothing survives', () {
      final String blocks = jsonEncode(<Map<String, dynamic>>[
        {'type': 'text', 'text': kConnectionErrorNotice},
      ]);
      expect(stripStreamErrorNoticeFromBlocksJson(blocks), isNull);
    });

    test('leaves other payloads alone', () {
      expect(stripStreamErrorNoticeFromBlocksJson(null), isNull);
      expect(stripStreamErrorNoticeFromBlocksJson('not json'), 'not json');
    });
  });
}
