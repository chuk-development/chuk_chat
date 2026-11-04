// test/services/offline_retry_manager_test.dart
//
// Unit tests for OfflineRetryManager — verifies that the retry manager calls
// the registered executor in created_at order, removes the queue entry on
// success, marks non-retryable failures, and defers retryable failures.

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:chuk_chat/models/queued_message.dart';
import 'package:chuk_chat/services/offline_queue_service.dart';
import 'package:chuk_chat/services/offline_retry_manager.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    OfflineQueueService.debugDatabaseFactory = databaseFactoryFfi;
    OfflineQueueService.debugDatabasePath = inMemoryDatabasePath;
  });

  setUp(() async {
    await OfflineQueueService.instance.debugReset();
    await OfflineQueueService.instance.init();
    await OfflineQueueService.instance.debugClearAll();
    OfflineRetryManager.instance.debugReset();
  });

  group('OfflineRetryManager.retryNow', () {
    test('calls executor in created_at order on success', () async {
      final id1 = await OfflineQueueService.instance.enqueue(
        chatId: 'c',
        sendPayload: {'i': 1},
      );
      await Future<void>.delayed(const Duration(milliseconds: 2));
      final id2 = await OfflineQueueService.instance.enqueue(
        chatId: 'c',
        sendPayload: {'i': 2},
      );

      final called = <String>[];
      OfflineRetryManager.instance.registerExecutor((QueuedMessage msg) async {
        called.add(msg.id);
        return const SendExecutorResult.success();
      });

      await OfflineRetryManager.instance.retryNow();

      expect(called, [id1, id2]);
      expect(await OfflineQueueService.instance.count(), 0);
    });

    test('non-retryable error marks failed (stays in queue)', () async {
      final id = await OfflineQueueService.instance.enqueue(
        chatId: 'c',
        sendPayload: {'i': 1},
      );

      OfflineRetryManager.instance.registerExecutor((QueuedMessage msg) async {
        return const SendExecutorResult.failure('HTTP 401 unauthorized');
      });

      await OfflineRetryManager.instance.retryNow();

      final remaining = await OfflineQueueService.instance.getById(id);
      expect(remaining, isNotNull);
      expect(remaining!.lastError, contains('401'));
      expect(remaining.attemptCount, greaterThanOrEqualTo(1));
    });

    test('retryable error defers (stays queued with a backoff time)', () async {
      final id = await OfflineQueueService.instance.enqueue(
        chatId: 'c',
        sendPayload: {'i': 1},
      );

      OfflineRetryManager.instance.registerExecutor((QueuedMessage msg) async {
        return const SendExecutorResult.failure(
          'SocketException: Connection refused',
        );
      });

      await OfflineRetryManager.instance.retryNow();

      final remaining = await OfflineQueueService.instance.getById(id);
      expect(remaining, isNotNull);
      // One attempt per flush; the row waits for its backoff time, still
      // queued, with the error kept for the UI.
      expect(remaining!.state, OutboxState.queued);
      expect(remaining.attemptCount, 1);
      expect(remaining.nextAttemptAt, greaterThan(0));
    });

    test('emits events for success and failure', () async {
      await OfflineQueueService.instance.enqueue(
        chatId: 'c',
        sendPayload: {'i': 1},
      );
      await OfflineQueueService.instance.enqueue(
        chatId: 'c',
        sendPayload: {'i': 2},
      );

      OfflineRetryManager.instance.registerExecutor((QueuedMessage msg) async {
        if (msg.sendPayload['i'] == 1) {
          return const SendExecutorResult.success();
        }
        return const SendExecutorResult.failure('HTTP 400 bad request');
      });

      final events = <OfflineRetryEventType>[];
      final sub = OfflineRetryManager.instance.events.listen((e) {
        events.add(e.type);
      });

      await OfflineRetryManager.instance.retryNow();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await sub.cancel();

      expect(events.contains(OfflineRetryEventType.success), isTrue);
      expect(events.contains(OfflineRetryEventType.failedNonRetryable), isTrue);
    });

    test('no executor emits noExecutor event and keeps entries', () async {
      // Re-register with null by resetting (which clears executor).
      OfflineRetryManager.instance.debugReset();
      await OfflineQueueService.instance.enqueue(
        chatId: 'c',
        sendPayload: {'i': 1},
      );

      final events = <OfflineRetryEventType>[];
      final sub = OfflineRetryManager.instance.events.listen((e) {
        events.add(e.type);
      });

      await OfflineRetryManager.instance.retryNow();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await sub.cancel();

      expect(events, contains(OfflineRetryEventType.noExecutor));
      expect(await OfflineQueueService.instance.count(), 1);
    });
  });
}
