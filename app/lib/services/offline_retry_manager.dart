// COWORK STUB. Upstream: chuk_chat/lib/services/offline_retry_manager.dart @ d31526a229fdde27c82adf3661d5d3a149db8340.
// Reason: replaced by relay — there is no offline send queue in CoWork (the run
// lives on the host). `instance` is inert: it never retries and never emits.
// Keep the public API signature-compatible with upstream so the imported chat UI compiles unchanged. Do not "improve" this file.

import 'dart:async';

import 'package:cowork/models/queued_message.dart';

class SendExecutorResult {
  const SendExecutorResult.success() : success = true, error = null;
  const SendExecutorResult.failure(String this.error) : success = false;

  final bool success;
  final String? error;
}

typedef SendExecutor = Future<SendExecutorResult> Function(QueuedMessage msg);

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

  void init() {}

  void registerExecutor(SendExecutor executor) {}

  Future<void> retryNow() async {}

  Stream<OfflineRetryEvent> get events => _events.stream;

  Future<void> debugRetryAll() async {}

  void debugReset() {}
}
