/// Where a notification tap goes.
///
/// A tap on an "answer ready" toast (local or push) names ONE thread: the
/// `session_key` the host wrote into the notification row. Nothing else
/// travels with it — no answer, no prompt. The shell owns navigation, so
/// the router only records the target and tells the shell; the shell selects
/// the agent that owns the thread and the thread view replays it from
/// the host (docs/PLAN_2026-09-04_AGENTS_CHUK_ALIGN.md, WS-7 "Reopen flow").
///
/// The target is kept until the shell takes it, so a tap that launches the
/// app cold (the shell is not built yet) is not lost.
library;

import 'package:flutter/foundation.dart';

@immutable
class NotificationTarget {
  const NotificationTarget({
    required this.sessionKey,
    this.runId,
    this.connectorId,
  });

  /// The `kind` of a host notice about a connector whose sign-in expired.
  static const String kindConnectorExpired = 'mcp_signin_expired';

  /// The `session_key` prefix of that notice; the connector id follows it.
  static const String connectorTargetPrefix = 'mcp-connector:';

  /// The thread to open — the executor's session key.
  final String sessionKey;

  /// The run the notification was about, when the sender knew it.
  final String? runId;

  /// Set when the notice is about a connector, not a thread: the tap opens
  /// that connector's sign-in again.
  final String? connectorId;

  /// Parses the payload both channels use: the local toast's JSON payload
  /// and the FCM `data` map carry `session_key` and `run_id`.
  static NotificationTarget? fromData(Map<Object?, Object?>? data) {
    if (data == null) return null;
    final Object? key = data['session_key'] ?? data['sessionKey'];
    if (key is! String || key.isEmpty) return null;
    final Object? run = data['run_id'] ?? data['runId'];
    String? connector;
    if (data['kind'] == kindConnectorExpired &&
        key.startsWith(connectorTargetPrefix)) {
      final String id = key.substring(connectorTargetPrefix.length);
      if (id.isNotEmpty) connector = id;
    }
    return NotificationTarget(
      sessionKey: key,
      runId: run is String && run.isNotEmpty ? run : null,
      connectorId: connector,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is NotificationTarget &&
      other.sessionKey == sessionKey &&
      other.runId == runId &&
      other.connectorId == connectorId;

  @override
  int get hashCode => Object.hash(sessionKey, runId, connectorId);

  @override
  String toString() => 'NotificationTarget($sessionKey, run=$runId)';
}

class NotificationRouter {
  NotificationRouter._();

  static final NotificationRouter instance = NotificationRouter._();

  /// The tap nobody has handled yet. The shell listens, reads, then calls
  /// [take] to clear it.
  final ValueNotifier<NotificationTarget?> pending =
      ValueNotifier<NotificationTarget?>(null);

  /// A tap arrived (from the local plugin, from FCM, or from the launch
  /// details of a cold start).
  void open(NotificationTarget target) {
    pending.value = target;
  }

  /// The shell took the target. Returns it, or null when there was none.
  NotificationTarget? take() {
    final NotificationTarget? target = pending.value;
    pending.value = null;
    return target;
  }

  /// Test seam.
  @visibleForTesting
  void reset() => pending.value = null;
}
