// lib/services/multiplex_connection.dart
//
// Client side of the multiplexed `/v2/ws` protocol. A single WebSocket
// carries any number of concurrent chat streams + single-shot tool calls,
// all routed by per-request `req_id`. See `CLAUDE.md` in api_server for
// the wire format; the doc comment on [MultiplexConnection] mirrors it
// for quick reference.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:chuk_chat/models/chat_stream_event.dart';
import 'package:chuk_chat/services/tool_result_cache_registry.dart';
import 'package:chuk_chat/services/websocket_connector.dart' as ws_connector;

const _uuid = Uuid();

/// Error surfaced by [MultiplexConnection.tool] (and the chat stream's
/// error event) when the server reports failure or the local transport
/// dies.
class MultiplexException implements Exception {
  MultiplexException(this.detail, {this.code});
  final String detail;
  final String? code;

  @override
  String toString() => code == null ? detail : '[$code] $detail';
}

/// Generate a fresh request id. ≤ 32 hex chars — comfortably under the
/// 64-char protocol limit.
String _newReqId() => _uuid.v4().replaceAll('-', '');

/// Multiplexed WebSocket client.
///
/// One [MultiplexConnection] owns one WS. Open it lazily via
/// [ensureReady]; concurrent callers share the same handshake. After
/// auth_ok the connection accepts any number of in-flight chat / tool
/// requests, each tagged with a `req_id`. The connection terminates all
/// in-flight requests when the transport dies — callers must retry on
/// their own, ideally re-running [ensureReady] first.
class MultiplexConnection {
  MultiplexConnection({
    required this.accessTokenProvider,
    required this.baseUrl,
    Future<String?> Function()? freshTokenProvider,
    this.authRefreshFetchTimeout = const Duration(seconds: 10),
    this.authRefreshReplyTimeout = const Duration(seconds: 15),
    this.authRefreshRetryDelay = const Duration(seconds: 30),
  }) : freshTokenProvider = freshTokenProvider ?? accessTokenProvider;

  /// Called to fetch a fresh Supabase access token at handshake time. May
  /// return null when the user is signed out — in which case [ensureReady]
  /// rejects with a [MultiplexException].
  final Future<String?> Function() accessTokenProvider;

  /// Called when the socket needs a *newly minted* token mid-connection —
  /// i.e. after the server sent `auth_refresh_needed`, or when an earlier
  /// `auth_refresh` did not land. Unlike [accessTokenProvider] this should
  /// force a token refresh rather than return the cached (possibly expiring)
  /// one. Defaults to [accessTokenProvider].
  ///
  /// It must never sign the user out: returning null simply means "no token
  /// right now", and the connection retries later with the session intact.
  final Future<String?> Function() freshTokenProvider;

  /// How long to wait for [freshTokenProvider] to hand back a token.
  ///
  /// Deliberately separate from [authRefreshReplyTimeout]: this bounds a
  /// local token-mint round-trip (Supabase), that one bounds the chat
  /// server's reply to a handover already on the wire. They are different
  /// hops and must be tunable apart.
  ///
  /// Without this bound a `refreshSession()` that never completes would
  /// leave the fetch guard raised for the life of the socket, so every
  /// later attempt would return at the guard and no retry would ever be
  /// armed — the socket would sit on an expired token forever, which is
  /// the exact failure this class exists to prevent.
  final Duration authRefreshFetchTimeout;

  /// How long to wait for `auth_refreshed` / `auth_refresh_failed` before
  /// treating the server as silent and arming a retry.
  final Duration authRefreshReplyTimeout;

  /// Delay before a failed/silent/impossible token handover is retried.
  final Duration authRefreshRetryDelay;

  /// HTTP base URL (`https://api.chuk.chat` etc). Will be transparently
  /// rewritten to `wss://api.chuk.chat/v2/ws`.
  final String baseUrl;

  /// Tunable timeouts. The handshake must complete inside
  /// [_authTimeout] or [ensureReady] gives up; idle [_pingInterval]
  /// keepalives keep NATs / LBs happy while the connection sits between
  /// chats.
  static const Duration _authTimeout = Duration(seconds: 15);
  static const Duration _pingInterval = Duration(seconds: 25);

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _channelSubscription;
  Timer? _pingTimer;

