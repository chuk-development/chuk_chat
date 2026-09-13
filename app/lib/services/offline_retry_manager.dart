// AGENTS ADAPTER. Upstream: chuk_chat/lib/services/offline_retry_manager.dart @ d31526a229fdde27c82adf3661d5d3a149db8340.
// Reason: replaced by relay. Upstream drives a `SendExecutor` that re-runs the
// whole send against the hosted API and PRODUCES THE ANSWER. Agents must not:
// the run belongs to the host, which is still working while no client is
// attached, so a second producer would double the turn. `registerExecutor`
// therefore stays a no-op on purpose.
//
// What is real here is the other half. `retryNow()` used to be an empty
// `async {}`, so the Retry button in the imported bubble
// (`chat_ui_mobile.dart`, `chat_ui_desktop.dart`) did nothing at all. It now
// does the one thing Agents's Retry means:
//
//   * paired  -> flush the thread's outbox (the same work the `paired`
//                transition does), through the closure `AgentsThreadView`
//                registers;
//   * not paired -> ask the transport to reconnect. "Retry" while the host is
//                asleep means "go get the host", not "try the same dead
//                socket again".
//
// The question Agents asks is "is my host reachable", never "is there
// internet": there is no `NetworkStatusService` probe in here.
// Keep the public API signature-compatible with upstream so the imported chat UI compiles unchanged. Do not "improve" this file.

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/models/queued_message.dart';

class SendExecutorResult {
  const SendExecutorResult.success() : success = true, error = null;
  const SendExecutorResult.failure(String this.error) : success = false;

  final bool success;
  final String? error;
}

typedef SendExecutor = Future<SendExecutorResult> Function(QueuedMessage msg);

/// Sends everything queued for the thread it was registered for, and answers
/// how many prompts went out.
typedef OutboxFlush = Future<int> Function();

/// Gets the transport to try the host again, from scratch.
typedef HostReconnect = Future<void> Function();

enum OfflineRetryEventType { started, succeeded, failed, exhausted }

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

class OfflineRetryManager {
  OfflineRetryManager._();

  static final OfflineRetryManager instance = OfflineRetryManager._();

  final StreamController<OfflineRetryEvent> _events =
      StreamController<OfflineRetryEvent>.broadcast();

  /// Set while a thread view is paired; cleared when it is not. Null therefore
  /// means "no host on the other end right now", which is what turns Retry
  /// into a reconnect.
  OutboxFlush? _flush;
  HostReconnect? _reconnect;
  String? _sessionKey;

  /// One retry at a time. The button is easy to hit twice, and two flushes of
  /// the same queue would send the same prompt twice.
  bool _busy = false;

  void init() {}

  /// Upstream replays the send itself here. Agents does not: the host owns the
  /// run. Kept so the imported call sites compile.
  void registerExecutor(SendExecutor executor) {}

  /// Called by the thread view on the `paired` transition, and with null when
  /// the socket goes away again.
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

  /// Called by the thread view for its whole life: it is what Retry falls back
  /// to when nothing is paired.
  void registerReconnect(HostReconnect? reconnect) {
    _reconnect = reconnect;
  }

  /// What the Retry button does.
  Future<void> retryNow() async {
    if (_busy) return;
    _busy = true;
    final String chatId = _sessionKey ?? '';
    _emit(OfflineRetryEventType.started, chatId: chatId);
    try {
      final OutboxFlush? flush = _flush;
      if (flush != null) {
        final int sent = await flush();
        if (kDebugMode) {
          debugPrint('[agents-retry] flushed $sent queued prompt(s)');
        }
        _emit(OfflineRetryEventType.succeeded, chatId: chatId);
        return;
      }
      final HostReconnect? reconnect = _reconnect;
      if (reconnect == null) {
        // Nothing is mounted that could reach a host. The prompt stays queued;
        // the next pairing sends it.
        _emit(
          OfflineRetryEventType.exhausted,
          chatId: chatId,
          error: 'No host connection to retry on.',
        );
        return;
      }
      await reconnect();
      _emit(OfflineRetryEventType.succeeded, chatId: chatId);
    } catch (error) {
      _emit(OfflineRetryEventType.failed, chatId: chatId, error: '$error');
    } finally {
      _busy = false;
    }
  }

  Stream<OfflineRetryEvent> get events => _events.stream;

  Future<void> debugRetryAll() => retryNow();

  void debugReset() {
    _flush = null;
    _reconnect = null;
    _sessionKey = null;
    _busy = false;
  }

  void _emit(
    OfflineRetryEventType type, {
    required String chatId,
    String? error,
  }) {
    if (_events.isClosed) return;
    _events.add(
      OfflineRetryEvent(
        type: type,
        // The queue is per thread, not per message: a retry asks for the whole
        // thread's backlog, so there is no single entry to name.
        queueId: '',
        chatId: chatId.isEmpty ? null : chatId,
        error: error,
      ),
    );
  }
}
