// The streaming phase: a long answer through the real send path, with the
// network replaced at `WebSocketChatService.debugHostedSend`. Chunk size and
// pace follow a fast hosted model (about 100 tokens per second).

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart' show Offset, Size;

import 'package:chuk_chat/models/chat_stream_event.dart';
import 'package:chuk_chat/platform_specific/chat/chat_ui_mobile.dart';
import 'package:chuk_chat/services/websocket_chat_service.dart';

import 'bench_fixture.dart';

/// The crawl sends by accident (retry, edit); a short answer keeps it moving.
bool benchShortStream = false;

void installBenchStream() {
  WebSocketChatService.debugHostedSend = (String? chatId) async* {
    final String answer = benchShortStream ? 'Ok.' : benchStreamAnswer();
    const int chunk = 24;
    for (int i = 0; i < answer.length; i += chunk) {
      final int end = i + chunk < answer.length ? i + chunk : answer.length;
      yield ContentEvent(answer.substring(i, end));
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    yield const DoneEvent();
  };
}

typedef BenchPhase =
    Future<void> Function(
      String name,
      Future<void> Function() body, {
      int reps,
      String note,
      Future<void> Function()? between,
    });

Future<void> _untilIdle(ChukChatUIMobileState chat) async {
  final Stopwatch w = Stopwatch()..start();
  await Future<void>.delayed(const Duration(milliseconds: 300));
  while (chat.transcriptStreaming && w.elapsedMilliseconds < 120000) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

Future<void> benchStreamPhase(
  ChukChatUIMobileState chat,
  BenchPhase phase,
  Size screen,
) async {
  await phase(
    'send, long chat',
    () async {
      final int before = chat.transcriptRows.length;
      chat.composerController.text = 'One more question, please.';
      unawaited(chat.sendMessage());
      while (chat.transcriptRows.length == before) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      await SchedulerBinding.instance.endOfFrame;
    },
    note: 'send call to user bubble on screen',
  );
  await _untilIdle(chat);
  await phase(
    'stream 12 KB answer, long chat',
    () async {
      chat.composerController.text = 'And one more, please.';
      unawaited(chat.sendMessage());
      await _untilIdle(chat);
    },
    note: 'tables, code, ::: blocks',
  );
  await phase(
    'stream 12 KB, reader scrolled up',
    () async {
      chat.composerController.text = 'And a third one.';
      unawaited(chat.sendMessage());
      await Future<void>.delayed(const Duration(milliseconds: 600));
      chat.scrollController.jumpTo(chat.scrollController.position.pixels - 3000);
      // A reader who keeps dragging up and down while the answer comes in.
      Offset at = Offset(screen.width / 2, screen.height * .4);
      const int pointer = 7000;
      Duration t = const Duration(seconds: 9000);
      GestureBinding.instance.handlePointerEvent(
        PointerDownEvent(pointer: pointer, position: at, timeStamp: t),
      );
      for (int i = 0; i < 400 && chat.transcriptStreaming; i++) {
        final Offset step = Offset(0, i % 80 < 40 ? 6 : -6);
        at += step;
        t += const Duration(milliseconds: 16);
        GestureBinding.instance.handlePointerEvent(
          PointerMoveEvent(
            pointer: pointer,
            position: at,
            delta: step,
            timeStamp: t,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
      GestureBinding.instance.handlePointerEvent(
        PointerUpEvent(pointer: pointer, position: at, timeStamp: t),
      );
      await _untilIdle(chat);
    },
    note: 'drag while it streams',
  );
}