  /// Wall-clock time of the last frame received from the server (including
  /// pongs). Used to gauge whether a backgrounded socket has gone stale:
  /// while the app is suspended the heartbeat timer is frozen, so a load
  /// balancer can silently drop the idle connection without the listener's
  /// onDone/onError ever firing. [ensureReady] would then hand back the
  /// already-resolved handshake and never notice. See [sinceLastInbound].
  DateTime? _lastInboundAt;

  /// Single shared handshake future. While non-null any [ensureReady]
  /// call returns it; reset to null when the handshake settles (success
  /// or failure).
  Future<void>? _ready;

  /// Per-`req_id` state. Chat streams push into [_chatControllers] until
  /// the server emits `done`; tool calls resolve [_toolCompleters].
  final Map<String, StreamController<ChatStreamEvent>> _chatControllers =
      <String, StreamController<ChatStreamEvent>>{};
  final Map<String, Completer<Map<String, dynamic>>> _toolCompleters =
      <String, Completer<Map<String, dynamic>>>{};

  bool _disposed = false;

  /// The access token the server is believed to hold for this socket. Set
  /// at handshake time and updated only once the server confirms a handover
  /// with `auth_refreshed` — a refused handover leaves the previous token in
  /// place, exactly as the server does.
  String? _activeAuthToken;

  /// Token written to the wire in an `auth_refresh` frame whose reply has
  /// not arrived yet. `auth_refresh` carries no `req_id`, so at most one
  /// handover is in flight at a time.
  String? _inFlightAuthToken;

  /// Newest token handed in while another handover was still awaiting its
  /// reply. Sent as soon as that reply settles, so two tokens are never on
  /// the wire at once and a reply can never be credited to the wrong one.
  String? _queuedAuthToken;

  /// The token the server held before the last confirmed handover.
  ///
  /// `onAuthStateChange` replays the session it had when the event was
  /// queued, so a late or duplicate event can offer a token the socket has
  /// already moved past. Re-sending it would walk the identity backwards,
  /// which is worse than doing nothing at all.
  String? _supersededAuthToken;

  Timer? _authRefreshReplyTimer;
  Timer? _authRefreshRetryTimer;
  /// The one [freshTokenProvider] call that is currently running, or null
  /// when none is.
  ///
  /// This is the single-flight cell, and it is deliberately NOT a boolean
  /// tied to a waiter. `Future.timeout` stops *waiting*; it does not stop
  /// the provider. A guard that fell with the waiter would therefore let
  /// the next attempt start a second provider call while the first was
  /// still running — and a Supabase refresh token is single-use and shared
  /// with the paired host, so two overlapping refreshes are exactly the
  /// shape that signs people out. The cell instead lives as long as the
  /// provider future itself, so a later attempt attaches to the run already
  /// in progress. For the same reason teardown does not clear it: a dead
  /// socket must not license a second refresh.
  Future<String?>? _authTokenFetch;

  /// Consecutive retries armed without a confirmed handover. Bounds the
  /// retry loop so a permanently refusing server cannot turn into a frame
  /// storm. Reset by a confirmed handover or by a token the app hands in.
  int _authRefreshRetries = 0;
  static const int _maxAuthRefreshRetries = 5;

  /// Number of `auth_refresh_failed` replies seen since the last confirmed
  /// handover. Diagnostics only — a refusal never signs anyone out.
  int _authRefreshFailures = 0;

  /// Whether the socket has an authenticated identity at all.
  ///
  /// The token itself stays private: handing out a raw bearer JWT invites
  /// it into a log line or a crash report. Callers that need to know *which*
  /// token is in force compare through [holdsAuthToken].
  bool get hasActiveAuthToken => _activeAuthToken != null;

  /// Whether the server currently authenticates this socket with exactly
  /// [token]. A null or empty argument is never a match.
  bool holdsAuthToken(String? token) =>
      token != null && token.isNotEmpty && _activeAuthToken == token;

  /// True while an `auth_refresh` frame is awaiting its reply.
  bool get hasPendingAuthRefresh => _inFlightAuthToken != null;

  /// True while a newer token waits for the in-flight handover to settle.
  bool get hasQueuedAuthRefresh => _queuedAuthToken != null;

  /// True while a later retry of the token handover is armed.
  bool get hasAuthRefreshRetryScheduled =>
      _authRefreshRetryTimer?.isActive ?? false;

  /// How many times the server refused a token handover since the last
  /// confirmed one.
  int get authRefreshFailures => _authRefreshFailures;

