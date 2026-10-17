// Chat WebSocket side of the chuk API emulator, spoken at the wire level.
// The request frames use the exact format the app sends
// (lib/services/websocket_chat_service.dart, multiplex_connection.dart).

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/io.dart';

import '../../tool/emulator/emulator.dart';

/// A minimal /v2/ws client that collects frames per req_id.
class _WireClient {
  _WireClient(this.channel) {
    channel.stream.listen(
      (raw) => _frames.add(jsonDecode(raw as String) as Map<String, dynamic>),
      onDone: () => _closed.complete(),
    );
  }

  final IOWebSocketChannel channel;
  final _frames = StreamController<Map<String, dynamic>>.broadcast();
  final _closed = Completer<void>();
  late final Stream<Map<String, dynamic>> frames = _frames.stream;

  Future<void> get closed => _closed.future;

  static Future<_WireClient> connect(ChukEmulator emu) async {
    final channel = IOWebSocketChannel.connect(
      Uri.parse('ws://127.0.0.1:${emu.port}/v2/ws'),
    );
    await channel.ready;
    final client = _WireClient(channel);
    final ok = client.frames.first;
    client.send({'type': 'auth', 'token': 'any-token'});
    expect(await ok, {'type': 'auth_ok'});
    return client;
  }

  void send(Map<String, Object?> frame) => channel.sink.add(jsonEncode(frame));

  /// Sends a chat request and returns every frame up to `done`.
  Future<List<Map<String, dynamic>>> chat(
    String reqId,
    Map<String, Object?> payload,
  ) {
    final result = frames
        .where((f) => f['req_id'] == reqId)
        .takeWhile((f) => f['kind'] != 'done')
        .toList();
    send({'req_id': reqId, 'type': 'chat', 'payload': payload});
    return result;
  }
}

Map<String, Object?> _payload(String message) => {
  'message': message,
  'model_id': 'deepseek/deepseek-v4-flash-0731',
  'provider_slug': 'open-inference/fp8',
  'max_tokens': 512,
  'temperature': 0.7,
};

String _joined(List<Map<String, dynamic>> frames, String kind) => frames
    .where((f) => f['kind'] == kind)
    .map((f) => f['data'] as String)
    .join();

