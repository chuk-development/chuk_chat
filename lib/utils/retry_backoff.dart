// lib/utils/retry_backoff.dart
//
// Delay before the next reconnect attempt of a streaming pass.
import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

/// First delay of the reconnect backoff.
const Duration kReconnectBackoffBase = Duration(milliseconds: 700);

/// No reconnect waits longer than this, jitter included.
const Duration kReconnectBackoffCap = Duration(seconds: 8);

/// The jitter is this fraction of the delay, up or down.
const double kReconnectBackoffJitter = 0.10;

final Random _random = Random();

/// The wait before reconnect attempt [attempt] (0 for the first retry):
/// `700 ms * 2^attempt`, moved by up to ±10 % at random, never above
/// [kReconnectBackoffCap]. Without jitter every client that lost the same
/// server came back at the same instant.
///
/// [random] is for tests.
Duration reconnectBackoff(int attempt, {Random? random}) {
  final int safeAttempt = attempt.clamp(0, 20);
  final double base =
      kReconnectBackoffBase.inMilliseconds * pow(2, safeAttempt).toDouble();
  final double jitter =
      ((random ?? _random).nextDouble() * 2 - 1) * kReconnectBackoffJitter;
  final double ms = min(
    base * (1 + jitter),
    kReconnectBackoffCap.inMilliseconds.toDouble(),
  );
  return Duration(milliseconds: ms.round());
}

/// Waits [delay], or less: the wait ends at once when [online] turns true
/// (the network came back). A reconnect then does not sit out the rest of an
/// 8 s backoff after the phone found its signal again.
Future<void> waitBeforeReconnect(
  Duration delay, {
  ValueListenable<bool>? online,
}) {
  final Completer<void> done = Completer<void>();
  final bool wasOnline = online?.value ?? true;
  void finish() {
    if (!done.isCompleted) done.complete();
  }

  final Timer timer = Timer(delay, finish);
  void onChange() {
    // Only a change to online ends the wait early; the status saying
    // "online" the whole time says nothing new.
    if ((online?.value ?? false) && !wasOnline) finish();
  }

  online?.addListener(onChange);
  return done.future.whenComplete(() {
    timer.cancel();
    online?.removeListener(onChange);
  });
}
