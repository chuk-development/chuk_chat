"""Bounded idle WebSocket reuse; never sends a model request to keep warm."""

from __future__ import annotations

import threading
from typing import Any


class BackendConnectionPool:
    """Exclusive leases keyed by endpoint and authentication token.

    Only fully drained responses may be returned. Idle sockets retain the
    websocket library's protocol ping/pong, and expire without another task
    needing to arrive. A changed token cannot borrow an older authentication.
    """

    def __init__(self, *, max_idle: int = 4, idle_seconds: float = 60.0):
        self._max_idle = max_idle
        self._idle_seconds = idle_seconds
        self._lock = threading.Lock()
        self._idle: list[tuple[tuple[str, str], Any, threading.Timer]] = []
        self._closed = False

    def take(self, key: tuple[str, str]) -> Any | None:
        with self._lock:
            for i in range(len(self._idle) - 1, -1, -1):
                stored_key, ws, timer = self._idle[i]
                if stored_key == key:
                    self._idle.pop(i)
                    timer.cancel()
                    return ws
        return None

    def put(self, key: tuple[str, str], ws: Any) -> None:
        with self._lock:
            if self._closed or len(self._idle) >= self._max_idle:
                discard = True
            else:
                discard = False
                timer = threading.Timer(self._idle_seconds, lambda: self._expire(ws, timer))
                timer.daemon = True
                self._idle.append((key, ws, timer))
                timer.start()
        if discard:
            _close(ws)

    def _expire(self, target: Any, expired_timer: threading.Timer) -> None:
        with self._lock:
            for i, (_, ws, timer) in enumerate(self._idle):
                if ws is target and timer is expired_timer:
                    self._idle.pop(i)
                    break
            else:
                return  # already leased; its new owner decides when to close
        _close(target)

    def close(self) -> None:
        with self._lock:
            self._closed = True
            idle, self._idle = self._idle, []
        for _, ws, timer in idle:
            timer.cancel()
            _close(ws)


def _close(ws: Any) -> None:
    try:
        ws.close()
    except Exception:
        pass
