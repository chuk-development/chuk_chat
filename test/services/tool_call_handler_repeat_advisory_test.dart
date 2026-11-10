// Repeat-call advisory: identical calls (same tool, same key-sorted
// arguments) in one turn get a note appended to the result at the 3rd, 5th
// and 8th call. Advice only; the call still runs.

import 'package:chuk_chat/models/chat_stream_event.dart' show NativeToolCall;
import 'package:chuk_chat/services/tool_call_handler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  group('repeatCallAdvisory', () {
    test('only at 3, 5 and 8', () {
      for (var n = 1; n <= 10; n++) {
        final note = repeatCallAdvisory('get_time', const {}, n);
        expect(
          note != null,
          kRepeatCallAdvisoryThresholds.contains(n),
          reason: 'count $n',
        );
      }
    });

    test('3 is the gentle note, later ones name tool, count and args', () {
      final gentle = repeatCallAdvisory('web_search', {'q': 'x'}, 3)!;
      expect(gentle, contains('identical arguments'));
      expect(gentle, isNot(contains('web_search')));
      final detailed = repeatCallAdvisory('web_search', {'z': 1, 'a': 2}, 5)!;
      expect(detailed, contains('- tool: web_search'));
      expect(detailed, contains('- identical_calls: 5'));
      expect(detailed, contains('{"a":2,"z":1}'));
    });

    test('long arguments are cut in the note', () {
      final note = repeatCallAdvisory('w', {'body': 'x' * 2000}, 8)!;
      expect(note, contains('more chars)'));
      expect(note.length, lessThan(1200));
    });
  });

  group('in the tool loop', () {
    ToolLoopSession newSession(ToolCallHandler handler) =>
        handler.createSession(
          initialUserMessage: 'time?',
          history: const [],
          accessToken: 'test-token',
          toolCallingEnabled: true,
          discoveryMode: false,
          nativeToolCalling: true,
        );

    Future<String> runRound(
      ToolCallHandler handler,
      ToolLoopSession session,
      List<NativeToolCall> calls,
    ) async {
      final result = await handler.processAssistantResponse(
        session: session,
        content: '',
        reasoning: '',
        nativeToolCalls: calls,
      );
      return result.nextStep!.history.lastWhere(
            (m) => m['role'] == 'tool',
          )['content']
          as String;
    }

    test('key order does not matter; the note is not in the UI row', () async {
      final handler = ToolCallHandler();
      final session = newSession(handler);
      const a = NativeToolCall(
        id: 'a',
        name: 'get_time',
        arguments: '{"x":1,"y":2}',
      );
      const b = NativeToolCall(
        id: 'b',
        name: 'get_time',
        arguments: '{"y":2,"x":1}',
      );
      const c = NativeToolCall(
        id: 'c',
        name: 'get_time',
        arguments: '{"x":1,"y":2}',
      );
      expect(await runRound(handler, session, [a]), isNot(contains('[REPEAT')));
      expect(await runRound(handler, session, [b]), isNot(contains('[REPEAT')));
      expect(await runRound(handler, session, [c]), contains('[REPEAT NOTE]'));
      expect(session.toolCalls.last.result, isNot(contains('[REPEAT NOTE]')));
    });

    test('a new turn starts the count again', () async {
      final handler = ToolCallHandler();
      const call = NativeToolCall(id: 'a', name: 'get_time', arguments: '{}');
      final first = newSession(handler);
      await runRound(handler, first, [call]);
      await runRound(handler, first, [call]);
      final second = newSession(handler);
      expect(
        await runRound(handler, second, [call]),
        isNot(contains('[REPEAT NOTE]')),
      );
    });
  });
}
