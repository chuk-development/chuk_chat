import 'package:flutter_test/flutter_test.dart';
import 'package:chuk_chat/services/tool_call_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

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

    test('detects "I need to search" phrasing from regression log', () {
      const content =
          'I need to search for current information about Codex access on '
          'different OpenAI plans, as pricing and feature availability '
          'change frequently.';

      expect(
        ToolCallHandler.looksLikeDeferredActionWithoutToolCall(content),
        isTrue,
      );
    });

    test('detects "Let me search ...:" with trailing colon', () {
      const content =
          'Let me search more specifically for Business plan Codex details:';

      expect(
        ToolCallHandler.looksLikeDeferredActionWithoutToolCall(content),
        isTrue,
      );
    });

    test('detects German search-intent phrasing from regression log', () {
      const content =
          'Ich suche nach aktuellen Informationen zu Codex-Modellen und deren '
          'Verfügbarkeit in verschiedenen Plänen.';

      expect(
        ToolCallHandler.looksLikeDeferredActionWithoutToolCall(content),
        isTrue,
      );
    });

    test(
      'retries when stream signals tool use but no parseable tool call',
      () async {
        final handler = ToolCallHandler();
        final session = handler.createSession(
          initialUserMessage: 'test',
          history: const [],
          accessToken: 'test-token',
          toolCallingEnabled: true,
          discoveryMode: false,
        );

        final result = await handler.processAssistantResponse(
          session: session,
          content: '<tool_call>{"name":"web_search"',
          reasoning: '',
          turnSignals: ToolTurnSignals.fromMeta(const {
            'stop_reason': 'tool_use',
          }),
        );

        expect(result.shouldContinue, isTrue);
        expect(result.nextStep, isNotNull);
      },
    );
  });
}
