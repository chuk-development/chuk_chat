import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/message_feedback_store.dart';
import 'package:chuk_chat/services/message_feedback_sync.dart';
import 'package:chuk_chat/services/prompt_cache/prompt_context.dart';

Map<String, dynamic> _body(String id) => <String, dynamic>{
  'message_id': id,
  'chat_hash': '0123456789abcdef',
  'rating': 'positive',
};

/// Lets the background hand-over (unawaited futures, prefs I/O) finish.
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('feedbackRequestBody', () {
    test('maps the verdict onto the server body, never the text', () {
      final Map<String, dynamic>? body = feedbackRequestBody(
        messageId: 'm1',
        chatHash: chatIdHash('chat-1'),
        positive: false,
        categories: const <String>['task-result', 'other'],
        note: '  it stopped  ',
        modelId: 'deepseek/deepseek-v4-flash-0731',
        provider: 'fireworks',
      );
      expect(body, <String, dynamic>{
        'message_id': 'm1',
        'chat_hash': chatIdHash('chat-1'),
        'rating': 'negative',
        'categories': <String>['task-result', 'other'],
        'note': 'it stopped',
        'model_id': 'deepseek/deepseek-v4-flash-0731',
        'provider': 'fireworks',
      });
      expect(chatIdHash('chat-1'), hasLength(16));
    });

    test('cuts the note at 1000 and leaves empty fields out', () {
      final Map<String, dynamic>? body = feedbackRequestBody(
        messageId: 'm1',
        chatHash: '0123456789ABCDEF',
        positive: true,
        categories: const <String>[],
        note: 'x' * 1500,
        modelId: '  ',
      );
      expect(body?['note'], hasLength(1000));
      expect(body?['chat_hash'], '0123456789abcdef');
      expect(body?.containsKey('categories'), isFalse);
      expect(body?.containsKey('model_id'), isFalse);
      expect(body?['rating'], 'positive');
    });

    test('no chat hash: nothing to send', () {
      expect(
        feedbackRequestBody(
          messageId: 'm1',
          chatHash: null,
          positive: true,
          categories: const <String>[],
        ),
        isNull,
      );
    });
  });

  group('MessageFeedbackApi', () {
    test('POST and DELETE carry the bearer and the right paths', () async {
      final List<http.Request> seen = <http.Request>[];
      final MessageFeedbackApi api = MessageFeedbackApi(
        client: MockClient((http.Request r) async {
          seen.add(r);
          return http.Response('{"ok": true}', 200);
        }),
        baseUrl: 'https://api.example',
        token: () async => 'tok',
      );
      await api.post(_body('m/1'));
      await api.delete('m/1');
      expect(seen[0].method, 'POST');
      expect(seen[0].url.toString(), 'https://api.example/v1/feedback');
      expect(seen[0].headers['Authorization'], 'Bearer tok');
      expect(jsonDecode(seen[0].body), _body('m/1'));
      expect(seen[1].method, 'DELETE');
      expect(seen[1].url.toString(), 'https://api.example/v1/feedback/m%2F1');
    });

    test('a 422 is final, a 503 and a network error are retryable', () async {
      int status = 422;
      final MessageFeedbackApi api = MessageFeedbackApi(
        client: MockClient((http.Request r) async {
          if (status == 0) throw http.ClientException('offline');
          return http.Response('{"detail": "bad"}', status);
        }),
        baseUrl: 'https://api.example',
        token: () async => 'tok',
      );
      Future<FeedbackSendException> fail() async {
        try {
          await api.post(_body('m'));
        } on FeedbackSendException catch (e) {
          return e;
        }
        throw StateError('expected a failure');
      }

      expect((await fail()).retryable, isFalse);
      status = 503;
      expect((await fail()).retryable, isTrue);
      status = 0;
      expect((await fail()).retryable, isTrue);
    });

    test('no session: not signed in, nothing sent', () async {
      bool called = false;
      final MessageFeedbackApi api = MessageFeedbackApi(
        client: MockClient((http.Request r) async {
          called = true;
          return http.Response('', 200);
        }),
        token: () async => null,
      );
      await expectLater(
        api.post(_body('m')),
        throwsA(
          isA<FeedbackSendException>().having(
            (e) => e.status,
            'status',
            FeedbackSendException.notSignedIn,
          ),
        ),
      );
      expect(called, isFalse);
    });
  });

  group('MessageFeedbackSync', () {
    test('sends set and delete in order, then empties', () async {
      final List<String> calls = <String>[];
      final MessageFeedbackSync sync = MessageFeedbackSync(
        post: (b) async => calls.add('post ${b['message_id']}'),
        delete: (id) async => calls.add('delete $id'),
      );
      await sync.attach('u1');
      await sync.enqueue(FeedbackJob.set('a', _body('a')));
      await sync.flush();
      await sync.enqueue(FeedbackJob.remove('b'));
      await sync.flush();
      expect(calls, <String>['post a', 'delete b']);
      expect(sync.pending, isEmpty);
      sync.resetForTest();
    });

    test('offline: the job waits, survives a restart, goes out later', () {
      fakeAsync((FakeAsync async) {
        bool online = false;
        final List<String> sent = <String>[];
        Future<void> post(Map<String, dynamic> b) async {
          if (!online) throw const FeedbackSendException(0, 'network');
          sent.add('${b['message_id']}');
        }

        final MessageFeedbackSync sync = MessageFeedbackSync(
          post: post,
          delete: (_) async {},
          backoff: const <Duration>[Duration(seconds: 30)],
        );
        sync.attach('u1');
        async.flushMicrotasks();
        sync.enqueue(FeedbackJob.set('a', _body('a')));
        async.flushMicrotasks();
        expect(sent, isEmpty);
        expect(sync.pending.single.messageId, 'a');
        expect(sync.retryScheduled, isTrue);

        // A fresh queue (an app restart) reads the job back from disk.
        final MessageFeedbackSync after = MessageFeedbackSync(
          post: post,
          delete: (_) async {},
          backoff: const <Duration>[Duration(seconds: 30)],
        );
        after.attach('u1');
        async.flushMicrotasks();
        expect(after.pending.single.messageId, 'a');
        after.resetForTest();

        online = true;
        async.elapse(const Duration(seconds: 31));
        async.flushMicrotasks();
        expect(sent, <String>['a']);
        expect(sync.pending, isEmpty);
        sync.resetForTest();
      });
    });

    test('a refused job is dropped, the next one still goes', () async {
      final List<String> sent = <String>[];
      final MessageFeedbackSync sync = MessageFeedbackSync(
        post: (b) async {
          if (b['message_id'] == 'bad') {
            throw const FeedbackSendException(422, 'bad');
          }
          sent.add('${b['message_id']}');
        },
        delete: (_) async {},
      );
      await sync.attach('u1');
      await sync.enqueue(FeedbackJob.set('bad', _body('bad')));
      await sync.enqueue(FeedbackJob.set('ok', _body('ok')));
      await sync.flush();
      await sync.flush();
      expect(sent, <String>['ok']);
      expect(sync.pending, isEmpty);
      expect(sync.retryScheduled, isFalse);
    });

    test('not signed in: kept without a timer', () async {
      final MessageFeedbackSync sync = MessageFeedbackSync(
        post: (_) async => throw const FeedbackSendException(
          FeedbackSendException.notSignedIn,
        ),
        delete: (_) async {},
      );
      await sync.attach(null);
      await sync.enqueue(FeedbackJob.set('a', _body('a')));
      await sync.flush();
      expect(sync.pending, hasLength(1));
      expect(sync.retryScheduled, isFalse);
    });

    test('the newest job per message wins, the queue stays small', () async {
      final MessageFeedbackSync sync = MessageFeedbackSync(
        post: (_) async => throw const FeedbackSendException(
          FeedbackSendException.notSignedIn,
        ),
        delete: (_) async => throw const FeedbackSendException(
          FeedbackSendException.notSignedIn,
        ),
      );
      await sync.attach('u1');
      await sync.enqueue(FeedbackJob.set('a', _body('a')));
      await sync.enqueue(FeedbackJob.remove('a'));
      expect(sync.pending.single.isRemove, isTrue);
      for (int i = 0; i < MessageFeedbackSync.maxJobs + 5; i++) {
        await sync.enqueue(FeedbackJob.remove('m$i'));
      }
      expect(sync.pending, hasLength(MessageFeedbackSync.maxJobs));
      expect(sync.pending.first.messageId, 'm5');
    });

    test('sign-out drops the queue from memory and disk', () async {
      final MessageFeedbackSync sync = MessageFeedbackSync(
        post: (_) async => throw const FeedbackSendException(
          FeedbackSendException.notSignedIn,
        ),
        delete: (_) async {},
      );
      await sync.attach('u1');
      await sync.enqueue(FeedbackJob.set('a', _body('a')));
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(MessageFeedbackSync.prefsKeyFor('u1')), isNotNull);
      await sync.clearForSignOut('u1');
      expect(sync.pending, isEmpty);
      expect(prefs.getString(MessageFeedbackSync.prefsKeyFor('u1')), isNull);
    });
  });

  group('MessageFeedbackStore to the server', () {
    final MessageFeedbackStore store = MessageFeedbackStore.instance;
    late List<String> calls;

    setUp(() {
      calls = <String>[];
      store.resetForTest();
      MessageFeedbackStore.userIdReader = () => 'u1';
      MessageFeedbackStore.sync = MessageFeedbackSync(
        post: (b) async => calls.add('post ${jsonEncode(b)}'),
        delete: (id) async => calls.add('delete $id'),
      );
      MessageFeedbackStore.sendToBackend = (fb) async {
        final Map<String, dynamic>? body = fb.toBackendBody();
        if (body != null) {
          await MessageFeedbackStore.sync.enqueue(
            FeedbackJob.set(fb.messageId, body),
          );
        }
      };
      MessageFeedbackStore.removeFromBackend = (id) =>
          MessageFeedbackStore.sync.enqueue(FeedbackJob.remove(id));
    });

    tearDown(() {
      MessageFeedbackStore.sync.resetForTest();
      MessageFeedbackStore.sendToBackend = null;
      MessageFeedbackStore.removeFromBackend = null;
    });

    test('save posts the hashed chat, remove deletes it', () async {
      await store.save(
        MessageFeedback(
          messageId: 'm1',
          rating: FeedbackRating.down,
          categories: const <FeedbackCategory>[
            FeedbackCategory.securityPrivacy,
          ],
          modelId: 'z-ai/glm-5.3-flash',
          provider: 'orcarouter',
          chatHash: chatIdHash('chat-9'),
          createdAt: DateTime.utc(2026, 11, 5),
        ),
      );
      // The store hands the job over in the background.
      await _settle();
      await MessageFeedbackStore.sync.flush();
      expect(calls, hasLength(1));
      final Map<String, dynamic> body = jsonDecode(
        calls.single.substring('post '.length),
      ) as Map<String, dynamic>;
      expect(body['chat_hash'], chatIdHash('chat-9'));
      expect(body['rating'], 'negative');
      expect(body['categories'], <String>['security-privacy-permission']);
      expect(body['provider'], 'orcarouter');
      expect(body.containsKey('text'), isFalse);

      await store.remove('m1');
      await _settle();
      await MessageFeedbackStore.sync.flush();
      expect(calls.last, 'delete m1');
    });

    test('a verdict without a chat hash stays on the device', () async {
      await store.save(
        MessageFeedback(
          messageId: 'm2',
          rating: FeedbackRating.up,
          createdAt: DateTime.utc(2026, 11, 5),
        ),
      );
      await _settle();
      await MessageFeedbackStore.sync.flush();
      expect(calls, isEmpty);
      expect(store.peek('m2'), isNotNull);
    });
  });
}
