import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:chuk_chat/services/account_session.dart';

/// The app's own access-token refresh, replacing gotrue's auto refresh
/// (bead cowork-2n1; `autoRefreshToken: false` in `SupabaseService`).
///
/// gotrue's built-in refresh is blind to the paired host: it spends the
/// refresh token as soon as the token nears expiry — also right after the
/// laptop wakes, before the relay has reattached and learned that the host
/// rotated the pair while the app was away. GoTrue then rejects the dead
/// token, gotrue wipes the local session (login page), and GoTrue's reuse
/// detection may terminate the whole family, host included.
///
/// This scheduler keeps gotrue's cadence (a 30 s tick, refresh at <= 60 s
/// left) but obeys the pairing:
///
///  1. a network refresh only when the access token is about to lapse;
///  2. with the host away ([hostAttached] false), the relay is first given a
///     chance to reattach and adopt a rotated pair ([reconnectHost]);
///  3. if the host stays unreachable, the app still refreshes itself — it
///     must never sit without a token;
///  4. a successful refresh goes through gotrue, so `tokenRefreshed` fires
///     and the relay client re-provisions the host as before (cowork-c91);
///  5. a rejected refresh never costs the local session while the access
///     token is valid ([SupabaseAccountSession.refresh] restores it).
class SessionRefreshScheduler with WidgetsBindingObserver {
  SessionRefreshScheduler({
    AccountSessionSource source = const SupabaseAccountSession(),
    DateTime Function()? now,
    Duration tick = defaultTick,
    Duration headroom = SupabaseAccountSession.refreshHeadroom,
    Duration reconnectGrace = defaultReconnectGrace,
  }) : _source = source,
       _now = now ?? DateTime.now,
       _tick = tick,
       _headroom = headroom,
       _reconnectGrace = reconnectGrace;

  /// The app-wide scheduler, started by `SupabaseService.initialize`.
  static final SessionRefreshScheduler instance = SessionRefreshScheduler();

  static const Duration defaultTick = Duration(seconds: 30);
  static const Duration defaultReconnectGrace = Duration(seconds: 10);

  final AccountSessionSource _source;
  final DateTime Function() _now;
  final Duration _tick;
  final Duration _headroom;
  final Duration _reconnectGrace;

  /// Whether the paired host is attached right now. Set by the relay client:
  /// true while paired, false while a pairing exists but the socket is down,
  /// null when no relay is in use (then the app refreshes on its own).
  bool? hostAttached;

  /// A way to get the relay reattached (and a pair the host rotated adopted)
  /// before the app spends its own refresh token while the host is away.
  /// Optional; without it rule 3 applies at once.
  Future<void> Function()? reconnectHost;

  Timer? _timer;
  bool _busy = false;
  bool _observing = false;

  /// Number of network refreshes this scheduler triggered (for tests/logs).
  int refreshes = 0;

  bool get isRunning => _timer != null;

  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(_tick, (_) => refreshIfDue());
    if (!_observing) {
      WidgetsBinding.instance.addObserver(this);
      _observing = true;
    }
    // A first look right away: a persisted session may already be near expiry.
    unawaited(refreshIfDue());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    if (_observing) {
      WidgetsBinding.instance.removeObserver(this);
      _observing = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back from sleep: the timer slept too. Check now, not in 30 s.
    if (state == AppLifecycleState.resumed) unawaited(refreshIfDue());
  }

  int? _secondsLeft(AccountSession session) {
    final expiresAt = session.expiresAt;
    if (expiresAt == null) return null;
    return expiresAt - _now().millisecondsSinceEpoch ~/ 1000;
  }

  /// One tick. Returns true when a network refresh (or an adoption through
  /// the host) replaced the access token.
  Future<bool> refreshIfDue() async {
    if (_busy) return false;
    _busy = true;
    try {
      final current = _source.current();
      if (current == null) return false;
      final left = _secondsLeft(current);
      if (left != null && left > _headroom.inSeconds) return false;

      if (hostAttached == false) {
        // The host may have rotated the pair while we were away. Let the
        // relay ask it before we spend a token that may already be dead.
        final reconnect = reconnectHost;
        if (reconnect != null) {
          try {
            await reconnect().timeout(_reconnectGrace);
          } catch (_) {
            // Unreachable or slow: fall through to our own refresh (rule 3).
          }
          final after = _source.current();
          if (after != null && after.accessToken != current.accessToken) {
            return true; // adopted the host's pair; nothing to spend
          }
        }
      }

      refreshes++;
      final refreshed = await _source.refresh();
      return refreshed != null && refreshed.accessToken != current.accessToken;
    } finally {
      _busy = false;
    }
  }
}
