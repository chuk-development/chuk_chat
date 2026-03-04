import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/models/tool_call.dart';

void main() {
  group('ContentBlock constructors', () {
    test('text block', () {
      const block = ContentBlock.text('Hello world');
      expect(block.type, equals(ContentBlockType.text));
      expect(block.text, equals('Hello world'));
      expect(block.toolCalls, isNull);
    });

    test('reasoning block', () {
      const block = ContentBlock.reasoning('Let me think...');
      expect(block.type, equals(ContentBlockType.reasoning));
      expect(block.text, equals('Let me think...'));
      expect(block.toolCalls, isNull);
    });

    test('toolCalls block', () {
      final calls = [
        ToolCall(name: 'web_search', arguments: {'query': 'test'}),
      ];
      final block = ContentBlock.toolCalls(calls);
      expect(block.type, equals(ContentBlockType.toolCalls));
      expect(block.text, isNull);
      expect(block.toolCalls, hasLength(1));
      expect(block.toolCalls!.first.name, equals('web_search'));
    });
  });

  group('ContentBlock toJson', () {
    test('text block serializes correctly', () {
      const block = ContentBlock.text('Hello');
      final json = block.toJson();
      expect(json['type'], equals('text'));
      expect(json['text'], equals('Hello'));
      expect(json.containsKey('toolCalls'), isFalse);
    });

    test('reasoning block serializes correctly', () {
      const block = ContentBlock.reasoning('Thinking...');
      final json = block.toJson();
      expect(json['type'], equals('reasoning'));
      expect(json['text'], equals('Thinking...'));
    });

    test('toolCalls block serializes correctly', () {
      final calls = [
        ToolCall(
          id: 'call-1',
          name: 'calculate',
          arguments: {'expression': '2+2'},
          result: '4',
          status: ToolCallStatus.completed,
        ),
      ];
      final block = ContentBlock.toolCalls(calls);
      final json = block.toJson();
      expect(json['type'], equals('toolCalls'));
      expect(json['toolCalls'], isList);
      final toolCallJson = (json['toolCalls'] as List).first;
      expect(toolCallJson['name'], equals('calculate'));
      expect(toolCallJson['result'], equals('4'));
      expect(toolCallJson['status'], equals('completed'));
    });
  });

  group('ContentBlock fromJson', () {
    test('text block deserializes', () {
      final block = ContentBlock.fromJson({'type': 'text', 'text': 'Hello'});
      expect(block.type, equals(ContentBlockType.text));
      expect(block.text, equals('Hello'));
    });

    test('reasoning block deserializes', () {
      final block = ContentBlock.fromJson({
        'type': 'reasoning',
        'text': 'Let me think',
      });
      expect(block.type, equals(ContentBlockType.reasoning));
      expect(block.text, equals('Let me think'));
    });

    test('toolCalls block deserializes', () {
      final block = ContentBlock.fromJson({
        'type': 'toolCalls',
        'toolCalls': [
          {
            'id': 'call-1',
            'name': 'web_search',
            'arguments': {'query': 'test'},
            'result': 'found it',
            'status': 'completed',
          },
        ],
      });
      expect(block.type, equals(ContentBlockType.toolCalls));
      expect(block.toolCalls, hasLength(1));
      expect(block.toolCalls!.first.name, equals('web_search'));
      expect(block.toolCalls!.first.result, equals('found it'));
      expect(block.toolCalls!.first.status, equals(ToolCallStatus.completed));
    });

    test('unknown type defaults to text', () {
      final block = ContentBlock.fromJson({
        'type': 'unknown_type',
        'text': 'fallback',
      });
      expect(block.type, equals(ContentBlockType.text));
      expect(block.text, equals('fallback'));
    });

    test('missing type defaults to text', () {
      final block = ContentBlock.fromJson({'text': 'no type'});
      expect(block.type, equals(ContentBlockType.text));
    });
  });

  group('ContentBlock roundtrip', () {
    test('text block roundtrip', () {
      const original = ContentBlock.text('Hello world');
      final restored = ContentBlock.fromJson(original.toJson());
      expect(restored.type, equals(original.type));
      expect(restored.text, equals(original.text));
    });

    test('reasoning block roundtrip', () {
      const original = ContentBlock.reasoning('Deep thought');
      final restored = ContentBlock.fromJson(original.toJson());
      expect(restored.type, equals(original.type));
      expect(restored.text, equals(original.text));
    });

    test('toolCalls block roundtrip', () {
      final calls = [
        ToolCall(
          id: 'call-1',
          name: 'web_search',
          arguments: {'query': 'flutter'},
          result: 'A UI framework',
          status: ToolCallStatus.completed,
        ),
        ToolCall(
          id: 'call-2',
          name: 'calculate',
          arguments: {'expression': '1+1'},
          status: ToolCallStatus.running,
        ),
      ];
      final original = ContentBlock.toolCalls(calls);
      final restored = ContentBlock.fromJson(original.toJson());
      expect(restored.type, equals(ContentBlockType.toolCalls));
      expect(restored.toolCalls, hasLength(2));
      expect(restored.toolCalls![0].name, equals('web_search'));
      expect(restored.toolCalls![0].result, equals('A UI framework'));
      expect(restored.toolCalls![1].name, equals('calculate'));
      expect(restored.toolCalls![1].status, equals(ToolCallStatus.running));
    });

    test('JSON-encoded list of blocks roundtrip', () {
      final blocks = [
        const ContentBlock.text('Let me search for that'),
        ContentBlock.toolCalls([
          ToolCall(
            id: 'c1',
            name: 'web_search',
            arguments: {'query': 'dart'},
            result: 'Dart is a language',
            status: ToolCallStatus.completed,
          ),
        ]),
        const ContentBlock.reasoning('Analyzing results...'),
        const ContentBlock.text('Here are the results'),
      ];

      final json = jsonEncode(blocks.map((b) => b.toJson()).toList());
      final decoded = (jsonDecode(json) as List)
          .whereType<Map>()
          .map((m) => ContentBlock.fromJson(Map<String, dynamic>.from(m)))
          .toList();

      expect(decoded, hasLength(4));
      expect(decoded[0].type, equals(ContentBlockType.text));
      expect(decoded[0].text, equals('Let me search for that'));
      expect(decoded[1].type, equals(ContentBlockType.toolCalls));
      expect(decoded[1].toolCalls, hasLength(1));
      expect(decoded[2].type, equals(ContentBlockType.reasoning));
      expect(decoded[2].text, equals('Analyzing results...'));
      expect(decoded[3].type, equals(ContentBlockType.text));
      expect(decoded[3].text, equals('Here are the results'));
    });
  });
}
