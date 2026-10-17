// The app's real client code pointed at the chuk API emulator:
// MultiplexConnection (the /v2/ws client every hosted chat goes through) and
// the web tool handlers (HTTP fallback when no multiplex session is open).

import 'package:chuk_chat/models/chat_stream_event.dart';
import 'package:chuk_chat/services/multiplex_connection.dart';
import 'package:chuk_chat/tool_handlers/web_tools.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../tool/emulator/emulator.dart';

void main() {
  late ChukEmulator emu;
  late MultiplexConnection connection;

  setUp(() async {
    emu = await startEmulator(port: 0);
    connection = MultiplexConnection(
      accessTokenProvider: () async => 'emulator-token',
      baseUrl: emu.baseUrl,
    );
  });

  tearDown(() async {
    await connection.dispose();
    await emu.close();
  });

  Map<String, dynamic> payload(String message) => {
    'message': message,
    'model_id': 'deepseek/deepseek-v4-flash-0731',
    'provider_slug': 'open-inference/fp8',
    'max_tokens': 512,
    'temperature': 0.7,
  };

  test('MultiplexConnection streams a default echo turn', () async {
    final events = await connection.chat(payload: payload('ping me')).toList();
    final text = events.whereType<ContentEvent>().map((e) => e.text).join();
    expect(text, 'Echo: ping me');
    expect(events.whereType<MetaEvent>(), hasLength(1));
    expect(events.whereType<UsageEvent>(), hasLength(1));
    expect(events.last, isA<DoneEvent>());
    expect(connection.hasActiveAuthToken, isTrue);
  });

  test('MultiplexConnection parses a scripted tool call', () async {
    emu.script([
      {'type': 'reasoning', 'text': 'Need data.'},
      {
        'type': 'tool_call',
        'id': 'call_9',
        'name': 'web_search',
        'arguments_chunks': ['{"query"', ':"kiel"}'],
      },
    ]);
    final events = await connection.chat(payload: payload('search')).toList();
    expect(
      events.whereType<ReasoningEvent>().map((e) => e.text).join(),
      'Need data.',
    );
    final calls = events.whereType<ToolCallsEvent>().single.calls;
    expect(calls.single.id, 'call_9');
    expect(calls.single.name, 'web_search');
    expect(calls.single.arguments, '{"query":"kiel"}');
  });

  test('MultiplexConnection surfaces a scripted error', () async {
    emu.script([
      {'type': 'error', 'message': 'No provider selected', 'code': 'x'},
    ]);
    final events = await connection.chat(payload: payload('x')).toList();
    final error = events.whereType<ErrorEvent>().single;
    expect(error.message, 'No provider selected');
    expect(events.last, isA<DoneEvent>());
  });

  test('MultiplexConnection reports a scripted disconnect', () async {
    emu.script([
      {'type': 'text', 'text': 'half an answer'},
      {'type': 'disconnect'},
    ]);
    final events = await connection.chat(payload: payload('x')).toList();
    final error = events.whereType<ErrorEvent>().single;
    expect(error.code, StreamErrorCodes.connectionLost);
    expect(events.last, isA<DoneEvent>());
  });

  test('MultiplexConnection runs a server tool', () async {
    final result = await connection.tool(
      tool: 'crawl',
      payload: {'url': 'https://example.org/page'},
    );
    expect(result['url'], 'https://example.org/page');
    expect(result['content'], contains('example.org/page'));
  });

  test('web tool handlers work over the HTTP routes', () async {
    final headers = {
      'Authorization': 'Bearer emulator-token',
      'Content-Type': 'application/json',
    };
    final search = await executeWebSearch(
      serverHttpUrl: emu.baseUrl,
      serverHeaders: headers,
      args: {'query': 'kiel harbour'},
    );
    expect(search, contains('Result 1 for kiel harbour'));

    final crawl = await executeWebCrawl(
      serverHttpUrl: emu.baseUrl,
      serverHeaders: headers,
      args: {'url': 'https://example.org/x'},
    );
    expect(crawl, contains('canned content of https://example.org/x'));

    final paths = emu.requests.map((r) => r['path']).toList();
    expect(paths, containsAll(['/v1/tools/brave/search', '/v1/tools/crawl']));
  });
}
