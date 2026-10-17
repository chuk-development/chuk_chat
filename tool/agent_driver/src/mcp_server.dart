// A small MCP server over stdio (JSON-RPC 2.0, one message per line).
//
// It implements the parts of the protocol that a tool server needs:
// initialize, ping, tools/list and tools/call. stdout carries only protocol
// messages. Logs go to stderr.

import 'dart:async';
import 'dart:convert';

import 'tools.dart';

const String serverName = 'chuk-agent-driver';
const String serverVersion = '1.0.0';
const String _defaultProtocol = '2025-06-18';

class McpServer {
  McpServer(this.tools, {required this.send, this.log});

  final AgentTools tools;

  /// Writes one protocol line.
  final void Function(String line) send;

  final void Function(String line)? log;

  /// Calls run one after the other: the app has one UI, and two parallel
  /// taps would race.
  Future<void> _queue = Future<void>.value();

  /// Handles one input line. Returns when the answer for it is sent.
  Future<void> handleLine(String line) {
    final String t = line.trim();
    if (t.isEmpty) return Future<void>.value();
    final Completer<void> done = Completer<void>();
    _queue = _queue.then((_) async {
      try {
        await _handle(t);
      } catch (e) {
        // Never let one bad request break the queue: a failed future here
        // would stop every later request.
        log?.call('internal error: $e');
        _error(_idOf(t), -32603, 'Internal error: $e');
      } finally {
        done.complete();
      }
    });
    return done.future;
  }

  Future<void> _handle(String t) async {
    Object? msg;
    try {
      msg = jsonDecode(t);
    } on FormatException {
      _error(null, -32700, 'Parse error');
      return;
    }
    if (msg is! Map) {
      _error(null, -32600, 'Invalid request');
      return;
    }
    final Object? id = msg['id'];
    final Object? method = msg['method'];
    if (method is! String) {
      // A response from the client, for example to a ping. Nothing to do.
      return;
    }
    final Map<String, Object?> params = msg['params'] is Map
        ? (msg['params'] as Map).cast<String, Object?>()
        : <String, Object?>{};
    final bool isNotification = !msg.containsKey('id');

    switch (method) {
      case 'initialize':
        final Object? asked = params['protocolVersion'];
        _result(id, <String, Object?>{
          'protocolVersion': asked is String ? asked : _defaultProtocol,
          'capabilities': <String, Object?>{
            'tools': <String, Object?>{'listChanged': false},
          },
          'serverInfo': <String, Object?>{
            'name': serverName,
            'version': serverVersion,
          },
          'instructions':
              'Drives the chuk_chat Linux app against the local E2E stack. '
              'Call app_start first. Find widgets with read_state, act with '
              'tap / enter_text / tap_at, and check every step with '
              'screenshot. Call app_stop at the end. See docs/AGENT_DRIVER.md.',
        });
      case 'ping':
        _result(id, <String, Object?>{});
      case 'tools/list':
        _result(id, <String, Object?>{'tools': toolDefinitions});
      case 'tools/call':
        final Object? name = params['name'];
        if (name is! String) {
          _error(id, -32602, 'tools/call needs a tool name');
          return;
        }
        final Map<String, Object?> args = params['arguments'] is Map
            ? (params['arguments'] as Map).cast<String, Object?>()
            : <String, Object?>{};
        log?.call('call $name');
        final ToolResult r = await tools.call(name, args);
        if (r.isError) log?.call('error in $name: ${r.text}');
        _result(id, r.toJson());
      default:
        if (method.startsWith('notifications/') || isNotification) return;
        _error(id, -32601, 'Method not found: $method');
    }
  }

  /// The request id in [line], or null when there is none.
  Object? _idOf(String line) {
    try {
      final Object? msg = jsonDecode(line);
      return msg is Map ? msg['id'] : null;
    } on FormatException {
      return null;
    }
  }

  void _result(Object? id, Map<String, Object?> result) => send(
    jsonEncode(<String, Object?>{'jsonrpc': '2.0', 'id': id, 'result': result}),
  );

  void _error(Object? id, int code, String message) => send(
    jsonEncode(<String, Object?>{
      'jsonrpc': '2.0',
      'id': id,
      'error': <String, Object?>{'code': code, 'message': message},
    }),
  );
}
