// test/services/offline_send_executor_routing_test.dart
//
// Which path sends a queued message (docs/OFFLINE_SEND.md, bead
// chuk_chat-gzd8): the screen that shows the chat (its own send path, with
// tools), else the headless tool turn. A chat with a turn running (also
// between two tool passes) is left alone.

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/queued_message.dart';
import 'package:chuk_chat/services/chat_runtime_registry.dart';
import 'package:chuk_chat/services/offline_retry_manager.dart';
import 'package:chuk_chat/services/offline_send_coordinator.dart';
import 'package:chuk_chat/services/offline_send_executor.dart';

class _Screen implements OutboxScreen {
  _Screen(this.outboxChatId, this.answer);

  @override
  final String? outboxChatId;
  final SendExecutorResult? answer;
  final List<String> sent = <String>[];

  @override
  Future<SendExecutorResult?> sendOutboxRow(
    QueuedMessage queued,
    OfflineSendPayload payload,
  ) async {
    sent.add(queued.id);
    return answer;
  }
}

QueuedMessage _row(String id) => QueuedMessage(
  id: id,
  chatId: 'chat-1',
  sendPayload: const <String, dynamic>{
    'chatId': 'chat-1',
    'messageText': 'hello',
    'modelId': 'm',
    'providerSlug': 'p',
  },
  attemptCount: 0,
  createdAt: 0,
  updatedAt: 0,
);

void main() {
  final List<String> headless = <String>[];

  setUp(() {
    headless.clear();
    OfflineSendExecutor.accessToken = () => 'token';
    OfflineSendExecutor.toolTurn = (q, p) async {
      headless.add(q.id);
      return const SendExecutorResult.success();
    };
  });

  tearDown(() {
    OfflineSendExecutor.resetSeams();
    ChatRuntimeRegistry.instance.clear();
  });

  test('the chat on screen sends the row through its own path', () async {
    final screen = _Screen('chat-1', const SendExecutorResult.success());
    OfflineSendExecutor.registerScreen(screen);
    OfflineSendExecutor.isChatBusy = (_) => false;

    final r = await OfflineSendExecutor.execute(_row('q1'));
    expect(r.success, isTrue);
    expect(screen.sent, ['q1']);
    expect(headless, isEmpty);
  });

  test('a screen that cannot take it hands over to the headless turn',
      () async {
    final screen = _Screen('chat-1', null);
    OfflineSendExecutor.registerScreen(screen);
    OfflineSendExecutor.isChatBusy = (_) => false;

    final r = await OfflineSendExecutor.execute(_row('q1'));
    expect(r.success, isTrue);
    expect(screen.sent, ['q1']);
    expect(headless, ['q1']);
  });

  test('a screen on another chat is not asked', () async {
    final screen = _Screen('chat-2', const SendExecutorResult.success());
    OfflineSendExecutor.registerScreen(screen);
    OfflineSendExecutor.isChatBusy = (_) => false;

    await OfflineSendExecutor.execute(_row('q1'));
    expect(screen.sent, isEmpty);
    expect(headless, ['q1']);
    OfflineSendExecutor.unregisterScreen(screen);
    expect(OfflineSendExecutor.screenFor('chat-2'), isNull);
  });

  test('a turn in flight (no stream open) defers the row', () async {
    ChatRuntimeRegistry.instance.get('chat-1').isSending.value = true;
    expect(OfflineSendExecutor.isTurnRunning('chat-1'), isTrue);

    final r = await OfflineSendExecutor.execute(_row('q1'));
    expect(r.deferred, isTrue);
    expect(headless, isEmpty);
  });
}
