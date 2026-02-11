import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:chuk_chat/utils/api_request_queue.dart';

void main() {
  late ApiRequestQueue queue;

  setUp(() {
    queue = ApiRequestQueue();
    queue.clear();
    queue.maxConcurrentRequests = 3;
  });

  group('QueuedRequest', () {
    test('has id and priority', () {
      final request = QueuedRequest<String>(
        id: 'req-1',
        operation: () async => 'result',
        priority: 5,
      );
      expect(request.id, equals('req-1'));
      expect(request.priority, equals(5));
      expect(request.queuedAt, isA<DateTime>());
    });
  });

  group('enqueue', () {
    test('executes immediately when under concurrency limit', () async {
      final result = await queue.enqueue<String>(
        id: 'test-1',
        operation: () async => 'success',
      );
      expect(result, equals('success'));
    });

    test('returns operation result', () async {
      final result = await queue.enqueue<int>(
        id: 'test-2',
        operation: () async => 42,
      );
      expect(result, equals(42));
    });

    test('propagates errors', () async {
      expect(
        () => queue.enqueue<String>(
          id: 'test-err',
          operation: () async => throw Exception('boom'),
        ),
        throwsA(isA<Exception>()),
      );
    });

    test('multiple concurrent requests execute', () async {
      final results = await Future.wait([
        queue.enqueue<int>(
          id: 'a',
          operation: () async {
            await Future.delayed(const Duration(milliseconds: 10));
            return 1;
          },
        ),
        queue.enqueue<int>(
          id: 'b',
          operation: () async {
            await Future.delayed(const Duration(milliseconds: 10));
            return 2;
          },
        ),
        queue.enqueue<int>(
          id: 'c',
          operation: () async {
            await Future.delayed(const Duration(milliseconds: 10));
            return 3;
          },
        ),
      ]);
      expect(results, containsAll([1, 2, 3]));
    });
  });

  group('concurrency control', () {
    test('respects maxConcurrentRequests', () async {
      queue.maxConcurrentRequests = 2;
      int concurrent = 0;
      int maxConcurrent = 0;

      Future<int> trackConcurrency(int id) async {
        concurrent++;
        if (concurrent > maxConcurrent) maxConcurrent = concurrent;
        await Future.delayed(const Duration(milliseconds: 50));
        concurrent--;
        return id;
      }

      final futures = <Future<int>>[];
      for (int i = 0; i < 5; i++) {
        futures.add(
          queue.enqueue<int>(
            id: 'req-$i',
            operation: () => trackConcurrency(i),
          ),
        );
      }

      await Future.wait(futures);
      expect(maxConcurrent, lessThanOrEqualTo(2));
    });
  });

  group('priority ordering', () {
    test('higher priority requests execute first when queued', () async {
      queue.maxConcurrentRequests = 1;
      final executionOrder = <String>[];
      final completer = Completer<void>();

      // Fill the single slot with a blocking request
      queue.enqueue<void>(
        id: 'blocker',
        operation: () async {
          await completer.future;
        },
      );

      // Queue up requests with different priorities
      final low = queue.enqueue<void>(
        id: 'low',
        operation: () async {
          executionOrder.add('low');
        },
        priority: 1,
      );

      final high = queue.enqueue<void>(
        id: 'high',
        operation: () async {
          executionOrder.add('high');
        },
        priority: 10,
      );

      // Release the blocker
      completer.complete();

      await Future.wait([low, high]);
      // High priority should execute before low
      expect(executionOrder.first, equals('high'));
    });
  });

  group('statistics', () {
    test('initial statistics are zero', () {
      final stats = queue.statistics;
      expect(stats['pending'], equals(0));
      expect(stats['active'], equals(0));
    });

    test('completed count increases', () async {
      await queue.enqueue<void>(
        id: 'stat-1',
        operation: () async {},
      );
      await queue.enqueue<void>(
        id: 'stat-2',
        operation: () async {},
      );

      final stats = queue.statistics;
      expect(stats['completed'], greaterThanOrEqualTo(2));
      expect(stats['queued'], greaterThanOrEqualTo(2));
    });

    test('failed count increases on error', () async {
      try {
        await queue.enqueue<void>(
          id: 'fail',
          operation: () async => throw Exception('fail'),
        );
      } catch (_) {}

      final stats = queue.statistics;
      expect(stats['failed'], greaterThanOrEqualTo(1));
    });
  });

  group('queueSize and activeRequests', () {
    test('queueSize starts at 0', () {
      expect(queue.queueSize, equals(0));
    });

    test('activeRequests starts at 0', () {
      expect(queue.activeRequests, equals(0));
    });
  });

  group('clear', () {
    test('cancels pending requests with StateError', () async {
      queue.maxConcurrentRequests = 1;
      final blocker = Completer<void>();

      // Block the single slot
      queue.enqueue<void>(
        id: 'blocker',
        operation: () => blocker.future,
      );

      // Queue a request that will be cancelled
      final pendingFuture = queue.enqueue<void>(
        id: 'pending',
        operation: () async {},
      );

      // Clear the queue
      queue.clear();
      blocker.complete();

      // The pending request should fail with StateError
      expect(pendingFuture, throwsA(isA<StateError>()));
    });

    test('queue is empty after clear', () {
      queue.clear();
      expect(queue.queueSize, equals(0));
    });
  });
}
