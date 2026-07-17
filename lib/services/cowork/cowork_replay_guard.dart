import 'package:chuk_chat/services/cowork/cowork_frame.dart';

/// Replay protection for one peer device: a strictly monotonic `seq` inside a
/// `ts` freshness window.
///
/// The two checks cover each other. `seq` alone would let a hostile relay bank
/// a frame forever and replay it into the *next* session, where the counter has
/// reset. `ts` alone would let it replay freely inside the window. Together, a
/// relay that records every frame can still only drop, delay or reorder — a
/// bounded DoS, not forgery.
///
/// State is deliberately in-memory and injectable ([lastSeq] in, [lastSeq] out)
/// so the guard stays pure and storage-agnostic: the laptop daemon persists the
/// counter to its SQLite `kv_cache`, tests hold it in a field, and neither
/// concern leaks into this class.
class CoworkReplayGuard {
  CoworkReplayGuard({
    this.window = const Duration(seconds: 60),
    DateTime Function()? clock,
    int? lastSeq,
  }) : _clock = clock ?? DateTime.now,
       _lastSeq = lastSeq;

  /// How far `ts` may sit from local time in either direction.
  ///
  /// Symmetric on purpose: rejecting only the past would let an attacker with a
  /// skewed clock bank far-future frames to replay later.
  final Duration window;

  final DateTime Function() _clock;

  int? _lastSeq;

  /// Highest `seq` accepted so far, or null if nothing has been accepted yet.
  /// Persist this to survive a daemon restart; pass it back via `lastSeq`.
  int? get lastSeq => _lastSeq;

  /// Validates [frame]'s freshness without changing any state, or throws
  /// [CoworkFrameRejectedException].
  ///
  /// Call this only **after** the signature verifies — there is no point
  /// spending clock checks on bytes anybody could have written.
  void check(CoworkFrame frame) {
    _checkTimestamp(frame);
    _checkSeq(frame);
  }

  /// Burns [frame]'s sequence number, or throws if it is no longer ahead.
  ///
  /// Call this only once the frame has been fully authenticated *and*
  /// decrypted. Split from [check] so that only frames actually delivered to
  /// the executor advance the counter: a frame that fails GCM authentication
  /// was never delivered, so it must not consume a sequence number.
  ///
  /// Both admission conditions are re-validated here rather than trusted from
  /// [check]. [check] and [commit] straddle an `await` (the decryption), and
  /// that gap matters twice over:
  ///
  ///  * **seq** — two frames opened concurrently can both pass [check] before
  ///    either commits; without this second look the loser is delivered twice.
  ///  * **ts** — a frame can pass [check] just inside the window and only reach
  ///    [commit] after it has expired, which would deliver a stale frame.
  ///
  /// Re-checking makes the pair safe under concurrency without a lock.
  void commit(CoworkFrame frame) {
    _checkTimestamp(frame);
    _checkSeq(frame);
    _lastSeq = frame.seq;
  }

  void _checkTimestamp(CoworkFrame frame) {
    final skew = _clock().toUtc().millisecondsSinceEpoch - frame.ts;
    if (skew.abs() > window.inMilliseconds) {
      throw const CoworkFrameRejectedException(
        CoworkFrameRejection.timestampOutOfWindow,
      );
    }
  }

  void _checkSeq(CoworkFrame frame) {
    final last = _lastSeq;
    if (last != null && frame.seq <= last) {
      throw const CoworkFrameRejectedException(
        CoworkFrameRejection.replayedSequence,
      );
    }
  }
}
