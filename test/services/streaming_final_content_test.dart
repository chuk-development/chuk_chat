import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:cowork/models/chat_stream_event.dart';
import 'package:cowork/services/streaming_manager_io.dart' as native;
import 'package:cowork/services/streaming_manager_stub.dart' as web;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const answer =
      'Spotify: [Search](https://open.spotify.com/search/song/tracks)\nShazam: complete';

  for (final isWeb in [false, true]) {
    for (final prefix in [
      'Spotify: [Search](https://open.spotify.com/search/so',
      'An earlier provisional answer',
      answer,
      '',
    ]) {
      test(
        '${isWeb ? 'web' : 'native'} canonical final replaces prefix ${prefix.length} without duplication',
        () async {
          final dynamic manager = isWeb
              ? web.StreamingManager()
              : native.StreamingManager();
          final input = StreamController<ChatStreamEvent>();
          final done = Completer<String>();
          final updates = <String>[];
          var completions = 0;
          const chatId = 'final-answer-regression';
          await manager.startStream(
            chatId: chatId,
            messageIndex: 0,
            stream: input.stream,
            onUpdate: (String text, String reasoning) => updates.add(text),
            onComplete: (String text, String reasoning, double? tps) {
              completions++;
              if (!done.isCompleted) done.complete(text);
            },
            onError: (String message, {String? code}) => fail(message),
          );
          // No33ms wait: terminal must win even with a queued native UI flush.
          input.add(ContentEvent(prefix));
          input.add(const FinalContentEvent(answer));
          input.add(const DoneEvent());
          await input.close();
          expect(await done.future, answer);
          expect(updates.last, answer);
          expect(completions, 1);
          await manager.cancelStream(chatId);
        },
      );
    }
  }
}
