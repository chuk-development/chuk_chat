// The `/v2/ws` chat frames the client used to drop (B4), the error `class`
// (B6) and the server tool-call timeout (item 24), against a fake server.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chuk_chat/models/chat_stream_event.dart';
import 'package:chuk_chat/services/multiplex_connection.dart';
import 'package:flutter_test/flutter_test.dart';

/// Answers the handshake; answers every `chat` with [chatReply]; never
/// answers a `tool` frame; records `cancel` frames.
class _FakeServer {
  _FakeServer._(this._server);

  final HttpServer _server;
  final List<WebSocket> _sockets = <WebSocket>[];
  final List<String> cancelled = <String>[];
  List<Map<String, dynamic>> Function(String reqId) chatReply = (_) => [];

  static Future<_FakeServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = _FakeServer._(server);
    unawaited(fake._accept());
    return fake;
  }

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  Future<void> _accept() async {
    try {
      await for (final HttpRequest request in _server) {
        final socket = await WebSocketTransformer.upgrade(request);
        _sockets.add(socket);
        socket.listen((dynamic raw) {
          if (raw is! String) return;
          final frame = jsonDecode(raw) as Map<String, dynamic>;
          switch (frame['type']) {
            case 'auth':
              socket.add(jsonEncode({'type': 'auth_ok'}));
            case 'chat':
              for (final out in chatReply(frame['req_id'] as String)) {
                socket.add(jsonEncode(out));
              }
            case 'cancel':
              cancelled.add(frame['req_id'] as String);
            default:
              break;
          }
        }, onError: (Object _) {});
      }
    } catch (_) {}
  }

  Future<void> stop() async {
    for (final s in _sockets) {
      try {
        await s.close();
      } catch (_) {}
    }
    await _server.close(force: true);
  }
}

void main() {
  late _FakeServer server;
  late MultiplexConnection connection;

  setUp(() async {
    server = await _FakeServer.start();
    connection = MultiplexConnection(
      baseUrl: server.baseUrl,
      accessTokenProvider: () async => 'token',
    );
  });

  tearDown(() async {
    await connection.dispose();
    await server.stop();
  });

  Future<List<ChatStreamEvent>> chat() =>
      connection.chat(payload: const {'message': 'hi'}).toList();

  List<String?> finishReasons(List<ChatStreamEvent> events) => [
    for (final e in events)
      if (e is MetaEvent && e.meta.containsKey('finish_reason'))
        e.meta['finish_reason'] as String?,
  ];

  test('old server: finish_reason from the timing frame', () async {
    server.chatReply = (id) => [
      {'req_id': id, 'kind': 'content', 'data': 'cut'},
      {
        'req_id': id,
        'kind': 'timing',
        'data': {'phase': 'first_token', 'ttft_ms': 10},
      },
      {
        'req_id': id,
        'kind': 'timing',
        'data': {'phase': 'complete', 'finish_reason': 'length'},
      },
      {'req_id': id, 'kind': 'done'},
    ];
    final events = await chat();
    expect(finishReasons(events), ['length']);
    expect(events.last, isA<DoneEvent>());
  });

  test('new server: meta frame and done payload', () async {
    server.chatReply = (id) => [
      {
        'req_id': id,
        'kind': 'meta',
        'data': {'finish_reason': 'tool_calls'},
      },
      {
        'req_id': id,
        'kind': 'done',
        'data': {'finish_reason': 'tool_calls'},
      },
    ];
    final events = await chat();
    expect(finishReasons(events), ['tool_calls', 'tool_calls']);
    // The meta event lands before done, where the tool loop reads it.
    expect(events.last, isA<DoneEvent>());
  });

  test('done with a top-level finish_reason', () async {
    server.chatReply = (id) => [
      {'req_id': id, 'kind': 'done', 'finish_reason': 'stop'},
    ];
    expect(finishReasons(await chat()), ['stop']);
  });

  test('a bare done adds no meta', () async {
    server.chatReply = (id) => [
      {'req_id': id, 'kind': 'done'},
    ];
    final events = await chat();
    expect(events.single, isA<DoneEvent>());
  });

  test('error class and code reach the ErrorEvent', () async {
    server.chatReply = (id) => [
      {
        'req_id': id,
        'kind': 'error',
        'detail': 'No credits left.',
        'code': 'billing',
        'class': 'quota',
      },
      {'req_id': id, 'kind': 'done'},
    ];
    final error = (await chat()).whereType<ErrorEvent>().single;
    expect(error.code, 'billing');
    expect(error.errorClass, 'quota');
    expect(error.isPaymentRequired, isTrue);
  });

  test(
    'a server tool call with no answer times out and is cancelled',
    () async {
      await connection.ensureReady();
      Object? failure;
      try {
        await connection.tool(
          tool: 'brave_search',
          payload: const {},
          timeout: const Duration(milliseconds: 200),
        );
      } catch (error) {
        failure = error;
      }
      expect(failure, isA<MultiplexException>());
      final e = failure! as MultiplexException;
      expect(e.code, 'timeout');
      expect(e.detail, 'tool call timed out after 200ms');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(server.cancelled, hasLength(1));
    },
  );

  test('the default server tool timeout is 120 s', () {
    expect(
      MultiplexConnection.defaultToolTimeout,
      const Duration(seconds: 120),
    );
  });
}
