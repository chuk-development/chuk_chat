/// The one entry point the app touches for "answer ready" notifications.
///
/// It applies WS-7's anti-duplicate rule on the app side:
///
///  * **attached + foreground** — the user is watching: nothing.
///  * **attached + background** — the app itself shows a local toast on the
///    live `done` ([onLiveDone]); the host sees a controller and does NOT
///    push.
///  * **not attached** — the host pushes (Supabase → FCM) and toasts on its
///    own desktop; the app only learns about it later, when a replay lands
///    with `while_away` ([onAnswerReplayed]): then the row is consumed and
///    any OS toast for the thread is cleared.
///
/// "Foreground" is `WidgetsBinding.lifecycleState == resumed`. A null state
/// (no lifecycle event yet, which happens on desktop) counts as foreground —
/// the window that just started is in front of the user.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:cowork/services/notifications/local_notifications.dart';
import 'package:cowork/services/notifications/push_service.dart';
import 'package:cowork/services/notifications/run_notifications.dart';

/// Resolves the label a toast carries for a thread — the coworker's name.
/// The shell knows the roster; the services do not.
typedef ThreadLabelResolver = String Function(String sessionKey);

class CoworkNotifications {
  CoworkNotifications._();

  static final CoworkNotifications instance = CoworkNotifications._();

  /// Set by the shell. Default: a neutral label.
  ThreadLabelResolver threadLabel = (String sessionKey) => 'Chuk Chat';

  /// Test seam: overrides the lifecycle the rule reads.
  @visibleForTesting
  AppLifecycleState? lifecycleOverride;

  bool _initialized = false;

  /// Initialises the local plugin and starts push registration. Both are
  /// best-effort and independent of each other. Safe to call twice.
  Future<void> initialize({
    LocalNotificationsBackend? localBackend,
    bool startPush = true,
  }) async {
    if (_initialized) return;
    _initialized = true;
    await LocalNotifications.instance.initialize(backend: localBackend);
    await LocalNotifications.instance.checkLaunchNotification();
    if (startPush) await PushService.instance.start();
  }

  bool get _inForeground {
    final AppLifecycleState? state =
        lifecycleOverride ?? WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  /// A live `done` reached the thread view for [sessionKey]. Toast only when
  /// the app is not in front of the user.
  Future<void> onLiveDone(String sessionKey, {String? runId}) async {
    if (_inForeground) return;
    await LocalNotifications.instance.showAnswerReady(
      sessionKey: sessionKey,
      threadLabel: threadLabel(sessionKey),
      runId: runId,
    );
  }

  /// A replayed run terminal with `while_away` landed for [sessionKey]: the
  /// answer is on screen now. Close the host's notification row and clear
  /// the OS toast.
  Future<void> onAnswerReplayed(String sessionKey, {String? runId}) async {
    await Future.wait(<Future<void>>[
      RunNotifications.instance.consumeForSession(sessionKey, runId: runId),
      LocalNotifications.instance.cancelForSession(sessionKey),
    ]);
  }

  /// The user tapped a notification for [sessionKey]; the shell opened the
  /// thread. Same bookkeeping as a replay.
  Future<void> onOpenedFromNotification(String sessionKey, {String? runId}) async {
    await Future.wait(<Future<void>>[
      if (runId != null) RunNotifications.instance.consumeRun(runId),
      RunNotifications.instance.consumeForSession(sessionKey),
      LocalNotifications.instance.cancelForSession(sessionKey),
    ]);
  }

  /// Test seam.
  @visibleForTesting
  void reset() {
    _initialized = false;
    lifecycleOverride = null;
    threadLabel = (String sessionKey) => 'Chuk Chat';
  }
}
