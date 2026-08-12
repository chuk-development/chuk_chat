import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/cowork/cowork_demo_server.dart';

/// Connects a raw `dart:io` WebSocket to the running demo server and returns
/// both the socket and a broadcast stream of decoded JSON frames it sends.
Future<(WebSocket, Stream<Map<String, Object?>>)> _connect(Uri httpUri) async {
  final wsUri = httpUri.replace(scheme: 'ws', path: '/');
  final socket = await WebSocket.connect(wsUri.toString());
  final frames = socket
      .cast<String>()
      .map((s) => jsonDecode(s) as Map<String, Object?>)
      .asBroadcastStream();
  return (socket, frames);
}

void main() {
  group('CoworkDemoServer', () {
    late CoworkDemoServer server;
    late Uri uri;

    setUp(() async {
      server = CoworkDemoServer();
      uri = await server.start(port: 0);
    });

    tearDown(() async {
      await server.stop();
    });

    test('binds to loopback only, never a wildcard address', () {
      expect(uri.host, '127.0.0.1');
      expect(uri.scheme, 'http');
      expect(uri.port, greaterThan(0));
      expect(server.isRunning, isTrue);
    });

    test('serves the phone HTML page on GET /', () async {
      final client = HttpClient();
      addTearDown(client.close);
      final req = await client.getUrl(uri);
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      expect(resp.statusCode, HttpStatus.ok);
      expect(body, contains('CoWork Phone'));
      expect(body, contains('WebSocket'));
    });

    test('an inject frame arrives on injectedMessages', () async {
      final (socket, _) = await _connect(uri);
      addTearDown(() => socket.close());

      final injected = server.injectedMessages.first;
      socket.add(jsonEncode({'type': 'inject', 'text': 'build me a widget'}));
      expect(await injected, 'build me a widget');
    });

    test('pushDelta and pushDone reach the connected client', () async {
      final (socket, frames) = await _connect(uri);
      addTearDown(() => socket.close());

      // Give the server time to register the socket.
      await _waitFor(() => server.connectionCount == 1);

      final received = <Map<String, Object?>>[];
      final sub = frames.listen(received.add);
      addTearDown(sub.cancel);

      server.pushDelta('Hel');
      server.pushDelta('lo');
      server.pushToolCall('read_file', 'main.dart');
      server.pushToolResult('read_file', '42 lines');
      server.pushDone();

      await _waitFor(() => received.length >= 5);

      expect(received[0], {'type': 'delta', 'text': 'Hel'});
      expect(received[1], {'type': 'delta', 'text': 'lo'});
      expect(received[2], {'type': 'tool', 'name': 'read_file', 'args': 'main.dart'});
      expect(received[3],
          {'type': 'toolResult', 'name': 'read_file', 'result': '42 lines'});
      expect(received[4], {'type': 'done'});
    });

    test('pushError reaches the client', () async {
      final (socket, frames) = await _connect(uri);
      addTearDown(() => socket.close());
      await _waitFor(() => server.connectionCount == 1);

      final next = frames.first;
      server.pushError('boom');
      expect(await next, {'type': 'error', 'message': 'boom'});
    });

    test('broadcasts to multiple connected phone tabs', () async {
      final (s1, f1) = await _connect(uri);
      final (s2, f2) = await _connect(uri);
      addTearDown(() => s1.close());
      addTearDown(() => s2.close());
      await _waitFor(() => server.connectionCount == 2);

      final n1 = f1.first;
      final n2 = f2.first;
      server.pushDelta('hi');
      expect(await n1, {'type': 'delta', 'text': 'hi'});
      expect(await n2, {'type': 'delta', 'text': 'hi'});
    });

    test('handles disconnect cleanly and keeps serving', () async {
      final (s1, _) = await _connect(uri);
      await _waitFor(() => server.connectionCount == 1);
      await s1.close();
      await _waitFor(() => server.connectionCount == 0);

      // A fresh connection still works after the first one dropped.
      final (s2, f2) = await _connect(uri);
      addTearDown(() => s2.close());
      await _waitFor(() => server.connectionCount == 1);
      final next = f2.first;
      server.pushDelta('again');
      expect(await next, {'type': 'delta', 'text': 'again'});
    });

    test('ignores malformed frames without emitting', () async {
      final (socket, _) = await _connect(uri);
      addTearDown(() => socket.close());

      var emitted = false;
      final sub = server.injectedMessages.listen((_) => emitted = true);
      addTearDown(sub.cancel);

      socket.add('not json at all');
      socket.add(jsonEncode({'type': 'other'}));
      socket.add(jsonEncode({'type': 'inject'})); // no text
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(emitted, isFalse);
    });
  });
}

/// Polls [predicate] until true or a timeout. Avoids fixed sleeps that flake.
Future<void> _waitFor(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
