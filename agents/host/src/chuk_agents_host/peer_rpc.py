"""Request and answer between two hosts over the peer channel (CHAT-177).

Every message is one JSON object inside a sealed ``peer`` body
(:mod:`chuk_agents_host.peer_channel`):

    {"t": "req",   "id": "<hex>", "kind": "<kind>", "args": {...}}
    {"t": "chunk", "id": "<hex>", "data": {...}}          (zero or more)
    {"t": "end",   "id": "<hex>", "ok": true,  "result": {...}}
    {"t": "end",   "id": "<hex>", "ok": false, "error": "<code>", "message": "..."}

The caller waits for ``end``. Each ``chunk`` resets its idle timer, so a long
task that sends a heartbeat chunk stays alive while a dead peer is found in
``idle_timeout`` seconds. A handler runs on a worker thread, never on the
relay's reader thread.

Error codes the caller can get: the handler's own code, ``unknown_kind``,
``handler_failed``, ``timeout``, ``busy`` (no free worker), and the relay's
codes for the frame (``peer_unreachable``, ``rate_limited``,
``payload_too_large``, ``invalid_target``, ``invalid_body``), plus
``not_a_peer`` when this host does not know the target.
"""

from __future__ import annotations

import queue
import secrets
import threading
import time
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor

#: Emits one ``chunk`` toward the caller.
Emit = Callable[[dict], None]
#: ``handler(peer_host_id, args, emit) -> result``. Raise :class:`PeerRpcError`
#: for an answer with an error code.
Handler = Callable[[str, dict, Emit], dict]
#: ``send(peer_host_id, message) -> relay req ids`` (empty when nothing left).
Send = Callable[[str, dict], "list[str]"]

#: The worker threads for inbound requests. A task holds one for a whole run.
DEFAULT_WORKERS = 8

#: Longest error message carried. Never content, only a reason.
MAX_MESSAGE_CHARS = 300


class PeerRpcError(Exception):
    """A call that ended without a result."""

    def __init__(self, code: str, message: str = "") -> None:
        self.code = code
        self.message = message[:MAX_MESSAGE_CHARS]
        super().__init__(f"{code}: {self.message}" if message else code)


class _Call:
    def __init__(self, peer: str) -> None:
        self.peer = peer
        self.inbox: queue.Queue = queue.Queue()


