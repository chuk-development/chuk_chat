import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:chuk_chat/utils/debug_chat_formatter.dart';

void main() {
  group('DebugChatFormatter', () {
    test('redacts image payloads from images field', () {
      final messages = [
        <String, String>{
          'sender': 'user',
          'text': 'hello',
          'images': jsonEncode(['data:image/jpeg;base64,QUJDREVGR0g=']),
        },
      ];

      final formatted = DebugChatFormatter.format(messages);

      expect(formatted.contains('data:image'), isFalse);
      expect(
        formatted.contains('Images: 1 (content omitted from clipboard)'),
        isTrue,
      );
    });

    test('redacts image payloads from debug request payloads', () {
      final messages = [
        <String, String>{
          'sender': 'assistant',
          'debugRequests': jsonEncode([
            {
              'images': ['data:image/png;base64,SGVsbG8='],
              'message': 'check this',
            },
          ]),
        },
      ];

      final formatted = DebugChatFormatter.format(messages);

      expect(formatted.contains('data:image'), isFalse);
      expect(formatted.contains('[image removed]'), isTrue);
    });
  });
}
