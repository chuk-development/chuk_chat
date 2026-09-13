// AGENTS STUB. Upstream: chuk_chat/lib/services/offline_queue_service.dart
// (conditional export of offline_queue_service_native.dart / _web.dart)
// @ d31526a229fdde27c82adf3661d5d3a149db8340.
// Reason: replaced by relay — the run belongs to the host, which keeps working
// with no client attached, so there is no offline send queue. Nothing in the
// imported closure reaches this file; it exists so a future re-sync has a
// landing place instead of pulling in the sqflite-backed original.
// Keep the public API signature-compatible with upstream so the imported chat UI compiles unchanged. Do not "improve" this file.

import 'package:chuk_chat/models/queued_message.dart';

class OfflineQueueService {
  OfflineQueueService._();

  static final OfflineQueueService instance = OfflineQueueService._();

  Future<String> enqueue({
    required String chatId,
    required Map<String, dynamic> sendPayload,
  }) async => '';

  Future<List<QueuedMessage>> pending() async => const <QueuedMessage>[];

  Future<void> remove(String id) async {}

  Future<void> clear() async {}
}
