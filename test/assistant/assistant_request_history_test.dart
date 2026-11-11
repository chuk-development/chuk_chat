// B21: the voice assistant sent its first user turn twice, once at the end of
// the history and once as `message`, which the server appends again.

import 'package:chuk_chat/assistant/assistant_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the first pass leaves the trailing user turn out of the history', () {
    final history = <Map<String, dynamic>>[
      {'role': 'user', 'content': 'earlier question'},
      {'role': 'assistant', 'content': 'earlier answer'},
      {'role': 'user', 'content': 'wie spät ist es'},
    ];
    final sent = assistantRequestHistory(history, 'wie spät ist es');
    expect(sent, hasLength(2));
    expect(sent.last['content'], 'earlier answer');
    expect(history, hasLength(3), reason: 'the session history is untouched');
  });

  test('a tool-result pass (empty message) keeps the full history', () {
    final history = <Map<String, dynamic>>[
      {'role': 'user', 'content': 'q'},
      {'role': 'assistant', 'content': null, 'tool_calls': []},
      {'role': 'tool', 'tool_call_id': 'a', 'content': 'r'},
    ];
    expect(assistantRequestHistory(history, ''), history);
  });

  test('a different trailing turn is kept', () {
    final history = <Map<String, dynamic>>[
      {'role': 'system', 'content': 'screen'},
    ];
    expect(assistantRequestHistory(history, 'q'), history);
  });
}
