import 'package:chuk_chat/platform_specific/chat/transcript_row_memo.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('hands back the same row while message and inputs hold', () {
    final TranscriptRowMemo memo = TranscriptRowMemo();
    final Map<String, String> message = <String, String>{'text': 'hi'};
    const Widget row = SizedBox();
    memo.store(0, message, <Object?>[1, 'a'], row);
    expect(memo.lookup(0, message, <Object?>[1, 'a']), same(row));
  });

  test('an in-place edit of the message map misses', () {
    final TranscriptRowMemo memo = TranscriptRowMemo();
    final Map<String, String> message = <String, String>{'text': 'hi'};
    memo.store(0, message, const <Object?>[], const SizedBox());
    message['text'] = 'hi there';
    expect(memo.lookup(0, message, const <Object?>[]), isNull);
  });

  test('a changed input misses', () {
    final TranscriptRowMemo memo = TranscriptRowMemo();
    final Map<String, String> message = <String, String>{'text': 'hi'};
    memo.store(0, message, <Object?>[true], const SizedBox());
    expect(memo.lookup(0, message, <Object?>[false]), isNull);
  });

  test('trimTo drops rows past the new length, clear drops all', () {
    final TranscriptRowMemo memo = TranscriptRowMemo();
    for (int i = 0; i < 4; i++) {
      memo.store(i, <String, String>{}, const <Object?>[], const SizedBox());
    }
    memo.trimTo(2);
    expect(memo.length, 2);
    expect(memo.lookup(3, <String, String>{}, const <Object?>[]), isNull);
    memo.clear();
    expect(memo.length, 0);
  });
}
