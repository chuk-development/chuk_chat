/// How long a failed attempt waits before the next one.
///
/// Ported from `chuk_chat/lib/utils/exponential_backoff.dart`, but only the
/// part CoWork needs: the delay curve. Upstream's `ExponentialBackoff.execute`
/// drives a retry LOOP around an operation; the outbox does not want that. An
/// outbox entry is retried by an outside trigger — a pairing, an app resume,
/// the Retry button — so all this has to answer is "is this entry due yet".
///
/// Without it every trigger would re-send every queued prompt at once: a
/// watchdog tick every 8 s, a resume, and a reconnect all land within a second
/// of each other, and a host that just refused a prompt gets it three more
/// times before it can say no again.
library;

import 'dart:math' as math;

/// The delay curve for one kind of work.
class CoworkBackoff {
  const CoworkBackoff({
    this.maxAttempts = 3,
    this.initialDelay = const Duration(milliseconds: 500),
    this.maxDelay = const Duration(seconds: 10),
    this.multiplier = 2.0,
    this.jitter = 0.1,
  });

  /// What a chat send waits: upstream's `BackoffConfig.chat`, 500 ms to 10 s.
  static const CoworkBackoff chat = CoworkBackoff();

  /// How many attempts the curve is drawn for. The outbox keeps its own,
  /// higher give-up cap ([CoworkTaskOutbox.maxAttempts]); this is the point
  /// where the delay stops growing in practice.
  final int maxAttempts;
  final Duration initialDelay;
  final Duration maxDelay;
  final double multiplier;

  /// Fraction of the delay spent on random spread, so two threads that failed
  /// on the same dropped socket do not come back in the same millisecond.
  final double jitter;

  /// The wait after [attempt] failures. `attempt` is 1-based: 1 is the first
  /// failure, and it waits [initialDelay].
  ///
  /// Pass [random] to make the jitter reproducible in a test.
  Duration delayAfter(int attempt, {math.Random? random}) {
    if (attempt < 1) return Duration.zero;
    final double raw =
        initialDelay.inMilliseconds *
        math.pow(multiplier, attempt - 1).toDouble();
    final double capped = math.min(raw, maxDelay.inMilliseconds.toDouble());
    if (jitter <= 0) return Duration(milliseconds: capped.round());
    final math.Random rng = random ?? math.Random();
    final double spread = capped * jitter;
    final double withJitter = capped + (rng.nextDouble() * 2 - 1) * spread;
    return Duration(milliseconds: withJitter.clamp(0, double.infinity).round());
  }
}
