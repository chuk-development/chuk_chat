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

    test('a tool with a changing result is never reused', () {
      expect(repeatableLookupToolNames, isNot(contains('get_time')));
      expect(repeatableLookupToolNames, isNot(contains('roll_dice')));
      expect(repeatableLookupToolNames, isNot(contains('random_number')));
      expect(repeatableLookupToolNames, isNot(contains('notes')));
    });
  });
}
