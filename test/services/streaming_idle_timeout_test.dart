// chuk_chat's idle timeout, with FEATURE_AGENTS off (the default in tests).
//
// No event of any kind for 60 seconds ends the stream: an error with the
// `idle_timeout` code when nothing had arrived, a completion with the partial
// content when something had. The Agents build replaces this with a log-only
// silence watch; that side is pinned by streaming_silence_test.dart.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/chat_stream_event.dart';
import 'package:chuk_chat/services/agents/agents_chat_core.dart';
import 'package:chuk_chat/services/streaming_manager_io.dart';

void main() {
  late StreamController<ChatStreamEvent> input;
  late List<String> completions;
  late List<String> errors;
  late List<String?> errorCodes;
  final manager = StreamingManager();

  setUp(() {
    debugAgentsChatCoreOverride = null;
    input = StreamController<ChatStreamEvent>();
    completions = <String>[];
    errors = <String>[];
    errorCodes = <String?>[];
  });

  Future<void> start(String chatId) => manager.startStream(
    chatId: chatId,
    messageIndex: 0,
    stream: input.stream,
    onUpdate: (String content, String reasoning) {},
    onComplete: (String content, String reasoning, double? tps) =>
        completions.add(content),
    onError: (String message, {String? code}) {
      errors.add(message);
      errorCodes.add(code);
    },
  );

  Future<void> dispose(WidgetTester tester, String chatId) async {
    unawaited(manager.cancelStream(chatId));
    if (!input.isClosed) unawaited(input.close());
    await tester.pump();
  }

  test('the idle timeout is on in a chuk_chat build', () {
    expect(StreamingManager.idleTimeoutEnabled, isTrue);
  });

  testWidgets('a silent stream errors with idle_timeout after 60 s', (
    tester,
  ) async {
    await start('idle-empty');

    await tester.pump(const Duration(seconds: 59));
    expect(errors, isEmpty);
    expect(manager.isStreaming('idle-empty'), isTrue);

    await tester.pump(const Duration(seconds: 2));
    expect(errorCodes, <String?>[StreamErrorCodes.idleTimeout]);
    expect(completions, isEmpty);
    expect(manager.isStreaming('idle-empty'), isFalse);

    await dispose(tester, 'idle-empty');
  });

  testWidgets('every event restarts the idle window', (tester) async {
    await start('idle-reset');

    await tester.pump(const Duration(seconds: 50));
    input.add(const MetaEvent(<String, dynamic>{}));
    await tester.pump(const Duration(seconds: 50));
    expect(errors, isEmpty, reason: 'the meta frame reset the timer');

    await tester.pump(const Duration(seconds: 11));
    expect(errorCodes, <String?>[StreamErrorCodes.idleTimeout]);

    await dispose(tester, 'idle-reset');
  });

  testWidgets('the timeout closes the dead stream\'s subscription', (
    tester,
  ) async {
    var cancelled = false;
    input = StreamController<ChatStreamEvent>(onCancel: () => cancelled = true);
    await start('idle-cancel');

    await tester.pump(const Duration(seconds: 61));
    expect(errorCodes, <String?>[StreamErrorCodes.idleTimeout]);
    expect(cancelled, isTrue);

    await dispose(tester, 'idle-cancel');
  });

  testWidgets('partial content is completed, not thrown away', (tester) async {
    await start('idle-partial');

    input.add(const ContentEvent('half an answer'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 61));

    expect(errors, isEmpty);
    expect(completions, <String>['half an answer']);

    await dispose(tester, 'idle-partial');
  });
}
