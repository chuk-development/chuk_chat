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
///     token is valid ([SupabaseAccountSession.refresh] restores it);
///  6. every minted token is announced to the registered [addTokenSink]s, so
///     a connection that authenticated once at its handshake — the `/v2/ws`
///     socket — is handed the new token instead of serving the rest of its
///     life with a dead one.
class SessionRefreshScheduler with WidgetsBindingObserver {
  SessionRefreshScheduler({
    AccountSessionSource source = const SupabaseAccountSession(),
    DateTime Function()? now,
    Duration tick = defaultTick,
    Duration headroom = SupabaseAccountSession.refreshHeadroom,
    Duration reconnectGrace = defaultReconnectGrace,
    Duration sinkGrace = defaultSinkGrace,
  }) : _source = source,
       _now = now ?? DateTime.now,
       _tick = tick,
       _headroom = headroom,
       _reconnectGrace = reconnectGrace,
       _sinkGrace = sinkGrace;

  /// The app-wide scheduler, started by `SupabaseService.initialize`.
  static final SessionRefreshScheduler instance = SessionRefreshScheduler();

  static const Duration defaultTick = Duration(seconds: 30);
  static const Duration defaultReconnectGrace = Duration(seconds: 10);

  /// How long one token sink may take before the announcement moves on. A
  /// sink writes one frame to a socket, so this is only a guard against a
  /// hung transport holding up the next tick.
  static const Duration defaultSinkGrace = Duration(seconds: 5);

  final AccountSessionSource _source;
  final DateTime Function() _now;
  final Duration _tick;
  final Duration _headroom;
  final Duration _reconnectGrace;
  final Duration _sinkGrace;

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

  /// Who has to learn about a freshly minted access token.
  ///
  /// A long-lived socket authenticates ONCE, at its handshake, and then keeps
  /// that identity: refreshing here reaches every new HTTP call but nothing
  /// that is already open. That is how an app left open all day ended up
  /// asking a live socket a billing question with a dead token and being told
  /// the credits were gone. So every mint is announced, and each holder of an
  /// open connection hands the new token to its peer.
  ///
  /// Announcing is best-effort in the strongest sense: a sink that throws,
  /// hangs or refuses changes nothing about the session. The user stays
  /// signed in either way.
  final List<Future<void> Function(String token)> _tokenSinks =
      <Future<void> Function(String token)>[];

  /// Registers [sink] for every future mint. Registering twice is a no-op.
  void addTokenSink(Future<void> Function(String token) sink) {
    if (_tokenSinks.contains(sink)) return;
    _tokenSinks.add(sink);
  }

  /// Takes [sink] off the list.
  void removeTokenSink(Future<void> Function(String token) sink) {
    _tokenSinks.remove(sink);
  }

  /// Number of registered sinks (tests/logs).
  int get tokenSinkCount => _tokenSinks.length;

  Future<void> _announce(String token) async {
    if (token.isEmpty || _tokenSinks.isEmpty) return;
    for (final sink in List.of(_tokenSinks)) {
      try {
        await sink(token).timeout(_sinkGrace);
      } catch (_) {
        // A transport that will not take the token keeps its old one. That
        // is a "try again later", never a reason to disturb the session.
      }
    }
  }

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
            // Adopted the host's pair; nothing to spend. The open sockets
            // still carry the old token, so they hear about this one too.
            await _announce(after.accessToken);
            return true;
          }
        }
      }

      refreshes++;
      final refreshed = await _source.refresh();
      if (refreshed == null || refreshed.accessToken == current.accessToken) {
        return false;
      }
      await _announce(refreshed.accessToken);
      return true;
    } finally {
      _busy = false;
    }
  }
}
