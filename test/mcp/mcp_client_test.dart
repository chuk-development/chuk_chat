// The MCP transport, against a server that is only a function.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:chuk_chat/services/mcp/mcp_client.dart';

http.Response _json(Object body, {Map<String, String> headers = const {}}) =>
    http.Response(jsonEncode(body), 200, headers: {
      'content-type': 'application/json',
      ...headers,
    });

void main() {
  final endpoint = Uri.parse('https://mcp.example.com/mcp');

  test('initialize reports what the server calls itself', () async {
    final client = McpClient(
      endpoint: endpoint,
      httpClient: MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        if (body['method'] == 'notifications/initialized') {
          return http.Response('', 202);
        }
        expect(request.headers['accept'], contains('text/event-stream'));
        return _json({
          'jsonrpc': '2.0',
          'id': body['id'],
          'result': {
            'protocolVersion': '2025-06-18',
            'serverInfo': {'name': 'example', 'title': 'Example'},
          },
        }, headers: {'mcp-session-id': 'abc123'});
      }),
    );

    final info = await client.initialize();
    expect(info.displayName, 'Example');
    expect(client.sessionId, 'abc123');
  });

  test('the session id comes back on every later request', () async {
    final sessions = <String?>[];
    final client = McpClient(
      endpoint: endpoint,
      httpClient: MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        sessions.add(request.headers['mcp-session-id']);
        if (body['method'] == 'notifications/initialized') {
          return http.Response('', 202);
        }
        return _json({
          'jsonrpc': '2.0',
          'id': body['id'],
          'result': body['method'] == 'initialize'
              ? {'serverInfo': <String, dynamic>{}}
              : {'tools': <dynamic>[]},
        }, headers: {'mcp-session-id': 's-1'});
      }),
    );

    await client.initialize();
    await client.listTools();
    expect(sessions.first, isNull);
    expect(sessions.last, 's-1');
  });

  test('a reply that arrives as an event stream is read', () async {
    final client = McpClient(
      endpoint: endpoint,
      httpClient: MockClient((request) async {
        final id = (jsonDecode(request.body) as Map)['id'];
        final payload = jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'result': {
            'tools': [
              {
                'name': 'search',
                'description': 'Search things',
                'inputSchema': {
                  'type': 'object',
                  'properties': {
                    'q': {'type': 'string'},
                  },
                },
              },
            ],
          },
        });
        // A progress notification first, then the answer — the shape a real
        // server streams.
        return http.Response(
          'event: message\n'
          'data: ${jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/progress'})}\n'
          '\n'
          'data: $payload\n'
          '\n',
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }),
    );

    final tools = await client.listTools();
    expect(tools, hasLength(1));
    expect(tools.single.name, 'search');
    expect(tools.single.inputSchema['properties'], isA<Map>());
  });

  test('tools/list follows the cursor to the end', () async {
    var calls = 0;
    final client = McpClient(
      endpoint: endpoint,
      httpClient: MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        calls++;
        final first = (body['params'] as Map)['cursor'] == null;
        return _json({
          'jsonrpc': '2.0',
          'id': body['id'],
          'result': {
            'tools': [
              {'name': first ? 'a' : 'b', 'description': ''},
            ],
            if (first) 'nextCursor': 'page-2',
          },
        });
      }),
    );

    final tools = await client.listTools();
    expect(calls, 2);
    expect(tools.map((t) => t.name), ['a', 'b']);
  });

  test('a 401 is an invitation to sign in, not a failure', () async {
    final client = McpClient(
      endpoint: endpoint,
      httpClient: MockClient(
        (_) async => http.Response('', 401, headers: {
          'www-authenticate':
              'Bearer resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource"',
        }),
      ),
    );

    await expectLater(
      client.initialize(),
      throwsA(
        isA<McpUnauthorized>().having(
          (e) => e.wwwAuthenticate,
          'challenge',
          contains('resource_metadata'),
        ),
      ),
    );
  });

  test('a tool result is flattened to the text a model can read', () async {
    final client = McpClient(
      endpoint: endpoint,
      httpClient: MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        return _json({
          'jsonrpc': '2.0',
          'id': body['id'],
          'result': {
            'content': [
              {'type': 'text', 'text': 'first'},
              {'type': 'image', 'data': '…'},
              {'type': 'resource_link', 'name': 'doc', 'uri': 'https://x/1'},
            ],
          },
        });
      }),
    );

    final result = await client.callTool('search', {'q': 'x'});
    expect(result.isError, isFalse);
    expect(result.text, contains('first'));
    expect(result.text, contains('[image returned by the tool]'));
    expect(result.text, contains('https://x/1'));
  });

  test('an error from the server surfaces as an exception', () async {
    final client = McpClient(
      endpoint: endpoint,
      httpClient: MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        return _json({
          'jsonrpc': '2.0',
          'id': body['id'],
          'error': {'code': -32602, 'message': 'Unknown tool'},
        });
      }),
    );

    await expectLater(
      client.callTool('nope', const {}),
      throwsA(isA<McpException>()),
    );
  });
}
