// test/services/offline_send_executor_test.dart
//
// The headless send of a queued message (docs/OFFLINE_SEND.md): the reply
// goes right after its question, the bubble loses its waiting state, a
// break after the server answered is "accepted" (never re-sent by itself),
// a break before is a retryable network failure, a chat streaming on
// screen is left alone, and the payload's settings reach the request.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/chat_message.dart';
import 'package:chuk_chat/models/chat_stream_event.dart';
import 'package:chuk_chat/models/queued_message.dart';
import 'package:chuk_chat/models/stored_chat.dart';
import 'package:chuk_chat/services/chat_storage_sync.dart'
    show encodeChatPayloadPair, neutralizeOutboxState;
import 'package:chuk_chat/services/offline_send_executor.dart';

QueuedMessage _row(String id, Map<String, dynamic> payload) => QueuedMessage(
  id: id,
  chatId: 'chat-1',
  sendPayload: payload,
  attemptCount: 0,
  createdAt: 0,
  updatedAt: 0,
);

StoredChat _chat(List<ChatMessage> messages) => StoredChat(
  id: 'chat-1',
  messages: messages,
  createdAt: DateTime(2026),
  isStarred: false,
);

void main() {
  late List<ChatMessage> stored;
  List<Map<String, dynamic>>? saved;
  OfflineSendRequest? lastRequest;

  setUp(() {
    saved = null;
    lastRequest = null;
    OfflineSendExecutor.accessToken = () => 'token';
    OfflineSendExecutor.isChatBusy = (_) => false;
    OfflineSendExecutor.loadChat = (_) async => _chat(stored);
    OfflineSendExecutor.saveChat = (_, maps) async => saved = maps;
  });

  tearDown(OfflineSendExecutor.resetSeams);

  void streamOf(List<ChatStreamEvent> events) {
    OfflineSendExecutor.stream = (req) {
      lastRequest = req;
      return Stream<ChatStreamEvent>.fromIterable(events);
    };
  }

  test('reply goes right after its question; waiting state is cleared',
      () async {
    stored = [
      ChatMessage(role: 'user', text: 'earlier'),
      ChatMessage(role: 'assistant', text: 'earlier answer'),
      ChatMessage(
        role: 'user',
        text: 'question',
        status: ChatMessageStatus.pending,
        queueId: 'q1',
      ),
      ChatMessage(
        role: 'user',
        text: 'later',
        status: ChatMessageStatus.pending,
        queueId: 'q2',
      ),
    ];
    streamOf(const [
      MetaEvent({'model': 'm'}),
      ContentEvent('the '),
      ContentEvent('answer'),
      DoneEvent(),
    ]);
    final result = await OfflineSendExecutor.execute(
      _row('q1', {
        'chatId': 'chat-1',
        'messageText': 'question',
        'modelId': 'model-x',
        'providerSlug': 'prov',
        'systemPrompt': 'be brief',
        'imagesJson': '["u/1.enc"]',
        'reasoningEffort': 'low',
      }),
    );
    expect(result.success, isTrue);
    expect(saved!.map((m) => m['text']), [
      'earlier',
      'earlier answer',
      'question',
      'the answer',
      'later',
    ]);
    expect(saved![2].containsKey('status'), isFalse);
    expect(saved![2].containsKey('queueId'), isFalse);
    expect(saved![4]['queueId'], 'q2');
    // Settings of the queued send reach the request; history stops before
    // the question and skips undelivered messages.
    expect(lastRequest!.systemPrompt, 'be brief');
    expect(lastRequest!.images, ['u/1.enc']);
    expect(lastRequest!.reasoningEffort, 'low');
    expect(lastRequest!.history.map((h) => h['content']), [
      'earlier',
      'earlier answer',
    ]);
    // Unknown model limits: never the old 512.
    expect(lastRequest!.maxTokens, OfflineSendExecutor.fallbackMaxTokens);
  });

  test('a dropped socket after the server answered goes back to the outbox',
      () async {
    stored = [
      ChatMessage(role: 'user', text: 'q', queueId: 'q1'),
    ];
    streamOf(const [
      ContentEvent('partial'),
      ErrorEvent('connection lost', code: StreamErrorCodes.connectionLost),
    ]);
    final result = await OfflineSendExecutor.execute(
      _row('q1', {'chatId': 'chat-1', 'messageText': 'q'}),
    );
    // The re-send carries the same client_request_id, so the server answers
    // it from its record and bills it once.
    expect(result.success, isFalse);
    expect(result.accepted, isFalse);
    expect(result.error, startsWith('network'));
    expect(lastRequest!.clientRequestId, 'ob-q1-p1');
    expect(saved, isNull);
  });

  test('a break the server cannot de-duplicate is accepted (no resend)',
      () async {
    stored = [
      ChatMessage(role: 'user', text: 'q', queueId: 'q1'),
    ];
    streamOf(const [
      ContentEvent('partial'),
      ErrorEvent('cut', code: StreamErrorCodes.upstreamInterrupted),
    ]);
    final result = await OfflineSendExecutor.execute(
      _row('q1', {'chatId': 'chat-1', 'messageText': 'q'}),
    );
    expect(result.success, isFalse);
    expect(result.accepted, isTrue);
    expect(saved, isNull);
  });

  test('a break before any frame is a retryable network failure', () async {
    stored = [ChatMessage(role: 'user', text: 'q', queueId: 'q1')];
    OfflineSendExecutor.stream = (_) =>
        Stream<ChatStreamEvent>.error(Exception('SocketException: refused'));
    final result = await OfflineSendExecutor.execute(
      _row('q1', {'chatId': 'chat-1', 'messageText': 'q'}),
    );
    expect(result.success, isFalse);
    expect(result.accepted, isFalse);
    expect(result.error, startsWith('network:'));
  });

  test('a chat streaming on screen is left alone', () async {
    stored = [ChatMessage(role: 'user', text: 'q', queueId: 'q1')];
    OfflineSendExecutor.isChatBusy = (_) => true;
    final result = await OfflineSendExecutor.execute(
      _row('q1', {'chatId': 'chat-1', 'messageText': 'q'}),
    );
    expect(result.deferred, isTrue);
  });

  test('no session defers', () async {
    stored = [];
    OfflineSendExecutor.accessToken = () => null;
    final result = await OfflineSendExecutor.execute(
      _row('q1', {'chatId': 'chat-1', 'messageText': 'q'}),
    );
    expect(result.deferred, isTrue);
  });

  test('a bubble that lost its id is found by its unanswered text', () {
    final messages = [
      ChatMessage(role: 'user', text: 'a'),
      ChatMessage(role: 'assistant', text: 'b'),
      ChatMessage(role: 'user', text: 'q'),
    ];
    expect(OfflineSendExecutor.findTarget(messages, _row('x', {}), 'q'), 2);
    expect(OfflineSendExecutor.findTarget(messages, _row('x', {}), 'a'), -1);
  });

  test('queued budget better than 512 is kept when limits are unknown', () {
    expect(
      OfflineSendExecutor.budgetFor(
        modelId: 'unknown/model',
        history: const [],
        message: 'hi',
        queued: 2000,
      ),
      2000,
    );
    expect(
      OfflineSendExecutor.budgetFor(
        modelId: 'unknown/model',
        history: const [],
        message: 'hi',
        queued: 512,
      ),
      OfflineSendExecutor.fallbackMaxTokens,
    );
  });

  group('cloud copy', () {
    test('pending and failed user messages sync as plain messages', () {
      final maps = <Map<String, dynamic>>[
        {'role': 'user', 'text': 'a', 'status': 'pending', 'queueId': 'q'},
        {'role': 'user', 'text': 'b', 'status': 'failed', 'lastError': 'x'},
        {'role': 'assistant', 'text': 'c', 'status': 'interrupted'},
        {'role': 'user', 'text': 'd', 'status': 'sent'},
      ];
      neutralizeOutboxState(maps);
      expect(maps[0].keys, unorderedEquals(['role', 'text']));
      expect(maps[1].keys, unorderedEquals(['role', 'text']));
      expect(maps[2]['status'], 'interrupted');
      expect(maps[3]['status'], 'sent');
    });

    test('the cache copy keeps the outbox state, the cloud copy not',
        () async {
      final messages = [
        ChatMessage(role: 'user', text: 'hi'),
        ChatMessage(role: 'assistant', text: 'yo'),
        ChatMessage(
          role: 'user',
          text: 'waiting',
          status: ChatMessageStatus.pending,
          queueId: 'q-1',
        ),
      ];
      final pair = await encodeChatPayloadPair(messages, null);
      expect(pair.local, contains('"queueId":"q-1"'));
      expect(pair.local, contains('"status":"pending"'));
      expect(pair.cloud, isNot(contains('q-1')));
      expect(pair.cloud, isNot(contains('pending')));
    });

    test('with nothing waiting both copies are one encoding', () async {
      final pair = await encodeChatPayloadPair([
        ChatMessage(role: 'user', text: 'hi'),
      ], 'name');
      expect(identical(pair.local, pair.cloud), isTrue);
    });

    test('cloud writes never hand the neutral copy to the cache', () {
      // Every cloud write encodes the pair; a single `forCloud` encoding
      // there would also land in the cache and drop the queue ids.
      for (final path in [
        'lib/services/chat_storage_crud.dart',
        'lib/services/chat_storage_mutations.dart',
      ]) {
        final src = File(path).readAsStringSync();
        expect(src, isNot(contains('forCloud: true')), reason: path);
        expect(src, contains('encodeChatPayloadPair('), reason: path);
      }
    });
  });
}
