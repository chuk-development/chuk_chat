import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show Session;

import 'package:cowork/services/account_session.dart';
import 'package:cowork/services/cowork/cowork_cloud_relay.dart';
import 'package:cowork/services/cowork/cowork_pairing_store.dart';
import 'package:cowork/services/cowork/cowork_relay_client.dart';
import 'package:cowork/services/secrets/secrets_service.dart';
import 'package:cowork/services/supabase_service.dart';
import 'package:cowork/supabase_config.dart';

/// Session recovery through the paired host (bead cowork-2n1).
///
/// The problem. Supabase refresh tokens are single-use, and the app and its
/// host share ONE pair: while no app is attached the host refreshes on its own
/// (bead cowork-c91), which rotates the pair and leaves the app's persisted
/// copy dead. When the app comes back after its access token expired,
/// gotrue-dart refreshes the persisted session at startup, GoTrue rejects the
/// dead refresh token, gotrue wipes the session and the user lands on the
/// login page — logged out by a host action, with a perfectly live pair
/// sitting at the host. Worse, GoTrue's reuse detection can terminate the
/// whole session family on that rejected call, killing the host's run too.
///
/// The fix. Before gotrue gets to see an expired persisted session, the pair
/// is set aside ([SessionStash.setAsideExpiredSession]); the host is then
/// asked first ([SessionRecovery]): the app attaches over the relay with no
/// code, provisions the stale pair, and the host answers with the pair it
/// rotated (`account_session_rotated`), which the app adopts. Only when the
/// host has nothing newer is the app's own refresh token spent, and only when
/// that fails too is the login page shown. The same procedure runs when gotrue
/// signs the app out at runtime for an expired session.

/// The token pair set aside for recovery: what gotrue would otherwise refresh
/// (and lose) on its own.
@immutable
class SessionStash {
  const SessionStash({
    required this.accessToken,
    required this.refreshToken,
    required this.userId,
    this.expiresAt,
  });

  final String accessToken;
  final String refreshToken;
  final String userId;

  /// Epoch seconds; null when unknown.
  final int? expiresAt;

  /// Where a stash survives a crash mid-recovery. Cleared once the app holds
  /// a live session again.
  static const String prefsKey = 'cowork.session_stash_v1';

  /// The stash main() set aside at startup, for [AuthGate] to pick up.
  static SessionStash? pending;

  /// gotrue's own persisted-session key for [SupabaseConfig.supabaseUrl]
  /// (`SharedPreferencesLocalStorage.persistSessionKey`).
  static String persistedSessionKey([String? supabaseUrl]) {
    final url = supabaseUrl ?? SupabaseConfig.supabaseUrl;
    return 'sb-${Uri.parse(url).host.split('.').first}-auth-token';
  }

  AccountSession toAccountSession() => AccountSession(
        accessToken: accessToken,
        refreshToken: refreshToken,
        userId: userId,
        expiresAt: expiresAt,
      );

  Map<String, dynamic> toJson() => {
        'access_token': accessToken,
        'refresh_token': refreshToken,
        'user_id': userId,
        if (expiresAt != null) 'expires_at': expiresAt,
      };

