import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/offline_retry_manager.dart';
import 'package:chuk_chat/services/storage/chat_origin.dart';

/// The Retry button in the imported bubble calls
/// `OfflineRetryManager.instance.retryNow()`. That method used to be an empty
/// `async {}`: the button was there, it was pressed, and nothing happened.
void main() {
  // These tests model the Agents build: Agents threads take the Agents
  // store and queue (ChatOrigin). Tests run with FEATURE_AGENTS off.
  ChatOrigin.agentsEnabled = true;
  final OfflineRetryManager manager = OfflineRetryManager.instance;

  setUp(manager.debugReset);
  tearDown(manager.debugReset);

  test('with no pairing, retry asks for a reconnect', () async {
    int reconnects = 0;
    manager.registerReconnect(() async => reconnects++);

    await manager.retryNow();

    // "Retry" while the host is asleep means "go get the host".
    expect(reconnects, 1);
  });

  test(
    'with a pairing, retry flushes the queue and does not reconnect',
    () async {
      int reconnects = 0;
      int flushes = 0;
      manager.registerReconnect(() async => reconnects++);
      manager.registerFlush('thread-1', () async {
        flushes++;
        return 2;
      });

      await manager.retryNow();

      expect(flushes, 1);
      expect(reconnects, 0);
    },
  );

  test('losing the pairing puts retry back on reconnect', () async {
    int reconnects = 0;
    int flushes = 0;
    manager.registerReconnect(() async => reconnects++);
    manager.registerFlush('thread-1', () async {
      flushes++;
      return 0;
    });
    manager.registerFlush('thread-1', null);

    await manager.retryNow();

    expect(flushes, 0);
    expect(reconnects, 1);
  });

  test(
    'a view being disposed cannot silence the thread that replaced it',
    () async {
      int flushes = 0;
      manager.registerFlush('thread-2', () async {
        flushes++;
        return 1;
      });
      // The old view for thread-1 tears down after the new one registered.
      manager.registerFlush('thread-1', null);

      await manager.retryNow();

      expect(flushes, 1);
    },
  );

  test('the events stream reports what the retry did', () async {
    manager.registerFlush('thread-1', () async => 1);
    final List<OfflineRetryEvent> seen = <OfflineRetryEvent>[];
    final sub = manager.events.listen(seen.add);

    await manager.retryNow();
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();

    expect(seen.map((e) => e.type).toList(), <OfflineRetryEventType>[
      OfflineRetryEventType.started,
      OfflineRetryEventType.succeeded,
    ]);
    expect(seen.last.chatId, 'thread-1');
  });

  test('a flush that throws is reported, not swallowed', () async {
    manager.registerFlush(
      'thread-1',
      () async => throw StateError('no socket'),
    );
    final List<OfflineRetryEvent> seen = <OfflineRetryEvent>[];
    final sub = manager.events.listen(seen.add);

    await manager.retryNow();
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();

    expect(seen.last.type, OfflineRetryEventType.failed);
    expect(seen.last.error, contains('no socket'));
  });

  test('nothing registered at all is reported, not a crash', () async {
    final List<OfflineRetryEvent> seen = <OfflineRetryEvent>[];
    final sub = manager.events.listen(seen.add);

    await manager.retryNow();
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();

    expect(seen.last.type, OfflineRetryEventType.exhausted);
  });

  test('two presses in a row are one retry', () async {
    int flushes = 0;
    manager.registerFlush('thread-1', () async {
      flushes++;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return 1;
    });

    await Future.wait(<Future<void>>[manager.retryNow(), manager.retryNow()]);

    expect(flushes, 1);
  });

  test('Agents never produces the answer itself', () async {
    // Upstream runs a `SendExecutor` here and writes the reply. The host owns
    // the run, so registering one must stay a no-op.
    int executed = 0;
    manager.registerExecutor((msg) async {
      executed++;
      return const SendExecutorResult.success();
    });
    manager.registerReconnect(() async {});

    await manager.retryNow();

    expect(executed, 0);
  });
}
