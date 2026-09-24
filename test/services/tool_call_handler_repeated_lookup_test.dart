// Regression: a weather question looped until the tool-call safety limit.
//
// Live, 2026-09-23 (upstream chuk_chat and the merged build alike, model
// z-ai/glm-5.3-flash): "Wie ist das Wetter gerade in Kiel? Kurz." got a good
// answer after one `weather` call. The [VERIFY] pass that follows then called
// `weather` with the same arguments again, and kept doing so on every pass —
// twenty identical calls, 1.1 MB of tool results saved once per round, and in
// the end "Sorry, I hit the tool-call safety limit" instead of the answer.
//
// The loop now answers a repeated read-only lookup from the result the turn
// already holds, and a verify pass that asks for nothing new keeps the
// candidate answer, as an [OK] would.

import 'dart:convert';

import 'package:chuk_chat/models/chat_stream_event.dart' show NativeToolCall;
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/services/tool_call_handler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  const kielArgs = <String, dynamic>{'action': 'current', 'location': 'Kiel'};
  const weatherResult = 'Kiel: 15 °C, partly cloudy';

  ToolLoopSession newSession(ToolCallHandler handler) => handler.createSession(
    initialUserMessage: 'Wie ist das Wetter gerade in Kiel? Kurz.',
    history: const [],
    accessToken: 'test-token',
    toolCallingEnabled: true,
    discoveryMode: false,
    nativeToolCalling: true,
  );

  ToolCall completedWeather() => ToolCall(
    id: 'tc-weather-1',
    name: 'weather',
    arguments: kielArgs,
    status: ToolCallStatus.completed,
    result: weatherResult,
  );

  NativeToolCall nativeWeather(String id, Map<String, dynamic> args) =>
      NativeToolCall(id: id, name: 'weather', arguments: jsonEncode(args));

  group('toolCallIdentityKey', () {
    test('ignores the order of the argument keys', () {
      expect(
        toolCallIdentityKey('weather', {'location': 'Kiel', 'action': 'x'}),
        toolCallIdentityKey('weather', {'action': 'x', 'location': 'Kiel'}),
      );
    });

    test('differs for other arguments or another tool', () {
      final base = toolCallIdentityKey('weather', kielArgs);
      expect(
        toolCallIdentityKey('weather', {
          'action': 'forecast',
          'location': 'Kiel',
        }),
        isNot(base),
      );
      expect(toolCallIdentityKey('web_search', kielArgs), isNot(base));
    });
  });

  group('verify pass that repeats a lookup', () {
    test('keeps the candidate instead of running the tool again', () async {
      final handler = ToolCallHandler();
      final session = newSession(handler)..toolCalls.add(completedWeather());

      const candidate = 'Kiel: 15 °C, aufgelockert bewölkt.';
      final first = await handler.processAssistantResponse(
        session: session,
        content: candidate,
        reasoning: 'answer reasoning',
      );
      expect(first.shouldContinue, isTrue);
      expect(first.nextStep!.message, contains('[VERIFY]'));

      // The verify pass asks for the very same lookup again.
      final second = await handler.processAssistantResponse(
        session: session,
        content: '',
        reasoning: '',
        nativeToolCalls: [nativeWeather('call-2', kielArgs)],
      );

      expect(second.shouldContinue, isFalse);
      expect(second.finalContent, candidate);
      expect(second.finalReasoning, 'answer reasoning');
      expect(session.factCheckCandidate, isNull);
      expect(
        session.toolCalls.where((c) => c.name == 'weather'),
        hasLength(1),
        reason: 'the repeat must not run, nor show as another row',
      );
    });

    test('a verify pass with a NEW lookup still runs the loop', () async {
      final handler = ToolCallHandler();
      final session = newSession(handler)..toolCalls.add(completedWeather());

      await handler.processAssistantResponse(
        session: session,
        content: 'Kiel: 15 °C.',
        reasoning: '',
      );

      // Different arguments: not a repeat. Use a tool that fails fast
      // offline so the test does not touch the network.
      final second = await handler.processAssistantResponse(
        session: session,
        content: '',
        reasoning: '',
        nativeToolCalls: const [
          NativeToolCall(
            id: 'call-2',
            name: 'calculate',
            arguments: '{"expression":"1+1"}',
          ),
        ],
      );

      expect(second.shouldContinue, isTrue);
      expect(session.factCheckCandidate, isNotNull);
    });
  });

  group('repeated lookup outside a verify pass', () {
    test('is answered from the earlier result, not run again', () async {
      final handler = ToolCallHandler();
      final session = newSession(handler)..toolCalls.add(completedWeather());

      final result = await handler.processAssistantResponse(
        session: session,
        content: '',
        reasoning: '',
        nativeToolCalls: [nativeWeather('call-2', kielArgs)],
      );

      expect(result.shouldContinue, isTrue);
      final repeat = session.toolCalls.last;
      expect(repeat.name, 'weather');
      expect(repeat.status, ToolCallStatus.completed);
      expect(repeat.result, startsWith(kRepeatedToolCallNote));
      expect(repeat.result, contains(weatherResult));

      final toolMessage = result.nextStep!.history.lastWhere(
        (m) => m['role'] == 'tool',
      );
      expect(toolMessage['tool_call_id'], 'call-2');
      expect(toolMessage['content'], contains(weatherResult));
    });

    test('a failed earlier call is not reused', () async {
      final handler = ToolCallHandler();
      final session = newSession(handler)
        ..toolCalls.add(
          ToolCall(
            id: 'tc-weather-err',
            name: 'calculate',
            arguments: const {'expression': '2*3'},
            status: ToolCallStatus.error,
            result: 'Error: boom',
          ),
        );

      final result = await handler.processAssistantResponse(
        session: session,
        content: '',
        reasoning: '',
        nativeToolCalls: const [
          NativeToolCall(
            id: 'call-2',
            name: 'calculate',
            arguments: '{"expression":"2*3"}',
          ),
        ],
      );

      expect(result.shouldContinue, isTrue);
      expect(
        session.toolCalls.last.result,
        isNot(startsWith(kRepeatedToolCallNote)),
      );
    });

    test('a model that keeps repeating gets the tools closed, then a stop', () async {
      final handler = ToolCallHandler();
      final session = newSession(handler)..toolCalls.add(completedWeather());
      expect(handler.nativeToolDefinitions(session), isNotEmpty);

      // 1st repeat: answered from the held result, tools stay open.
      final first = await handler.processAssistantResponse(
        session: session,
        content: '',
        reasoning: '',
        nativeToolCalls: [nativeWeather('call-2', kielArgs)],
      );
      expect(first.shouldContinue, isTrue);
      expect(session.toolsClosed, isFalse);
      expect(session.toolCalls.last.result, isNot(contains(kToolsClosedNote)));

      // 2nd repeat: the model ignored the note. Tools close for the next pass.
      final second = await handler.processAssistantResponse(
        session: session,
        content: '',
        reasoning: '',
        nativeToolCalls: [nativeWeather('call-3', kielArgs)],
      );
      expect(second.shouldContinue, isTrue);
      expect(session.toolsClosed, isTrue);
      expect(session.toolCalls.last.result, contains(kToolsClosedNote));
      expect(handler.nativeToolDefinitions(session), isEmpty);

      // Still asking with the tools closed: the turn ends instead of looping.
      final third = await handler.processAssistantResponse(
        session: session,
        content: '',
        reasoning: '',
        nativeToolCalls: [nativeWeather('call-4', kielArgs)],
      );
      expect(third.shouldContinue, isFalse);
      expect(third.finalContent, isNotEmpty);
    });

    test('an answer after the tools closed ends the turn normally', () async {
      final handler = ToolCallHandler();
      final session = newSession(handler)..toolCalls.add(completedWeather());
      for (final id in ['call-2', 'call-3']) {
        await handler.processAssistantResponse(
          session: session,
          content: '',
          reasoning: '',
          nativeToolCalls: [nativeWeather(id, kielArgs)],
        );
      }
      expect(session.toolsClosed, isTrue);

      const answer = 'Kiel: 15 °C, aufgelockert bewölkt.';
      final verify = await handler.processAssistantResponse(
        session: session,
        content: answer,
        reasoning: '',
      );
      expect(verify.nextStep!.message, contains('[VERIFY]'));
      final done = await handler.processAssistantResponse(
        session: session,
        content: '[OK]',
        reasoning: '',
      );
      expect(done.shouldContinue, isFalse);
      expect(done.finalContent, answer);
    });

    test('a round that mixes a repeat with a new call counts too', () async {
      final handler = ToolCallHandler();
      final session = newSession(handler)..toolCalls.add(completedWeather());

      NativeToolCall calc(String id, String expression) => NativeToolCall(
        id: id,
        name: 'calculate',
        arguments: jsonEncode({'expression': expression}),
      );

      // Each round adds one new call next to the repeat. Before, only a round
      // of nothing but repeats counted, so this pattern ran to the cap.
      await handler.processAssistantResponse(
        session: session,
        content: '',
        reasoning: '',
        nativeToolCalls: [
          nativeWeather('call-2', kielArgs),
          calc('c-1', '1+1'),
        ],
      );
      expect(session.toolsClosed, isFalse);
      final second = await handler.processAssistantResponse(
        session: session,
        content: '',
        reasoning: '',
        nativeToolCalls: [
          nativeWeather('call-3', kielArgs),
          calc('c-2', '2+2'),
        ],
      );
      expect(second.shouldContinue, isTrue);
      expect(session.toolsClosed, isTrue);
      expect(handler.nativeToolDefinitions(session), isEmpty);
    });

    test('the same lookup twice in one round runs once', () async {
      final handler = ToolCallHandler();
      final session = newSession(handler);

      await handler.processAssistantResponse(
        session: session,
        content: '',
        reasoning: '',
        nativeToolCalls: const [
          NativeToolCall(
            id: 'c-1',
            name: 'calculate',
            arguments: '{"expression":"6*7"}',
          ),
          NativeToolCall(
            id: 'c-2',
            name: 'calculate',
            arguments: '{"expression":"6*7"}',
          ),
        ],
      );

      final first = session.toolCalls[0];
      final second = session.toolCalls[1];
      expect(first.result, isNot(startsWith(kRepeatedToolCallNote)));
      expect(second.result, startsWith(kRepeatedToolCallNote));
      expect(second.result, endsWith(first.result!));
    });

    test('a model that asks the same thing every pass is stopped within '
        'four passes, and the tool runs once', () async {
      // The failure seen live: one call, then the identical call on every
      // pass. Nothing is pre-seeded here; the loop starts from scratch.
      final handler = ToolCallHandler();
      final session = newSession(handler);

      var passes = 0;
      ToolLoopResult result;
      do {
        passes++;
        result = await handler.processAssistantResponse(
          session: session,
          content: '',
          reasoning: '',
          nativeToolCalls: [
            NativeToolCall(
              id: 'c-$passes',
              name: 'calculate',
              arguments: '{"expression":"2*3"}',
            ),
          ],
        );
      } while (result.shouldContinue && passes < 30);

      expect(result.shouldContinue, isFalse);
      expect(passes, lessThanOrEqualTo(4));
      final executed = session.toolCalls.where(
        (c) => !(c.result ?? '').startsWith(kRepeatedToolCallNote),
      );
      expect(executed, hasLength(1));
    });

    test('new calls on every pass stop at the round cap', () async {
      final handler = ToolCallHandler();
      final session = newSession(handler);
      expect(kMaxToolRoundsPerTurn, lessThanOrEqualTo(16));

      var passes = 0;
      ToolLoopResult result;
      do {
        passes++;
        result = await handler.processAssistantResponse(
          session: session,
          content: '',
          reasoning: '',
          nativeToolCalls: [
            NativeToolCall(
              id: 'c-$passes',
              name: 'calculate',
              arguments: '{"expression":"$passes+1"}',
            ),
          ],
        );
      } while (result.shouldContinue && passes < 100);

      expect(result.shouldContinue, isFalse);
      expect(passes, kMaxToolRoundsPerTurn + 1);
    });

    test('a tool with a changing result is never reused', () {
      expect(repeatableLookupToolNames, isNot(contains('get_time')));
      expect(repeatableLookupToolNames, isNot(contains('roll_dice')));
      expect(repeatableLookupToolNames, isNot(contains('random_number')));
      expect(repeatableLookupToolNames, isNot(contains('notes')));
    });
  });
}
