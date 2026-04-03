import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/platform_specific/chat/chat_ui_helpers.dart';

void main() {
  group('ChatUiHelpers.finalizeStaleToolCallsInRawMessage', () {
    test('finalizes stale toolCalls JSON entries', () {
      final message = <String, String>{
        'sender': 'ai',
        'text': 'Test',
        'toolCalls': jsonEncode([
          ToolCall(
            id: 'tc-1',
            name: 'web_search',
            status: ToolCallStatus.running,
          ).toJson(),
        ]),
      };

      final changed = ChatUiHelpers.finalizeStaleToolCallsInRawMessage(message);

      expect(changed, isTrue);
      final decoded = (jsonDecode(message['toolCalls']!) as List).cast<Map>();
      final restored = ToolCall.fromJson(Map<String, dynamic>.from(decoded[0]));
      expect(restored.status, ToolCallStatus.error);
      expect(restored.result, isNotEmpty);
    });

    test('finalizes stale toolCalls inside contentBlocks JSON', () {
      final block = ContentBlock.toolCalls([
        ToolCall(
          id: 'tc-2',
          name: 'search_places',
          status: ToolCallStatus.pending,
        ),
      ]);
      final message = <String, String>{
        'sender': 'ai',
        'text': 'Test',
        'contentBlocks': jsonEncode([block.toJson()]),
      };

      final changed = ChatUiHelpers.finalizeStaleToolCallsInRawMessage(message);

      expect(changed, isTrue);
      final decoded = (jsonDecode(message['contentBlocks']!) as List)
          .cast<Map>();
      final restoredBlock = ContentBlock.fromJson(
        Map<String, dynamic>.from(decoded[0]),
      );
      expect(restoredBlock.toolCalls, isNotNull);
      expect(restoredBlock.toolCalls!.first.status, ToolCallStatus.error);
    });

    test('does nothing when all tool calls are already terminal', () {
      final message = <String, String>{
        'sender': 'ai',
        'text': 'Done',
        'toolCalls': jsonEncode([
          ToolCall(
            id: 'tc-3',
            name: 'weather',
            status: ToolCallStatus.completed,
            result: 'Sunny',
          ).toJson(),
        ]),
      };

      final changed = ChatUiHelpers.finalizeStaleToolCallsInRawMessage(message);

      expect(changed, isFalse);
    });
  });
}
