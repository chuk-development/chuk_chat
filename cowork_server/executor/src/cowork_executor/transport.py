"""Loopback transport (task 3).

An in-process duplex link between a controller endpoint and an executor endpoint.
There is **no network** — the production relay is out of scope. This stands in
for it so the whole controller -> executor -> controller path runs locally.

Each endpoint satisfies ``cowork_manager.relay.Transport`` (a ``send(bytes)``
method), so the same relay frame contract that would run over a real WebSocket
runs here unchanged. On top of ``send`` an endpoint adds a blocking ``recv`` so a
background serve loop can wait on inbound bytes.

The two directions are independent thread-safe queues, so one endpoint can run in
a background thread (the executor) while the other drives it (the controller).
The relay is blind by construction: it only ever moves opaque bytes, and every
payload that crosses it is an already-sealed CoWork frame.
"""

from __future__ import annotations

import queue


class LoopbackEndpoint:
    """One side of the loopback link. ``send`` writes to the peer; ``recv`` reads
    what the peer sent to us."""

    def __init__(self, outbox: "queue.Queue[bytes]", inbox: "queue.Queue[bytes]") -> None:
        self._outbox = outbox
        self._inbox = inbox

    # -- cowork_manager.relay.Transport ----------------------------------
    def send(self, data: bytes) -> None:
        """Deliver ``data`` to the peer's inbox."""
        self._outbox.put(data)

    # -- receive side ----------------------------------------------------
    def recv(self, timeout: float | None = None) -> bytes | None:
        """Block for one inbound chunk, or return ``None`` on timeout."""
        try:
            return self._inbox.get(timeout=timeout)
        except queue.Empty:
            return None


def loopback_pair() -> tuple[LoopbackEndpoint, LoopbackEndpoint]:
    """Build two linked endpoints. Bytes sent on one arrive on the other.

    Returns ``(controller_endpoint, executor_endpoint)`` by convention, though
    the link is symmetric.
    """
    c_to_e: "queue.Queue[bytes]" = queue.Queue()
    e_to_c: "queue.Queue[bytes]" = queue.Queue()
    controller = LoopbackEndpoint(outbox=c_to_e, inbox=e_to_c)
    executor = LoopbackEndpoint(outbox=e_to_c, inbox=c_to_e)
    return controller, executor
