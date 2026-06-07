import 'package:flutter_test/flutter_test.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/services/tool_call_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  ToolLoopSession newSession(ToolCallHandler handler) => handler.createSession(
    initialUserMessage: 'test',
    history: const [],
    accessToken: 'test-token',
    toolCallingEnabled: true,
    discoveryMode: false,
  );

  ToolCall completed(String name) => ToolCall(
    id: 'tc-$name',
    name: name,
    arguments: const <String, dynamic>{},
    status: ToolCallStatus.completed,
    result: 'ok',
  );

  group('ToolCallHandler fact-check pass', () {
    test('runs ONE verification pass after a fact-bearing tool answer', () async {
      final handler = ToolCallHandler();
      final session = newSession(handler)..toolCalls.add(completed('web_search'));

      final result = await handler.processAssistantResponse(
        session: session,
        content: 'David Goggins finished Ironman Australia 1988 in 10:51:38.',
        reasoning: '',
      );

      expect(result.shouldContinue, isTrue);
      expect(result.nextStep, isNotNull);
      expect(result.nextStep!.message, contains('[VERIFY]'));
      // Unverified candidate must NOT be surfaced as interim text.
      expect(result.interimContent, '');
      expect(session.factCheckRecoveryAttempts, 1);
    });

    test('only fires once — second turn goes final', () async {
      final handler = ToolCallHandler();
      final session = newSession(handler)..toolCalls.add(completed('web_search'));

      final first = await handler.processAssistantResponse(
        session: session,
        content: 'First candidate answer grounded in search.',
        reasoning: '',
      );
      expect(first.shouldContinue, isTrue);

      final second = await handler.processAssistantResponse(
        session: session,
        content: 'Verified final answer.',
        reasoning: '',
      );
      expect(
        second.shouldContinue,
        isFalse,
        reason: 'fact-check is one-shot; the verified answer is final.',
      );
      expect(second.finalContent, 'Verified final answer.');
    });

    test('does NOT fire when no tools ran', () async {
      final handler = ToolCallHandler();
      final session = newSession(handler);

      final result = await handler.processAssistantResponse(
        session: session,
        content: 'A direct answer with no tool grounding.',
        reasoning: '',
      );

      expect(result.shouldContinue, isFalse);
      expect(session.factCheckRecoveryAttempts, 0);
    });

    test('does NOT fire when only non-factual tools ran', () async {
      final handler = ToolCallHandler();
      final session = newSession(handler)..toolCalls.add(completed('flip_coin'));

      final result = await handler.processAssistantResponse(
        session: session,
        content: 'The coin landed on heads.',
        reasoning: '',
      );

      expect(result.shouldContinue, isFalse);
      expect(session.factCheckRecoveryAttempts, 0);
    });

    test('does NOT fire on an empty answer', () async {
      final handler = ToolCallHandler();
      final session = newSession(handler)..toolCalls.add(completed('web_search'));

      await handler.processAssistantResponse(
        session: session,
        content: '   ',
        reasoning: '',
      );

      // Empty answers fall through to other recovery/final paths, not the
      // fact-check pass.
      expect(session.factCheckRecoveryAttempts, 0);
    });

    test('ignores errored tool calls when deciding to verify', () async {
      final handler = ToolCallHandler();
      final session = newSession(handler)
        ..toolCalls.add(
          ToolCall(
            id: 'tc-bad',
            name: 'web_search',
            arguments: const <String, dynamic>{},
            status: ToolCallStatus.error,
            result: 'Rejected: nope',
          ),
        );

      final result = await handler.processAssistantResponse(
        session: session,
        content: 'Answer despite a failed search.',
        reasoning: '',
      );

      // The only tool call errored → nothing trustworthy to verify against.
      expect(result.shouldContinue, isFalse);
      expect(session.factCheckRecoveryAttempts, 0);
    });
  });
}
