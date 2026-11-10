import 'package:chuk_chat/services/tool_pairing_validator.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _assistant(List<String> ids) => {
  'role': 'assistant',
  'content': null,
  'tool_calls': [
    for (final id in ids)
      {
        'id': id,
        'type': 'function',
        'function': {'name': 'calculate', 'arguments': '{}'},
      },
  ],
};

Map<String, dynamic> _tool(String id, String content) => {
  'role': 'tool',
  'tool_call_id': id,
  'content': content,
};

List<String> _callIds(Map<String, dynamic> message) => [
  for (final c in message['tool_calls'] as List) (c as Map)['id'] as String,
];

void main() {
  test('a valid history passes through unchanged', () {
    final history = [
      {'role': 'user', 'content': 'q'},
      _assistant(['a', 'b']),
      _tool('a', '1'),
      _tool('b', '2'),
      {'role': 'assistant', 'content': 'done'},
    ];
    expect(validateToolPairing(history), history);
  });

  test('orphan tool results are dropped', () {
    final out = validateToolPairing([
      {'role': 'user', 'content': 'q'},
      _tool('ghost', 'x'),
      _assistant(['a']),
      _tool('a', '1'),
      _tool('other', 'y'),
    ]);
    expect(
      out.where((m) => m['role'] == 'tool').map((m) => m['tool_call_id']),
      ['a'],
    );
  });

  test('an unanswered call gets an error result right after its message', () {
    final out = validateToolPairing([
      _assistant(['a', 'b']),
      _tool('a', '1'),
      {'role': 'user', 'content': 'next'},
    ]);
    expect(out[1]['tool_call_id'], 'a');
    expect(out[2]['tool_call_id'], 'b');
    expect(out[2]['content'], kUnansweredToolCallResult);
    expect(out[3]['role'], 'user');
  });

  test('a result after a user turn does not answer an earlier call', () {
    final out = validateToolPairing([
      _assistant(['a']),
      {'role': 'user', 'content': 'next'},
      _tool('a', 'late'),
    ]);
    expect(out, hasLength(3));
    expect(out[1]['content'], kUnansweredToolCallResult);
    expect(out[2]['role'], 'user');
  });

  test('duplicate ids in one message are renamed, results follow in order', () {
    final out = validateToolPairing([
      _assistant(['x', 'x']),
      _tool('x', 'first'),
      _tool('x', 'second'),
    ]);
    expect(_callIds(out[0]), ['x', 'x_2']);
    expect(out[1], {'role': 'tool', 'tool_call_id': 'x', 'content': 'first'});
    expect(out[2], {
      'role': 'tool',
      'tool_call_id': 'x_2',
      'content': 'second',
    });
  });

  test('an id reused in a later round is renamed with its result', () {
    final out = validateToolPairing([
      _assistant(['call_0']),
      _tool('call_0', 'r1'),
      _assistant(['call_0']),
      _tool('call_0', 'r2'),
    ]);
    expect(_callIds(out[2]), ['call_0_2']);
    expect(out[3]['tool_call_id'], 'call_0_2');
    expect(out[3]['content'], 'r2');
  });

  test('a second answer for the same call is dropped', () {
    final out = validateToolPairing([
      _assistant(['a']),
      _tool('a', '1'),
      _tool('a', 'again'),
    ]);
    expect(out, hasLength(2));
  });

  test('the input is not modified', () {
    final assistant = _assistant(['x', 'x']);
    final history = [assistant, _tool('x', '1')];
    validateToolPairing(history);
    expect(_callIds(assistant), ['x', 'x']);
    expect(history, hasLength(2));
  });

  test('uniqueToolCallId adds suffixes', () {
    final used = <String>{'a', 'a_2'};
    expect(uniqueToolCallId('a', used), 'a_3');
    expect(uniqueToolCallId('b', used), 'b');
    expect(used, containsAll(['a_3', 'b']));
  });
}
