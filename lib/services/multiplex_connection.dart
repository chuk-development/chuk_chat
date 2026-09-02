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
  });

  /// Called to fetch a fresh Supabase access token at handshake time. May
  /// return null when the user is signed out — in which case [ensureReady]
  /// rejects with a [MultiplexException].
  final Future<String?> Function() accessTokenProvider;

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

    _startHeartbeat();

    if (kDebugMode) {
      debugPrint('🔌 [Multiplex] /v2/ws ready');
    }
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