  static SessionStash? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final access = raw['access_token'];
    final refresh = raw['refresh_token'];
    final userId = raw['user_id'];
    if (access is! String || access.isEmpty) return null;
    if (refresh is! String || refresh.isEmpty) return null;
    final expires = raw['expires_at'];
    return SessionStash(
      accessToken: access,
      refreshToken: refresh,
      userId: userId is String ? userId : '',
      expiresAt: expires is num ? expires.toInt() : _jwtExp(access),
    );
  }

  /// Parses what gotrue persists (`Session.toJson()`): the tokens, the user
  /// and `expires_at`.
  static SessionStash? fromPersistedSession(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final user = decoded['user'];
      return fromJson({
        'access_token': decoded['access_token'],
        'refresh_token': decoded['refresh_token'],
        'user_id': user is Map ? user['id'] : null,
        'expires_at': decoded['expires_at'],
      });
    } catch (_) {
      return null;
    }
  }

  static int? _jwtExp(String token) {
    final parts = token.split('.');
    if (parts.length < 2) return null;
    try {
      final payload = utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
      final claims = jsonDecode(payload);
      final exp = claims is Map ? claims['exp'] : null;
      return exp is num ? exp.toInt() : null;
    } catch (_) {
      return null;
    }
  }

  /// Seconds of access-token life left at [now]; null when unknown.
  int? secondsLeft(DateTime now) {
    final exp = expiresAt;
    if (exp == null) return null;
    return exp - now.millisecondsSinceEpoch ~/ 1000;
  }

  /// Sets an expiring persisted session aside so gotrue does not refresh it
  /// at startup. Call BEFORE `Supabase.initialize`.
  ///
  /// Returns the stash when one was set aside (or one from a crashed earlier
  /// recovery is still waiting), null when gotrue may restore the session as
  /// usual: no session, or a session with life left. An expired session is
  /// set aside even with no paired host: gotrue runs with `autoRefreshToken:
  /// false` (see `SessionRefreshScheduler`) and would sign it out locally
  /// instead of refreshing it; [SessionRecovery] spends the refresh token
  /// itself then. Everything is injectable for tests.
  static Future<SessionStash?> setAsideExpiredSession({
    SharedPreferences? prefs,
    String? persistedKey,
    DateTime Function()? now,
    Duration headroom = SupabaseAccountSession.refreshHeadroom,
  }) async {
    try {
      final store = prefs ?? await SharedPreferences.getInstance();
      final key = persistedKey ?? persistedSessionKey();

      // A stash left behind by a recovery that never finished (crash, kill).
      final leftover = store.getString(prefsKey);
      if (leftover != null) {
        final stash = fromJson(jsonDecode(leftover));
        if (stash != null && store.getString(key) == null) {
          pending = stash;
          return stash;
        }
        await store.remove(prefsKey);
      }

      final raw = store.getString(key);
      if (raw == null) return null;
      final stash = fromPersistedSession(raw);
      if (stash == null) return null;

      final left = stash.secondsLeft((now ?? DateTime.now)());
      if (left != null && left > headroom.inSeconds) return null;

      await store.setString(prefsKey, jsonEncode(stash.toJson()));
      await store.remove(key);
      pending = stash;
      return stash;
    } catch (_) {
      // Any trouble here means: leave the session to gotrue, as before.
      return null;
    }
  }

  /// Forgets the crash-safe copy once a live session exists (or the pair is
  /// known dead).
  static Future<void> clearPersisted({SharedPreferences? prefs}) async {
    try {
      final store = prefs ?? await SharedPreferences.getInstance();
      await store.remove(prefsKey);
    } catch (_) {
      // Best effort; a stale stash is dropped at the next startup check.
    }
  }
}

/// The relay side of a recovery, behind a small seam so the procedure is
/// testable with no socket. [CoworkRelayRecoveryLink] is the real one.
abstract interface class RecoveryLink {
  /// Attaches to the stored host with no code. [sessionSource] answers the
  /// host's `reprovision_request`s, [adopter] takes its
  /// `account_session_rotated`.
  Future<void> attach({
    required AccountSessionSource sessionSource,
    required Future<AccountSession?> Function(String refreshToken) adopter,
  });

  /// Hands the host the (stale) pair: this is what makes the host flush a
  /// pair it rotated, or ask for a fresh one.
  Future<void> provision(AccountSession session);

  Future<void> dispose();
}

/// [RecoveryLink] over a real [CoworkRelayClient] built from the app's stored
/// device identity.
class CoworkRelayRecoveryLink implements RecoveryLink {
  CoworkRelayRecoveryLink({
    required CoworkPairingStore store,
    required CoworkStoredPairing pairing,
  })  : _store = store,
        _pairing = pairing;

  final CoworkPairingStore _store;
  final CoworkStoredPairing _pairing;
  CoworkRelayClient? _client;

  @override
  Future<void> attach({
    required AccountSessionSource sessionSource,
    required Future<AccountSession?> Function(String refreshToken) adopter,
  }) async {
    final identity = await _store.loadOrCreateIdentity();
    final client = CoworkRelayClient(
      deviceId: identity.deviceId,
      signingKeyPair: identity.keyPair,
      // The stored trust names the cloud relay, so the recovery link must dial
      // it the same way the shell does: authenticated as this account's
      // controller. A local `ws://` trust still opens the plain socket.
      connector: coworkCloudRelayConnector(
        deviceId: identity.deviceId,
        sessionSource: sessionSource,
      ),
      sessionSource: sessionSource,
      sessionAdopter: adopter,
      // docs/WIRE_CONTRACT.md, "Secrets": the set rides behind the token.
      secretsForwarder: SecretsService.instance.forwardToHost,
    );
    _client = client;
    await client.reconnect(hostUrl: _pairing.hostUrl, pairing: _pairing);
  }

  @override
  Future<void> provision(AccountSession session) async {
    final client = _client;
    if (client == null) throw StateError('attach() first');
    await client.provisionAccount(session);
  }

  @override
  Future<void> dispose() async {
    final client = _client;
    _client = null;
    if (client != null) await client.dispose();
  }
}

/// Runs one recovery: host first, own refresh token second, login page last.
class SessionRecovery {
  SessionRecovery({
    required this.stash,
    required RecoveryLink? link,
    Session? Function()? currentSession,
    Future<Session?> Function(String refreshToken)? refreshFromToken,
    Duration hostTimeout = const Duration(seconds: 15),
    Duration adoptionGrace = const Duration(seconds: 5),
    Duration pollInterval = const Duration(milliseconds: 100),
  })  : _link = link,
        _currentSession = currentSession,
        _refreshFromToken = refreshFromToken,
        _hostTimeout = hostTimeout,
        _adoptionGrace = adoptionGrace,
        _poll = pollInterval;