class PeerRpc:
    """Both sides of the request protocol for one host."""

    def __init__(
        self,
        *,
        send: Send,
        handlers: dict[str, Handler] | None = None,
        workers: int = DEFAULT_WORKERS,
        log: Callable[[str], None] | None = None,
    ) -> None:
        self._send = send
        self._handlers: dict[str, Handler] = dict(handlers or {})
        self._log = log or (lambda _m: None)
        self._pool = ThreadPoolExecutor(max_workers=workers, thread_name_prefix="peer-rpc")
        self._workers = workers
        self._busy = 0
        self._calls: dict[str, _Call] = {}
        # relay req_id -> call id, so a relay error reaches the waiting caller.
        self._req_to_call: dict[str, str] = {}
        # A relay refusal that came before its call had mapped the req id
        # (the reader thread can win that race): req id -> code.
        self._early: dict[str, str] = {}
        self._lock = threading.Lock()

    def register(self, kind: str, handler: Handler) -> None:
        self._handlers[kind] = handler

    def shutdown(self) -> None:
        self._pool.shutdown(wait=False, cancel_futures=True)
        with self._lock:
            calls = list(self._calls.values())
        for call in calls:
            call.inbox.put(("error", "shutdown", "this host is stopping"))

    # -- caller side ---------------------------------------------------------

    def call(
        self,
        peer: str,
        kind: str,
        args: dict,
        *,
        timeout: float = 60.0,
        idle_timeout: float | None = None,
        on_chunk: Callable[[dict], None] | None = None,
    ) -> dict:
        """Send one request and wait for its ``end``. Returns ``result``;
        raises :class:`PeerRpcError` otherwise. ``timeout`` bounds the whole
        call, ``idle_timeout`` the gap between two messages of the answer."""
        call_id = secrets.token_hex(8)
        call = _Call(peer)
        with self._lock:
            self._calls[call_id] = call
        try:
            req_ids = self._send(peer, {"t": "req", "id": call_id, "kind": kind, "args": args})
            early = None
            with self._lock:
                for req_id in req_ids:
                    self._req_to_call[req_id] = call_id
                    if early is None and req_id in self._early:
                        early = self._early.pop(req_id)
            if not req_ids:
                raise PeerRpcError("peer_unreachable", "no relay link")
            if early is not None:
                raise PeerRpcError(early, "the relay refused the frame")
            deadline = time.monotonic() + timeout
            idle = idle_timeout if idle_timeout is not None else timeout
            while True:
                now = time.monotonic()
                wait = min(deadline - now, idle)
                if wait <= 0:
                    raise PeerRpcError("timeout", f"no answer from the peer for {kind}")
                try:
                    item = call.inbox.get(timeout=wait)
                except queue.Empty:
                    raise PeerRpcError("timeout", f"no answer from the peer for {kind}") from None
                tag = item[0]
                if tag == "chunk":
                    if on_chunk is not None:
                        try:
                            on_chunk(item[1])
                        except PeerRpcError:
                            raise
                        except Exception as exc:  # noqa: BLE001 — the caller's bug
                            raise PeerRpcError("chunk_failed", type(exc).__name__) from exc
                    continue
                if tag == "end":
                    msg = item[1]
                    if msg.get("ok") is True:
                        result = msg.get("result")
                        return result if isinstance(result, dict) else {}
                    raise PeerRpcError(
                        str(msg.get("error") or "failed")[:64], str(msg.get("message") or "")
                    )
                raise PeerRpcError(item[1], item[2])
        finally:
            with self._lock:
                self._calls.pop(call_id, None)
                for req_id in [r for r, c in self._req_to_call.items() if c == call_id]:
                    self._req_to_call.pop(req_id, None)

    def fail_request(self, req_id: object, code: str) -> bool:
        """The relay refused a frame of ours. ``True`` when a waiting call was
        ended by it."""
        if not isinstance(req_id, str):
            return False
        with self._lock:
            call_id = self._req_to_call.pop(req_id, None)
            call = self._calls.get(call_id) if call_id else None
            if call_id is None:
                self._early[req_id] = code
                while len(self._early) > 256:
                    self._early.pop(next(iter(self._early)))
        if call is None:
            return False
        call.inbox.put(("error", code, "the relay refused the frame"))
        return True

    def fail_peer(self, peer: str, code: str, message: str = "") -> None:
        """End every call waiting on ``peer`` (it was forgotten)."""
        with self._lock:
            calls = [c for c in self._calls.values() if c.peer == peer]
        for call in calls:
            call.inbox.put(("error", code, message))

    # -- both sides ----------------------------------------------------------

    def on_message(self, peer: str, message: dict) -> None:
        """One opened message from ``peer``. Never blocks on a handler."""
        tag = message.get("t")
        msg_id = message.get("id")
        if not isinstance(msg_id, str) or not msg_id or len(msg_id) > 64:
            return
        if tag in ("chunk", "end"):
            with self._lock:
                call = self._calls.get(msg_id)
            if call is None or call.peer != peer:
                return  # late, or for a call of another peer: dropped
            if tag == "chunk":
                data = message.get("data")
                call.inbox.put(("chunk", data if isinstance(data, dict) else {}))
            else:
                call.inbox.put(("end", message))
            return
        if tag != "req":
            return
        kind = message.get("kind")
        args = message.get("args")
        handler = self._handlers.get(kind) if isinstance(kind, str) else None
        if handler is None:
            self._end(peer, msg_id, error="unknown_kind", message=f"unknown kind {kind!r}"[:80])
            return
        with self._lock:
            if self._busy >= self._workers:
                full = True
            else:
                full = False
                self._busy += 1
        if full:
            self._end(peer, msg_id, error="busy", message="the peer host is busy")
            return
        try:
            self._pool.submit(
                self._serve, peer, msg_id, kind, handler, args if isinstance(args, dict) else {}
            )
        except RuntimeError:
            with self._lock:
                self._busy -= 1

    def _serve(self, peer: str, msg_id: str, kind: str, handler: Handler, args: dict) -> None:
        try:
            def emit(data: dict) -> None:
                self._send(peer, {"t": "chunk", "id": msg_id, "data": data})

            try:
                result = handler(peer, args, emit)
            except PeerRpcError as exc:
                self._end(peer, msg_id, error=exc.code, message=exc.message)
                return
            except Exception as exc:  # noqa: BLE001 — the caller hears it, the host lives
                self._log(f"[peers] {kind} handler failed: {type(exc).__name__}")
                self._end(peer, msg_id, error="handler_failed", message=type(exc).__name__)
                return
            self._send(
                peer,
                {"t": "end", "id": msg_id, "ok": True, "result": result if isinstance(result, dict) else {}},
            )
        finally:
            with self._lock:
                self._busy -= 1

    def _end(self, peer: str, msg_id: str, *, error: str, message: str = "") -> None:
        self._send(
            peer,
            {"t": "end", "id": msg_id, "ok": False, "error": error,
             "message": message[:MAX_MESSAGE_CHARS]},
        )


def chunk_heartbeat(emit: Emit, stop: threading.Event, every: float) -> threading.Thread:
    """Send ``{"event": "working"}`` every ``every`` seconds until ``stop``.
    Keeps a long call alive on the caller's idle timer."""

    def beat() -> None:
        while not stop.wait(every):
            try:
                emit({"event": "working"})
            except Exception:  # noqa: BLE001 — a lost beat is not a failure
                pass

    thread = threading.Thread(target=beat, name="peer-heartbeat", daemon=True)
    thread.start()
    return thread


__all__ = ["Emit", "Handler", "PeerRpc", "PeerRpcError", "chunk_heartbeat"]
