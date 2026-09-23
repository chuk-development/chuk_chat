/// The app's side of `cowork_run_notifications` (docs/SUPABASE_SCHEMA.md).
///
/// The host inserts a row when a run ends with no app attached; the Edge
/// Function pushes it. The app's only write is `consumed_at`: once the
/// answer is on screen (a replay landed, or the user tapped the toast), the
/// row is closed so nothing re-pushes it and a later device sees it as read.
///
/// Best-effort throughout. Supabase not initialised (tests), no session, no
/// network — every failure is swallowed; the worst case is an open row.
library;

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/services/supabase_service.dart';

/// Test seam: how a consume is written. The default talks to Supabase.
typedef RunNotificationsWriter =
    Future<void> Function({
      required String userId,
      String? sessionKey,
      String? runId,
      required String consumedAt,
    });

class RunNotifications {
  RunNotifications._();

  static final RunNotifications instance = RunNotifications._();

  static const String table = 'cowork_run_notifications';

  RunNotificationsWriter? _writer;
  String? Function()? _userId;

  /// Every answer this app already closed since launch — `session/run_id`
  /// when the run is known, the bare session key when it is not — so a replay
  /// that lands twice does not PATCH twice, while a SECOND run's row for the
  /// same coworker is still closed (review F7).
  final Set<String> _consumedSessions = <String>{};

  /// Injects the writer and the user-id lookup (tests). Null restores the
  /// Supabase defaults.
  @visibleForTesting
  void configure({RunNotificationsWriter? writer, String? Function()? userId}) {
    _writer = writer;
    _userId = userId;
    _consumedSessions.clear();
  }

  /// Marks every open row for [sessionKey] consumed. Idempotent per launch
  /// per answer: [runId] (the replayed run's id, when the host stamped it)
  /// tells a new answer from a re-replay of one already closed.
  Future<void> consumeForSession(String sessionKey, {String? runId}) async {
    final String key = runId == null ? sessionKey : '$sessionKey/$runId';
    if (!_consumedSessions.add(key)) return;
    await _consume(sessionKey: sessionKey);
  }

  /// Marks the row for one run consumed (a tap that named the run).
  Future<void> consumeRun(String runId) => _consume(runId: runId);

  Future<void> _consume({String? sessionKey, String? runId}) async {
    final String? userId = (_userId ?? _defaultUserId)();
    if (userId == null) return;
    try {
      await (_writer ?? _defaultWriter)(
        userId: userId,
        sessionKey: sessionKey,
        runId: runId,
        consumedAt: DateTime.now().toUtc().toIso8601String(),
      );
    } catch (error) {
      if (kDebugMode) debugPrint('[RunNotifications] consume failed: $error');
    }
  }

  static String? _defaultUserId() {
    if (!SupabaseService.isInitialized) return null;
    return SupabaseService.auth.currentUser?.id;
  }

  static Future<void> _defaultWriter({
    required String userId,
    String? sessionKey,
    String? runId,
    required String consumedAt,
  }) async {
    var query = SupabaseService.client
        .from(table)
        .update(<String, dynamic>{'consumed_at': consumedAt})
        .eq('user_id', userId)
        .isFilter('consumed_at', null);
    if (sessionKey != null) query = query.eq('session_key', sessionKey);
    if (runId != null) query = query.eq('run_id', runId);
    await query;
  }
}
