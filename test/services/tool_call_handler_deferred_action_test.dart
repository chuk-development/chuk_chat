import 'package:flutter_test/flutter_test.dart';
import 'package:chuk_chat/models/tool_call.dart';
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

    test('detects German "Lass mich ... erstellen" after a filler sentence', () {
      // Regression: Kimi ended a 4-search turn with only this promise, so the
      // user got no summary at all.
      const content =
          'Ich habe jetzt ausreichend Informationen gesammelt. Lass mich dir '
          'eine detaillierte Zusammenfassung erstellen.';

      expect(
        ToolCallHandler.looksLikeDeferredActionWithoutToolCall(content),
        isTrue,
      );
    });

    test('detects English "Let me write ..." after a filler sentence', () {
      const content =
          'I have gathered enough information. Let me write the summary for '
          'you now.';

      expect(
        ToolCallHandler.looksLikeDeferredActionWithoutToolCall(content),
        isTrue,
      );
    });

    test('does not flag a multi-line answer that opens with intent', () {
      const content =
          'Let me summarize the findings:\n\n- Magellan left in 1519\n'
          '- Only 18 men returned in 1522';

      expect(
        ToolCallHandler.looksLikeDeferredActionWithoutToolCall(content),
        isFalse,
      );
    });

    test('does not flag an answer delivered after a colon on one line', () {
      const content = 'Let me summarize the findings: Magellan left in 1519.';

      expect(
        ToolCallHandler.looksLikeDeferredActionWithoutToolCall(content),
        isFalse,
      );
    });

    test('detects "Ich werde ... prüfen"', () {
      const content = 'Ich werde die aktuellen Preise für beide Anbieter '
          'prüfen.';

      expect(
        ToolCallHandler.looksLikeDeferredActionWithoutToolCall(content),
        isTrue,
      );
    });

    test('detects Italian and Dutch intent prefixes with matching verbs', () {
      expect(
        ToolCallHandler.looksLikeDeferredActionWithoutToolCall(
          'Vado a cercare i dettagli della spedizione.',
        ),
        isTrue,
      );
      expect(
        ToolCallHandler.looksLikeDeferredActionWithoutToolCall(
          'Wij gaan de laatste cijfers opzoeken.',
        ),
        isTrue,
      );
    });

    test('does not flag a final sentence without an action verb', () {
      const content =
          'The expedition lasted three years. Let me know if you want more '
          'detail on the ships.';

      expect(
        ToolCallHandler.looksLikeDeferredActionWithoutToolCall(content),
        isFalse,
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

    test('keeps deferred interim text visible while retrying', () async {
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
        content:
            "I'll search for the latest Codex plan limits and compare them.",
        reasoning: '',
      );

      expect(result.shouldContinue, isTrue);
      expect(
        result.interimContent,
        "I'll search for the latest Codex plan limits and compare them.",
      );
    });

    test('retries non-final signaled turns during active tool loop', () async {
      final handler = ToolCallHandler();
      final session = handler.createSession(
        initialUserMessage: 'test',
        history: const [],
        accessToken: 'test-token',
        toolCallingEnabled: true,
        discoveryMode: false,
      );
      session.toolCalls.add(
        ToolCall(
          id: 'tc-1',
          name: 'web_search',
          arguments: const <String, dynamic>{},
          status: ToolCallStatus.completed,
          result: 'ok',
        ),
      );

      final result = await handler.processAssistantResponse(
        session: session,
        content: 'Working on it now.',
        reasoning: '',
        turnSignals: ToolTurnSignals.fromMeta(const {
          'stop_reason': 'pause_turn',
        }),
      );

      expect(result.shouldContinue, isTrue);
      expect(result.nextStep, isNotNull);
      expect(result.interimContent, 'Working on it now.');
    });

    test(
      'does NOT retry when provider emits no finish/stop reason '
      '(Fireworks/Kimi: prevents duplicate reformulated answer)',
      () async {
        final handler = ToolCallHandler();
        final session = handler.createSession(
          initialUserMessage: 'test',
          history: const [],
          accessToken: 'test-token',
          toolCallingEnabled: true,
          discoveryMode: false,
        );
        session.toolCalls.add(
          ToolCall(
            id: 'tc-1',
            name: 'web_search',
            arguments: const <String, dynamic>{},
            status: ToolCallStatus.completed,
            result: 'ok',
          ),
        );
        // Isolate the non-final-turn logic: pretend the one-shot fact-check
        // pass has already run, so it does not add its own retry here.
        session.factCheckRecoveryAttempts = 1;

        // No stop_reason or finish_reason at all — absence MUST NOT be
        // treated as "non-final" or the model gets asked to redo its
        // already-complete answer, producing a duplicate reformulation.
        final result = await handler.processAssistantResponse(
          session: session,
          content: 'Here is the complete final answer to the user question.',
          reasoning: '',
          turnSignals: ToolTurnSignals.fromMeta(const {}),
        );

        expect(
          result.shouldContinue,
          isFalse,
          reason: 'Missing finish_reason must default to final, not retry.',
        );
      },
    );
  });
}
