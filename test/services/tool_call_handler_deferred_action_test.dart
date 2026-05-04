import 'package:flutter_test/flutter_test.dart';
import 'package:chuk_chat/services/tool_call_handler.dart';

void main() {
  group('ToolCallHandler deferred-action detection', () {
    test('detects action preamble without tool call', () {
      const content =
          "I'll search for the current pricing across providers and compare it.";

      expect(
        ToolCallHandler.looksLikeDeferredActionWithoutToolCall(content),
        isTrue,
      );
    });

    test('does not flag a normal direct answer', () {
      const content =
          'DeepSeek direct API is usually cheaper for token pricing, while '
          'OpenRouter adds routing overhead.';

      expect(
        ToolCallHandler.looksLikeDeferredActionWithoutToolCall(content),
        isFalse,
      );
    });

    test('does not flag non-tool intent phrasing', () {
      const content = "I'll explain how caching affects total cost.";

      expect(
        ToolCallHandler.looksLikeDeferredActionWithoutToolCall(content),
        isFalse,
      );
    });
  });
}
