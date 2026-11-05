// A steer (a message the user sends while the turn runs) goes to the model
// as a user message after the round, and the round hands the UI a steer
// block at the same place, so the transcript shows it.

import 'package:chuk_chat/models/chat_stream_event.dart' show NativeToolCall;
import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/services/composer/follow_up_queue.dart';
import 'package:chuk_chat/services/tool_call_handler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  setUp(SteerInbox.debugClear);
  tearDown(SteerInbox.debugClear);

  test('native round: the steer is in the history and a block', () async {
    final handler = ToolCallHandler();
    final session = handler.createSession(
      initialUserMessage: 'time?',
      history: const [],
      accessToken: 'test-token',
      toolCallingEnabled: true,
      discoveryMode: false,
      nativeToolCalling: true,
      discoveryContextKey: 'chat-steer',
    );
    SteerInbox.post(
      'chat-steer',
      const SteerEntry(id: 's1', text: 'use UTC please'),
    );

    final result = await handler.processAssistantResponse(
      session: session,
      content: '',
      reasoning: '',
      nativeToolCalls: const [
        NativeToolCall(id: 'a', name: 'get_time', arguments: '{}'),
      ],
    );

    final history = result.nextStep!.history;
    expect(history.last['role'], 'user');
    expect(history.last['content'], SteerInbox.messageFor('use UTC please'));

    final steers = result.producedBlocks
        .where((b) => b.type == ContentBlockType.steer)
        .toList();
    expect(steers, hasLength(1));
    expect(steers.single.text, 'use UTC please');

    // The block survives the stored JSON round trip.
    final back = ContentBlock.fromJson(steers.single.toJson());
    expect(back.type, ContentBlockType.steer);
    expect(back.text, 'use UTC please');

    // Taken once: the next round has no steer.
    expect(SteerInbox.take('chat-steer'), isEmpty);
  });
}
