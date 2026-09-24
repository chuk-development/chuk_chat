// Chat payload v3: every tool call stored once, nested fields as real JSON,
// roundThinking by reference — and lossless: v2 -> v3 -> messages equals
// v2 -> messages. The real-data proof over a copy of a production cache is
// test/manual/chat_payload_v3_real_data_test.dart.

import 'dart:convert';

import 'package:chuk_chat/models/chat_message.dart';
import 'package:chuk_chat/services/chat_payload_codec.dart';
import 'package:chuk_chat/services/chat_storage_sync.dart'
    show deserializePayloadIsolate;
import 'package:flutter_test/flutter_test.dart';

/// A tool turn the way the app stores it in v2: the same tool calls (with
/// their results) in `toolCalls` and inside a `toolCalls` content block, and
/// each round's thinking in a reasoning block and in `roundThinking`.
Map<String, dynamic> _toolTurn({String result = 'RESULT ', int repeat = 400}) {
  final bigResult = List.filled(repeat, result).join();
  final calls = [
    {
      'id': 'call_1',
      'name': 'web_search',
      'arguments': '{"q":"wetter kiel"}',
      'status': 'completed',
      'result': bigResult,
      'startedAt': '2026-09-24T10:00:00.000Z',
      'completedAt': '2026-09-24T10:00:01.000Z',
      'roundThinking': 'I should search the weather first.',
    },
    {
      'id': 'call_2',
      'name': 'fetch',
      'arguments': '{"url":"https://example.org"}',
      'status': 'completed',
      'result': 'page body ${bigResult.substring(0, 100)}',
      'roundThinking': 'Now fetch the page.',
    },
    {
      'id': 'call_3',
      'name': 'calc',
      'arguments': '{}',
      'status': 'completed',
      'result': '42',
      // In the message reasoning, not in any block.
      'roundThinking': 'middle part',
    },
    {
      'id': 'call_4',
      'name': 'calc',
      'arguments': '{}',
      'status': 'completed',
      'result': '43',
      // Nowhere else: stays a string.
      'roundThinking': 'thought only stored here',
    },
  ];
  final blocks = [
    {'type': 'reasoning', 'text': 'I should search the weather first.'},
    {
      'type': 'toolCalls',
      'toolCalls': [calls[0]],
    },
    {'type': 'reasoning', 'text': 'Now fetch the page.'},
    {
      'type': 'toolCalls',
      'toolCalls': [
        calls[1],
        // Same id, different bytes (an older status): kept as it is.
        {...calls[2], 'status': 'running'},
        calls[3],
      ],
    },
    {'type': 'text', 'text': 'Es sind 14 Grad.'},
  ];
  return ChatMessage(
    role: 'assistant',
    text: 'Es sind 14 Grad.',
    reasoning: 'start, middle part, end',
    toolCalls: jsonEncode(calls),
    contentBlocks: jsonEncode(blocks),
    modelId: 'deepseek/deepseek-v4-flash-0731',
    provider: 'fireworks',
    messageId: 'm-1',
    generationMs: '1234',
    status: ChatMessageStatus.interrupted,
    images: jsonEncode(['user-1/a.enc']),
    variants: jsonEncode([
      {'text': 'old answer', 'modelId': 'x', 'tps': '12.5'},
    ]),
    activeVariant: 1,
  ).toJson();
}

Map<String, dynamic> _v2Payload(List<Map<String, dynamic>> messages) => {
  'v': 2,
  'messages': messages,
  'customName': 'Wetter',
};

List<String> _inMemory(String payloadJson) => [
  for (final m in deserializePayloadIsolate(payloadJson).messages)
    jsonEncode(ChatMessage.fromJson(m).toJson()),
];

