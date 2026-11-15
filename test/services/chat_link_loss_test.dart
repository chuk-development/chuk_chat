// CHAT-119: a chat turn survives a lost connection.
//
// - a socket that cannot be opened (no DNS) counts as a lost connection, so
//   the chat layer waits and re-sends instead of failing the turn;
// - the reader sees one plain sentence in an error card, never the raw
//   socket error as if it were the answer;
// - a tool-loop pass that ends is not "done": an open turn holds the
//   completion notification back and keeps the turn busy between passes;
// - the header says "Reconnecting" while the link is gone.

import 'dart:async';

import 'package:chuk_chat/models/chat_stream_event.dart';
import 'package:chuk_chat/models/stream_phase.dart';
import 'package:chuk_chat/services/multiplex_connection.dart';
import 'package:chuk_chat/services/streaming_manager.dart';
import 'package:chuk_chat/utils/answer_blocks_parser.dart';
import 'package:chuk_chat/utils/retry_backoff.dart';
import 'package:chuk_chat/utils/stream_error_notice.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('handshake failures', () {
    test('a socket that cannot be opened is a lost connection', () {
      for (final String code in <String>[
        'ws_connect_failed',
        'ws_timeout',
        'ws_error',
        'ws_closed',
        'auth_timeout',
        'auth_protocol',
      ]) {
        expect(
          MultiplexConnection.handshakeErrorCode(
            MultiplexException('x', code: code),
          ),
          StreamErrorCodes.connectionLost,
          reason: code,
        );
      }
      expect(
        StreamErrorCodes.retryable,
        contains(StreamErrorCodes.connectionLost),
      );
    });

    test('an auth refusal keeps its code', () {
      expect(
        MultiplexConnection.handshakeErrorCode(
          MultiplexException('no', code: 'auth_error'),
        ),
        'auth_error',
      );
      expect(
        MultiplexConnection.handshakeErrorCode(
          MultiplexException('no', code: 'no_token'),
        ),
        'no_token',
      );
    });
  });

  group('what the reader is told', () {
    const String raw =
        "WebSocket connection failed: SocketException: Failed host lookup: "
        "'api.chuk.chat' (OS Error: No address associated with hostname, "
        'errno = 7)';

    test('a raw socket error becomes one plain sentence', () {
      final String text = userFacingStreamError(raw, code: 'ws_connect_failed');
      expect(text, isNot(contains('SocketException')));
      expect(text, isNot(contains('api.chuk.chat')));
      expect(text, contains('No connection'));
    });

    test('a server message stays, without an Error: prefix', () {
      expect(
        userFacingStreamError('Error: Model is overloaded.', code: 'x'),
        'Model is overloaded.',
      );
    });

    test('the note draws as the error card and strips away again', () {
      final String note = turnErrorNote('No connection.\nTry again.');
      final AnswerBlockSegment alert = splitAnswerBlocks(
        'half an answer\n\n$note',
      ).whereType<AnswerBlockSegment>().single;
      expect(alert.kind, AnswerBlockKind.alert);
      expect(alert.arg, kTurnErrorAlertType);
      expect(alert.lines, <String>['No connection.', 'Try again.']);

      expect(
        stripStreamErrorNotice('half an answer\n\n$note'),
        'half an answer',
      );
      expect(stripStreamErrorNotice(note), '');
    });

    test('a model warning is not stripped', () {
      const String warning = '> [!WARNING]\n> Hot surface.';
      expect(stripStreamErrorNotice(warning), warning);
    });
  });

  group('waitBeforeReconnect', () {
    test('the network coming back ends the wait at once', () async {
      final ValueNotifier<bool> online = ValueNotifier<bool>(false);
      final Stopwatch watch = Stopwatch()..start();
      final Future<void> wait = waitBeforeReconnect(
        const Duration(seconds: 30),
        online: online,
      );
      online.value = true;
      await wait;
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('without a change it waits the full delay', () async {
      final ValueNotifier<bool> online = ValueNotifier<bool>(true);
      final Stopwatch watch = Stopwatch()..start();
      await waitBeforeReconnect(
        const Duration(milliseconds: 120),
        online: online,
      );
      expect(
        watch.elapsed,
        greaterThanOrEqualTo(const Duration(milliseconds: 100)),
      );
    });
  });

  group('turns', () {
    final StreamingManager manager = StreamingManager();

    tearDown(() async {
      await manager.endTurn('turn-a');
      await manager.cancelAllStreams();
    });

    test('a turn stays open between passes and says Reconnecting', () async {
      manager.beginTurn('turn-a');
      expect(manager.isTurnOpen('turn-a'), isTrue);
      expect(manager.isStreaming('turn-a'), isFalse);

      manager.setReconnecting('turn-a', true);
      expect(manager.phaseOf('turn-a'), StreamPhase.reconnecting);

      // The next pass: its first frame ends "Reconnecting".
      final StreamController<ChatStreamEvent> controller =
          StreamController<ChatStreamEvent>();
      await manager.startStream(
        chatId: 'turn-a',
        messageIndex: 0,
        stream: controller.stream,
        onUpdate: (_, _) {},
        onComplete: (_, _, _) {},
        onError: (_, {String? code}) {},
      );
      expect(manager.phaseOf('turn-a'), StreamPhase.reconnecting);
      controller.add(const ChatStreamEvent.content('hi'));
      await Future<void>.delayed(Duration.zero);
      expect(manager.isReconnecting('turn-a'), isFalse);
      expect(manager.phaseOf('turn-a'), StreamPhase.writing);

      await manager.endTurn('turn-a');
      expect(manager.isTurnOpen('turn-a'), isFalse);
      await controller.close();
    });

    test('ending a turn clears its reconnecting mark', () async {
      manager.beginTurn('turn-a');
      manager.setReconnecting('turn-a', true);
      await manager.endTurn('turn-a');
      expect(manager.isReconnecting('turn-a'), isFalse);
      expect(manager.phaseOf('turn-a'), isNull);
    });
  });
}
