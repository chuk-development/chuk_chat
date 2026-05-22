// lib/services/multiplex_session.dart
//
// Process-wide holder for the active chat's [MultiplexConnection]. UI
// code calls [MultiplexSession.openForChat] when a chat becomes active
// and [MultiplexSession.closeForChat] when it goes away; everything
// else (chat send, tool clients) reads [MultiplexSession.current] to
// route requests through the multiplexed `/v2/ws` socket.

import 'dart:async';

import 'package:flutter/foundation.dart';

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
    final conn = _current;
    _current = null;
    if (conn != null) {
      await conn.dispose();
    }
  }

  static Future<String?> _tokenProvider() async {
    final session = SupabaseService.auth.currentSession;
    return session?.accessToken;
  }
}
