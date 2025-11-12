import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart';

/// Represents a queued API request.
class QueuedRequest<T> {
  final String id;
  final Future<T> Function() operation;
  final Completer<T> completer;
  final DateTime queuedAt;
  final int priority;

  QueuedRequest({
    required this.id,
    required this.operation,
    required this.priority,
  })  : completer = Completer<T>(),
        queuedAt = DateTime.now();

  Future<T> get future => completer.future;
}

/// Manages a queue of API requests with concurrency control and prioritization.
class ApiRequestQueue {
  ApiRequestQueue._();

  static final ApiRequestQueue _instance = ApiRequestQueue._();
  factory ApiRequestQueue() => _instance;

  /// Maximum concurrent requests
  int maxConcurrentRequests = 3;

  /// Active requests currently being processed
  int _activeRequests = 0;

  /// Queue of pending requests (priority queue)
  final Queue<QueuedRequest> _queue = Queue<QueuedRequest>();

  /// Track request statistics
  int _totalQueued = 0;
  int _totalCompleted = 0;
  int _totalFailed = 0;

  /// Enqueue a request with optional priority (higher = more important).
  Future<T> enqueue<T>({
    required String id,
    required Future<T> Function() operation,
    int priority = 0,
  }) async {
    final request = QueuedRequest<T>(
      id: id,
      operation: operation,
      priority: priority,
    );

    _totalQueued++;
    _queue.add(request);

    if (kDebugMode) {
      debugPrint('📥 Request queued: $id (priority: $priority)');
      debugPrint('   Queue size: ${_queue.length}, Active: $_activeRequests');
    }

    // Process queue
    _processQueue();

    return request.future;
  }

  /// Process queued requests respecting concurrency limit.
  void _processQueue() {
    while (_activeRequests < maxConcurrentRequests && _queue.isNotEmpty) {
      // Sort queue by priority (higher priority first)
      final sortedQueue = _queue.toList()
        ..sort((a, b) => b.priority.compareTo(a.priority));

      _queue.clear();
      _queue.addAll(sortedQueue);

      final request = _queue.removeFirst();
      _executeRequest(request);
    }
  }

  /// Execute a single request.
  Future<void> _executeRequest<T>(QueuedRequest<T> request) async {
    _activeRequests++;

    final waitTime = DateTime.now().difference(request.queuedAt);

    if (kDebugMode) {
      debugPrint('🚀 Executing request: ${request.id}');
      debugPrint('   Wait time: ${waitTime.inMilliseconds}ms');
      debugPrint('   Active requests: $_activeRequests/$maxConcurrentRequests');
    }

    try {
      final result = await request.operation();
      request.completer.complete(result);
      _totalCompleted++;

      if (kDebugMode) {
        final totalTime = DateTime.now().difference(request.queuedAt);
        debugPrint('✅ Request completed: ${request.id}');
        debugPrint('   Total time: ${totalTime.inMilliseconds}ms');
      }
    } catch (error, stackTrace) {
      request.completer.completeError(error, stackTrace);
      _totalFailed++;

      if (kDebugMode) {
        debugPrint('❌ Request failed: ${request.id}');
        debugPrint('   Error: $error');
      }
    } finally {
      _activeRequests--;

      // Process next queued request
      _processQueue();
    }
  }

  /// Get current queue size.
  int get queueSize => _queue.length;

  /// Get number of active requests.
  int get activeRequests => _activeRequests;

  /// Get queue statistics.
  Map<String, int> get statistics => {
        'queued': _totalQueued,
        'completed': _totalCompleted,
        'failed': _totalFailed,
        'pending': _queue.length,
        'active': _activeRequests,
      };

  /// Clear the queue (cancels all pending requests).
  void clear() {
    for (final request in _queue) {
      request.completer.completeError(
        StateError('Request cancelled: Queue cleared'),
      );
    }
    _queue.clear();

    if (kDebugMode) {
      debugPrint('🧹 Request queue cleared');
    }
  }

  /// Log queue status (debug mode only).
  void logStatus() {
    if (!kDebugMode) return;

    debugPrint('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    debugPrint('📊 REQUEST QUEUE STATUS');
    debugPrint('Pending: ${_queue.length}');
    debugPrint('Active: $_activeRequests/$maxConcurrentRequests');
    debugPrint('Total queued: $_totalQueued');
    debugPrint('Completed: $_totalCompleted');
    debugPrint('Failed: $_totalFailed');
    debugPrint('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  }
}

/// Convenience extension for adding queue support to functions.
extension QueueableFunction<T> on Future<T> Function() {
  /// Execute this function through the request queue.
  Future<T> queued({
    required String id,
    int priority = 0,
  }) {
    return ApiRequestQueue().enqueue(
      id: id,
      operation: this,
      priority: priority,
    );
  }
}
