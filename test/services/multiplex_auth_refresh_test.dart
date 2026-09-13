// Handing a fresh access token to an ALREADY-OPEN `/v2/ws` socket.
//
// `/v2/ws` authenticates once, at the handshake, and that identity used to
// serve the whole connection: an app left open long enough asked a live socket
// a billing question with a token that had aged out, and the answer came back
// `JWT expired` — the user was told the credits were spent while he still had
// them. The server now takes `auth_refresh` on an open socket; these tests
// cover the client half of that conversation.
//
// The rule that outranks every other assertion here: NO failure mode of this
// feature may cost the user the session. A refusal, a socket that will not
// take the token, a server that never answers — each one ends in "keep the
// session, try again", and the last group proves it end to end.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:chuk_chat/models/chat_stream_event.dart';
import 'package:chuk_chat/services/account_session.dart';
import 'package:chuk_chat/services/multiplex_connection.dart';
import 'package:chuk_chat/services/session_refresh_scheduler.dart';

/// A socket the test drives by hand: it records what the client sent and
/// plays server frames back on demand.
class _FakeSocket {
  final StreamController<dynamic> _inbound = StreamController<dynamic>();
  final List<String> sent = <String>[];

  /// Makes every later `sink.add` throw, the way a dead transport does.
  bool sinkIsDead = false;

  late final WebSocketChannel channel = _FakeChannel(this);

  void serverSays(Map<String, dynamic> frame) {
    if (_inbound.isClosed) return;
    _inbound.add(jsonEncode(frame));
  }

  List<Map<String, dynamic>> framesOfType(String type) => sent
      .map((raw) => jsonDecode(raw) as Map<String, dynamic>)
      .where((frame) => frame['type'] == type)
      .toList();

  Map<String, dynamic>? lastOfType(String type) {
    final frames = framesOfType(type);
    return frames.isEmpty ? null : frames.last;
  }

  Future<void> close() async {
    if (!_inbound.isClosed) await _inbound.close();
  }
}

class _FakeSink implements WebSocketSink {
  _FakeSink(this._socket);

  final _FakeSocket _socket;
  final Completer<void> _done = Completer<void>();

  @override
  void add(dynamic data) {
    if (_socket.sinkIsDead) throw StateError('sink is dead');
    _socket.sent.add(data as String);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<dynamic> stream) async {}

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    if (!_done.isCompleted) _done.complete();
    await _socket.close();
  }

  @override
  Future<void> get done => _done.future;
}

/// `WebSocketChannel` carries the whole `StreamChannel` surface; the
/// connection only ever touches `stream`, `sink` and `ready`, so the rest is
/// left to `noSuchMethod` instead of hand-written stubs.
class _FakeChannel implements WebSocketChannel {
  _FakeChannel(this._socket) : sink = _FakeSink(_socket);

  final _FakeSocket _socket;

  @override
  final WebSocketSink sink;

  @override
  Stream<dynamic> get stream => _socket._inbound.stream;

  @override
  Future<void> get ready => Future<void>.value();

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  String? get protocol => null;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('not used by MultiplexConnection');
}

