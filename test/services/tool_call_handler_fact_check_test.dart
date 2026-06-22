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

    test('[OK] keeps the grounded candidate as the final answer', () async {
      final handler = ToolCallHandler();
      final session = newSession(handler)..toolCalls.add(completed('web_search'));

      const candidate = 'Germany clinched the group early after a late goal.';
      final first = await handler.processAssistantResponse(
        session: session,
        content: candidate,
        reasoning: 'reasoning that produced the answer',
      );
      expect(first.shouldContinue, isTrue);
      // Candidate is captured, not shown yet.
      expect(first.interimContent, '');

      // The verify pass acknowledges with the [OK] sentinel — a weak model
      // that does NOT re-emit the answer must not blank it out.
      final second = await handler.processAssistantResponse(
        session: session,
        content: '[OK]',
        reasoning: 'verification reasoning',
      );
      expect(second.shouldContinue, isFalse);
      expect(
        second.finalContent,
        candidate,
        reason: 'no [CORRECTED] marker → keep the grounded candidate.',
      );
      expect(second.finalReasoning, 'reasoning that produced the answer');
    });

    test('a bare acknowledgement (no marker) still keeps the candidate',
        () async {
      final handler = ToolCallHandler();
      final session = newSession(handler)..toolCalls.add(completed('web_search'));

      const candidate = 'Today: a warehouse fire spread smoke across the city.';
      await handler.processAssistantResponse(
        session: session,
        content: candidate,
        reasoning: '',
      );

      // The exact failure mode from the bug report: the model narrates
      // "everything checks out" instead of re-emitting the answer.
      final second = await handler.processAssistantResponse(
        session: session,
        content: 'All facts match the search results — no corrections needed.',
        reasoning: '',
      );
      expect(second.shouldContinue, isFalse);
      expect(
        second.finalContent,
        candidate,
        reason: 'narration without [CORRECTED] must not replace the answer.',
      );
    });

    test('[CORRECTED] replaces the candidate with the corrected answer',
        () async {
      final handler = ToolCallHandler();
      final session = newSession(handler)..toolCalls.add(completed('web_search'));

      await handler.processAssistantResponse(
        session: session,
        content: 'The event happened in 1985.',
        reasoning: '',
      );

      final second = await handler.processAssistantResponse(
        session: session,
        content: '[CORRECTED]\nThe event happened in 1995, per the source.',
        reasoning: '',
      );
      expect(second.shouldContinue, isFalse);
      expect(
        second.finalContent,
        'The event happened in 1995, per the source.',
      );
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