void main() {
  final messages = <Map<String, dynamic>>[
    ChatMessage(role: 'user', text: 'Wie ist das Wetter in Kiel?').toJson(),
    _toolTurn(),
  ];
  final v2 = jsonEncode(_v2Payload(messages));

  group('v3 round trip', () {
    test('v2 -> v3 -> messages equals v2 -> messages', () {
      final v3 = encodeChatPayload(messages, customName: 'Wetter');
      expect(_inMemory(v3), _inMemory(v2));
      expect(deserializePayloadIsolate(v3).customName, 'Wetter');
      expect(peekChatPayloadVersion(v3), 3);
    });

    test('each tool call and its result is stored once', () {
      final v3 = encodeChatPayload(messages, customName: 'Wetter');
      final marker = 'RESULT RESULT RESULT';
      expect(marker.allMatches(v2).length, greaterThan(1));
      // The big result appears once in v3 (call_2 holds only a prefix).
      final v3Message = (jsonDecode(v3)['messages'] as List)[1] as Map;
      final blocks = v3Message['contentBlocks'] as List;
      expect((blocks[1] as Map)['toolCalls'], [0]);
      // call_2 and call_4 are references; the changed call_3 is kept.
      final second = (blocks[3] as Map)['toolCalls'] as List;
      expect(second[0], 1);
      expect(second[1], isA<Map>());
      expect(second[2], 3);
      expect(v3.length, lessThan(v2.length * 0.7));
    });

    test('roundThinking becomes a reference only where the text exists', () {
      final v3 = encodeChatPayload(messages);
      final v3Message = (jsonDecode(v3)['messages'] as List)[1] as Map;
      final calls = v3Message['toolCalls'] as List;
      expect((calls[0] as Map)['roundThinking'], 0); // reasoning block 0
      expect((calls[1] as Map)['roundThinking'], 2); // reasoning block 2
      expect((calls[2] as Map)['roundThinking'], [7, 11]); // in `reasoning`
      expect((calls[3] as Map)['roundThinking'], 'thought only stored here');
      expect(v3Message['_ref'], 3);
    });

    test('nested fields are real JSON, not JSON in a string', () {
      final v3Message =
          (jsonDecode(encodeChatPayload(messages))['messages'] as List)[1]
              as Map;
      expect(v3Message['images'], ['user-1/a.enc']);
      expect(v3Message['variants'], isA<List>());
      expect(v3Message['toolCalls'], isA<List>());
    });

    test('a string that does not re-encode byte for byte stays a string', () {
      final m = ChatMessage(
        role: 'assistant',
        text: 'x',
        // Pretty-printed JSON: jsonEncode(jsonDecode(s)) != s.
        toolCalls: '[ {"id": "a", "result": "r"} ]',
        contentBlocks: 'not json at all',
        images: '"a string, not a list"',
      ).toJson();
      final v3 = encodeChatPayload([m]);
      final stored = (jsonDecode(v3)['messages'] as List).single as Map;
      expect(stored['toolCalls'], '[ {"id": "a", "result": "r"} ]');
      expect(stored['contentBlocks'], 'not json at all');
      expect(stored['images'], '"a string, not a list"');
      expect(_inMemory(v3), _inMemory(jsonEncode(_v2Payload([m]))));
    });

    test('ints that are data are never read as references', () {
      final m = ChatMessage(
        role: 'assistant',
        text: 'x',
        toolCalls: jsonEncode([
          {'id': 'a', 'result': 'r', 'roundThinking': 5},
        ]),
        contentBlocks: jsonEncode([
          {
            'type': 'toolCalls',
            'toolCalls': [0, 1],
          },
          {'type': 'reasoning', 'text': 'r'},
        ]),
      ).toJson();
      final v3 = encodeChatPayload([m]);
      expect(_inMemory(v3), _inMemory(jsonEncode(_v2Payload([m]))));
    });

    test('a v3 message without references reads like v2', () {
      final plain = ChatMessage(role: 'user', text: 'hallo').toJson();
      final v3 = jsonEncode({
        'v': 3,
        'messages': [plain],
      });
      expect(_inMemory(v3), [jsonEncode(plain)]);
    });
  });

  group('versions', () {
    test('v1 is still normalised', () {
      final v1 = jsonEncode({
        'messages': [
          {'role': 'assistant', 'text': 'a', 'toolCalls': '[]', 'extra': 1},
        ],
      });
      final decoded = decodeChatPayload(v1);
      expect(decoded.version, 1);
      expect(decoded.messages.single.containsKey('extra'), isFalse);
      expect(decoded.messages.single['toolCalls'], '[]');
    });

    test('a newer version is refused, not read as v1', () {
      expect(
        () => decodeChatPayload('{"v":4,"messages":[]}'),
        throwsUnsupportedError,
      );
    });

    test('toChatPayloadV3 converts v1/v2 and passes v3 through', () {
      final v3 = toChatPayloadV3(v2);
      expect(peekChatPayloadVersion(v3), 3);
      expect(identical(toChatPayloadV3(v3), v3), isTrue);
      expect(toChatPayloadV3Verified(v2), v3);
    });

    test('equivalence ignores fields toJson drops', () {
      final a = DecodedChatPayload([
        {'role': 'user', 'text': 'x', 'reasoning': ''},
      ]);
      final b = DecodedChatPayload([
        {'role': 'user', 'text': 'x'},
      ]);
      final c = DecodedChatPayload([
        {'role': 'user', 'text': 'y'},
      ]);
      expect(chatPayloadsEquivalent(a, b), isTrue);
      expect(chatPayloadsEquivalent(a, c), isFalse);
    });
  });
}