  /// Establish (or reuse) the connection and perform the auth handshake.
  /// Idempotent — concurrent callers share one in-flight handshake.
  Future<void> ensureReady() {
    if (_disposed) {
      return Future.error(MultiplexException('connection disposed'));
    }
    final existing = _ready;
    if (existing != null) return existing;

    final future = _openAndAuthenticate();
    _ready = future;
    // On failure clear the cached future so callers can retry.
    future.catchError((Object _) {
      if (identical(_ready, future)) _ready = null;
    });
    return future;
  }

  Future<void> _openAndAuthenticate() async {
    final token = await accessTokenProvider();
    if (token == null || token.isEmpty) {
      throw MultiplexException('no access token available', code: 'no_token');
    }

    final wsUrl = _resolveWsUrl();

    WebSocketChannel channel;
    try {
      channel = await ws_connector
          .connectWebSocket(wsUrl)
          .timeout(_authTimeout);
      await channel.ready.timeout(_authTimeout);
    } on TimeoutException {
      throw MultiplexException(
        'WebSocket connection timed out',
        code: 'ws_timeout',
      );
    } catch (e) {
      throw MultiplexException(
        'WebSocket connection failed: $e',
        code: 'ws_connect_failed',
      );
    }

    final authCompleter = Completer<void>();
    Timer? authTimer;

    _channel = channel;
    _channelSubscription = channel.stream.listen(
      (dynamic raw) {
        _lastInboundAt = DateTime.now();
        if (!authCompleter.isCompleted) {
          // We're still inside the auth handshake — interpret the very
          // first frame as auth_ok / auth_error.
          if (raw is String) {
            try {
              final decoded = jsonDecode(raw);
              if (decoded is Map<String, dynamic>) {
                final type = decoded['type'];
                if (type == 'auth_ok') {
                  authTimer?.cancel();
                  authCompleter.complete();
                  return;
                }
                if (type == 'auth_error') {
                  authTimer?.cancel();
                  final detail =
                      decoded['detail']?.toString() ?? 'auth_error';
                  authCompleter.completeError(
                    MultiplexException(detail, code: 'auth_error'),
                  );
                  return;
                }
              }
            } catch (_) {
              // Fall through to generic protocol error below.
            }
          }
          authTimer?.cancel();
          authCompleter.completeError(
            MultiplexException(
              'unexpected handshake frame',
              code: 'auth_protocol',
            ),
          );
          return;
        }

        _onFrame(raw);
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!authCompleter.isCompleted) {
          authTimer?.cancel();
          authCompleter.completeError(
            MultiplexException('socket error during auth: $error',
                code: 'ws_error'),
          );
        }
        _handleTransportFailure('socket error: $error');
      },
      onDone: () {
        if (!authCompleter.isCompleted) {
          authTimer?.cancel();
          authCompleter.completeError(
            MultiplexException('socket closed during auth',
                code: 'ws_closed'),
          );
        }
        _handleTransportFailure('socket closed');
      },
      cancelOnError: true,
    );

    // Push the auth frame.
    channel.sink.add(jsonEncode({'type': 'auth', 'token': token}));

    authTimer = Timer(_authTimeout, () {
      if (!authCompleter.isCompleted) {
        authCompleter.completeError(
          MultiplexException(
            'auth_ok not received within ${_authTimeout.inSeconds}s',
            code: 'auth_timeout',
          ),
        );
      }
    });

    try {
      await authCompleter.future;
    } catch (e) {
      // Tear down the half-open transport so the next ensureReady() can
      // try again with a fresh socket.
      await _teardown();
      rethrow;
    }

    // The handshake identity the server now holds. A later `auth_refresh`
    // only replaces it once the server confirms with `auth_refreshed`.
    _activeAuthToken = token;
    _inFlightAuthToken = null;
    _queuedAuthToken = null;
    _supersededAuthToken = null;
    _authRefreshReplyTimer?.cancel();
    _authRefreshReplyTimer = null;
    _authRefreshRetryTimer?.cancel();
    _authRefreshRetryTimer = null;
    _authRefreshRetries = 0;
    _authRefreshFailures = 0;

    _startHeartbeat();

