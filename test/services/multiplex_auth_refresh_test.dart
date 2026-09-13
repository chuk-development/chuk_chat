// test/services/multiplex_auth_refresh_test.dart
//
// The `/v2/ws` socket is authenticated once, at the handshake, and the
// server reuses that identity for every request on it. When the Supabase
// access token behind that identity ages out, per-user reads start failing
// with `PGRST303 JWT expired` while the socket itself is perfectly healthy
// — which is how a user with credit in the account was told he had none.
//
// The fix is the mid-connection token handover:
//
//   -> {"type":"auth_refresh","token":"<fresh access token>"}
//   <- {"type":"auth_refreshed","expires_at":<unix>}
//   <- {"type":"auth_refresh_failed","detail":"<reason>"}
//   <- {"type":"auth_refresh_needed","expires_at":<unix>}
//
// The hard rule these tests exist to pin down: NO failure mode may sign the
// user out. No token, a dead socket, a silent server, an explicit refusal —
// every one of them must end in "keep the session, try again later", with
// the socket still usable afterwards.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/multiplex_connection.dart';

/// Minimal stand-in for the `/v2/ws` endpoint.
///
/// Answers the handshake, answers `ping` and `tool`, records every
/// `auth_refresh` it receives, and lets each test decide how to answer it.
class _FakeMultiplexServer {
  _FakeMultiplexServer._(this._server);

  final HttpServer _server;
  WebSocket? _socket;

  /// Tokens received in `auth_refresh` frames, in arrival order.
  final List<String> refreshTokens = <String>[];

  /// Token received in the handshake `auth` frame.
  String? handshakeToken;

  /// How to answer an `auth_refresh`. Default: accept it.
  void Function(WebSocket socket, String token) onAuthRefresh =
      (WebSocket socket, String token) {
    socket.add(jsonEncode(<String, dynamic>{
      'type': 'auth_refreshed',
      'expires_at': 4102444800,
    }));
  };

  static Future<_FakeMultiplexServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = _FakeMultiplexServer._(server);
    unawaited(fake._accept());
    return fake;
  }

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  Future<void> _accept() async {
    // This loop is deliberately fire-and-forget, so it must swallow its own
    // errors. `stop()` closes the server under it (force: true), which makes
    // the request iteration or the upgrade throw; an unhandled async error
    // there would fail whichever test happened to be running with a
    // confusing, unrelated message.
    try {
      await for (final HttpRequest request in _server) {
        final WebSocket socket = await WebSocketTransformer.upgrade(request);
        _socket = socket;
        socket.listen(
          (dynamic raw) => _onFrame(socket, raw),
          onError: (Object _) {},
          cancelOnError: false,
        );
      }
    } catch (_) {
      // Teardown only — the server is going away.
    }
  }

  void _onFrame(WebSocket socket, dynamic raw) {
    if (raw is! String) return;
    final dynamic decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) return;
    switch (decoded['type']) {
      case 'auth':
        handshakeToken = decoded['token'] as String?;
        socket.add(jsonEncode(<String, dynamic>{'type': 'auth_ok'}));
        break;
      case 'ping':
        socket.add(jsonEncode(<String, dynamic>{'type': 'pong'}));
        break;
      case 'auth_refresh':
        refreshTokens.add(decoded['token'] as String? ?? '');
        onAuthRefresh(socket, decoded['token'] as String? ?? '');
        break;
      case 'tool':
        socket.add(jsonEncode(<String, dynamic>{
          'req_id': decoded['req_id'],
          'kind': 'result',
          'data': <String, dynamic>{'ok': true},
        }));
        break;
      default:
        break;
    }
  }

  /// Push an unsolicited server frame, e.g. `auth_refresh_needed`.
  void push(Map<String, dynamic> frame) => _socket?.add(jsonEncode(frame));

  /// Answer a handover that [onAuthRefresh] deliberately left unanswered.
  void acceptPendingRefresh() => push(<String, dynamic>{
        'type': 'auth_refreshed',
        'expires_at': 4102444800,
      });

  Future<void> stop() async {
    try {
      await _socket?.close();
    } catch (_) {}
    await _server.close(force: true);
  }
}