void main() {
  /// Opens a connection against [socket] and completes the handshake.
  Future<MultiplexConnection> connected(
    _FakeSocket socket, {
    String token = 'token-1',
    Future<void> Function()? onAuthRefreshNeeded,
    Duration authRefreshTimeout = const Duration(seconds: 15),
  }) async {
    final connection = MultiplexConnection(
      baseUrl: 'https://api.example.test',
      accessTokenProvider: () async => token,
      onAuthRefreshNeeded: onAuthRefreshNeeded,
      authRefreshTimeout: authRefreshTimeout,
      connect: (_) async => socket.channel,
    );
    final ready = connection.ensureReady();
    await pumpEventQueue();
    socket.serverSays(<String, dynamic>{'type': 'auth_ok'});
    await ready;
    return connection;
  }

  group('auth_refresh on an open socket', () {
    test('hands a freshly minted token to the socket', () async {
      final socket = _FakeSocket();
      final connection = await connected(socket);

      expect(connection.authToken, 'token-1');
      expect(connection.sendAuthRefresh('token-2'), isTrue);
      expect(socket.lastOfType('auth_refresh')?['token'], 'token-2');

      socket.serverSays(<String, dynamic>{
        'type': 'auth_refreshed',
        'expires_at': 1800003600,
      });
      await pumpEventQueue();

      expect(connection.authToken, 'token-2');
      expect(connection.authExpiresAt, 1800003600);
      expect(connection.authRefreshAccepted, 1);
      expect(connection.lastAuthRefreshFailure, isNull);
      await connection.dispose();
    });

    test('does not re-send a token the socket already carries', () async {
      final socket = _FakeSocket();
      final connection = await connected(socket);

      // The handshake token.
      expect(connection.sendAuthRefresh('token-1'), isFalse);
      // The token of an attempt still waiting for its answer.
      expect(connection.sendAuthRefresh('token-2'), isTrue);
      expect(connection.sendAuthRefresh('token-2'), isFalse);
      socket.serverSays(<String, dynamic>{'type': 'auth_refreshed'});
      await pumpEventQueue();
      // And the token the server confirmed.
      expect(connection.sendAuthRefresh('token-2'), isFalse);

      expect(socket.framesOfType('auth_refresh'), hasLength(1));
      await connection.dispose();
    });

    test('a refusal keeps the socket, its token and every request', () async {
      final socket = _FakeSocket();
      final connection = await connected(socket);

      final events = <ChatStreamEvent>[];
      final sub = connection.chat(payload: <String, dynamic>{}).listen(
        events.add,
      );
      await pumpEventQueue();
      final reqId = socket.lastOfType('chat')?['req_id'] as String;

      connection.sendAuthRefresh('token-2');
      socket.serverSays(<String, dynamic>{
        'type': 'auth_refresh_failed',
        'detail': 'token belongs to another user',
      });
      await pumpEventQueue();

      // The session is not the socket's business, and the socket is not
      // closed: it still carries its old identity and its in-flight request.
      expect(connection.authToken, 'token-1');
      expect(connection.lastAuthRefreshFailure, 'token belongs to another user');
      expect(connection.authRefreshRefused, 1);
      expect(events.whereType<ErrorEvent>(), isEmpty);
      expect(events.whereType<DoneEvent>(), isEmpty);

      socket.serverSays(<String, dynamic>{
        'req_id': reqId,
        'kind': 'content',
        'data': 'still serving',
      });
      await pumpEventQueue();
      expect(
        events.whereType<ContentEvent>().map((e) => e.text),
        <String>['still serving'],
      );

      // A refusal means "try again later", so the same token may be offered
      // again on the next mint.
      expect(connection.sendAuthRefresh('token-2'), isTrue);

      await sub.cancel();
      await connection.dispose();
    });

    test('a server that never answers forgets the attempt', () async {
      final socket = _FakeSocket();
      final connection = await connected(
        socket,
        authRefreshTimeout: const Duration(milliseconds: 20),
      );

      expect(connection.sendAuthRefresh('token-2'), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 60));

      // Nothing was torn down, and the socket still holds the token it had.
      expect(connection.authToken, 'token-1');
      expect(connection.authRefreshAccepted, 0);
      expect(connection.authRefreshRefused, 0);
      // The same token may go out again.
      expect(connection.sendAuthRefresh('token-2'), isTrue);
      expect(socket.framesOfType('auth_refresh'), hasLength(2));
      await connection.dispose();
    });

    test('a dead sink is a false, not a throw', () async {
      final socket = _FakeSocket();
      final connection = await connected(socket);
      socket.sinkIsDead = true;

      expect(connection.sendAuthRefresh('token-2'), isFalse);
      expect(connection.authToken, 'token-1');
      await connection.dispose();
    });

    test('a socket that was never opened takes nothing', () async {
      final socket = _FakeSocket();
      final connection = MultiplexConnection(
        baseUrl: 'https://api.example.test',
        accessTokenProvider: () async => 'token-1',
        connect: (_) async => socket.channel,
      );

      expect(connection.sendAuthRefresh('token-2'), isFalse);
      expect(socket.framesOfType('auth_refresh'), isEmpty);

      await connection.dispose();
      expect(connection.sendAuthRefresh('token-3'), isFalse);
    });

    test('waits for the handshake before amending it', () async {
      final socket = _FakeSocket();
      final connection = MultiplexConnection(
        baseUrl: 'https://api.example.test',
        accessTokenProvider: () async => 'token-1',
        connect: (_) async => socket.channel,
      );
      final ready = connection.ensureReady();
      await pumpEventQueue();

      // The socket is open but `auth_ok` has not arrived: an `auth_refresh`
      // now would overtake the `auth` frame it amends.
      expect(socket.lastOfType('auth')?['token'], 'token-1');
      expect(connection.sendAuthRefresh('token-2'), isFalse);
      expect(socket.framesOfType('auth_refresh'), isEmpty);

      socket.serverSays(<String, dynamic>{'type': 'auth_ok'});
      await ready;

      expect(connection.sendAuthRefresh('token-2'), isTrue);
      await connection.dispose();
    });

    test('an empty token is never sent', () async {
      final socket = _FakeSocket();
      final connection = await connected(socket);

      expect(connection.sendAuthRefresh(''), isFalse);
      expect(socket.framesOfType('auth_refresh'), isEmpty);
      await connection.dispose();
    });
  });

  group('auth_refresh_needed', () {
    test('asks the app for a token right away, once', () async {
      final socket = _FakeSocket();
      var asks = 0;
      final gate = Completer<void>();
      final connection = await connected(
        socket,
        onAuthRefreshNeeded: () async {
          asks++;
          await gate.future;
        },
      );

      socket.serverSays(<String, dynamic>{
        'type': 'auth_refresh_needed',
        'expires_at': 1800000300,
      });
      await pumpEventQueue();
      // A second hint while the first ask is still running asks no twice.
      socket.serverSays(<String, dynamic>{'type': 'auth_refresh_needed'});
      await pumpEventQueue();

      expect(asks, 1);
      expect(connection.authRefreshNeeded, 2);
      expect(connection.authExpiresAt, 1800000300);

      gate.complete();
      await pumpEventQueue();
      await connection.dispose();
    });

    test('a refresh that fails on the hint disturbs nothing', () async {
      final socket = _FakeSocket();
      final connection = await connected(
        socket,
        onAuthRefreshNeeded: () async => throw StateError('refresh refused'),
      );

      final events = <ChatStreamEvent>[];
      final sub = connection.chat(payload: <String, dynamic>{}).listen(
        events.add,
      );
      await pumpEventQueue();

      socket.serverSays(<String, dynamic>{'type': 'auth_refresh_needed'});
      await pumpEventQueue();

      // The hint is a hint: the request it rode in on is still served.
      expect(events.whereType<ErrorEvent>(), isEmpty);
      expect(connection.authToken, 'token-1');
      await sub.cancel();
      await connection.dispose();
    });

    test('a hint on a connection with no handler is harmless', () async {
      final socket = _FakeSocket();
      final connection = await connected(socket);

      socket.serverSays(<String, dynamic>{'type': 'auth_refresh_needed'});
      await pumpEventQueue();

      expect(connection.authRefreshNeeded, 1);
      expect(connection.authToken, 'token-1');
      await connection.dispose();
    });
  });

  // The constraint that matters more than the feature: the user stays signed
  // in through every one of these. The scheduler is wired to a live socket
  // exactly as the app wires it, and each failure mode is played out against
  // the pair.
  group('every failure mode leaves the local session intact', () {
    const int nowSeconds = 1800000000;
    DateTime clock() =>
        DateTime.fromMillisecondsSinceEpoch(nowSeconds * 1000);

    late _RecordingSource source;
    late SessionRefreshScheduler scheduler;

    setUp(() {
      source = _RecordingSource(
        const AccountSession(
          accessToken: 'token-1',
          refreshToken: 'r1',
          userId: 'user-1',
          expiresAt: nowSeconds + 30,
        ),
      );
      scheduler = SessionRefreshScheduler(
        source: source,
        now: clock,
        sinkGrace: const Duration(milliseconds: 50),
      );
    });

    void expectStillSignedIn() {
      expect(source.current(), isNotNull, reason: 'the session was cleared');
      expect(source.cleared, isFalse, reason: 'something signed the user out');
      expect(source.current()!.userId, 'user-1');
    }

    test('the server refuses the new token', () async {
      final socket = _FakeSocket();
      final connection = await connected(socket);
      scheduler.addTokenSink((token) async {
        connection.sendAuthRefresh(token);
      });

      expect(await scheduler.refreshIfDue(), isTrue);
      socket.serverSays(<String, dynamic>{
        'type': 'auth_refresh_failed',
        'detail': 'sub mismatch',
      });
      await pumpEventQueue();

      expectStillSignedIn();
      expect(source.current()!.accessToken, 'token-1+');
      expect(connection.authRefreshRefused, 1);
      await connection.dispose();
    });

    test('the socket will not take the new token', () async {
      final socket = _FakeSocket();
      final connection = await connected(socket);
      socket.sinkIsDead = true;
      scheduler.addTokenSink((token) async {
        connection.sendAuthRefresh(token);
      });

      expect(await scheduler.refreshIfDue(), isTrue);
      expectStillSignedIn();
      expect(source.current()!.accessToken, 'token-1+');
      await connection.dispose();
    });

    test('there is no socket at all', () async {
      scheduler.addTokenSink((token) async {});

      expect(await scheduler.refreshIfDue(), isTrue);
      expectStillSignedIn();
    });

    test('the sink itself throws', () async {
      scheduler.addTokenSink((token) async => throw StateError('no socket'));

      expect(await scheduler.refreshIfDue(), isTrue);
      expectStillSignedIn();
      expect(source.current()!.accessToken, 'token-1+');
    });

    test('the sink never returns', () async {
      scheduler.addTokenSink((token) => Completer<void>().future);

      expect(await scheduler.refreshIfDue(), isTrue);
      expectStillSignedIn();
    });

    test('the refresh itself is rejected', () async {
      source.refreshFails = true;
      final socket = _FakeSocket();
      final connection = await connected(socket);
      scheduler.addTokenSink((token) async {
        connection.sendAuthRefresh(token);
      });

      // Nothing minted, so nothing announced — and the session the app holds
      // is exactly the one it had.
      expect(await scheduler.refreshIfDue(), isFalse);
      expectStillSignedIn();
      expect(source.current()!.accessToken, 'token-1');
      expect(socket.framesOfType('auth_refresh'), isEmpty);
      await connection.dispose();
    });

    test('the server asks and the app cannot answer', () async {
      source.refreshFails = true;
      final socket = _FakeSocket();
      late final MultiplexConnection connection;
      connection = await connected(
        socket,
        onAuthRefreshNeeded: () async {
          await scheduler.refreshIfDue();
          final current = source.current();
          if (current != null) connection.sendAuthRefresh(current.accessToken);
        },
      );

      socket.serverSays(<String, dynamic>{'type': 'auth_refresh_needed'});
      await pumpEventQueue();

      expectStillSignedIn();
      expect(source.current()!.accessToken, 'token-1');
      await connection.dispose();
    });
  });
}

/// A session source that mints a new token on refresh and records whether
/// anything ever took the session away.
class _RecordingSource implements AccountSessionSource {
  _RecordingSource(this._current);

  AccountSession? _current;

  /// True once the session went from present to absent — the outcome this
  /// whole feature must never produce.
  bool cleared = false;

  /// Makes [refresh] behave like a rejected refresh that the account session
  /// source has already recovered from: no new token, session untouched.
  bool refreshFails = false;

  int refreshCalls = 0;

  @override
  AccountSession? current() => _current;

  @override
  Future<AccountSession?> refresh() async {
    refreshCalls++;
    final before = _current;
    if (before == null) return null;
    if (refreshFails) return before;
    _current = AccountSession(
      accessToken: '${before.accessToken}+',
      refreshToken: '${before.refreshToken}+',
      userId: before.userId,
      expiresAt: (before.expiresAt ?? 0) + 3600,
    );
    if (_current == null) cleared = true;
    return _current;
  }
}
