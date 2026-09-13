import 'package:supabase_flutter/supabase_flutter.dart' show Session;

import 'package:chuk_chat/services/supabase_service.dart';

/// Immutable snapshot of the account's authenticated session.
///
/// This is the *authentication* the app hands to an executor: the pair of
/// Supabase tokens plus the user id. It is NEVER the login password. The
/// access token is short-lived and the whole session is revocable server-side,
/// so handing it over is safe in a way that handing over the password is not.
class AccountSession {
  const AccountSession({
    required this.accessToken,
    required this.refreshToken,
    required this.userId,
    this.expiresAt,
  });

  /// Short-lived JWT. Authorises API calls (`Authorization: Bearer <token>`).
  final String accessToken;

  /// Long-lived token used to mint a new access token when the old one expires.
  final String refreshToken;

  /// The Supabase user id that owns this session.
  final String userId;

  /// When [accessToken] expires, as epoch seconds. Null when unknown. The host
  /// uses it to refresh before a call fails (docs/WIRE_CONTRACT.md).
  final int? expiresAt;

  /// Maps a raw Supabase [Session] into the token snapshot the app hands out.
  factory AccountSession.fromSupabase(Session session) {
    return AccountSession(
      accessToken: session.accessToken,
      refreshToken: session.refreshToken ?? '',
      userId: session.user.id,
      expiresAt: session.expiresAt,
    );
  }
}

/// Reads the current [AccountSession] and refreshes it on demand.
///
/// An interface so callers (and tests) do not depend on Supabase directly.
abstract interface class AccountSessionSource {
  /// The current session, without a network round-trip. Null when signed out.
  AccountSession? current();

  /// Hands back a session the host can use. Refreshes only when the access
  /// token is about to lapse (see [SupabaseAccountSession.refreshHeadroom]);
  /// otherwise the current pair is returned as-is. Returns null only when no
  /// live session is left (refresh token revoked/invalidated).
  Future<AccountSession?> refresh();
}

/// [AccountSessionSource] backed by the live Supabase session.
///
/// Why the refresh is guarded (bead cowork-2n1): Supabase refresh tokens are
/// single-use, and gotrue-dart wipes the LOCAL session and emits `signedOut`
/// on any non-retryable refresh error — even while the access token is still
/// perfectly valid. So every avoidable `/token` call is a chance to log the
/// user out because some other holder (a host that rotated the pair while the
/// app was away, a stale host process) spent the refresh token first. This
/// source therefore:
///
///  * never refreshes for a host request while the access token still has
///    [refreshHeadroom] left — the current pair is the answer;
///  * refreshes only at real expiry, when gotrue would refresh anyway;
///  * if that refresh is rejected while the access token we held is still
///    valid, restores the pair locally (`setSession` with the access token
///    goes through `/user`, spends nothing, and undoes gotrue's wipe).
///
/// The three collaborators are injectable so a test drives the policy with no
/// Supabase; the const default reads the live client.
class SupabaseAccountSession implements AccountSessionSource {
  const SupabaseAccountSession({
    Session? Function()? currentSession,
    Future<Session?> Function()? refreshSession,
    Future<Session?> Function(String refreshToken, String accessToken)?
    restoreSession,
    DateTime Function()? now,
  }) : _currentSession = currentSession,
       _refreshSession = refreshSession,
       _restoreSession = restoreSession,
       _now = now;

  /// How much life the access token must still have for a host request to be
  /// answered with the current pair instead of a refresh. Above gotrue's own
  /// 30 s expiry margin and the host's 30 s skew (`SupabaseSession.is_expired`),
  /// so a host that legitimately reports `token_expired` always gets a fresh
  /// pair, and a host that is merely early gets the pair it already had.
  static const Duration refreshHeadroom = Duration(seconds: 60);

  final Session? Function()? _currentSession;
  final Future<Session?> Function()? _refreshSession;
  final Future<Session?> Function(String refreshToken, String accessToken)?
  _restoreSession;
  final DateTime Function()? _now;

  Session? _readCurrent() {
    final read = _currentSession;
    if (read != null) return read();
    return SupabaseService.auth.currentSession;
  }

  Future<Session?> _doRefresh() {
    final refresh = _refreshSession;
    if (refresh != null) return refresh();
    return SupabaseService.refreshSession();
  }

  Future<Session?> _doRestore(String refreshToken, String accessToken) async {
    final restore = _restoreSession;
    if (restore != null) return restore(refreshToken, accessToken);
    final response = await SupabaseService.auth.setSession(
      refreshToken,
      accessToken: accessToken,
    );
    return response.session;
  }

  DateTime _clock() => (_now ?? DateTime.now)();

  /// Seconds of life left on [session]'s access token; null when unknown.
  int? _secondsLeft(Session session) {
    final expiresAt = session.expiresAt;
    if (expiresAt == null) return null;
    return expiresAt - _clock().millisecondsSinceEpoch ~/ 1000;
  }

  /// True when the access token is (about to be) expired, i.e. a refresh is
  /// due. An unknown expiry counts as due: better one refresh than a stale
  /// token at the host.
  bool needsRefresh(Session session) {
    final left = _secondsLeft(session);
    if (left == null) return true;
    return left <= refreshHeadroom.inSeconds;
  }

  /// True when the access token is still usable right now (past gotrue's own
  /// 30 s expiry margin is fine — the API only checks `exp`).
  bool _stillValid(Session session) {
    final left = _secondsLeft(session);
    return left != null && left > 0;
  }

  @override
  AccountSession? current() {
    final session = _readCurrent();
    if (session == null || session.accessToken.isEmpty) return null;
    return AccountSession.fromSupabase(session);
  }

  @override
  Future<AccountSession?> refresh() async {
    final before = _readCurrent();
    if (before == null || before.accessToken.isEmpty) return null;

    // Fresh enough: the current pair is the answer. No network, nothing spent.
    if (!needsRefresh(before)) return AccountSession.fromSupabase(before);

    Session? refreshed;
    try {
      refreshed = await _doRefresh();
    } catch (_) {
      refreshed = null;
    }
    if (refreshed != null && refreshed.accessToken.isNotEmpty) {
      return AccountSession.fromSupabase(refreshed);
    }

    // The refresh was rejected. gotrue has wiped the local session by now if
    // the error was not a transient one. If the access token we held is still
    // valid, put the pair back: the user stays signed in, and the host gets
    // the token that still works. Only when even that fails is the session
    // really gone.
    if (_readCurrent() == null &&
        _stillValid(before) &&
        (before.refreshToken ?? '').isNotEmpty) {
      try {
        final restored = await _doRestore(
          before.refreshToken!,
          before.accessToken,
        );
        if (restored != null && restored.accessToken.isNotEmpty) {
          return AccountSession.fromSupabase(restored);
        }
      } catch (_) {
        // Fall through: the session is gone server-side too.
      }
    }
    final after = _readCurrent();
    if (after == null || after.accessToken.isEmpty) return null;
    return AccountSession.fromSupabase(after);
  }
}