void main() {
  late ChukEmulator emu;

  setUp(() async {
    emu = await startEmulator(port: 0);
  });

  tearDown(() async {
    await emu.close();
  });

  test('default turn echoes the message in content chunks', () async {
    final client = await _WireClient.connect(emu);
    final frames = await client.chat('r1', _payload('hello world'));
    expect(frames.first['kind'], 'meta');
    expect(
      (frames.first['data'] as Map)['model'],
      containsPair('id', 'deepseek/deepseek-v4-flash-0731'),
    );
    expect(frames.where((f) => f['kind'] == 'content').length, greaterThan(1));
    expect(_joined(frames, 'content'), 'Echo: hello world');
    expect(frames.last['kind'], 'usage');

    final logged = emu.requests.where((r) => r['type'] == 'chat').single;
    expect((logged['payload'] as Map)['message'], 'hello world');
    expect(logged['req_id'], 'r1');
    await client.channel.sink.close();
  });

  test('scripted turn: reasoning, text, chunked tool call', () async {
    emu.script([
      {'type': 'reasoning', 'text': 'Let me think.'},
      {
        'type': 'text',
        'chunks': ['I will ', 'search.'],
      },
      {
        'type': 'tool_call',
        'id': 'call_1',
        'name': 'web_search',
        'arguments_chunks': ['{"query":', '"kiel"}'],
      },
      {
        'type': 'tool_call',
        'name': 'web_crawl',
        'arguments': {'url': 'u'},
      },
      {'type': 'usage', 'prompt_tokens': 7, 'completion_tokens': 3},
    ]);
    final client = await _WireClient.connect(emu);
    final frames = await client.chat('r2', _payload('weather in kiel?'));
    expect(_joined(frames, 'reasoning'), 'Let me think.');
    expect(frames.where((f) => f['kind'] == 'content').length, 2);
    final toolFrames = frames.where((f) => f['kind'] == 'tool_calls').toList();
    expect(toolFrames, hasLength(1));
    final calls = toolFrames.single['data'] as List;
    expect(calls, hasLength(2));
    expect(calls[0], {
      'id': 'call_1',
      'type': 'function',
      'function': {'name': 'web_search', 'arguments': '{"query":"kiel"}'},
    });
    expect((calls[1] as Map)['function'], {
      'name': 'web_crawl',
      'arguments': '{"url":"u"}',
    });
    final usage = frames.where((f) => f['kind'] == 'usage').toList();
    expect(usage.single['data'], {'prompt_tokens': 7, 'completion_tokens': 3});

    // The queue is used up: the next turn is the echo again.
    final next = await client.chat('r3', _payload('again'));
    expect(_joined(next, 'content'), 'Echo: again');
    await client.channel.sink.close();
  });

  test('scripted error ends the turn with error then done', () async {
    emu.script([
      {'type': 'text', 'text': 'partial'},
      {'type': 'error', 'message': 'upstream broke', 'code': 'upstream_status'},
      {'type': 'text', 'text': 'never sent'},
    ]);
    final client = await _WireClient.connect(emu);
    final frames = await client.chat('r4', _payload('x'));
    expect(frames.last, {
      'req_id': 'r4',
      'kind': 'error',
      'detail': 'upstream broke',
      'code': 'upstream_status',
    });
    expect(_joined(frames, 'content'), 'partial');
    await client.channel.sink.close();
  });

  test('scripted disconnect closes the socket mid-turn', () async {
    emu.script([
      {'type': 'text', 'text': 'half'},
      {'type': 'disconnect'},
    ]);
    final client = await _WireClient.connect(emu);
    final seen = <Map<String, dynamic>>[];
    client.frames.listen(seen.add);
    client.send({'req_id': 'r5', 'type': 'chat', 'payload': _payload('x')});
    await client.closed.timeout(const Duration(seconds: 5));
    expect(seen.any((f) => f['kind'] == 'done'), isFalse);
    expect(seen.any((f) => f['kind'] == 'content'), isTrue);
  });

  test('ping, auth_refresh, tool frames and cancel', () async {
    final client = await _WireClient.connect(emu);

    final pong = client.frames.first;
    client.send({'type': 'ping'});
    expect(await pong, {'type': 'pong'});

    final refreshed = client.frames.first;
    client.send({'type': 'auth_refresh', 'token': 'fresh'});
    expect((await refreshed)['type'], 'auth_refreshed');

    final toolFrames = client.frames
        .where((f) => f['req_id'] == 't1')
        .takeWhile((f) => f['kind'] != 'done')
        .toList();
    client.send({
      'req_id': 't1',
      'type': 'tool',
      'tool': 'brave_search',
      'payload': {'query': 'kiel', 'count': 2},
    });
    final result = (await toolFrames).single;
    expect(result['kind'], 'result');
    expect((result['data'] as Map)['results'], hasLength(2));

    final unknown = client.frames
        .where((f) => f['req_id'] == 't2')
        .takeWhile((f) => f['kind'] != 'done')
        .toList();
    client.send({
      'req_id': 't2',
      'type': 'tool',
      'tool': 'nope',
      'payload': {},
    });
    expect((await unknown).single['code'], 'unknown_tool');

    emu.script([
      {'type': 'text', 'text': 'one'},
      {'type': 'delay', 'ms': 500},
      {'type': 'text', 'text': 'two'},
    ]);
    final cancelled = client.chat('r6', _payload('x'));
    await client.frames.firstWhere(
      (f) => f['req_id'] == 'r6' && f['kind'] == 'content',
    );
    client.send({'req_id': 'r6', 'type': 'cancel'});
    final frames = await cancelled;
    expect(frames.last['code'], 'cancelled');
    expect(_joined(frames, 'content'), 'one');
    await client.channel.sink.close();
  });

  test('legacy /v1/ai/chat/ws speaks the flat frame format', () async {
    final channel = IOWebSocketChannel.connect(
      Uri.parse('ws://127.0.0.1:${emu.port}/v1/ai/chat/ws'),
    );
    await channel.ready;
    final frames = channel.stream
        .map((raw) => jsonDecode(raw as String) as Map<String, dynamic>)
        .takeWhile((f) => f['done'] != true)
        .toList();
    channel.sink.add(jsonEncode({..._payload('legacy'), 'token': 'tok'}));
    final got = await frames;
    expect(got.first.keys.single, 'meta');
    expect(
      got
          .where((f) => f.containsKey('content'))
          .map((f) => f['content'])
          .join(),
      'Echo: legacy',
    );
    await channel.sink.close();
  });
}
