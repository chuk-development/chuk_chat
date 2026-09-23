import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show
        AuthApiException,
        AuthException,
        AuthRetryableFetchException,
        Session;

import 'package:chuk_chat/services/network_status_service.dart';

import 'package:chuk_chat/services/account_session.dart';
import 'package:chuk_chat/services/agents/agents_cloud_relay.dart';
import 'package:chuk_chat/services/agents/agents_pairing_store.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/secrets/secrets_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/supabase_config.dart';

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
  static const String prefsKey = 'agents.session_stash_v1';

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
      final payload = utf8.decode(
        base64Url.decode(base64Url.normalize(parts[1])),
      );
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

/// Why a recovery ended the way it did.
///
/// The distinction the login page hangs on: a refresh token GoTrue rejected is
/// dead and the user has to sign in again, but a request that never reached
/// GoTrue says nothing about the token. Treating the second as the first is
/// how a start with no signal signed the user out for good — the stash was
/// dropped along with the session, so the next start had nothing left to try
/// (bead cowork-h1fr).
enum RecoveryOutcome {
  /// A live session is held again.
  recovered,

  /// GoTrue answered and refused the pair. Nothing is left to recover.
  tokenRejected,

  /// Nothing reached GoTrue: no signal, DNS, a timeout, a 5xx. The pair is
  /// still worth keeping and the recovery is worth running again.
  unreachable,
}

/// What a recovery came back with.
@immutable
class RecoveryResult {
  const RecoveryResult(this.outcome, [this.session]);

  final RecoveryOutcome outcome;

  /// The recovered session; null unless [outcome] is
  /// [RecoveryOutcome.recovered].
  final AccountSession? session;

  bool get isRecovered => session != null;

  /// True while the pair may still be good: keep it, and try again.
  bool get keepStash => outcome == RecoveryOutcome.unreachable;
}

/// True when [error] means the request never got an answer from GoTrue.
///
/// gotrue-dart raises [AuthRetryableFetchException] for a transport failure
/// and for a 5xx; a timeout or a socket error can also arrive raw when the
/// failure happens below that layer (the socket case comes through
/// [NetworkStatusService.isNetworkError], which reads the message rather than
/// importing `dart:io` into a file the web build also compiles). Everything
/// else — an [AuthApiException] with a 4xx, above all — is GoTrue speaking,
/// and it is final.
bool isTransportFailure(Object? error) {
  if (error == null) return false;
  if (error is AuthRetryableFetchException) return true;
  if (error is TimeoutException) return true;
  if (error is http.ClientException) return true;
  if (error is AuthApiException) return false;
  if (error is AuthException) return false;
  return NetworkStatusService.isNetworkError(error);
}

/// The relay side of a recovery, behind a small seam so the procedure is
/// testable with no socket. [AgentsRelayRecoveryLink] is the real one.
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

/// [RecoveryLink] over a real [AgentsRelayClient] built from the app's stored
/// device identity.
class AgentsRelayRecoveryLink implements RecoveryLink {
  AgentsRelayRecoveryLink({
    required AgentsPairingStore store,
    required AgentsStoredPairing pairing,
  }) : _store = store,
       _pairing = pairing;

  final AgentsPairingStore _store;
  final AgentsStoredPairing _pairing;
  AgentsRelayClient? _client;

  @override
  Future<void> attach({
    required AccountSessionSource sessionSource,
    required Future<AccountSession?> Function(String refreshToken) adopter,
  }) async {
    final identity = await _store.loadOrCreateIdentity();
    final client = AgentsRelayClient(
      deviceId: identity.deviceId,
      signingKeyPair: identity.keyPair,
      // The stored trust names the cloud relay, so the recovery link must dial
      // it the same way the shell does: authenticated as this account's
      // controller. A local `ws://` trust still opens the plain socket.
      connector: agentsCloudRelayConnector(
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
  /// The recovery running right now, or null.
  ///
  /// The recovery link dials the SAME relay with the SAME device id the shell's
  /// transport uses. Two controller sockets for one device is how a recovered
  /// session gets lost: the second connection displaces the first, and the
  /// `account_session_rotated` frame the recovery is waiting for never lands.
  ///
  /// So the gate no longer holds the whole app behind the recovery (the roster
  /// and the transcript are on this device and paint at once) — it publishes
  /// the recovery here instead, and the shell waits for THIS before it opens
  /// its own socket. The user sees their conversation immediately; only the
  /// reconnect waits, which it was going to do anyway.
  static Future<void>? inFlight;

  SessionRecovery({
    required this.stash,
    required RecoveryLink? link,
    Session? Function()? currentSession,
    Future<Session?> Function(String refreshToken)? refreshFromToken,
    Duration hostTimeout = const Duration(seconds: 15),
    Duration adoptionGrace = const Duration(seconds: 5),
    Duration pollInterval = const Duration(milliseconds: 100),
  }) : _link = link,
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

  /// Set once the app's own refresh token actually reached `/token` — the
  /// token is single-use, so one answered call is all it gets. A call that
  /// never got an answer does NOT set it: nothing was spent, and the next
  /// attempt is free.
  bool _stashSpent = false;

  /// Set when a call to `/token` never reached GoTrue. Then nothing has been
  /// learned about the pair, and neither the session nor the stash may be
  /// thrown away.
  bool _transportFailed = false;

  /// Set when GoTrue answered and refused a token. That is the one answer
  /// that ends a recovery: the pair is dead and the login page is right.
  bool _tokenRefused = false;

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
      if (session == null || session.accessToken.isEmpty) {
        // GoTrue answered; the host's pair is no good either.
        _tokenRefused = true;
        return null;
      }
      return AccountSession.fromSupabase(session);
    } catch (error) {
      if (isTransportFailure(error)) {
        _transportFailed = true;
      } else {
        _tokenRefused = true;
      }
      return null;
    }
  }

  /// Spends the app's own refresh token — once, and never after the host
  /// reported a rotation (that token is dead, and `/token` with a dead token
  /// can terminate the whole family, host included).
  Future<Session?> _spendStash() async {
    if (_stashSpent || _rotationSeen) return null;
    try {
      final session = await _exchange(stash.refreshToken);
      _stashSpent = true;
      if (session == null || session.accessToken.isEmpty) _tokenRefused = true;
      return session;
    } catch (error) {
      if (isTransportFailure(error)) {
        // The call never got there: the token is untouched and the pair is
        // still the newest one anybody has. Say so, and leave it spendable.
        _transportFailed = true;
        return null;
      }
      // GoTrue answered and refused it. Spent either way.
      _stashSpent = true;
      _tokenRefused = true;
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

  /// Runs the recovery and says how it ended: a live session, a pair GoTrue
  /// refused, or a call that never arrived. Always disposes the link.
  ///
  /// Only [RecoveryOutcome.tokenRejected] means the login page. An
  /// [RecoveryOutcome.unreachable] keeps the pair and is worth repeating —
  /// signing the user out because the phone had no signal for a second is the
  /// bug this distinction exists for (bead cowork-h1fr).
  Future<RecoveryResult> run() async {
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
      if (live != null && live.accessToken.isNotEmpty) {
        return RecoveryResult(
          RecoveryOutcome.recovered,
          AccountSession.fromSupabase(live),
        );
      }
      if (_transportFailed && !_tokenRefused) {
        // Nothing ever reached GoTrue, so nothing is known about the pair and
        // nothing may be thrown away.
        return const RecoveryResult(RecoveryOutcome.unreachable);
      }
      return const RecoveryResult(RecoveryOutcome.tokenRejected);
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
