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

      // Compact summary — raw request JSON is no longer dumped. The image
      // payload must not appear anywhere in the output; a summary line
      // replaces the full dump.
      expect(formatted.contains('data:image'), isFalse);
      expect(formatted.contains('Request Payloads:'), isTrue);
    });

    test('never includes a system prompt section', () {
      final messages = [
        <String, String>{'sender': 'user', 'text': 'hi'},
      ];

      final formatted = DebugChatFormatter.format(
        messages,
        context: {'Model': 'x'},
      );

      // The system prompt is intentionally excluded from debug copies so
      // sensitive or injected prompt scaffolding never lands on the clipboard.
      expect(formatted.contains('--- System Prompt ---'), isFalse);
    });

    test('renders context block with provided keys in order', () {
      final messages = [
        <String, String>{'sender': 'user', 'text': 'hi'},
      ];

      final formatted = DebugChatFormatter.format(
        messages,
        context: {
          'Model': 'claude-opus-4-6',
          'Provider': 'anthropic',
          'Workspace': '',
          'Platform': 'desktop',
        },
      );

      expect(formatted.contains('--- Context ---'), isTrue);
      expect(formatted.contains('Model: claude-opus-4-6'), isTrue);
      expect(formatted.contains('Provider: anthropic'), isTrue);
      expect(formatted.contains('Platform: desktop'), isTrue);
      // Blank values are skipped.
      expect(formatted.contains('Workspace:'), isFalse);

      final modelIdx = formatted.indexOf('Model:');
      final providerIdx = formatted.indexOf('Provider:');
      final platformIdx = formatted.indexOf('Platform:');
      expect(modelIdx < providerIdx, isTrue);
      expect(providerIdx < platformIdx, isTrue);
    });

    test(
      'renders header-only export when messages empty but context given',
      () {
        final formatted = DebugChatFormatter.format(
          const [],
          context: {'Model': 'x'},
        );

        expect(formatted.contains('Model: x'), isTrue);
        expect(formatted.contains('Messages: 0'), isTrue);
      },
    );

    test('returns placeholder when nothing provided', () {
      final formatted = DebugChatFormatter.format(const []);
      expect(formatted, equals('(empty chat)'));
    });

    test('truncates oversized message text', () {
      final longText = 't' * 2600;
      final messages = [
        <String, String>{'sender': 'assistant', 'text': longText},
      ];

      final formatted = DebugChatFormatter.format(messages);

      expect(formatted.contains('(2600 chars total)'), isTrue);
    });
  });
}
