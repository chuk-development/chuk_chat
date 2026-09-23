// Live probe (not a unit test — no `_test.dart` suffix): drives the REAL
// dart_rfb client against a REAL x11vnc that was armed with a per-view secret
// (§10.12), through a host-side socat mirror of the container's RFB port.
//
//   cd app && dart run test/vnc/live_auth_probe.dart <port> <secret>
//
// Proves three things in one run: the client authenticates with the secret and
// receives a framebuffer update (Tight rects decoded, count printed); a wrong
// secret is rejected by the server; no secret is rejected by the client because
// the server offers VNC auth only. Exit 0 only if all three hold.
import 'dart:async';
import 'dart:io';

import 'package:dart_rfb/dart_rfb.dart';

Future<String> attempt(int port, String? password) async {
  final client = RemoteFrameBufferClient();
  try {
    await client.connect(hostname: '127.0.0.1', port: port, password: password);
    final first = Completer<RemoteFrameBufferClientUpdate>();
    final sub = client.updateStream.listen((u) {
      if (!first.isCompleted) first.complete(u);
    });
    client
      ..handleIncomingMessages()
      ..requestUpdate();
    final update = await first.future.timeout(const Duration(seconds: 10));
    await sub.cancel();
    return 'OK: ${update.rectangles.length} rectangles';
  } catch (e) {
    return 'REJECTED: ${e.toString().split('\n').first}';
  } finally {
    try {
      await client.close();
    } catch (_) {}
  }
}

Future<void> main(List<String> args) async {
  final port = int.parse(args[0]);
  final secret = args[1];
  final withSecret = await attempt(port, secret);
  final wrongSecret = await attempt(port, 'nope1234');
  final noSecret = await attempt(port, null);
  stdout.writeln('with secret : $withSecret');
  stdout.writeln('wrong secret: $wrongSecret');
  stdout.writeln('no secret   : $noSecret');
  final ok = withSecret.startsWith('OK') &&
      wrongSecret.startsWith('REJECTED') &&
      noSecret.startsWith('REJECTED');
  stdout.writeln(ok ? 'AUTH CHAIN: PASS' : 'AUTH CHAIN: FAIL');
  exit(ok ? 0 : 1);
}
