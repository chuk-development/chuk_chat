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

import 'package:chuk_chat/models/chat_stream_event.dart';
import 'package:chuk_chat/services/api_config_service.dart';
import 'package:chuk_chat/services/multiplex_connection.dart';
import 'package:chuk_chat/services/supabase_service.dart';

/// Default grace period before tearing down the WS after the last chat
/// closes. Lets the user navigate between chats without thrashing the
/// underlying socket.
const Duration _idleCloseDelay = Duration(seconds: 60);

class MultiplexSession {
  MultiplexSession._();

  static MultiplexConnection? _current;
  static String? _currentChatId;
  static Timer? _idleCloseTimer;

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
    _idleCloseTimer?.cancel();
    _idleCloseTimer = Timer(_idleCloseDelay, () {
      _idleCloseTimer = null;
      // The chat id may have been claimed by a new openForChat call in
      // the meantime — only tear down if nothing is using it.
      if (_currentChatId == null) {
        final conn = _current;
        _current = null;
        if (conn != null) {
          unawaited(conn.dispose());
        }
      }
    });
  }

  /// Tear down the connection immediately. Used on logout.
  static Future<void> shutdown() async {
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

  /// True when [chatId] currently has an in-flight chat stream
  /// tracked by [chatForChat]. Diagnostic helper for callers that
  /// want to serialize background work (e.g. title generation) after
  /// the main response finishes.
  static bool hasActiveChatStream(String chatId) {
    return _activeChatStreams.containsKey(chatId);
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
    final session = SupabaseService.auth.currentSession;
    return session?.accessToken;
  }
}

/// Per-chatId book-keeping for the single in-flight chat stream
/// enforced by [MultiplexSession.chatForChat].
class _ActiveChatStream {
  _ActiveChatStream({required this.controller});

  final StreamController<ChatStreamEvent> controller;
  late StreamSubscription<ChatStreamEvent> subscription;
}
