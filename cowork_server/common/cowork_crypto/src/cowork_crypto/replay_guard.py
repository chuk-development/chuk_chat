"""Replay protection for one peer device — Python twin of ``CoworkReplayGuard``.

A strictly monotonic ``seq`` inside a ``ts`` freshness window. The two checks
cover each other. ``seq`` alone would let a hostile relay bank a frame forever
and replay it into the next session, where the counter reset. ``ts`` alone would
let it replay freely inside the window. Together, a relay that records every
frame can still only drop, delay or reorder — a bounded DoS, not forgery.

State is deliberately injectable (``last_seq`` in, ``last_seq`` out) so the
guard stays pure and storage-agnostic.

Mirrors ``cowork_replay_guard.dart``.
"""

from __future__ import annotations

import time
from collections.abc import Callable

from .frame import CoworkFrame, CoworkFrameRejected, CoworkFrameRejection

# Default freshness window, in milliseconds (Dart default: 60 seconds).
DEFAULT_WINDOW_MS = 60_000


def _default_now_ms() -> int:
    """Milliseconds since the Unix epoch, UTC — matches Dart's
    ``DateTime.now().toUtc().millisecondsSinceEpoch``."""
    return int(time.time() * 1000)


class ReplayGuard:
    def __init__(
        self,
        window_ms: int = DEFAULT_WINDOW_MS,
        now_ms: Callable[[], int] | None = None,
        last_seq: int | None = None,
    ):
        # How far ``ts`` may sit from local time in either direction. Symmetric
        # on purpose: rejecting only the past would let an attacker with a skewed
        # clock bank far-future frames to replay later.
        self.window_ms = window_ms
        self._now_ms = now_ms or _default_now_ms
        self._last_seq = last_seq

    @property
    def last_seq(self) -> int | None:
        """Highest ``seq`` accepted so far, or None if nothing yet. Persist this
        to survive a daemon restart; pass it back via ``last_seq``."""
        return self._last_seq

    def check(self, frame: CoworkFrame) -> None:
        """Validate freshness without changing state. Call only *after* the
        signature verifies. Mirrors ``check``."""
        self._check_timestamp(frame)
        self._check_seq(frame)

    def commit(self, frame: CoworkFrame) -> None:
        """Burn the frame's sequence number. Call only once the frame is fully
        authenticated *and* decrypted, so a frame that failed GCM never consumes
        a seq. Both conditions are re-validated here rather than trusted from
        :meth:`check`, closing the concurrency gap across the decrypt ``await``.
        Mirrors ``commit``."""
        self._check_timestamp(frame)
        self._check_seq(frame)
        self._last_seq = frame.seq

    def _check_timestamp(self, frame: CoworkFrame) -> None:
        skew = self._now_ms() - frame.ts
        if abs(skew) > self.window_ms:
            raise CoworkFrameRejected(CoworkFrameRejection.TIMESTAMP_OUT_OF_WINDOW)

    def _check_seq(self, frame: CoworkFrame) -> None:
        last = self._last_seq
        if last is not None and frame.seq <= last:
            raise CoworkFrameRejected(CoworkFrameRejection.REPLAYED_SEQUENCE)