  final SessionStash stash;

  /// Null when no host is paired: then there is nobody to ask, and the app's
  /// own refresh token is the only candidate.
  final RecoveryLink? _link;
  final Session? Function()? _currentSession;
  final Future<Session?> Function(String refreshToken)? _refreshFromToken;
  final Duration _hostTimeout;
  final Duration _adoptionGrace;
  final Duration _poll;

  /// Set the moment the host reports a rotated pair: from then on the app's
  /// own refresh token is known dead and must never be sent to `/token`.
  bool _rotationSeen = false;

  /// Set once the app's own refresh token went to `/token` — single-use.
  bool _stashSpent = false;

  Session? _live() {
    final read = _currentSession;
    if (read != null) return read();
    if (!SupabaseService.isInitialized) return null;
    return SupabaseService.auth.currentSession;
  }

  Future<Session?> _exchange(String refreshToken) async {
    final exchange = _refreshFromToken;
    if (exchange != null) return exchange(refreshToken);
    final response = await SupabaseService.auth.setSession(refreshToken);
    return response.session;
  }

  /// Waits until gotrue holds a session, at most [limit].
  Future<Session?> _awaitLive(Duration limit) async {
    final deadline = DateTime.now().add(limit);
    while (true) {
      final live = _live();
      if (live != null && live.accessToken.isNotEmpty) return live;
      if (!DateTime.now().isBefore(deadline)) return null;
      await Future<void>.delayed(_poll);
    }
  }

  /// The host rotated the pair: take it. `/token` with the host's token is
  /// fine here — there is no session of our own left to lose.
  Future<AccountSession?> _adopt(String refreshToken) async {
    _rotationSeen = true;
    try {
      final session = await _exchange(refreshToken);
      if (session == null || session.accessToken.isEmpty) return null;
      return AccountSession.fromSupabase(session);
    } catch (_) {
      return null;
    }
  }

  /// Spends the app's own refresh token — once, and never after the host
  /// reported a rotation (that token is dead, and `/token` with a dead token
  /// can terminate the whole family, host included).
  Future<Session?> _spendStash() async {
    if (_stashSpent || _rotationSeen) return null;
    _stashSpent = true;
    try {
      return await _exchange(stash.refreshToken);
    } catch (_) {
      return null;
    }
  }

  /// What the host sees while we recover: the stale pair, until a live one
  /// exists. A `reprovision_request` (the host could not use the stale pair)
  /// is answered with the live session if any, else — when no rotation was
  /// reported, i.e. the host has nothing newer — by spending our own token.
  AccountSessionSource get _sessionSource => _RecoverySessionSource(this);

  Future<AccountSession?> _refreshForHost() async {
    final live = _live();
    if (live != null && live.accessToken.isNotEmpty) {
      return AccountSession.fromSupabase(live);
    }
    if (_rotationSeen) {
      // The adoption is in flight; give it a moment rather than answering
      // with the dead pair.
      final adopted = await _awaitLive(_adoptionGrace);
      return adopted == null ? null : AccountSession.fromSupabase(adopted);
    }
    final spent = await _spendStash();
    return spent == null ? null : AccountSession.fromSupabase(spent);
  }

  AccountSession? _currentForHost() {
    final live = _live();
    if (live != null && live.accessToken.isNotEmpty) {
      return AccountSession.fromSupabase(live);
    }
    return stash.toAccountSession();
  }

  /// Returns the recovered session, or null when nothing is left to recover
  /// (then the login page is the right answer). Always disposes the link.
  Future<AccountSession?> run() async {
    final link = _link;
    try {
      Session? live;
      var attached = false;
      if (link != null) {
        try {
          await link.attach(sessionSource: _sessionSource, adopter: _adopt);
          attached = true;
          await link.provision(stash.toAccountSession());
          live = await _awaitLive(_hostTimeout);
        } catch (_) {
          // Host unreachable, handshake failed, or the send failed: fall back.
        }
      }
      if (live == null && !attached) {
        // No host to ask: our own token is the only candidate.
        live = await _spendStash();
      } else if (live == null && !_rotationSeen) {
        // The host answered nothing usable and reported no rotation: the
        // pair we hold is the newest there is.
        live = await _spendStash();
      }
      if (live == null || live.accessToken.isEmpty) return null;
      return AccountSession.fromSupabase(live);
    } finally {
      try {
        await link?.dispose();
      } catch (_) {
        // The link is gone either way.
      }
    }
  }
}

class _RecoverySessionSource implements AccountSessionSource {
  const _RecoverySessionSource(this._recovery);

  final SessionRecovery _recovery;

  @override
  AccountSession? current() => _recovery._currentForHost();

  @override
  Future<AccountSession?> refresh() => _recovery._refreshForHost();
}
