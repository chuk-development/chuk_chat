// test/services/follow_up_dispatcher_test.dart
//
// Follow-ups typed during a reply go out in the background too
// (docs/OFFLINE_SEND.md): once the chat's turn is over and no screen holds
// the chat, each parked follow-up becomes an outbox row with a waiting
// bubble at the end of the chat, in order, and leaves the park.

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/chat_message.dart';
import 'package:chuk_chat/models/stored_chat.dart';
import 'package:chuk_chat/services/follow_up_dispatcher.dart';
import 'package:chuk_chat/services/follow_up_parking_service.dart';
import 'package:chuk_chat/services/offline_outbox_cipher.dart';
import 'package:chuk_chat/services/offline_send_coordinator.dart';

void main() {
  final disk = <String, String>{};
  final enqueued = <OfflineSendPayload>[];
  List<Map<String, dynamic>>? saved;
  var kicks = 0;
  var onScreen = false;
  var running = false;
  var clock = DateTime(2026, 11, 4, 12);

  setUp(() {
    disk.clear();
    enqueued.clear();
    saved = null;
    kicks = 0;
    onScreen = false;
    running = false;
    clock = DateTime(2026, 11, 4, 12);
    OutboxCipher.useFake(userId: 'u1');
    FollowUpParkingService.read = (k) async => disk[k];
    FollowUpParkingService.write = (k, v) async => disk[k] = v;
    FollowUpParkingService.delete = (k) async => disk.remove(k);
    FollowUpParkingService.keys = (prefix) async =>
        disk.keys.where((k) => k.startsWith(prefix)).toList();
    FollowUpDispatcher.isOnScreen = (_) => onScreen;
    FollowUpDispatcher.isTurnRunning = (_) => running;
    FollowUpDispatcher.now = () => clock;
    FollowUpDispatcher.settle = const Duration(seconds: 3);
    FollowUpDispatcher.pollEvery = const Duration(hours: 1);
    FollowUpDispatcher.kickOutbox = () => kicks++;
    FollowUpDispatcher.enqueue = (p) async {
      enqueued.add(p);
      return 'q${enqueued.length}';
    };
    FollowUpDispatcher.loadChat = (id) async => StoredChat(
      id: id,
      messages: [
        ChatMessage(role: 'user', text: 'question'),
        ChatMessage(
          role: 'assistant',
          text: 'answer',
          modelId: 'model-x',
          provider: 'prov',
        ),
      ],
      createdAt: DateTime(2026),
      isStarred: false,
    );
    FollowUpDispatcher.saveChat = (_, maps) async => saved = maps;
  });

  tearDown(() {
    FollowUpDispatcher.resetSeams();
    FollowUpParkingService.resetSeams();
    OutboxCipher.reset();
  });

  Future<int> settleAndRun() async {
    await FollowUpDispatcher.instance.runOnce(); // starts the idle clock
    clock = clock.add(const Duration(seconds: 4));
    return FollowUpDispatcher.instance.runOnce();
  }

  test('parked follow-ups of a free chat go to the outbox in order', () async {
    await FollowUpParkingService.save('c1', ['first', 'second']);

    expect(await settleAndRun(), 2);

    expect(enqueued.map((p) => p.messageText).toList(), ['first', 'second']);
    expect(enqueued.first.chatId, 'c1');
    expect(enqueued.first.modelId, 'model-x');
    expect(enqueued.first.providerSlug, 'prov');
    expect(enqueued.first.resolvePromptAtSend, isTrue);
    expect(await FollowUpParkingService.load('c1'), isEmpty);

    final maps = saved!;
    expect(maps.map((m) => m['text']).toList(), [
      'question',
      'answer',
      'first',
      'second',
    ]);
    expect(maps[2]['status'], 'pending');
    expect(maps[2]['queueId'], 'q1');
    expect(maps[3]['queueId'], 'q2');
    expect(kicks, 1);
  });

  test('a chat on screen keeps its follow-ups', () async {
    onScreen = true;
    await FollowUpParkingService.save('c1', ['mine']);
    expect(await settleAndRun(), 0);
    expect(await FollowUpParkingService.load('c1'), ['mine']);
    expect(enqueued, isEmpty);
  });

  test('nothing goes out while the turn runs, nor right after it', () async {
    running = true;
    await FollowUpParkingService.save('c1', ['wait']);
    expect(await settleAndRun(), 0);

    running = false;
    // Just finished: the answer's save may still land.
    expect(await FollowUpDispatcher.instance.runOnce(), 0);
    expect(enqueued, isEmpty);
    clock = clock.add(const Duration(seconds: 4));
    expect(await FollowUpDispatcher.instance.runOnce(), 1);
  });

  test('a failed enqueue stays parked', () async {
    FollowUpDispatcher.enqueue = (p) async => throw StateError('disk full');
    await FollowUpParkingService.save('c1', ['keep me']);
    expect(await settleAndRun(), 0);
    expect(await FollowUpParkingService.load('c1'), ['keep me']);
    expect(saved, isNull);
  });

  test('a chat read that throws leaves the follow-ups parked', () async {
    FollowUpDispatcher.loadChat = (id) async => throw StateError('db locked');
    await FollowUpParkingService.save('c1', ['not lost']);
    expect(await settleAndRun(), 0);
    expect(await FollowUpParkingService.load('c1'), ['not lost']);
    expect(enqueued, isEmpty);
  });

  test('without a user nothing happens', () async {
    await FollowUpParkingService.save('c1', ['x']);
    OutboxCipher.useFake(userId: null);
    expect(await settleAndRun(), 0);
  });
}
