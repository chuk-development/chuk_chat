import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:fpdart/fpdart.dart';

extension RawSocketExtensions on RawSocket {
  /// Read exactly [length] bytes.
  ///
  /// CoWork fork: upstream spun on `read()` whenever bytes were not there yet
  /// — the `await` on an already-completed future only yields to the microtask
  /// queue, so a wait for the next TCP chunk pegged a core (and, on a phone,
  /// the battery) for as long as the server took. Now: bytes already buffered
  /// are drained with no delay at all (the common case — a Tight rectangle
  /// usually arrives in one chunk), a short microtask spin covers "the rest is
  /// a few µs away", and after that the wait sleeps in small steps so the
  /// event loop (timers, the isolate's message port) keeps running. A read
  /// that makes no progress for [deadline] throws [TimeoutException] instead of
  /// hanging the read loop forever on a server that announced a length and then
  /// went silent.
  ///
  /// [readWaitDuration], when given, is the sleep step (upstream API);
  /// otherwise the step grows from 1 ms to 5 ms while idle.
  Task<ByteData> readSync({
    required final int length,
    final Option<Duration> readWaitDuration = const None<Duration>(),
    final Duration deadline = const Duration(seconds: 30),
  }) =>
      Task<ByteData>(
        () async {
          final BytesBuilder bytesBuilder = BytesBuilder(copy: false);
          int idleRounds = 0;
          DateTime lastProgress = DateTime.now();
          while (bytesBuilder.length < length) {
            final Uint8List? chunk = read(
              min(length, length - bytesBuilder.length),
            );
            if (chunk != null && chunk.isNotEmpty) {
              bytesBuilder.add(chunk);
              idleRounds = 0;
              lastProgress = DateTime.now();
              continue;
            }
            if (DateTime.now().difference(lastProgress) > deadline) {
              throw TimeoutException(
                'socket read stalled: ${bytesBuilder.length}/$length bytes '
                'after $deadline',
              );
            }
            idleRounds++;
            if (idleRounds <= 16) {
              // Cheap spin: the bytes are usually a few microseconds behind.
              await Future<void>.value();
              continue;
            }
            await Future<void>.delayed(
              readWaitDuration.getOrElse(
                () => idleRounds < 256
                    ? const Duration(milliseconds: 1)
                    : const Duration(milliseconds: 5),
              ),
            );
          }
          return ByteData.sublistView(bytesBuilder.toBytes());
        },
      );
}
