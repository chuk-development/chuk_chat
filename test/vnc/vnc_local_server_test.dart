import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:cowork/widgets/vnc_local_server.dart';

/// The loopback server behind the noVNC viewer.
///
/// It carries the agent's screen in one direction and the user's keystrokes in
/// the other, on a port every other app on the phone can reach. So the tests
/// that matter are the ones about who gets in.
void main() {
  late VncLocalServer server;
  late List<String> asked;

  Future<Uint8List> fakeAsset(String key) async {
    asked.add(key);
    if (key == 'assets/vnc/viewer.html') {
      return Uint8List.fromList(utf8.encode('<!DOCTYPE html><body></body>'));
    }
    if (key == 'assets/novnc/core/rfb.js') {
      return Uint8List.fromList(utf8.encode('export default class RFB {}'));
    }
    throw Exception('no such asset: $key');
  }

  setUp(() async {
    asked = <String>[];
    server = await VncLocalServer.start(readAsset: fakeAsset);
  });

  tearDown(() async {
    await server.close();
  });

  String origin() => 'http://127.0.0.1:${server.port}';
  String socketUrl(String token) => 'ws://127.0.0.1:${server.port}/$token/rfb';

  Future<HttpClientResponse> fetch(String path) async {
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest request =
          await client.getUrl(Uri.parse('http://127.0.0.1:${server.port}$path'));
      return await request.close();
    } finally {
      client.close(force: true);
    }
  }

  Future<WebSocket> connect({String? token, String? withOrigin}) {
    return WebSocket.connect(
      socketUrl(token ?? server.token),
      headers: <String, dynamic>{'Origin': withOrigin ?? origin()},
    );
  }

  group('the token', () {
    test('is long enough to be unguessable and is not reused', () async {
      final VncLocalServer other =
          await VncLocalServer.start(readAsset: fakeAsset);
      addTearDown(other.close);
      // 32 bytes, base64url, padding stripped.
      expect(server.token.length, 43);
      expect(server.token, isNot(other.token));
    });

    test('gates the WebSocket', () async {
      await expectLater(
        connect(token: 'not-the-token'),
        throwsA(isA<WebSocketException>()),
      );
      // The real one still works afterwards, so a refusal costs nothing.
      final WebSocket socket = await connect();
      addTearDown(socket.close);
      expect(socket.readyState, WebSocket.open);
    });

    test('gates every asset, and a wrong one looks like a missing file',
        () async {
      final HttpClientResponse wrong =
          await fetch('/not-the-token/vnc/viewer.html');
      expect(wrong.statusCode, HttpStatus.notFound);
      // Nothing was even read from the bundle.
      expect(asked, isEmpty);

      final HttpClientResponse right =
          await fetch('/${server.token}/vnc/viewer.html');
      expect(right.statusCode, HttpStatus.ok);
      expect(asked, <String>['assets/vnc/viewer.html']);
    });
  });

  group('the WebSocket', () {
    test('refuses an upgrade from any other origin', () async {
      await expectLater(
        connect(withOrigin: 'https://evil.example'),
        throwsA(isA<WebSocketException>()),
      );
    });

    test('refuses a second connection while the first is live', () async {
      final WebSocket first = await connect();
      addTearDown(first.close);
      await expectLater(connect(), throwsA(isA<WebSocketException>()));
      // The first is untouched: a refusal must not be a way to knock the
      // viewer off its own socket.
      expect(first.readyState, WebSocket.open);
    });

    test('reopens the slot after the page drops, so it can reconnect',
        () async {
      final WebSocket first = await connect();
      await first.close();
      // The close has to land on the server side before the slot is free.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final WebSocket second = await connect();
      addTearDown(second.close);
      expect(second.readyState, WebSocket.open);
    });

    test('carries bytes from the tunnel to the page', () async {
      final WebSocket socket = await connect();
      addTearDown(socket.close);
      final Future<List<Object?>> received = socket.take(2).toList();
      server.send(Uint8List.fromList(<int>[82, 70, 66, 32, 48, 48, 51]));
      server.send(Uint8List.fromList(<int>[1, 2, 3]));
      final List<Object?> messages = await received;
      expect(messages.first, <int>[82, 70, 66, 32, 48, 48, 51]);
      expect(messages.last, <int>[1, 2, 3]);
    });

    test('holds server bytes until the page dials in', () async {
      // x11vnc speaks first, so its greeting can beat the WebView's load.
      server.send(Uint8List.fromList(<int>[82, 70, 66]));
      expect(server.hasClient, isFalse);
      final WebSocket socket = await connect();
      addTearDown(socket.close);
      expect(await socket.first, <int>[82, 70, 66]);
    });

    test('carries bytes from the page back to the tunnel', () async {
      final WebSocket socket = await connect();
      addTearDown(socket.close);
      final Future<Uint8List> first = server.fromPage.first;
      socket.add(<int>[5, 6, 7]);
      expect(await first, <int>[5, 6, 7]);
    });

    test('drops a text frame instead of forwarding it as RFB', () async {
      final WebSocket socket = await connect();
      addTearDown(socket.close);
      final List<Uint8List> seen = <Uint8List>[];
      final StreamSubscription<Uint8List> sub = server.fromPage.listen(seen.add);
      addTearDown(sub.cancel);
      socket.add('hello');
      socket.add(<int>[9]);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(seen, <List<int>>[
        <int>[9]
      ]);
    });
  });

  group('the asset routes', () {
    test('serve JavaScript as JavaScript, or the modules will not run',
        () async {
      final HttpClientResponse response =
          await fetch('/${server.token}/novnc/core/rfb.js');
      expect(response.statusCode, HttpStatus.ok);
      expect(response.headers.contentType?.mimeType, 'text/javascript');
    });

    test('refuse a path that walks out of the viewer', () async {
      final HttpClientResponse response =
          await fetch('/${server.token}/vnc/..%2F..%2Fsecrets.txt');
      expect(response.statusCode, HttpStatus.notFound);
      expect(asked, isEmpty);
    });

    test('refuse a root that is not the viewer or the library', () async {
      final HttpClientResponse response =
          await fetch('/${server.token}/fonts/Arimo-wght.ttf');
      expect(response.statusCode, HttpStatus.notFound);
      expect(asked, isEmpty);
    });

    test('forbid the page reaching anything but itself', () async {
      final HttpClientResponse response =
          await fetch('/${server.token}/vnc/viewer.html');
      final String? policy =
          response.headers.value('content-security-policy');
      expect(policy, isNotNull);
      expect(policy, contains("default-src 'none'"));
      expect(policy, contains("frame-ancestors 'none'"));
      expect(policy, contains('ws://127.0.0.1:${server.port}'));
      // The URL carries the token, so it must not travel with a navigation.
      expect(response.headers.value('referrer-policy'), 'no-referrer');
    });
  });

  group('the viewer URL', () {
    test('points the page at this server and at its own socket', () {
      final Uri url = server.viewerUrl;
      expect(url.host, '127.0.0.1');
      expect(url.port, server.port);
      expect(url.path, '/${server.token}/vnc/viewer.html');
      expect(url.queryParameters['ws'], socketUrl(server.token));
    });
  });

  group('a lost page', () {
    test('asks for a fresh executor stream, because the tunnel is stranded',
        () async {
      int restarts = 0;
      final VncLocalServer restarting = await VncLocalServer.start(
        readAsset: fakeAsset,
        onStreamRestartNeeded: () async => restarts++,
      );
      addTearDown(restarting.close);
      final WebSocket socket = await WebSocket.connect(
        'ws://127.0.0.1:${restarting.port}/${restarting.token}/rfb',
        headers: <String, dynamic>{
          'Origin': 'http://127.0.0.1:${restarting.port}',
        },
      );
      restarting.send(Uint8List.fromList(<int>[82, 70, 66]));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await socket.close();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(restarts, 1);
    });

    test('is not asked for when the EXECUTOR was the one that restarted',
        () async {
      // resetStream is the executor's own recovery landing: a fresh RFB
      // session is already on its way, so asking for another restart would
      // throw that one away.
      int restarts = 0;
      final VncLocalServer executorSide = await VncLocalServer.start(
        readAsset: fakeAsset,
        onStreamRestartNeeded: () async => restarts++,
      );
      addTearDown(executorSide.close);
      final WebSocket socket = await WebSocket.connect(
        'ws://127.0.0.1:${executorSide.port}/${executorSide.token}/rfb',
        headers: <String, dynamic>{
          'Origin': 'http://127.0.0.1:${executorSide.port}',
        },
      );
      // The page that was reading the dead session must be let go. Its own
      // reader stands in for noVNC's, and the done it reports is the proof.
      final Completer<void> oldPageGone = Completer<void>();
      socket.listen(
        (Object? _) {},
        onError: (Object _) {},
        onDone: () {
          if (!oldPageGone.isCompleted) oldPageGone.complete();
        },
      );
      executorSide.send(Uint8List.fromList(<int>[82, 70, 66]));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      executorSide.resetStream();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(restarts, 0, reason: 'the executor already restarted');
      expect(executorSide.hasClient, isFalse, reason: 'the page must redial');

      // The stale tail of the dead session is gone, and the page can dial
      // back in for a clean handshake.
      final WebSocket again = await WebSocket.connect(
        'ws://127.0.0.1:${executorSide.port}/${executorSide.token}/rfb',
        headers: <String, dynamic>{
          'Origin': 'http://127.0.0.1:${executorSide.port}',
        },
      );
      addTearDown(again.close);
      final Future<Object?> first = again.first;
      executorSide.send(Uint8List.fromList(<int>[1, 2, 3]));
      expect(await first, <int>[1, 2, 3]);
      await expectLater(
        oldPageGone.future.timeout(const Duration(seconds: 2)),
        completes,
      );
    });

    test('does not ask when no byte ever flowed', () async {
      int restarts = 0;
      final VncLocalServer quiet = await VncLocalServer.start(
        readAsset: fakeAsset,
        onStreamRestartNeeded: () async => restarts++,
      );
      addTearDown(quiet.close);
      final WebSocket socket = await WebSocket.connect(
        'ws://127.0.0.1:${quiet.port}/${quiet.token}/rfb',
        headers: <String, dynamic>{
          'Origin': 'http://127.0.0.1:${quiet.port}',
        },
      );
      await socket.close();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(restarts, 0);
    });
  });
}
