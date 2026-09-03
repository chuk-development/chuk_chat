import 'package:flutter_test/flutter_test.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/services/tool_call_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  ToolLoopSession newSession(ToolCallHandler handler) => handler.createSession(
    initialUserMessage: 'build me a paper',
    history: const [],
    accessToken: 'test-token',
    toolCallingEnabled: true,
    discoveryMode: false,
  );

  ToolCall completed(
    String name, [
    Map<String, dynamic> args = const {},
    String result = 'ok',
  ]) => ToolCall(
    id: 'tc-$name-${args.hashCode}-${result.hashCode}',
    name: name,
    arguments: args,
    status: ToolCallStatus.completed,
    result: result,
  );

  // A successful typst_compile result always carries a persisted "version: N";
  // a failed compile does not. The safety-limit message must only report a PDF
  // for the former.
  const typstOk =
      'Typst artifact "paper" created (version: 1, stored end-to-end '
      'encrypted in Supabase).';

  // Push the session's enforcer right up to its per-turn ceiling so the next
  // enforce() call (inside processAssistantResponse) trips the safety limit.
  void exhaustIterations(ToolLoopSession session) {
    // maxIterations is 24; enforce() increments then checks `> max`, so 24
    // empty passes leave the counter at 24 and the 25th (the real call) trips.
    for (var i = 0; i < 24; i++) {
      session.enforcer.enforce(const []);
    }
  }

  Future<String> tripLimit(
    ToolCallHandler handler,
    ToolLoopSession session,
  ) async {
    exhaustIterations(session);
    final result = await handler.processAssistantResponse(
      session: session,
      // A parseable tool call so the flow reaches the enforce/limit check.
      content: '<tool_call>{"name":"generate_image","arguments":{}}</tool_call>',
      reasoning: '',
    );
    expect(result.shouldContinue, isFalse);
    return result.finalContent ?? '';
  }

  group('safety-limit final message', () {
    test('reports the compiled PDF when typst_compile completed', () async {
      final handler = ToolCallHandler();
      final session = newSession(handler)
        ..toolCalls.add(completed('typst_compile', const {}, typstOk));

      final msg = await tripLimit(handler, session);
      expect(msg, contains('PDF'));
      expect(msg, contains('ready above'));
      expect(msg, isNot(contains('simpler prompt')));
    });

    test('reports the artifact for artifact_manager create/rewrite', () async {
      final handler = ToolCallHandler();
      final session = newSession(handler)
        ..toolCalls.add(completed('artifact_manager', {'action': 'create'}));

      final msg = await tripLimit(handler, session);
      expect(msg, contains('artifact'));
      expect(msg, isNot(contains('simpler prompt')));
    });

    test('reports a delivered file for send_file_to_user', () async {
      final handler = ToolCallHandler();
      final session = newSession(handler)
        ..toolCalls.add(completed('send_file_to_user'));

      final msg = await tripLimit(handler, session);
      expect(msg, contains('file'));
      expect(msg, isNot(contains('simpler prompt')));
    });

    test('names multiple deliverables together', () async {
      final handler = ToolCallHandler();
      final session = newSession(handler)
        ..toolCalls.add(completed('typst_compile', const {}, typstOk))
        ..toolCalls.add(completed('send_file_to_user'));

      final msg = await tripLimit(handler, session);
      expect(msg, contains('PDF'));
      expect(msg, contains('file'));
    });

    test('falls back to the retry message when nothing was produced', () async {
      final handler = ToolCallHandler();
      final session = newSession(handler)
        ..toolCalls.add(completed('web_search'));

      final msg = await tripLimit(handler, session);
      expect(msg, contains('simpler prompt'));
    });

    test('a typst_compile that failed to compile is not a delivered PDF', () async {
      final handler = ToolCallHandler();
      // Completed status, but the compile failed so no version was persisted
      // and no artifact card was shown — must not be reported as a ready PDF.
      final session = newSession(handler)
        ..toolCalls.add(
          completed(
            'typst_compile',
            const {},
            'Typst compile failed. The source was NOT saved.',
          ),
        );

      final msg = await tripLimit(handler, session);
      expect(msg, contains('simpler prompt'));
      expect(msg, isNot(contains('PDF')));
    });

    test('an errored deliverable does not count as delivered', () async {
      final handler = ToolCallHandler();
      final session = newSession(handler)
        ..toolCalls.add(
          ToolCall(
            id: 'tc-err',
            name: 'typst_compile',
            arguments: const {},
            status: ToolCallStatus.error,
            result: 'Error: HTTP 502 — bad gateway',
          ),
        );

      final msg = await tripLimit(handler, session);
      expect(msg, contains('simpler prompt'));
    });
  });
}
