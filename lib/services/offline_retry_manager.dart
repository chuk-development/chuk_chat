// lib/services/offline_retry_manager.dart
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/models/queued_message.dart';
import 'package:chuk_chat/services/network_status_service.dart';
import 'package:chuk_chat/services/offline_queue_service.dart';
import 'package:chuk_chat/utils/exponential_backoff.dart';

/// Outcome of a send executor call.
class SendExecutorResult {
  const SendExecutorResult.success() : success = true, error = null;
  const SendExecutorResult.failure(String this.error) : success = false;

  final bool success;
  final String? error;
}

/// Performs the actual send for one queued message. Returns success or a
/// classified failure.
typedef SendExecutor = Future<SendExecutorResult> Function(QueuedMessage msg);

/// Lifecycle event for retry attempts. Mostly useful for diagnostics + UI
/// notifications (snack bars, badges).
enum OfflineRetryEventType {
  started,
  success,
  failedNonRetryable,
  failedDeferred,
  noExecutor,
}

class OfflineRetryEvent {
  const OfflineRetryEvent({
    required this.type,
    required this.queueId,
    this.chatId,
    this.error,
  });

  final OfflineRetryEventType type;
  final String queueId;
  final String? chatId;
  final String? error;
}

/// Watches connectivity and drains the offline queue when the device returns
/// online.  Sends are performed by a registered [SendExecutor] so this service
/// stays free of any UI / chat-specific coupling.
class OfflineRetryManager {
  OfflineRetryManager._();

  static final OfflineRetryManager instance = OfflineRetryManager._();

  static const BackoffConfig _backoff = BackoffConfig.chat;

  SendExecutor? _executor;
  bool _initialized = false;
  bool _retrying = false;
  bool _wasOnline = true;
  final StreamController<OfflineRetryEvent> _events =
      StreamController<OfflineRetryEvent>.broadcast();

  void Function()? _listener;

  /// Wire up the connectivity listener. Safe to call multiple times.
  void init() {
    if (_initialized) return;
    _initialized = true;
    _wasOnline = NetworkStatusService.isOnline;
    _listener = () {
      final online = NetworkStatusService.isOnline;
      final wasOffline = !_wasOnline;
      _wasOnline = online;
      if (online && wasOffline) {
        if (kDebugMode) {
          debugPrint('[OfflineRetry] Back online — draining queue');
        }
        unawaited(_retryAll());
      }
    };
    NetworkStatusService.isOnlineListenable.addListener(_listener!);
  }

  /// Register the function that knows how to actually send one queued payload.
  /// The UI registers this at chat init.
  void registerExecutor(SendExecutor executor) {
    _executor = executor;
  }

  /// Manual trigger — UI "Retry" buttons call this.
  Future<void> retryNow() => _retryAll();

  Stream<OfflineRetryEvent> get events => _events.stream;

  Future<void> _retryAll() async {
    if (_retrying) return;
    _retrying = true;
    try {
      final pending = await OfflineQueueService.instance.listAll();
      if (pending.isEmpty) return;
      if (kDebugMode) {
        debugPrint('[OfflineRetry] draining ${pending.length} pending');
      }
      for (final msg in pending) {
        await _retryOne(msg);
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[OfflineRetry] drain failed: $e');
      }
    } finally {
      _retrying = false;
    }
  }

  Future<void> _retryOne(QueuedMessage msg) async {
    final executor = _executor;
    if (executor == null) {
      _emit(
        OfflineRetryEvent(
          type: OfflineRetryEventType.noExecutor,
          queueId: msg.id,
          chatId: msg.chatId,
        ),
      );
      return;
    }
    _emit(
      OfflineRetryEvent(
        type: OfflineRetryEventType.started,
        queueId: msg.id,
        chatId: msg.chatId,
      ),
    );

    String? lastError;
    final result = await ExponentialBackoff.execute<bool>(
      operation: () async {
        final outcome = await executor(msg);
        if (outcome.success) return true;
        lastError = outcome.error ?? 'send failed';
        throw _RetryableError(lastError!);
      },
      config: _backoff,
      shouldRetry: (err) {
        if (err is _RetryableError) {
          return ExponentialBackoff.shouldRetryError(err.message);
        }
        return ExponentialBackoff.shouldRetryError(err);
      },
    );

    if (result.success) {
      await OfflineQueueService.instance.remove(msg.id);
      _emit(
        OfflineRetryEvent(
          type: OfflineRetryEventType.success,
          queueId: msg.id,
          chatId: msg.chatId,
        ),
      );
      return;
    }

    final errStr = lastError ?? result.error ?? 'unknown error';
    final retryable = ExponentialBackoff.shouldRetryError(errStr);
    if (retryable) {
      // Network/5xx/429 — keep in queue, will retry on next online edge or
      // manual retry.
      await OfflineQueueService.instance.incrementAttempts(msg.id);
      _emit(
        OfflineRetryEvent(
          type: OfflineRetryEventType.failedDeferred,
          queueId: msg.id,
          chatId: msg.chatId,
          error: errStr,
        ),
      );
    } else {
      await OfflineQueueService.instance.markFailed(msg.id, errStr);
      _emit(
        OfflineRetryEvent(
          type: OfflineRetryEventType.failedNonRetryable,
          queueId: msg.id,
          chatId: msg.chatId,
          error: errStr,
        ),
      );
    }
  }

  void _emit(OfflineRetryEvent event) {
    if (_events.isClosed) return;
    _events.add(event);
  }

  @visibleForTesting
  Future<void> debugRetryAll() => _retryAll();

  @visibleForTesting
  void debugReset() {
    if (_listener != null) {
      NetworkStatusService.isOnlineListenable.removeListener(_listener!);
      _listener = null;
    }
    _initialized = false;
    _executor = null;
    _retrying = false;
    _wasOnline = true;
  }
}

class _RetryableError implements Exception {
  _RetryableError(this.message);
  final String message;
  @override
  String toString() => message;
}
