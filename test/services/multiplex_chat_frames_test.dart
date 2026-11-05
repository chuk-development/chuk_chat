// The `/v2/ws` chat frames the client used to drop (B4), the error `class`
// (B6) and the server tool-call timeout (item 24), against a fake server.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chuk_chat/models/chat_stream_event.dart';
import 'package:chuk_chat/services/multiplex_connection.dart';
import 'package:chuk_chat/utils/stream_error_notice.dart';
import 'package:flutter_test/flutter_test.dart';

/// Answers the handshake; answers every `chat` with [chatReply]; never
/// answers a `tool` frame; records `cancel` frames.
class _FakeServer {
  _FakeServer._(this._server);

  final HttpServer _server;
  final List<WebSocket> _sockets = <WebSocket>[];
  final List<String> cancelled = <String>[];
  final List<String> cancelledRequestIds = <String>[];
  final List<String> tools = <String>[];
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
              final crid = frame['client_request_id'];
              if (crid is String) cancelledRequestIds.add(crid);
            case 'tool':
              tools.add(frame['req_id'] as String);
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

  test(
    'a tool call that times out during the handshake is never sent',
    () async {
      final Completer<String?> token = Completer<String?>();
      final MultiplexConnection slow = MultiplexConnection(
        baseUrl: server.baseUrl,
        accessTokenProvider: () => token.future,
      );
      addTearDown(slow.dispose);
      Object? failure;
      final Future<void> call = slow
          .tool(
            tool: 'brave_search',
            payload: const {},
            timeout: const Duration(milliseconds: 50),
          )
          .then<void>((_) {}, onError: (Object e) => failure = e);
      await call;
      expect((failure! as MultiplexException).code, 'timeout');
      // The handshake finishes only after the caller gave up.
      token.complete('token');
      await slow.ensureReady();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(server.tools, isEmpty);
    },
  );

  group('request idempotency frames', () {
    test('duplicate: the stored answer arrives as a normal answer', () async {
      server.chatReply = (id) => [
        {
          'req_id': id,
          'kind': 'duplicate',
          'data': {
            'client_request_id': 'c-1',
            'content': 'stored answer',
            'tool_calls': [
              {
                'id': 'call_1',
                'type': 'function',
                'function': {'name': 'calc', 'arguments': '{"x":1}'},
              },
            ],
            'usage': {'prompt_tokens': 10, 'completion_tokens': 3},
            'meta': {'model': 'm', 'provider': 'p', 'finish_reason': 'tool_calls'},
            'finish_reason': 'tool_calls',
          },
        },
        {'req_id': id, 'kind': 'done'},
      ];
      final events = await chat();
      expect(events[0], isA<ContentEvent>());
      expect((events[0] as ContentEvent).text, 'stored answer');
      final calls = (events[1] as ToolCallsEvent).calls;
      expect(calls.single.name, 'calc');
      expect(calls.single.arguments, '{"x":1}');
      expect((events[2] as UsageEvent).usage['prompt_tokens'], 10);
      final meta = (events[3] as MetaEvent).meta;
      expect(meta['model'], 'm');
      expect(meta['finish_reason'], 'tool_calls');
      expect(events.last, isA<DoneEvent>());
      expect(events.whereType<ErrorEvent>(), isEmpty);
    });

    test('duplicate without tool calls has no tool event', () {
      final events = MultiplexConnection.duplicateEvents({
        'content': 'hi',
        'finish_reason': 'stop',
        'meta': {'model': 'm'},
      });
      expect(events.whereType<ToolCallsEvent>(), isEmpty);
      expect((events.last as MetaEvent).meta, {
        'model': 'm',
        'finish_reason': 'stop',
      });
    });

    test('a truncated record with no content is a clear error', () async {
      server.chatReply = (id) => [
        {
          'req_id': id,
          'kind': 'duplicate',
          'data': {
            'client_request_id': 'c-1',
            'content': '',
            'truncated': true,
            'usage': {},
            'meta': {},
            'finish_reason': 'stop',
          },
        },
        {'req_id': id, 'kind': 'done'},
      ];
      final events = await chat();
      final error = events.whereType<ErrorEvent>().single;
      expect(error.code, StreamErrorCodes.duplicateUnavailable);
      expect(error.message, kAnswerUnavailableNotice);
      expect(events.whereType<ContentEvent>(), isEmpty);
    });

    test('a truncated record that kept content shows the content', () {
      final events = MultiplexConnection.duplicateEvents({
        'content': 'cut at 512k',
        'truncated': true,
      });
      expect(events.whereType<ErrorEvent>(), isEmpty);
      expect((events.first as ContentEvent).text, 'cut at 512k');
    });

    test('duplicate_in_flight carries the poll hint', () async {
      server.chatReply = (id) => [
        {
          'req_id': id,
          'kind': 'duplicate_in_flight',
          'data': {'client_request_id': 'c-1', 'retry_after_s': 3},
        },
        {'req_id': id, 'kind': 'done'},
      ];
      final events = await chat();
      final error = events.whereType<ErrorEvent>().single;
      expect(error.code, StreamErrorCodes.duplicateInFlight);
      expect(error.retryAfterSeconds, 3);
      expect(events.last, isA<DoneEvent>());
    });

    test('cancelClientRequest sends cancel with the id', () async {
      await connection.ensureReady();
      connection.cancelClientRequest('ob-q1-p2');
      for (var i = 0; i < 50 && server.cancelledRequestIds.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(server.cancelledRequestIds, ['ob-q1-p2']);
      // Its own req_id, not one of a running chat.
      expect(server.cancelled.single, isNotEmpty);
    });
  });

  test('the default server tool timeout is 120 s', () {
    expect(
      MultiplexConnection.defaultToolTimeout,
      const Duration(seconds: 120),
    );
  });
}