    if (kDebugMode) {
      debugPrint('🔌 [Multiplex] /v2/ws ready');
    }
  }

  // ---------------------------------------------------------------------
  // Mid-connection token handover (`auth_refresh`).
  //
  // The server authenticates a `/v2/ws` socket once, at the handshake, and
  // reuses that identity for every request on it. When the Supabase access
  // token behind that identity ages out the server starts failing per-user
  // reads (`PGRST303 JWT expired`) even though the socket is fine. These
  // frames hand it a fresh token without reconnecting:
  //
  //   -> {"type":"auth_refresh","token":"<fresh access token>"}
  //   <- {"type":"auth_refreshed","expires_at":<unix>}
  //   <- {"type":"auth_refresh_failed","detail":"<reason>"}
  //   <- {"type":"auth_refresh_needed","expires_at":<unix>}
  //
  // None of them carry a `req_id`. `auth_refresh_needed` is a hint, never a
  // refusal — the request that triggered it is still served.
  //
  // NOTHING in this section may sign the user out, clear the local session
  // or surface an auth error to the UI. Every failure mode — no token, dead
  // socket, silent server, explicit refusal — ends in "keep the session,
  // try again later".
  // ---------------------------------------------------------------------

  /// Hand a freshly obtained access token to the already-open socket.
  ///
  /// Returns true when the frame reached the wire (or when the server
  /// already holds this exact token). Never throws, and a false result is
  /// not an auth failure: the session stays, and a retry is armed where a
  /// retry can help.
  Future<bool> updateAuthToken(String? token) async {
    if (_disposed) return false;

    if (token == null || token.isEmpty) {
      // No token to hand over right now. Keep the session and try later.
      if (kDebugMode) {
        debugPrint('🔑 [Multiplex] no token for auth_refresh — retrying later');
      }
      _scheduleAuthRefreshRetry();
      return false;
    }

    // A token the app hands in is a fresh chance — give the retry loop a
    // new budget.
    _authRefreshRetries = 0;

    if (token == _activeAuthToken) {
      // The server already authenticates this socket with this token, so it
      // is worth neither sending nor queueing. This must NOT be narrowed to
      // "…and nothing is in flight": during a handover that would let a
      // late event for the token already in force fall through and displace
      // a newer token waiting in the queue.
      return true;
    }
    if (token == _supersededAuthToken) {
      // Older than what the socket already holds. Never walk backwards.
      if (kDebugMode) {
        debugPrint('🔑 [Multiplex] ignoring a superseded token');
      }
      return true;
    }
    if (token == _inFlightAuthToken) {
      // Same token already on the wire, reply outstanding.
      return true;
    }
    if (_inFlightAuthToken != null) {
      // A handover is already on the wire. Replies carry no `req_id`, so a
      // second frame now would let the first reply be credited to the wrong
      // token. Hold the newer one and send it when that reply settles.
      _queuedAuthToken = token;
      return true;
    }

    final ch = _channel;
    if (ch == null) {
      // No live socket. The next handshake reads the token from
      // [accessTokenProvider], so there is nothing to repair here.
      return false;
    }

    try {
      ch.sink.add(jsonEncode({'type': 'auth_refresh', 'token': token}));
    } catch (e) {
      if (kDebugMode) {
        debugPrint('🔑 [Multiplex] auth_refresh send failed: $e');
      }
      _scheduleAuthRefreshRetry();
      return false;
    }

    _inFlightAuthToken = token;
    _authRefreshReplyTimer?.cancel();
    _authRefreshReplyTimer = Timer(authRefreshReplyTimeout, () {
      _authRefreshReplyTimer = null;
      if (_inFlightAuthToken == null) return;
      // Server never answered. Keep the session and the previous token,
      // and try the handover again later.
      if (kDebugMode) {
        debugPrint('🔑 [Multiplex] auth_refresh got no reply — retrying later');
      }
      _inFlightAuthToken = null;
      if (!_flushQueuedAuthToken()) _scheduleAuthRefreshRetry();
    });
    return true;
  }

  /// Send the token that was parked while a handover was in flight.
  /// Returns true when one was sent, so callers know a retry is redundant.
  bool _flushQueuedAuthToken() {
    final queued = _queuedAuthToken;
    if (queued == null) return false;
    _queuedAuthToken = null;
    if (queued == _activeAuthToken || queued == _supersededAuthToken) {
      // It stopped being news while it waited. Report "nothing sent" so the
      // caller arms its retry instead of assuming the socket is current.
      return false;
    }
    unawaited(updateAuthToken(queued));
    return true;
  }

  void _onAuthRefreshed(Map<String, dynamic> data) {
    _authRefreshReplyTimer?.cancel();
    _authRefreshReplyTimer = null;
    _authRefreshRetryTimer?.cancel();
    _authRefreshRetryTimer = null;
    _authRefreshRetries = 0;
    _authRefreshFailures = 0;
    final accepted = _inFlightAuthToken;
    if (accepted != null && accepted != _activeAuthToken) {
      _supersededAuthToken = _activeAuthToken;
      _activeAuthToken = accepted;
    }
    _inFlightAuthToken = null;
    if (kDebugMode) {
      debugPrint(
        '🔑 [Multiplex] auth_refreshed (expires_at=${data['expires_at']})',
      );
    }
    _flushQueuedAuthToken();
  }

  void _onAuthRefreshFailed(Map<String, dynamic> data) {
    _authRefreshReplyTimer?.cancel();
    _authRefreshReplyTimer = null;
    // The server keeps the socket open and keeps the previous token, so we
    // mirror that: the pending handover is dropped, nothing else changes.
    _inFlightAuthToken = null;
    _authRefreshFailures++;
    if (kDebugMode) {
      debugPrint(
        '🔑 [Multiplex] auth_refresh_failed: ${data['detail']} — '
        'keeping session, retrying later',
      );
    }
    // A newer token parked behind this one is a better answer than waiting
    // out the retry delay.
    if (!_flushQueuedAuthToken()) _scheduleAuthRefreshRetry();
  }

  void _onAuthRefreshNeeded(Map<String, dynamic> data) {
    if (kDebugMode) {
      debugPrint(
        '🔑 [Multiplex] auth_refresh_needed '
        '(expires_at=${data['expires_at']}) — fetching a fresh token',
      );
    }
    unawaited(_refreshAuthNow());
  }

  /// Obtain a fresh token and hand it over now. Best-effort and silent:
  /// no path here can fail the user's session.
  Future<void> _refreshAuthNow() async {
    if (_disposed) return;
    if (_inFlightAuthToken != null) return;

    String? token;
    try {
      // The timeout bounds how long *this* attempt waits. The fetch it waits
      // on stays one shared run, so a timed-out attempt never licenses a
      // second Supabase refresh.
      token = await _sharedTokenFetch().timeout(authRefreshFetchTimeout);
    } on TimeoutException {
      if (kDebugMode) {
        debugPrint(
          '🔑 [Multiplex] fresh token lookup timed out after '
          '${authRefreshFetchTimeout.inSeconds}s — retrying later',
        );
      }
      token = null;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('🔑 [Multiplex] fresh token lookup failed: $e');
      }
      token = null;
    }
    if (_disposed) return;
    if (token == null || token.isEmpty || token == _activeAuthToken) {
      // Nothing newer to offer yet — keep the session, try again later.
      _scheduleAuthRefreshRetry();
      return;
    }
    await updateAuthToken(token);
  }

  /// Start a [freshTokenProvider] run, or hand back the one already in
  /// flight. Exactly one provider call is ever outstanding.
  ///
  /// Attaching is the whole point: an attempt that gave up waiting leaves
  /// the run going, and the next attempt joins it rather than asking
  /// Supabase to burn the single-use refresh token a second time. If every
  /// waiter has walked away by the time it settles, the result is simply
  /// discarded.
  Future<String?> _sharedTokenFetch() {
    final existing = _authTokenFetch;
    if (existing != null) return existing;

    // Future(...) rather than a bare call, so a provider that throws
    // synchronously still lands as a future error.
    final fetch = Future<String?>(() => freshTokenProvider());
    _authTokenFetch = fetch;
    // One terminal chain that both frees the cell and swallows the outcome.
    // The `then` has to absorb the error before `whenComplete`, or the
    // future `whenComplete` returns carries it on with nobody listening and
    // it surfaces as an unhandled async error — a provider that throws is
    // an ordinary, expected case here.
    unawaited(
      fetch.then<void>((_) {}, onError: (Object error, StackTrace stack) {}).
          whenComplete(() {
        if (identical(_authTokenFetch, fetch)) _authTokenFetch = null;
      }),
    );
    return fetch;
  }

  void _scheduleAuthRefreshRetry() {
    if (_disposed) return;
    if (_authRefreshRetryTimer?.isActive ?? false) return;
    if (_authRefreshRetries >= _maxAuthRefreshRetries) {
      // Stop the loop, but never the session. A later `auth_refresh_needed`
      // or a token handed in by the app re-arms it.
      return;
    }
    _authRefreshRetries++;
    _authRefreshRetryTimer = Timer(authRefreshRetryDelay, () {
      _authRefreshRetryTimer = null;
      unawaited(_refreshAuthNow());
    });
  }

  void _cancelAuthRefreshTimers() {
    _authRefreshReplyTimer?.cancel();
    _authRefreshReplyTimer = null;
    _authRefreshRetryTimer?.cancel();
    _authRefreshRetryTimer = null;
    _inFlightAuthToken = null;
    _queuedAuthToken = null;
    _supersededAuthToken = null;
  }

  /// Time since the last server frame arrived, or null if the socket has
  /// never received one. A large value after an app resume strongly implies
  /// the connection was silently dropped while backgrounded.
  Duration? get sinceLastInbound => _lastInboundAt == null
      ? null
      : DateTime.now().difference(_lastInboundAt!);

  /// True while any chat stream or tool call is still awaiting frames. Used
  /// to avoid reconnecting a socket that's actively in use (e.g. a stream
  /// kept alive by the foreground service across a screen lock).
  bool get hasInFlight =>
      _chatControllers.isNotEmpty || _toolCompleters.isNotEmpty;

  Uri _resolveWsUrl() {
    final uri = Uri.parse(baseUrl);
    final scheme = uri.scheme == 'https' ? 'wss' : 'ws';
    final basePath = uri.path == '/' ? '' : uri.path;
    return Uri(
      scheme: scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: '$basePath/v2/ws',
    );
  }

  void _startHeartbeat() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(_pingInterval, (_) {
      final ch = _channel;
      if (ch == null) return;
      try {
        ch.sink.add(jsonEncode({'type': 'ping'}));
      } catch (_) {
        // Sink may already be closed — the listener's onError / onDone
        // will handle the teardown.
      }
    });
  }

  /// Parse a server-sent frame and route it to the matching per-req_id
  /// controller / completer. Unknown / unparseable frames are dropped.
  void _onFrame(dynamic raw) {
    if (raw is! String) return;
    Map<String, dynamic> data;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      data = decoded;
    } catch (_) {
      return;
    }

    final type = data['type'];
    if (type == 'pong') return;

    // Connection-scoped frames. These carry no `req_id`, so they must be
    // handled before the per-request routing below drops them.
    switch (type) {
      case 'auth_refreshed':
        _onAuthRefreshed(data);
        return;
      case 'auth_refresh_failed':
        _onAuthRefreshFailed(data);
        return;
      case 'auth_refresh_needed':
        _onAuthRefreshNeeded(data);
        return;
    }

    final reqId = data['req_id'];
    if (reqId is! String || reqId.isEmpty) return;
    final kind = data['kind']?.toString();

    final chatCtrl = _chatControllers[reqId];
    if (chatCtrl != null) {
      _dispatchChat(reqId, chatCtrl, kind, data);
      return;
    }

    final toolCompleter = _toolCompleters[reqId];
    if (toolCompleter != null) {
      _dispatchTool(reqId, toolCompleter, kind, data);
      return;
    }
    // Unknown req_id — likely a frame that arrived after a local cancel.
  }

  void _dispatchChat(
    String reqId,
    StreamController<ChatStreamEvent> ctrl,
    String? kind,
    Map<String, dynamic> data,
  ) {
    switch (kind) {
      case 'content':
        final text = data['data'];
        if (text is String && text.isNotEmpty) {
          ctrl.add(ChatStreamEvent.content(text));
        }
        break;
      case 'reasoning':
        final text = data['data'];
        if (text is String && text.isNotEmpty) {
          ctrl.add(ChatStreamEvent.reasoning(text));
        }
        break;
      case 'usage':
        final usage = data['data'];
        if (usage is Map<String, dynamic>) {
          ctrl.add(ChatStreamEvent.usage(usage));
        }
        break;
      case 'meta':
        final meta = data['data'];
        if (meta is Map<String, dynamic>) {
          ctrl.add(ChatStreamEvent.meta(meta));
        }
        break;
      case 'tps':
        final tps = data['data'];
        if (tps is num) {
          ctrl.add(ChatStreamEvent.tps(tps.toDouble()));
        }
        break;
      case 'tool_calls':
        final raw = data['data'];
        if (raw is List) {
          final calls = raw
              .whereType<Map>()
              .map((m) => NativeToolCall.fromJson(m.cast<String, dynamic>()))
              .toList();
          if (calls.isNotEmpty) {
            ctrl.add(ChatStreamEvent.toolCalls(calls));
          }
        }
        break;
      case 'error':
        final detail = data['detail']?.toString() ?? 'unknown error';
        // Surface the server `code` for cache misses so the streaming handler
        // can recognise it (clear the cache registry + replay full) instead of
        // treating it as a generic, user-facing failure.
        final code = data['code']?.toString();
        final message = code == kCacheMissErrorCode
            ? '$kCacheMissErrorCode: $detail'
            : detail;
        ctrl.add(ChatStreamEvent.error(message, code: code));
        // Don't close yet — server still owes us `done`. If it never
        // arrives the transport-failure path will close us.
        break;
      case 'done':
        ctrl.add(const ChatStreamEvent.done());
        _chatControllers.remove(reqId);
        unawaited(ctrl.close());
        break;
      default:
        // Ignore unknown frame kinds.
        break;
    }
  }

  void _dispatchTool(
    String reqId,
    Completer<Map<String, dynamic>> completer,
    String? kind,
    Map<String, dynamic> data,
  ) {
    switch (kind) {
      case 'result':
        final result = data['data'];
        if (!completer.isCompleted) {
          if (result is Map<String, dynamic>) {
            completer.complete(result);
          } else if (result is Map) {
            completer.complete(Map<String, dynamic>.from(result));
          } else {
            // Defensive: server should always wrap in an object.
            completer.complete(<String, dynamic>{'value': result});
          }
        }
        break;
      case 'error':
        if (!completer.isCompleted) {
          final detail = data['detail']?.toString() ?? 'tool error';
          final code = data['code']?.toString();
          completer.completeError(
            MultiplexException(detail, code: code),
          );
        }
        break;
      case 'done':
        if (!completer.isCompleted) {
          // No result or error frame arrived — treat as empty result so
          // callers don't hang forever.
          completer.complete(const <String, dynamic>{});
        }
        _toolCompleters.remove(reqId);
        break;
      default:
        break;
    }
  }

  /// Open a chat stream. Returns a single-subscription [Stream] of
  /// [ChatStreamEvent]; the stream ends after [DoneEvent].
  Stream<ChatStreamEvent> chat({required Map<String, dynamic> payload}) {
    final reqId = _newReqId();
    final controller = StreamController<ChatStreamEvent>(
      onCancel: () {
        // Caller dropped the stream — release server-side resources and
        // forget the controller without yielding more events.
        if (_chatControllers.remove(reqId) != null) {
          _sendCancel(reqId);
        }
      },
    );
    _chatControllers[reqId] = controller;

    // Fire off the request. ensureReady is awaited inside so the caller
    // can subscribe synchronously.
    unawaited(_send({
      'req_id': reqId,
      'type': 'chat',
      'payload': payload,
    }, controller: controller));

    return controller.stream;
  }

  /// Open a single-shot tool call. Resolves with the `result.data` map
  /// or rejects with [MultiplexException].
  Future<Map<String, dynamic>> tool({
    required String tool,
    required Map<String, dynamic> payload,
  }) {
    final reqId = _newReqId();
    final completer = Completer<Map<String, dynamic>>();
    _toolCompleters[reqId] = completer;

    unawaited(_send({
      'req_id': reqId,
      'type': 'tool',
      'tool': tool,
      'payload': payload,
    }, toolCompleter: completer));

    return completer.future;
  }

  /// Cancel an in-flight request. Idempotent; safe to call after the
  /// stream has already finished.
  void cancel(String reqId) {
    final ctrl = _chatControllers.remove(reqId);
    if (ctrl != null) {
      ctrl.add(const ChatStreamEvent.done());
      unawaited(ctrl.close());
    }
    final completer = _toolCompleters.remove(reqId);
    if (completer != null && !completer.isCompleted) {
      completer.completeError(
        MultiplexException('cancelled', code: 'cancelled'),
      );
    }
    _sendCancel(reqId);
  }

  void _sendCancel(String reqId) {
    final ch = _channel;
    if (ch == null) return;
    try {
      ch.sink.add(jsonEncode({'req_id': reqId, 'type': 'cancel'}));
    } catch (_) {
      // Connection already dead; nothing to clean up.
    }
  }

  Future<void> _send(
    Map<String, dynamic> frame, {
    StreamController<ChatStreamEvent>? controller,
    Completer<Map<String, dynamic>>? toolCompleter,
  }) async {
    try {
      await ensureReady();
    } catch (e) {
      final reqId = frame['req_id'] as String;
      _chatControllers.remove(reqId);
      _toolCompleters.remove(reqId);
      if (controller != null) {
        controller.add(
          ChatStreamEvent.error(
            e is MultiplexException ? e.detail : e.toString(),
            // Handshake failure before the request went out — nothing was
            // consumed upstream, so re-issuing the pass is exactly right.
            code: (e is MultiplexException ? e.code : null) ??
                StreamErrorCodes.connectionLost,
          ),
        );
        controller.add(const ChatStreamEvent.done());
        await controller.close();
      }
      if (toolCompleter != null && !toolCompleter.isCompleted) {
        toolCompleter.completeError(
          e is MultiplexException
              ? e
              : MultiplexException(e.toString(), code: 'send_failed'),
        );
      }
      return;
    }

    final ch = _channel;
    if (ch == null) {
      final reqId = frame['req_id'] as String;
      _chatControllers.remove(reqId);
      _toolCompleters.remove(reqId);
      const detail = 'connection unavailable';
      if (controller != null) {
        controller.add(
          const ChatStreamEvent.error(
            detail,
            code: StreamErrorCodes.connectionLost,
          ),
        );
        controller.add(const ChatStreamEvent.done());
        await controller.close();
      }
      if (toolCompleter != null && !toolCompleter.isCompleted) {
        toolCompleter.completeError(
          MultiplexException(detail, code: 'no_connection'),
        );
      }
      return;
    }

    try {
      ch.sink.add(jsonEncode(frame));
    } catch (e) {
      final reqId = frame['req_id'] as String;
      _chatControllers.remove(reqId);
      _toolCompleters.remove(reqId);
      if (controller != null) {
        controller.add(
          ChatStreamEvent.error(
            'send failed: $e',
            code: StreamErrorCodes.connectionLost,
          ),
        );
        controller.add(const ChatStreamEvent.done());
        await controller.close();
      }
      if (toolCompleter != null && !toolCompleter.isCompleted) {
        toolCompleter.completeError(
          MultiplexException('send failed: $e', code: 'send_failed'),
        );
      }
    }
  }

  void _handleTransportFailure(String reason) {
    if (_channel == null && _chatControllers.isEmpty &&
        _toolCompleters.isEmpty) {
      return;
    }
    final detail = 'connection lost: $reason';
    final controllers = _chatControllers.values.toList(growable: false);
    final completers = _toolCompleters.values.toList(growable: false);
    _chatControllers.clear();
    _toolCompleters.clear();

    for (final ctrl in controllers) {
      try {
        ctrl.add(
          ChatStreamEvent.error(
            detail,
            code: StreamErrorCodes.connectionLost,
          ),
        );
        ctrl.add(const ChatStreamEvent.done());
      } catch (_) {}
      unawaited(ctrl.close());
    }
    for (final completer in completers) {
      if (!completer.isCompleted) {
        completer.completeError(
          MultiplexException(detail, code: 'connection_lost'),
        );
      }
    }

    _pingTimer?.cancel();
    _pingTimer = null;
    _cancelAuthRefreshTimers();
    // The next handshake carries a token from [accessTokenProvider], so the
    // socket-scoped identity starts over. This is bookkeeping only — the
    // user's session is untouched.
    _activeAuthToken = null;
    _inFlightAuthToken = null;
    // Nothing is stranded by dropping the queue: the next handshake reads a
    // current token from [accessTokenProvider].
    _queuedAuthToken = null;
    _supersededAuthToken = null;
    _authRefreshRetries = 0;
    unawaited(_channelSubscription?.cancel());
    _channelSubscription = null;
    try {
      _channel?.sink.close();
    } catch (_) {}
    _channel = null;
    _ready = null;
  }

  Future<void> _teardown() async {
    _pingTimer?.cancel();
    _pingTimer = null;
    _cancelAuthRefreshTimers();
    await _channelSubscription?.cancel();
    _channelSubscription = null;
    try {
      await _channel?.sink.close();
    } catch (_) {}
    _channel = null;
  }

  /// Close the WS, abort all in-flight streams and reject pending tool
  /// calls. Subsequent calls to [ensureReady] / [chat] / [tool] will
  /// reject with `connection disposed`.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _handleTransportFailure('disposed');
    await _teardown();
    _ready = null;
  }
}