/// Let queued microtasks and socket I/O settle.
Future<void> _settle([int ms = 120]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  late _FakeMultiplexServer server;

  setUp(() async {
    server = await _FakeMultiplexServer.start();
  });

  tearDown(() async {
    await server.stop();
  });

  /// Proof that the session survived: the very same socket still carries a
  /// request afterwards. If anything had signed the user out or torn the
  /// connection down, this would fail.
  Future<void> expectStillUsable(MultiplexConnection connection) async {
    final Map<String, dynamic> result =
        await connection.tool(tool: 'noop', payload: const <String, dynamic>{});
    expect(result['ok'], isTrue);
  }

  MultiplexConnection connect({
    Future<String?> Function()? freshTokenProvider,
    Duration fetchTimeout = const Duration(seconds: 5),
    Duration replyTimeout = const Duration(seconds: 5),
    Duration retryDelay = const Duration(seconds: 30),
  }) {
    return MultiplexConnection(
      baseUrl: server.baseUrl,
      accessTokenProvider: () async => 'token-1',
      freshTokenProvider: freshTokenProvider,
      authRefreshFetchTimeout: fetchTimeout,
      authRefreshReplyTimeout: replyTimeout,
      authRefreshRetryDelay: retryDelay,
    );
  }

  group('auth_refresh handover', () {
    test('sends the new token and clears pending state on auth_refreshed',
        () async {
      final connection = connect();
      addTearDown(connection.dispose);
      await connection.ensureReady();
      expect(server.handshakeToken, 'token-1');
      expect(connection.holdsAuthToken('token-1'), isTrue);

      final bool sent = await connection.updateAuthToken('token-2');
      expect(sent, isTrue);
      await _settle();

      expect(server.refreshTokens, <String>['token-2']);
      expect(connection.hasPendingAuthRefresh, isFalse);
      expect(connection.holdsAuthToken('token-2'), isTrue);
      expect(connection.authRefreshFailures, 0);
      expect(connection.hasAuthRefreshRetryScheduled, isFalse);
      await expectStillUsable(connection);
    });

    test('re-sending the token the server already holds is a no-op', () async {
      final connection = connect();
      addTearDown(connection.dispose);
      await connection.ensureReady();

      expect(await connection.updateAuthToken('token-1'), isTrue);
      await _settle();

      expect(server.refreshTokens, isEmpty);
      expect(connection.holdsAuthToken('token-1'), isTrue);
      await expectStillUsable(connection);
    });

    test('auth_refresh_needed fetches a fresh token and hands it over',
        () async {
      int fetches = 0;
      final connection = connect(freshTokenProvider: () async {
        fetches++;
        return 'token-fresh';
      });
      addTearDown(connection.dispose);
      await connection.ensureReady();

      server.push(<String, dynamic>{
        'type': 'auth_refresh_needed',
        'expires_at': 4102444800,
      });
      await _settle(250);

      expect(fetches, 1);
      expect(server.refreshTokens, <String>['token-fresh']);
      expect(connection.holdsAuthToken('token-fresh'), isTrue);
      expect(connection.hasPendingAuthRefresh, isFalse);
      await expectStillUsable(connection);
    });

    test('a token handed in mid-handover is queued, then sent', () async {
      server.onAuthRefresh = (WebSocket socket, String token) {
        // Withhold the reply so the next token has to queue behind it.
      };
      final connection = connect();
      addTearDown(connection.dispose);
      await connection.ensureReady();

      expect(await connection.updateAuthToken('token-2'), isTrue);
      await _settle();
      expect(server.refreshTokens, <String>['token-2']);

      // Second token arrives while the first is still unanswered.
      expect(await connection.updateAuthToken('token-3'), isTrue);
      await _settle();
      expect(connection.hasQueuedAuthRefresh, isTrue);
      // Still only one frame on the wire.
      expect(server.refreshTokens, <String>['token-2']);

      // The reply settles the first handover and releases the queued one.
      server.acceptPendingRefresh();
      await _settle(200);

      expect(server.refreshTokens, <String>['token-2', 'token-3']);
      expect(connection.hasQueuedAuthRefresh, isFalse);
    });

    test('a queued token is dropped, not stranded, when the socket goes',
        () async {
      server.onAuthRefresh = (WebSocket socket, String token) {
        // Withhold the reply.
      };
      final connection = connect();
      await connection.ensureReady();

      expect(await connection.updateAuthToken('token-2'), isTrue);
      await _settle();
      expect(await connection.updateAuthToken('token-3'), isTrue);
      expect(connection.hasQueuedAuthRefresh, isTrue);

      await connection.dispose();

      // No marker survives the teardown; the next handshake would read a
      // current token from accessTokenProvider anyway.
      expect(connection.hasQueuedAuthRefresh, isFalse);
      expect(connection.hasPendingAuthRefresh, isFalse);
      expect(connection.hasActiveAuthToken, isFalse);
    });

    test('auth_refresh frames do not disturb an in-flight request', () async {
      final connection = connect(freshTokenProvider: () async => 'token-2');
      addTearDown(connection.dispose);
      await connection.ensureReady();

      final Future<Map<String, dynamic>> pending = connection.tool(
        tool: 'noop',
        payload: const <String, dynamic>{},
      );
      server.push(<String, dynamic>{
        'type': 'auth_refresh_needed',
        'expires_at': 4102444800,
      });

      expect((await pending)['ok'], isTrue);
    });
  });

  group('every failure mode keeps the user signed in', () {
    test('auth_refresh_failed keeps the session and the previous token',
        () async {
      server.onAuthRefresh = (WebSocket socket, String _) {
        socket.add(jsonEncode(<String, dynamic>{
          'type': 'auth_refresh_failed',
          'detail': 'subject mismatch',
        }));
      };
      final connection = connect();
      addTearDown(connection.dispose);
      await connection.ensureReady();

      // Must not throw, and must not report an auth failure upward.
      expect(await connection.updateAuthToken('token-2'), isTrue);
      await _settle();

      expect(connection.authRefreshFailures, 1);
      // Previous token kept, exactly as the server does.
      expect(connection.holdsAuthToken('token-1'), isTrue);
      expect(connection.hasPendingAuthRefresh, isFalse);
      // "Try again later", not "sign out".
      expect(connection.hasAuthRefreshRetryScheduled, isTrue);
      await expectStillUsable(connection);
    });

    test('a silent server keeps the session and arms a retry', () async {
      server.onAuthRefresh = (WebSocket socket, String token) {
        // Say nothing at all.
      };
      final connection = connect(
        replyTimeout: const Duration(milliseconds: 150),
      );
      addTearDown(connection.dispose);
      await connection.ensureReady();

      expect(await connection.updateAuthToken('token-2'), isTrue);
      await _settle(350);

      expect(connection.hasPendingAuthRefresh, isFalse);
      expect(connection.holdsAuthToken('token-1'), isTrue);
      expect(connection.hasAuthRefreshRetryScheduled, isTrue);
      await expectStillUsable(connection);
    });

    test('no token available keeps the session and arms a retry', () async {
      final connection = connect(freshTokenProvider: () async => null);
      addTearDown(connection.dispose);
      await connection.ensureReady();

      server.push(<String, dynamic>{
        'type': 'auth_refresh_needed',
        'expires_at': 4102444800,
      });
      await _settle(250);

      expect(server.refreshTokens, isEmpty);
      expect(connection.holdsAuthToken('token-1'), isTrue);
      expect(connection.hasAuthRefreshRetryScheduled, isTrue);
      await expectStillUsable(connection);
    });

    test('a throwing token source keeps the session and arms a retry',
        () async {
      final connection = connect(
        freshTokenProvider: () async => throw StateError('no auth client'),
      );
      addTearDown(connection.dispose);
      await connection.ensureReady();

      server.push(<String, dynamic>{
        'type': 'auth_refresh_needed',
        'expires_at': 4102444800,
      });
      await _settle(250);

      expect(server.refreshTokens, isEmpty);
      expect(connection.holdsAuthToken('token-1'), isTrue);
      expect(connection.hasAuthRefreshRetryScheduled, isTrue);
      await expectStillUsable(connection);
    });

    test('a handover offered with no open socket is refused, not fatal',
        () async {
      final connection = connect();
      addTearDown(connection.dispose);

      // Never opened — nothing to hand the token to. The next handshake
      // reads a current token anyway, so this is a no-op, not a logout.
      expect(await connection.updateAuthToken('token-2'), isFalse);
      expect(connection.hasActiveAuthToken, isFalse);

      // The connection is still perfectly openable afterwards.
      await connection.ensureReady();
      expect(connection.holdsAuthToken('token-1'), isTrue);
      await expectStillUsable(connection);
    });

    test('a null token is refused without touching the socket', () async {
      final connection = connect();
      addTearDown(connection.dispose);
      await connection.ensureReady();

      expect(await connection.updateAuthToken(null), isFalse);
      expect(await connection.updateAuthToken(''), isFalse);
      await _settle();

      expect(server.refreshTokens, isEmpty);
      expect(connection.holdsAuthToken('token-1'), isTrue);
      expect(connection.hasAuthRefreshRetryScheduled, isTrue);
      await expectStillUsable(connection);
    });

    test('a token source that never answers cannot silence the socket',
        () async {
      // The regression this guards: an unbounded Supabase refresh would
      // leave the fetch guard raised forever, so every later attempt would
      // return at the guard, no retry would be armed, and the socket would
      // keep the expired token for its whole life.
      final Completer<String?> never = Completer<String?>();
      addTearDown(() {
        if (!never.isCompleted) never.complete(null);
      });
      final connection = connect(
        freshTokenProvider: () => never.future,
        fetchTimeout: const Duration(milliseconds: 150),
      );
      addTearDown(connection.dispose);
      await connection.ensureReady();

      server.push(<String, dynamic>{
        'type': 'auth_refresh_needed',
        'expires_at': 4102444800,
      });
      await _settle(400);

      // Timed out, treated as "no token this time", retry armed.
      expect(server.refreshTokens, isEmpty);
      expect(connection.holdsAuthToken('token-1'), isTrue);
      expect(connection.hasAuthRefreshRetryScheduled, isTrue);
      await expectStillUsable(connection);

      // And the guard is down again: the very next handover works.
      expect(await connection.updateAuthToken('token-2'), isTrue);
      await _settle();
      expect(connection.holdsAuthToken('token-2'), isTrue);
    });

    test('a disposed connection refuses a handover instead of throwing',
        () async {
      final connection = connect();
      await connection.ensureReady();
      await connection.dispose();

      expect(await connection.updateAuthToken('token-2'), isFalse);
      expect(connection.hasPendingAuthRefresh, isFalse);
      expect(connection.hasAuthRefreshRetryScheduled, isFalse);
    });
  });
}
