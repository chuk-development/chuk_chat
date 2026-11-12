// Plane CHAT-33: the app notices a dead relay link by itself.
//
// Real sockets, no fakes. A dart:io WebSocket server stands in for the relay,
// and a TCP proxy the test controls sits in between. The proxy can make the
// path silent without closing anything: no FIN, no RST. That is what a phone
// that changed networks, or a laptop that slept, looks like to the app. A
// plain socket never errors in that state; only the WebSocket ping can see it.
//
// The production connector (`connectWebSocket`, lib/services/
// websocket_connector_io.dart) sets a 20 s ping interval on every `wss://`
// relay socket. These tests use the same dart:io mechanism with a short
// interval, so they run in about a second.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/io.dart';

/// Forwards TCP to [upstreamPort]. [blackHole] makes every open connection
/// silent for good, with its sockets left open.
class _BlackHoleProxy {
  _BlackHoleProxy._(this._server, this.upstreamPort);

  final ServerSocket _server;
  final int upstreamPort;
  bool _silent = false;
  final List<Socket> _sockets = <Socket>[];

  int get port => _server.port;

  static Future<_BlackHoleProxy> start(int upstreamPort) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = _BlackHoleProxy._(server, upstreamPort);
    server.listen(proxy._accept);
    return proxy;
  }

  Future<void> _accept(Socket client) async {
    final upstream = await Socket.connect(
      InternetAddress.loopbackIPv4,
      upstreamPort,
    );
    _sockets
      ..add(client)
      ..add(upstream);
    client.listen((data) {
      if (!_silent) upstream.add(data);
    }, onError: (Object _) {});
    upstream.listen((data) {
      if (!_silent) client.add(data);
    }, onError: (Object _) {});
  }

  void blackHole() => _silent = true;

  Future<void> close() async {
    for (final s in _sockets) {
      s.destroy();
    }
    await _server.close();
  }
}

/// A relay stand-in: accepts WebSocket upgrades and echoes. dart:io answers
/// protocol pings with pongs by itself, like the real relay.
Future<HttpServer> _relay() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final ws = await WebSocketTransformer.upgrade(request);
    ws.listen(ws.add, onError: (Object _) {});
  });
  return server;
}

void main() {
  test('a silent link is closed by the ping and the stream ends', () async {
    final relay = await _relay();
    final proxy = await _BlackHoleProxy.start(relay.port);
    addTearDown(() async {
      await proxy.close();
      await relay.close(force: true);
    });

    const ping = Duration(milliseconds: 300);
    final channel = IOWebSocketChannel.connect(
      Uri.parse('ws://127.0.0.1:${proxy.port}'),
      pingInterval: ping,
    );
    await channel.ready;

    // The link works.
    final echoes = <dynamic>[];
    final done = Completer<void>();
    channel.stream.listen(
      echoes.add,
      onDone: done.complete,
      onError: (Object _) {},
    );
    channel.sink.add('hello');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(echoes, <dynamic>['hello']);

    // The path goes silent.
    final cut = DateTime.now();
    proxy.blackHole();

    // The stream must end on its own: that `done` is what moves the relay
    // client to `closed` and starts the thread view's backoff reconnect.
    await done.future.timeout(
      ping * 10,
      onTimeout: () => fail('a silent link was never noticed'),
    );
    final noticed = DateTime.now().difference(cut);
    // dart:io closes when a pong is missing one interval after its ping.
    expect(noticed, lessThan(ping * 4));
    // ignore: avoid_print
    print(
      '[CHAT-33] silent link noticed after ${noticed.inMilliseconds} ms '
      '(ping interval ${ping.inMilliseconds} ms)',
    );
  });

  test('without a ping interval the same silent link stays "open"', () async {
    // The control case: why the ping interval is load-bearing.
    final relay = await _relay();
    final proxy = await _BlackHoleProxy.start(relay.port);
    addTearDown(() async {
      await proxy.close();
      await relay.close(force: true);
    });

    final channel = IOWebSocketChannel.connect(
      Uri.parse('ws://127.0.0.1:${proxy.port}'),
    );
    await channel.ready;
    var ended = false;
    channel.stream.listen(
      (_) {},
      onDone: () => ended = true,
      onError: (Object _) {},
    );
    proxy.blackHole();
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(ended, isFalse);
    await channel.sink.close().timeout(
      const Duration(milliseconds: 100),
      onTimeout: () {},
    );
  });
}
