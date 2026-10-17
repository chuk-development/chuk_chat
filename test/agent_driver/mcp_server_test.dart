// MCP protocol layer of the agent driver.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/agent_driver/src/mcp_server.dart';
import '../../tool/agent_driver/src/tools.dart';
import 'fake_app.dart';

void main() {
  late List<Map<String, Object?>> sent;
  late McpServer server;
  late FakeApp app;

  setUp(() {
    sent = <Map<String, Object?>>[];
    app = FakeApp();
    server = McpServer(
      AgentTools(app, shotsDir: '_scratch/test_agent_driver/unused'),
      send: (String line) => sent.add(jsonDecode(line) as Map<String, Object?>),
    );
  });

  Future<Map<String, Object?>> request(
    int id,
    String method, [
    Map<String, Object?>? params,
  ]) async {
    await server.handleLine(
      jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': ?params,
      }),
    );
    return sent.lastWhere((Map<String, Object?> m) => m['id'] == id);
  }

  test(
    'initialize returns the tools capability and echoes the version',
    () async {
      final Map<String, Object?> r = await request(
        1,
        'initialize',
        <String, Object?>{
          'protocolVersion': '2025-03-26',
          'capabilities': <String, Object?>{},
          'clientInfo': <String, Object?>{'name': 't', 'version': '1'},
        },
      );
      final Map<String, Object?> result = r['result']! as Map<String, Object?>;
      expect(result['protocolVersion'], '2025-03-26');
      expect(
        (result['capabilities']! as Map<String, Object?>)['tools'],
        isNotNull,
      );
      expect(
        (result['serverInfo']! as Map<String, Object?>)['name'],
        serverName,
      );
    },
  );

  test('notifications get no answer', () async {
    await server.handleLine(
      jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'method': 'notifications/initialized',
      }),
    );
    expect(sent, isEmpty);
  });

  test('tools/list lists the tools', () async {
    final Map<String, Object?> r = await request(2, 'tools/list');
    final List<Object?> tools =
        (r['result']! as Map<String, Object?>)['tools']! as List<Object?>;
    expect(tools.length, toolDefinitions.length);
  });

  test('tools/call runs the tool and returns MCP content', () async {
    final Map<String, Object?> r = await request(
      3,
      'tools/call',
      <String, Object?>{
        'name': 'tap',
        'arguments': <String, Object?>{'by': 'tooltip', 'value': 'Settings'},
      },
    );
    final Map<String, Object?> result = r['result']! as Map<String, Object?>;
    expect(result['isError'], isFalse);
    expect((result['content']! as List<Object?>).isNotEmpty, isTrue);
    expect(app.driverCalls.single['value'], 'Settings');
  });

  test(
    'a failing tool is a result with isError, not a protocol error',
    () async {
      final Map<String, Object?> r = await request(
        4,
        'tools/call',
        <String, Object?>{
          'name': 'tap',
          'arguments': <String, Object?>{'by': 'bogus', 'value': 'x'},
        },
      );
      expect(r['error'], isNull);
      expect((r['result']! as Map<String, Object?>)['isError'], isTrue);
    },
  );

  test('unknown methods and bad JSON give JSON-RPC errors', () async {
    final Map<String, Object?> r = await request(5, 'resources/list');
    expect((r['error']! as Map<String, Object?>)['code'], -32601);
    await server.handleLine('{not json');
    expect((sent.last['error']! as Map<String, Object?>)['code'], -32700);
  });

  test('calls run one after the other, in order', () async {
    final List<Future<void>> futures = <Future<void>>[
      for (int i = 0; i < 5; i++)
        server.handleLine(
          jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'id': 100 + i,
            'method': 'tools/call',
            'params': <String, Object?>{
              'name': 'tap',
              'arguments': <String, Object?>{'by': 'text', 'value': 'b$i'},
            },
          }),
        ),
    ];
    await Future.wait(futures);
    expect(app.driverCalls.map((Map<String, String> c) => c['value']), <String>[
      'b0',
      'b1',
      'b2',
      'b3',
      'b4',
    ]);
    expect(sent.map((Map<String, Object?> m) => m['id']), <int>[
      100,
      101,
      102,
      103,
      104,
    ]);
  });
}
