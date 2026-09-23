// lib/services/offline_retry_manager.dart
// MERGE NOTE: both retries live here now. Upstream's is connectivity-driven:
// a registered SendExecutor replays the persisted offline queue with backoff.
// The Agents one is host-driven: a paired thread flushes its own outbox, an
// unpaired one asks the transport to go get the host, and the executor is never
// used because the run belongs to the host (a second producer would double the
// turn). With FEATURE_AGENTS off retryNow() is upstream's drain only. With it
// on, a mounted thread view's registrations run first, then the persisted
// queue (chuk_chat chats only) drains as upstream's does.
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/models/queued_message.dart';
import 'package:chuk_chat/services/network_status_service.dart';
import 'package:chuk_chat/services/offline_queue_service.dart';
import 'package:chuk_chat/services/storage/chat_origin.dart';
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

/// Agents: sends everything queued for the thread it was registered for, and
/// answers how many prompts went out.
typedef OutboxFlush = Future<int> Function();

/// Agents: gets the transport to try the host again, from scratch.
typedef HostReconnect = Future<void> Function();

/// Lifecycle event for retry attempts. Mostly useful for diagnostics + UI
/// notifications (snack bars, badges).
enum OfflineRetryEventType {
  started,
  success,
  failedNonRetryable,
  failedDeferred,
  noExecutor,
  // The Agents retry reports on the whole thread, not on one queue entry.
  succeeded,
  failed,
  exhausted,
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

  /// Agents: set while a thread view is paired, cleared when it is not. Null
  /// therefore means "no host on the other end right now", which is what turns
  /// Retry into a reconnect.
  OutboxFlush? _flush;
  HostReconnect? _reconnect;
  String? _sessionKey;

  /// Agents: one retry at a time. The button is easy to hit twice, and two
  /// flushes of the same queue would send the same prompt twice.
  bool _busy = false;

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

  /// Agents: called by the thread view on the `paired` transition, and with
  /// null when the socket goes away again.
  void registerFlush(String sessionKey, OutboxFlush? flush) {
    if (flush == null) {
      // Only the owner of the current registration may clear it, so a view
      // being disposed cannot silence the one that just replaced it.
      if (_sessionKey != null && _sessionKey != sessionKey) return;
      _flush = null;
      _sessionKey = null;
      return;
    }
    _flush = flush;
    _sessionKey = sessionKey;
  }

  /// Agents: called by the thread view for its whole life; it is what Retry
  /// falls back to when nothing is paired.
  void registerReconnect(HostReconnect? reconnect) {
    _reconnect = reconnect;
  }

  /// Manual trigger — UI "Retry" buttons call this.
  ///
  /// AGENTS: with FEATURE_AGENTS off this is upstream's queue drain and
  /// nothing else. With it on, a mounted Agents thread view also gets the
  /// press: flush its outbox while the host is paired, otherwise go and get
  /// the host. The persisted queue only holds chuk_chat chats
  /// (`OfflineSendCoordinator` routes by chat kind), so it is drained as well
  /// whenever it holds anything; an Agents view in front must not strand a
  /// chuk_chat message.
  Future<void> retryNow() async {
    if (!ChatOrigin.agentsEnabled) return _retryAll();
    final OutboxFlush? flush = _flush;
    final HostReconnect? reconnect = _reconnect;
    if (flush == null && reconnect == null) {
      if (_executor != null) return _retryAll();
      // No Agents thread and no executor: drain anyway if anything is queued,
      // so upstream's `noExecutor` report still happens.
      if (await _hasQueuedMessages()) return _retryAll();
      _emitThreadEvent(OfflineRetryEventType.started, chatId: '');
      _emitThreadEvent(
        OfflineRetryEventType.exhausted,
        chatId: '',
        error: 'No host connection to retry on.',
      );
      return;
    }

    await _retryAgentsThread(flush, reconnect);
    if (_executor != null && await _hasQueuedMessages()) await _retryAll();
  }

  Future<void> _retryAgentsThread(
    OutboxFlush? flush,
    HostReconnect? reconnect,
  ) async {
    if (_busy) return;
    _busy = true;
    final String chatId = _sessionKey ?? '';
    _emitThreadEvent(OfflineRetryEventType.started, chatId: chatId);
    try {
      if (flush != null) {
        final int sent = await flush();
        if (kDebugMode) {
          debugPrint('[agents-retry] flushed $sent queued prompt(s)');
        }
        _emitThreadEvent(OfflineRetryEventType.succeeded, chatId: chatId);
        return;
      }
      if (reconnect == null) {
        // Nothing is mounted that could reach a host. The prompt stays queued;
        // the next pairing sends it.
        _emitThreadEvent(
          OfflineRetryEventType.exhausted,
          chatId: chatId,
          error: 'No host connection to retry on.',
        );
        return;
      }
      await reconnect();
      _emitThreadEvent(OfflineRetryEventType.succeeded, chatId: chatId);
    } catch (error) {
      _emitThreadEvent(
        OfflineRetryEventType.failed,
        chatId: chatId,
        error: '$error',
      );
    } finally {
      _busy = false;
    }
  }

  /// Whether the persisted queue holds anything. A queue that cannot even be
  /// opened (no platform channels in a widget test, web) counts as empty.
  Future<bool> _hasQueuedMessages() async {
    try {
      return await OfflineQueueService.instance.count() > 0;
    } catch (_) {
      return false;
    }
  }

  void _emitThreadEvent(
    OfflineRetryEventType type, {
    required String chatId,
    String? error,
  }) {
    _emit(
      OfflineRetryEvent(
        type: type,
        // The Agents queue is per thread, not per message: a retry asks for
        // the whole thread's backlog, so there is no single entry to name.
        queueId: '',
        chatId: chatId.isEmpty ? null : chatId,
        error: error,
      ),
    );
  }

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
  Future<void> debugRetryAll() => retryNow();

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
    _flush = null;
    _reconnect = null;
    _sessionKey = null;
    _busy = false;
  }
}

class _RetryableError implements Exception {
  _RetryableError(this.message);
  final String message;
  @override
  String toString() => message;
}
