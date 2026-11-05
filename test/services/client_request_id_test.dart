// Request idempotency on /v2/ws (bead chuk_chat-vnan): every chat frame
// carries a `client_request_id`, one per pass, the same on every re-send of
// that pass; outbox rows derive theirs from the row id. The send layer
// answers the server's idempotency frames (api_server CLAUDE.md, "/v2/ws").

import 'dart:async';

import 'package:chuk_chat/models/chat_stream_event.dart';
import 'package:chuk_chat/models/queued_message.dart';
import 'package:chuk_chat/services/client_request_ids.dart';
import 'package:chuk_chat/services/offline_send_coordinator.dart';
import 'package:chuk_chat/services/websocket_chat_service.dart';
import 'package:chuk_chat/utils/stream_error_notice.dart';
import 'package:flutter_test/flutter_test.dart';

/// A scripted server: answers each send with the next list of events and
/// records the `client_request_id` each send carried.
class _Script {
  _Script(this.replies);
  final List<List<ChatStreamEvent>> replies;
  final List<String?> sentIds = <String?>[];

  Stream<ChatStreamEvent> send(Map<String, dynamic> payload) {
    sentIds.add(payload['client_request_id'] as String?);
    final reply = replies.removeAt(0);
    return Stream<ChatStreamEvent>.fromIterable(reply);
  }
}

ErrorEvent _inFlight([double? after = 1]) => ErrorEvent(
  'running',
  code: StreamErrorCodes.duplicateInFlight,
  retryAfterSeconds: after,
);

QueuedMessage _row(String id, Map<String, dynamic> payload) => QueuedMessage(
  id: id,
  chatId: 'chat-1',
  sendPayload: payload,
  attemptCount: 0,
  createdAt: 0,
  updatedAt: 0,
);

