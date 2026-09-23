// dart_rfb's socket read loop (Agents fork): drains buffered bytes at once,
// does NOT busy-spin while waiting for the next chunk, and gives up after a
// deadline instead of hanging forever.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_rfb/src/extensions/raw_socket_extensions.dart';
import 'package:flutter_test/flutter_test.dart';

Future<(RawSocket, Socket)> _pair() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final accepted = server.first;
  final client = await RawSocket.connect(InternetAddress.loopbackIPv4, server.port);
  final serverSide = await accepted;
  await server.close();
  return (client, serverSide);
}

void main() {
  test('a read spanning two chunks completes, and timers keep firing meanwhile',
      () async {
    final (client, server) = await _pair();
    server.add(List<int>.filled(10, 1));
    await server.flush();
    // The second half arrives 250 ms later. A busy-spin on the microtask
    // queue would starve timers; count how often a 10 ms timer gets to run.
    var ticks = 0;
    final ticker = Timer.periodic(const Duration(milliseconds: 10), (_) => ticks++);
    Timer(const Duration(milliseconds: 250), () {
      server.add(List<int>.filled(10, 2)); // Socket writes eagerly; no flush
    });
    final data = await client.readSync(length: 20).run();
    ticker.cancel();
    expect(data.lengthInBytes, 20);
    expect(Uint8List.sublistView(data).sublist(10), List<int>.filled(10, 2));
    expect(ticks, greaterThan(5), reason: 'timers starved: the read busy-spun');
    client.close();
    await server.close();
  });

  test('already-buffered bytes are returned without sleeping', () async {
    final (client, server) = await _pair();
    server.add(List<int>.generate(64, (i) => i));
    await server.flush();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final sw = Stopwatch()..start();
    final data = await client.readSync(length: 64).run();
    sw.stop();
    expect(data.lengthInBytes, 64);
    expect(sw.elapsedMilliseconds, lessThan(50));
    client.close();
    await server.close();
  });

  test('a stalled read gives up after the deadline', () async {
    final (client, server) = await _pair();
    server.add(<int>[1, 2, 3]);
    await server.flush();
    await expectLater(
      client
          .readSync(length: 10, deadline: const Duration(milliseconds: 300))
          .run(),
      throwsA(isA<TimeoutException>()),
    );
    client.close();
    await server.close();
  });
}
