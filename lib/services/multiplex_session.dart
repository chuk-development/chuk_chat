// lib/services/multiplex_session.dart
//
// Process-wide holder for the active chat's [MultiplexConnection]. UI
// code calls [MultiplexSession.openForChat] when a chat becomes active
// and [MultiplexSession.closeForChat] when it goes away; everything
// else (chat send, tool clients) reads [MultiplexSession.current] to
// route requests through the multiplexed `/v2/ws` socket.
//
// In addition, [chatForChat] enforces a single in-flight chat stream
// per chat id — starting a new stream for the same chat id cancels
// the previous one. This is what prevents two concurrent chat
// completions from racing into the same UI message buffer (the bug
// that showed up after the /v2/ws multiplex landed: title generation
// and the main tool-loop response both writing into the assistant
// placeholder character-by-character).

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthState;

import 'package:chuk_chat/models/chat_stream_event.dart';
import 'package:chuk_chat/platform_config.dart' show kFeatureAgents;
import 'package:chuk_chat/services/api_config_service.dart';
import 'package:chuk_chat/services/multiplex_connection.dart';
import 'package:chuk_chat/services/session_refresh_scheduler.dart';
import 'package:chuk_chat/services/supabase_service.dart';

/// Default grace period before tearing down the WS after the last chat
/// closes. Lets the user navigate between chats without thrashing the
/// underlying socket.
const Duration _idleCloseDelay = Duration(seconds: 60);

/// How long without an inbound frame before [MultiplexSession.prewarm]
/// treats a socket as stale and reconnects from scratch. Comfortably above
/// the connection's 25s heartbeat so a healthy, foregrounded socket (which
/// gets a pong every cycle) is never mistaken for dead, while a connection
/// silently dropped during an app suspend is replaced proactively on resume.
const Duration _staleReconnectThreshold = Duration(seconds: 40);

class MultiplexSession {
  MultiplexSession._();

  static MultiplexConnection? _current;
  static String? _currentChatId;
  static Timer? _idleCloseTimer;

  /// Subscription that forwards every newly obtained Supabase access token
  /// to the open socket. The server authenticates `/v2/ws` once, at the
  /// handshake, so without this the socket keeps using the token it was
  /// opened with until it ages out and per-user reads start failing with
  /// `PGRST303 JWT expired`.
  static StreamSubscription<AuthState>? _authSubscription;

  /// Raised *before* `listen()` is called, not after it returns.
  ///
  /// `Supabase.auth.onAuthStateChange` emits its initial event
  /// synchronously on subscribe, so the handler can run while `listen()` is
  /// still on the stack and `_authSubscription` is still null. Guarding on
  /// the subscription alone would let anything reached from that handler —
  /// or a second `prewarm` / `openForChat` in the same turn — arm a second
  /// subscription, which would then deliver every token twice.
  static bool _authBridgeArmed = false;

  /// Per-chatId tracker for the in-flight chat stream. Lets
  /// [chatForChat] cancel a previous stream before opening a new one so
  /// only one chat completion is ever writing into a given chat's UI
  /// buffer at a time.
  ///
  /// The subscription's cancel() flows down into
  /// [MultiplexConnection]'s controller `onCancel`, which sends the
  /// server-side `cancel` frame AND closes the local controller — so
  /// no further `content` / `reasoning` / `done` events can leak out
  /// of the cancelled stream.
  static final Map<String, _ActiveChatStream> _activeChatStreams =
      <String, _ActiveChatStream>{};

  /// The active multiplex connection, or null when no chat is open.
  /// Callers should treat null as "fall back to v1 HTTP / legacy WS".
  static MultiplexConnection? get current => _current;

  /// The chat id this session was last opened for. Useful for diagnostics.
  static String? get currentChatId => _currentChatId;