void main() {
  group('ids', () {
    test('the server rule: 1 to 64 printable characters, no outer space', () {
      expect(ClientRequestIds.isValid('ob-1-p1'), isTrue);
      expect(ClientRequestIds.isValid(''), isFalse);
      expect(ClientRequestIds.isValid(null), isFalse);
      expect(ClientRequestIds.isValid(' a'), isFalse);
      expect(ClientRequestIds.isValid('a\n'), isFalse);
      expect(ClientRequestIds.isValid('a\u0001b'), isFalse);
      expect(ClientRequestIds.isValid('x' * 64), isTrue);
      expect(ClientRequestIds.isValid('x' * 65), isFalse);
    });

    test('fresh ids are valid and differ', () {
      final a = ClientRequestIds.fresh();
      final b = ClientRequestIds.fresh();
      expect(ClientRequestIds.isValid(a), isTrue);
      expect(a, isNot(b));
    });

    test('pass ids derive from the base: stable per pass, new per pass', () {
      const base = 'ob-5e22557d-0ba0-4f4a-a6f9-412266fe88ba';
      expect(ClientRequestIds.forPass(base, 1), '$base-p1');
      expect(ClientRequestIds.forPass(base, 1), ClientRequestIds.forPass(base, 1));
      expect(ClientRequestIds.forPass(base, 2), '$base-p2');
      expect(ClientRequestIds.isValid(ClientRequestIds.forPass(base, 20)), isTrue);
      // No base: a fresh id each time.
      expect(
        ClientRequestIds.forPass(null, 1),
        isNot(ClientRequestIds.forPass(null, 1)),
      );
    });

    test('an outbox base is clean and leaves room for the pass suffix', () {
      expect(ClientRequestIds.outboxBase('ab c\nd'), 'ob-abcd');
      final long = ClientRequestIds.outboxBase('x' * 200);
      expect(long.length, ClientRequestIds.maxBaseLength);
      expect(ClientRequestIds.isValid('$long-p20'), isTrue);
    });

    // Bead chuk_chat-3e67: the user's Retry of a turn the server may still
    // hold asks with that turn's ids.
    test('a kept base goes to one Retry of the same message only', () {
      ClientRequestIds.debugReset();
      final Map<String, String> row = <String, String>{
        'sender': 'user',
        'text': 'hi',
        'sentAt': '2026-11-05T10:00:00Z',
      };
      final String? key = ClientRequestIds.messageKeyOf(row);
      expect(key, 'sentAt:2026-11-05T10:00:00Z');
      expect(
        ClientRequestIds.messageKeyOf(<String, String>{...row, 'messageId': 'm1'}),
        'messageId:m1',
      );
      ClientRequestIds.keepForRetry('chat-1', key, 'c-base');
      // Another message or another chat does not get it.
      expect(ClientRequestIds.takeForRetry('chat-1', 'sentAt:other'), isNull);
      expect(ClientRequestIds.takeForRetry('chat-2', key), isNull);
      expect(ClientRequestIds.takeForRetry('chat-1', key), 'c-base');
      // Used once.
      expect(ClientRequestIds.takeForRetry('chat-1', key), isNull);
      // Bounded.
      for (int i = 0; i <= ClientRequestIds.maxKeptForRetry; i++) {
        ClientRequestIds.keepForRetry('chat-1', 'k$i', 'b$i');
      }
      expect(ClientRequestIds.takeForRetry('chat-1', 'k0'), isNull);
      expect(
        ClientRequestIds.takeForRetry(
          'chat-1',
          'k${ClientRequestIds.maxKeptForRetry}',
        ),
        'b${ClientRequestIds.maxKeptForRetry}',
      );
    });

    // Bead chuk_chat-074s: a dropped socket re-sends the pass under the
    // same id, a bounded number of times, and only for the failures the
    // server de-duplicates.
    test('a pass is re-sent under the same id only for de-duplicated codes', () {
      const Set<String> same = StreamErrorCodes.resendSameId;
      expect(
        ClientRequestIds.resendPassOnSameId(
          StreamErrorCodes.connectionLost,
          0,
          same,
        ),
        isTrue,
      );
      expect(
        ClientRequestIds.resendPassOnSameId(
          StreamErrorCodes.requestPending,
          ClientRequestIds.maxPassResends - 1,
          same,
        ),
        isTrue,
      );
      expect(
        ClientRequestIds.resendPassOnSameId(
          StreamErrorCodes.connectionLost,
          ClientRequestIds.maxPassResends,
          same,
        ),
        isFalse,
      );
      expect(
        ClientRequestIds.resendPassOnSameId(
          StreamErrorCodes.upstreamStatus,
          0,
          same,
        ),
        isFalse,
      );
      expect(ClientRequestIds.resendPassOnSameId(null, 0, same), isFalse);
    });

    test('an armed base is taken by one turn; disarm drops it', () {
      ClientRequestIds.arm('chat-1', 'ob-q1');
      expect(ClientRequestIds.take('chat-2'), isNull);
      expect(ClientRequestIds.take('chat-1'), 'ob-q1');
      expect(ClientRequestIds.take('chat-1'), isNull);
      ClientRequestIds.arm('chat-1', 'ob-q1');
      ClientRequestIds.disarm('chat-1');
      expect(ClientRequestIds.take('chat-1'), isNull);
    });

    test('an outbox row keeps its base; old rows derive it from the id', () {
      final stored = OfflineSendPayload.fromJson(const {
        'chatId': 'chat-1',
        'messageText': 'q',
        'clientRequestBase': 'c-abc',
      });
      expect(stored.toJson()['clientRequestBase'], 'c-abc');
      expect(
        OfflineSendCoordinator.requestBaseFor(_row('q1', const {}), stored),
        'c-abc',
      );
      final old = OfflineSendPayload.fromJson(const {
        'chatId': 'chat-1',
        'messageText': 'q',
      });
      expect(
        OfflineSendCoordinator.requestBaseFor(_row('q1', const {}), old),
        'ob-q1',
      );
      // A screen send that went into the outbox keeps its turn's base.
      expect(old.withRequestBase('c-turn').clientRequestBase, 'c-turn');
      expect(old.withRequestBase(null).clientRequestBase, isNull);
    });
  });

  group('runIdempotent', () {
    final waits = <Duration>[];
    setUp(() {
      waits.clear();
      WebSocketChatService.pollDelay = (d) async => waits.add(d);
    });
    tearDown(() => WebSocketChatService.pollDelay = Future<void>.delayed);

    Future<List<ChatStreamEvent>> run(
      _Script script, {
      String id = 'c-1',
      void Function(String)? onId,
    }) => WebSocketChatService.runIdempotent(
      payload: <String, dynamic>{'message': 'hi', 'client_request_id': id},
      send: script.send,
      onRequestId: onId,
    ).toList();

    test('in flight: polls with the same id until the answer comes', () async {
      final script = _Script([
        [_inFlight(3), const DoneEvent()],
        [_inFlight(0.2), const DoneEvent()],
        [const ContentEvent('stored'), const DoneEvent()],
      ]);
      final events = await run(script);
      expect(script.sentIds, ['c-1', 'c-1', 'c-1']);
      // The hint, held to 1 to 5 s.
      expect(waits, [const Duration(seconds: 3), const Duration(seconds: 1)]);
      expect(events.whereType<ErrorEvent>(), isEmpty);
      expect((events.first as ContentEvent).text, 'stored');
      expect(events.whereType<DoneEvent>(), hasLength(1));
    });

    test('still running after every poll: a pending error, then done',
        () async {
      final script = _Script([
        for (var i = 0; i <= WebSocketChatService.maxInFlightPolls; i++)
          [_inFlight(null), const DoneEvent()],
      ]);
      final events = await run(script);
      expect(script.sentIds, hasLength(WebSocketChatService.maxInFlightPolls + 1));
      expect(script.sentIds.toSet(), {'c-1'});
      final error = events.whereType<ErrorEvent>().single;
      expect(error.code, StreamErrorCodes.requestPending);
      expect(error.message, kAnswerPendingNotice);
      expect(events.last, isA<DoneEvent>());
      // A pending pass is retried with the same id by the pass retry.
      expect(StreamErrorCodes.retryable, contains(StreamErrorCodes.requestPending));
    });

    for (final code in [
      StreamErrorCodes.clientRequestIdConflict,
      StreamErrorCodes.invalidClientRequestId,
    ]) {
      test('$code: one re-send with a fresh id', () async {
        final script = _Script([
          [ErrorEvent('no', code: code), const DoneEvent()],
          [const ContentEvent('ok'), const DoneEvent()],
        ]);
        final learned = <String>[];
        final events = await run(script, onId: learned.add);
        expect(script.sentIds[0], 'c-1');
        expect(script.sentIds[1], isNot('c-1'));
        expect(ClientRequestIds.isValid(script.sentIds[1]), isTrue);
        expect(learned, [script.sentIds[1]]);
        expect(events.whereType<ErrorEvent>(), isEmpty);
      });
    }

    test('a second conflict is passed on, not looped', () async {
      final script = _Script([
        [
          const ErrorEvent('no', code: StreamErrorCodes.clientRequestIdConflict),
          const DoneEvent(),
        ],
        [
          const ErrorEvent('no', code: StreamErrorCodes.clientRequestIdConflict),
          const DoneEvent(),
        ],
      ]);
      final events = await run(script);
      expect(script.sentIds, hasLength(2));
      expect(events.whereType<ErrorEvent>().single.code,
          StreamErrorCodes.clientRequestIdConflict);
    });

    test('a transient routing error re-sends once with the same id', () async {
      final script = _Script([
        [const ErrorEvent("Model 'x' is not available on y"), const DoneEvent()],
        [const ContentEvent('ok'), const DoneEvent()],
      ]);
      final events = await run(script);
      expect(script.sentIds, ['c-1', 'c-1']);
      expect(events.whereType<ErrorEvent>(), isEmpty);
    });

    test('other errors pass through unchanged', () async {
      final script = _Script([
        [
          const ErrorEvent('cut', code: StreamErrorCodes.upstreamInterrupted),
          const DoneEvent(),
        ],
      ]);
      final events = await run(script);
      expect(script.sentIds, ['c-1']);
      expect(events.whereType<ErrorEvent>().single.code,
          StreamErrorCodes.upstreamInterrupted);
    });
  });

  group('stop', () {
    tearDown(() => WebSocketChatService.debugCancelSink = null);

    test("the user's Stop cancels the chat's running pass by its id", () {
      final cancelled = <String>[];
      WebSocketChatService.debugCancelSink = cancelled.add;
      WebSocketChatService.debugTrackRequest('chat-1', 'c-turn-p2');
      WebSocketChatService.declareStopIntent('chat-1');
      expect(cancelled, ['c-turn-p2']);
      // Once: the id is spent.
      WebSocketChatService.declareStopIntent('chat-1');
      expect(cancelled, ['c-turn-p2']);
      // Another chat has nothing running.
      WebSocketChatService.declareStopIntent('chat-2');
      expect(cancelled, ['c-turn-p2']);
    });
  });

  test('only failures the server de-duplicates go back to the outbox', () {
    // The server still has these requests under the same id.
    expect(
      StreamErrorCodes.resendSameId,
      containsAll(<String>[
        StreamErrorCodes.connectionLost,
        StreamErrorCodes.requestPending,
      ]),
    );
    expect(
      StreamErrorCodes.resendSameId,
      isNot(contains(StreamErrorCodes.upstreamInterrupted)),
    );
  });
}