  /// Open (or reuse) the multiplex connection for `chatId`. Idempotent —
  /// calling twice with the same chat id is a no-op. Switching chat ids
  /// reuses the existing socket; the per-request `chat_id` lives in the
  /// chat payload, not in the transport.
  static Future<void> openForChat(String chatId) async {
    _ensureAuthBridge();
    _idleCloseTimer?.cancel();
    _idleCloseTimer = null;
    _currentChatId = chatId;

    final existing = _current;
    if (existing != null) {
      // Best-effort: ensure the socket is healthy. ensureReady is cheap
      // when already authenticated.
      try {
        await existing.ensureReady();
        return;
      } catch (e) {
        if (kDebugMode) {
          debugPrint(
            '⚠️ [MultiplexSession] existing connection failed re-auth, '
            'reopening: $e',
          );
        }
        await existing.dispose();
        _current = null;
      }
    }

    final connection = MultiplexConnection(
      baseUrl: ApiConfigService.apiBaseUrl,
      accessTokenProvider: _tokenProvider,
      freshTokenProvider: _freshTokenProvider,
    );

    try {
      await connection.ensureReady();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ [MultiplexSession] ensureReady failed: $e');
      }
      await connection.dispose();
      rethrow;
    }
    _current = connection;
  }

  /// Pre-open the multiplex socket before the first send so the TLS + auth
  /// handshake overlaps with the user composing their message (and with
  /// startup work) instead of blocking time-to-first-token. Without this,
  /// the first message in a fresh chat — and the first send after a cold
  /// start, a long idle, or an app resume — pays the full connect + auth
  /// roundtrip on the critical path, which on mobile reads as "the
  /// connection takes forever".
  ///
  /// Best-effort: failures are swallowed (the send path re-runs
  /// [MultiplexConnection.ensureReady] and surfaces real errors). Leaves
  /// [currentChatId] untouched — when no chat is bound the socket is
  /// scheduled to idle-close so a prewarm that's never used doesn't leak a
  /// permanently-open connection.
  static Future<void> prewarm() async {
    _ensureAuthBridge();
    final existing = _current;
    if (existing != null) {
      // A socket that hasn't heard from the server in a while was probably
      // dropped silently while the app was suspended. ensureReady() would
      // hand back the stale, already-resolved handshake, so reconnect from
      // scratch instead — but only when nothing is actively streaming on it
      // (don't kill a response the foreground service kept alive).
      final idleFor = existing.sinceLastInbound;
      final stale = idleFor != null && idleFor > _staleReconnectThreshold;
      if (stale && !existing.hasInFlight && !_hasActiveStreams) {
        if (kDebugMode) {
          debugPrint(
            '🔁 [MultiplexSession] socket stale (${idleFor.inSeconds}s idle), '
            'reconnecting',
          );
        }
        await existing.dispose();
        _current = null;
        // Fall through to a fresh connect below.
      } else {
        // Cheap when already authenticated.
        try {
          await existing.ensureReady();
        } catch (e) {
          if (kDebugMode) {
            debugPrint('⚠️ [MultiplexSession] prewarm re-auth failed: $e');
          }
        }
        return;
      }
    }

    final connection = MultiplexConnection(
      baseUrl: ApiConfigService.apiBaseUrl,
      accessTokenProvider: _tokenProvider,
      freshTokenProvider: _freshTokenProvider,
    );
    try {
      await connection.ensureReady();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ [MultiplexSession] prewarm failed: $e');
      }
      await connection.dispose();
      return;
    }

    // Another opener (openForChat) may have won the race while we awaited
    // the handshake — keep theirs, drop ours.
    if (_current != null) {
      await connection.dispose();
      return;
    }
    _current = connection;
    // Nothing has claimed the socket — let it idle-close like closeForChat
    // would, so an unused prewarm doesn't keep a socket open forever.
    if (_currentChatId == null) {
      _scheduleIdleClose();
    }
  }

  /// Return the live connection, opening one on demand if none exists.
  ///
  /// This is the guarantee behind "one socket carries everything": every
  /// send routes through here, so there is never a per-request throwaway
  /// connection. Returns null only when the socket genuinely can't be
  /// established (offline / auth failure) — the caller surfaces that as a
  /// stream error rather than silently degrading to a second transport.
  static Future<MultiplexConnection?> ensureCurrent() async {
    if (_current != null) return _current;
    await prewarm();
    return _current;
  }

  /// Schedule the connection to close after [_idleCloseDelay]. If
  /// another chat is opened in the meantime the timer is cancelled and
  /// the same socket is reused.
  static void closeForChat(String chatId) {
    if (_currentChatId != chatId) {
      // The active session already belongs to a different chat — leave
      // it alone.
      return;
    }
    _currentChatId = null;
    _scheduleIdleClose();
  }

  /// Arm the idle-close timer. Tears the socket down after [_idleCloseDelay]
  /// only if no chat has claimed it in the meantime.
  static void _scheduleIdleClose() {
    _idleCloseTimer?.cancel();
    _idleCloseTimer = Timer(_idleCloseDelay, () {
      _idleCloseTimer = null;
      // The chat id may have been claimed by a new openForChat call in
      // the meantime — only tear down if nothing is using it.
      if (_currentChatId == null && !_hasActiveStreams) {
        final conn = _current;
        _current = null;
        if (conn != null) {
          unawaited(conn.dispose());
        }
      }
    });
  }

  static bool get _hasActiveStreams => _activeChatStreams.isNotEmpty;

  /// Tear down the connection immediately. Used on logout.
  static Future<void> shutdown() async {
    unawaited(_authSubscription?.cancel());
    _authSubscription = null;
    _authBridgeArmed = false;
    _idleCloseTimer?.cancel();
    _idleCloseTimer = null;
    _currentChatId = null;
    final tracked = _activeChatStreams.values.toList(growable: false);
    _activeChatStreams.clear();
    for (final entry in tracked) {
      try {
        await entry.subscription.cancel();
      } catch (_) {
        // best-effort
      }
      if (!entry.controller.isClosed) {
        unawaited(entry.controller.close());
      }
    }
    final conn = _current;
    _current = null;
    if (conn != null) {
      await conn.dispose();
    }
  }

  /// Start a chat stream that is tracked by [chatId]. If another chat
  /// stream is already in flight for the same chat id it is cancelled
  /// first — this enforces the invariant "exactly one active chat
  /// stream per chatId at any time" that fixes the v2/ws interleave
  /// regression.
  ///
  /// When [chatId] is null (offline executor, anonymous side-paths)
  /// the call falls through to the legacy un-tracked
  /// [MultiplexConnection.chat] so existing behaviour is preserved.
  ///
  /// Returns a broadcast-friendly single-subscription stream wrapping
  /// the underlying [MultiplexConnection] stream. The returned stream
  /// ends with a [DoneEvent] (or an [ErrorEvent] + [DoneEvent]) so
  /// callers' `await for` loops always terminate cleanly.
  static Stream<ChatStreamEvent> chatForChat({
    required String? chatId,
    required Map<String, dynamic> payload,
  }) {
    final connection = _current;
    if (connection == null) {
      // Caller should have checked MultiplexSession.current first.
      // Surface as a stream-shaped error so callers don't crash.
      final controller = StreamController<ChatStreamEvent>();
      controller.add(
        const ChatStreamEvent.error('Multiplex session not open'),
      );
      controller.add(const ChatStreamEvent.done());
      unawaited(controller.close());
      return controller.stream;
    }

    if (chatId == null || chatId.isEmpty) {
      if (kDebugMode) {
        debugPrint(
          '[MultiplexSession] chatForChat called without chatId — '
          'falling through to un-tracked chat() (offline executor / '
          'title fallback path)',
        );
      }
      return connection.chat(payload: payload);
    }

    // Cancel any in-flight stream for this chatId before opening the
    // new one. The cancel propagates to MultiplexConnection (server-
    // side cancel frame + local controller close), so no stale content
    // events can leak into the new stream's caller.
    final existing = _activeChatStreams.remove(chatId);
    if (existing != null) {
      if (kDebugMode) {
        debugPrint(
          '[MultiplexSession] cancelling previous in-flight chat '
          'stream for chatId=$chatId before starting a new one',
        );
      }
      try {
        unawaited(existing.subscription.cancel());
      } catch (_) {
        // best-effort
      }
      if (!existing.controller.isClosed) {
        // Inject a synthetic done so the previous caller's await-for
        // loop terminates even if the underlying source had already
        // emitted everything but not yet closed.
        try {
          existing.controller.add(const ChatStreamEvent.done());
        } catch (_) {}
        unawaited(existing.controller.close());
      }
    }

    final outbound = StreamController<ChatStreamEvent>();
    late final StreamSubscription<ChatStreamEvent> subscription;
    final tracker = _ActiveChatStream(controller: outbound);

    subscription = connection.chat(payload: payload).listen(
      (event) {
        if (outbound.isClosed) return;
        outbound.add(event);
        if (event is DoneEvent) {
          // Stream finished cleanly — drop from tracker so the next
          // send for the same chat starts fresh without trying to
          // cancel an already-finished stream.
          if (identical(_activeChatStreams[chatId], tracker)) {
            _activeChatStreams.remove(chatId);
          }
          unawaited(outbound.close());
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (outbound.isClosed) return;
        outbound.add(ChatStreamEvent.error(error.toString()));
        outbound.add(const ChatStreamEvent.done());
        if (identical(_activeChatStreams[chatId], tracker)) {
          _activeChatStreams.remove(chatId);
        }
        unawaited(outbound.close());
      },
      onDone: () {
        if (outbound.isClosed) return;
        // Defensive — if the source closed without DoneEvent ensure
        // the wrapper closes too. Listener's DoneEvent path normally
        // handles this; this is the safety net.
        outbound.add(const ChatStreamEvent.done());
        if (identical(_activeChatStreams[chatId], tracker)) {
          _activeChatStreams.remove(chatId);
        }
        unawaited(outbound.close());
      },
      cancelOnError: false,
    );

    tracker.subscription = subscription;
    _activeChatStreams[chatId] = tracker;

    outbound.onCancel = () {
      // Caller dropped the stream — propagate cancel downstream so the
      // server stops generating and the multiplex controller is
      // released. Drop tracker entry only if it still points at us
      // (a newer send may have replaced it).
      if (identical(_activeChatStreams[chatId], tracker)) {
        _activeChatStreams.remove(chatId);
      }
      try {
        unawaited(subscription.cancel());
      } catch (_) {}
    };

    return outbound.stream;
  }


  /// Wait until no in-flight chat stream for [chatId] remains, or
  /// [timeout] elapses (returns false on timeout). Used by title
  /// generation to serialize itself AFTER the main response so the
  /// two never share the per-chatId slot and can never race into the
  /// same UI buffer.
  static Future<bool> waitForChatStreamIdle(
    String chatId, {
    Duration timeout = const Duration(minutes: 5),
    Duration pollInterval = const Duration(milliseconds: 200),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (_activeChatStreams.containsKey(chatId)) {
      if (DateTime.now().isAfter(deadline)) {
        return false;
      }
      await Future<void>.delayed(pollInterval);
    }
    return true;
  }

  static Future<String?> _tokenProvider() async {
    try {
      final session = SupabaseService.auth.currentSession;
      return session?.accessToken;
    } catch (_) {
      // Supabase not initialised (early startup / tests).
      return null;
    }
  }

  /// Token source for a mid-connection handover. Forces a Supabase refresh
  /// so the socket gets a genuinely newer token, not the expiring one that
  /// made the server ask in the first place.
  ///
  /// Returns null when no token can be obtained. That is not an auth
  /// failure — the caller keeps the session and retries later. This method
  /// never signs anyone out.
  ///
  /// With Agents the Supabase refresh token is single-use and SHARED with the
  /// paired host, so whether a new token is minted stays the
  /// [SessionRefreshScheduler]'s decision: this asks it, it does not force.
  /// The server's ask is a hint, and the request that carried it was served.
  /// The auth bridge below hands the socket whatever the scheduler mints.
  static Future<String?> _freshTokenProvider() async {
    try {
      if (kFeatureAgents) {
        await SessionRefreshScheduler.instance.refreshIfDue();
      } else {
        final session = await SupabaseService.refreshSession();
        if (session != null) return session.accessToken;
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ [MultiplexSession] fresh token refresh failed: $e');
      }
    }
    try {
      return SupabaseService.auth.currentSession?.accessToken;
    } catch (_) {
      return null;
    }
  }

  /// Subscribe once to Supabase auth events so every new access token is
  /// pushed onto the open socket. Idempotent and best-effort: if Supabase
  /// is not initialised yet the bridge simply is not armed, and the next
  /// handshake still picks up a current token.
  static void _ensureAuthBridge() {
    if (_authBridgeArmed) return;
    _authBridgeArmed = true;
    try {
      _authSubscription = SupabaseService.auth.onAuthStateChange.listen(
        (AuthState state) {
          final token = state.session?.accessToken;
          // No session here means a sign-out, which this bridge does not
          // handle and must never cause.
          if (token == null || token.isEmpty) return;
          pushAuthToken(token);
        },
        onError: (Object error) {
          if (kDebugMode) {
            debugPrint('⚠️ [MultiplexSession] auth bridge error: $error');
          }
        },
      );
    } catch (e) {
      // Supabase is not up yet. Lower the flag so a later call retries;
      // the next handshake reads a current token regardless.
      _authBridgeArmed = false;
      if (kDebugMode) {
        debugPrint('⚠️ [MultiplexSession] auth bridge not armed: $e');
      }
    }
  }

  /// Hand [token] to every open multiplex connection. There is exactly one
  /// (`_current`) by design — one socket carries everything.
  ///
  /// Fire-and-forget and failure-tolerant: a socket that refuses the token,
  /// or is not there at all, keeps the user signed in.
  static void pushAuthToken(String? token) {
    final connection = _current;
    if (connection == null) return;
    unawaited(connection.updateAuthToken(token));
  }
}

/// Per-chatId book-keeping for the single in-flight chat stream
/// enforced by [MultiplexSession.chatForChat].
class _ActiveChatStream {
  _ActiveChatStream({required this.controller});

  final StreamController<ChatStreamEvent> controller;
  late StreamSubscription<ChatStreamEvent> subscription;
}
