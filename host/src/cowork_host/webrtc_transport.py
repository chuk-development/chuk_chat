"""WebRTC DataChannel transport for the host↔app pipe (§14.1).

The outer host↔app pipe moves to peer-to-peer WebRTC: our coordination server
only does signaling, and the sealed frames flow directly between the two peers —
no traffic through us, and **no open port** (outbound-only ICE/STUN hole
punching; a TURN relay is an outbound fallback). The inner executor loopback and
the sealed `cowork_frame` payload are untouched; only the pipe changes.

This module is the pipe, nothing above it. It exposes the same tiny surface the
rest of the host already speaks — `send(str)` and `recv(timeout) -> str | None`,
bytes/text in, bytes/text out — so `HostParty` consumes it exactly as it consumed
the WebSocket. aiortc is asyncio-native and the host stack is threads+queues, so
the endpoint owns a private event-loop thread and bridges across it with plain
`queue.Queue`s and `run_coroutine_threadsafe` — every aiortc object is touched
only on that loop.

Two facts from aiortc 1.15 shape the design:

- **No trickle ICE.** `setLocalDescription` blocks until ICE gathering finishes,
  so `localDescription.sdp` is already candidate-complete. Signaling is therefore
  just two messages — one offer SDP, one answer SDP — with no per-candidate
  relay. The peer must also send a candidate-complete SDP (wait for gathering).
- **~256 KiB single-message cap** (libwebrtc interop, safe at 16 KiB). Our outer
  frames can be megabytes (a `file` event), so the transport frames each logical
  message with a 4-byte length prefix and sends it in ≤16 KiB binary chunks over
  the reliable+ordered channel, reassembling on the far side. Backpressure waits
  on `bufferedAmount` so a burst cannot blow memory.
"""

from __future__ import annotations

import asyncio
import queue
import struct
import threading
from collections.abc import Callable
from typing import Any

from aiortc import (
    RTCConfiguration,
    RTCDataChannel,
    RTCIceServer,
    RTCPeerConnection,
    RTCSessionDescription,
)

CHANNEL_LABEL = "cowork"
CHUNK_SIZE = 16 * 1024  # cross-stack-safe single-message size (libwebrtc)
_LEN = struct.Struct(">I")  # 4-byte big-endian length prefix
MAX_MESSAGE_BYTES = 32 * 1024 * 1024  # a hostile/garbled length must not OOM us
_BUFFER_HIGH = 1 * 1024 * 1024  # pause sending past ~1 MB in flight
_BUFFER_LOW = 256 * 1024

# A signaling channel: two synchronous, thread-safe methods the coordinator
# backs. `send` hands one JSON-able dict to the peer; `recv` returns the next one
# (or None on timeout). The endpoint calls these off the event loop via an
# executor, so they may block.
SignalSend = Callable[[dict], None]
SignalRecv = Callable[[float], "dict | None"]


class WebRTCError(RuntimeError):
    """The DataChannel could not be established."""


def ice_configuration(ice_servers: list[dict] | None) -> RTCConfiguration:
    """Build an `RTCConfiguration` from a list of `{urls, username?, credential?}`.

    STUN entries need no credentials; a TURN entry carries the short-lived HMAC
    username/credential the coordinator minted (§14.1). None → no ICE servers,
    which still works on a LAN (host candidates only)."""
    servers: list[RTCIceServer] = []
    for entry in ice_servers or []:
        urls = entry.get("urls")
        if not urls:
            continue
        servers.append(
            RTCIceServer(
                urls=urls,
                username=entry.get("username"),
                credential=entry.get("credential"),
            )
        )
    return RTCConfiguration(iceServers=servers)


class _Reassembler:
    """Turns a stream of ordered binary chunks back into whole messages.

    The channel is reliable+ordered, so bytes arrive in order; message
    boundaries do not. Accumulate, then peel off each `[4-byte length][payload]`
    frame. A length past the cap is a corrupt/hostile stream — raise, the caller
    tears the channel down."""

    def __init__(self) -> None:
        self._buf = bytearray()

    def feed(self, chunk: bytes) -> list[bytes]:
        self._buf.extend(chunk)
        out: list[bytes] = []
        while len(self._buf) >= _LEN.size:
            (length,) = _LEN.unpack_from(self._buf, 0)
            if length > MAX_MESSAGE_BYTES:
                raise WebRTCError(f"framed message length {length} over the limit")
            if len(self._buf) < _LEN.size + length:
                break
            start = _LEN.size
            out.append(bytes(self._buf[start : start + length]))
            del self._buf[: start + length]
        return out


class WebRTCEndpoint:
    """A peer-to-peer DataChannel presented as a `send`/`recv(timeout)` pipe.

    Construct with a role (`"offer"` or `"answer"`) and a signaling pair, call
    `connect(timeout)` to negotiate and wait for the channel to open, then use
    `send`/`recv` exactly like the loopback/WebSocket endpoints. `close()` tears
    down the peer connection and the loop thread. Thread-safe: `send`/`recv`/
    `close` are called from the host's threads; every aiortc touch is marshalled
    onto the private loop.
    """

    def __init__(
        self,
        *,
        role: str,
        signal_send: SignalSend,
        signal_recv: SignalRecv,
        ice_servers: list[dict] | None = None,
    ) -> None:
        if role not in ("offer", "answer"):
            raise ValueError("role must be 'offer' or 'answer'")
        self._role = role
        self._signal_send = signal_send
        self._signal_recv = signal_recv
        self._config = ice_configuration(ice_servers)

        self._inbox: queue.Queue[str] = queue.Queue()
        self._reassembler = _Reassembler()
        self._open = threading.Event()
        self._closed = threading.Event()
        self._fail: BaseException | None = None

        self._pc: RTCPeerConnection | None = None
        self._channel: RTCDataChannel | None = None
        self._buffer_low = threading.Event()
        self._buffer_low.set()
        # Serializes whole framed messages on the loop: two concurrent `send`s
        # each schedule a `_send_framed` coroutine, and the backpressure `await`
        # would otherwise let the second interleave its chunks between the
        # first's — the receiver would then read a payload byte as a length
        # prefix and corrupt the stream. Created lazily on the loop (an
        # asyncio.Lock binds to the running loop).
        self._send_lock_obj: asyncio.Lock | None = None

        self._loop = asyncio.new_event_loop()
        self._loop_thread = threading.Thread(
            target=self._run_loop, name="webrtc-loop", daemon=True
        )
        self._loop_thread.start()

    # -- lifecycle ---------------------------------------------------------

    def _run_loop(self) -> None:
        asyncio.set_event_loop(self._loop)
        self._loop.run_forever()

    def connect(self, timeout: float = 30.0) -> None:
        """Negotiate the channel and block until it is open. Raises on failure."""
        fut = asyncio.run_coroutine_threadsafe(self._negotiate(), self._loop)
        try:
            fut.result(timeout=timeout)
        except Exception as exc:  # negotiation raised
            self.close()
            raise WebRTCError(f"negotiation failed: {exc}") from exc
        if not self._open.wait(timeout=timeout):
            self.close()
            raise WebRTCError("data channel did not open in time")
        if self._fail is not None:
            self.close()
            raise WebRTCError(f"connection failed: {self._fail}")

    async def _negotiate(self) -> None:
        pc = RTCPeerConnection(configuration=self._config)
        self._pc = pc

        @pc.on("connectionstatechange")
        async def _on_state() -> None:
            if pc.connectionState in ("failed", "closed"):
                self._fail = self._fail or WebRTCError(pc.connectionState)
                self._open.set()  # unblock a waiter so it can see the failure

        if self._role == "offer":
            channel = pc.createDataChannel(CHANNEL_LABEL, ordered=True)
            self._wire_channel(channel)
            await pc.setLocalDescription(await pc.createOffer())
            # aiortc gathering is complete here → SDP is candidate-complete.
            await self._loop.run_in_executor(
                None,
                self._signal_send,
                {"type": "offer", "sdp": pc.localDescription.sdp},
            )
            answer = await self._recv_signal("answer")
            await pc.setRemoteDescription(
                RTCSessionDescription(sdp=answer["sdp"], type="answer")
            )
        else:

            @pc.on("datachannel")
            def _on_channel(channel: RTCDataChannel) -> None:
                self._wire_channel(channel)

            offer = await self._recv_signal("offer")
            await pc.setRemoteDescription(
                RTCSessionDescription(sdp=offer["sdp"], type="offer")
            )
            await pc.setLocalDescription(await pc.createAnswer())
            await self._loop.run_in_executor(
                None,
                self._signal_send,
                {"type": "answer", "sdp": pc.localDescription.sdp},
            )

    async def _recv_signal(self, expected: str) -> dict:
        # The coordinator relays opaque dicts; wait for the one we need.
        while True:
            msg = await self._loop.run_in_executor(None, self._signal_recv, 30.0)
            if msg is None:
                raise WebRTCError(f"timed out waiting for signaling '{expected}'")
            if msg.get("type") == expected:
                return msg

    def _wire_channel(self, channel: RTCDataChannel) -> None:
        self._channel = channel
        channel.bufferedAmountLowThreshold = _BUFFER_LOW

        @channel.on("open")
        def _on_open() -> None:
            self._open.set()

        @channel.on("close")
        def _on_close() -> None:
            self._closed.set()

        @channel.on("bufferedamountlow")
        def _on_low() -> None:
            self._buffer_low.set()

        @channel.on("message")
        def _on_message(message: Any) -> None:
            data = message if isinstance(message, (bytes, bytearray)) else str(message).encode()
            try:
                for whole in self._reassembler.feed(bytes(data)):
                    self._inbox.put(whole.decode("utf-8", errors="replace"))
            except WebRTCError as exc:
                self._fail = exc
                self._closed.set()

        if channel.readyState == "open":  # answer side can miss the event
            self._open.set()

    # -- the pipe surface --------------------------------------------------

    def send(self, data: str | bytes) -> None:
        """Frame one logical message and stream it in chunks. Non-blocking."""
        if self._closed.is_set():
            return
        payload = data.encode("utf-8") if isinstance(data, str) else bytes(data)
        framed = _LEN.pack(len(payload)) + payload
        asyncio.run_coroutine_threadsafe(self._send_framed(framed), self._loop)

    def _send_lock(self) -> asyncio.Lock:
        # Runs on the loop thread (from _send_framed), so binding to the running
        # loop is safe. One lock per endpoint, created once.
        if self._send_lock_obj is None:
            self._send_lock_obj = asyncio.Lock()
        return self._send_lock_obj

    async def _send_framed(self, framed: bytes) -> None:
        async with self._send_lock():
            channel = self._channel
            if channel is None or channel.readyState != "open":
                return
            for i in range(0, len(framed), CHUNK_SIZE):
                if channel.bufferedAmount > _BUFFER_HIGH:
                    # Drain before sending more, so a burst cannot blow memory.
                    while (
                        channel.bufferedAmount > _BUFFER_LOW
                        and channel.readyState == "open"
                    ):
                        await asyncio.sleep(0.01)
                if channel.readyState != "open":
                    return
                channel.send(framed[i : i + CHUNK_SIZE])

    def recv(self, timeout: float | None = None) -> str | None:
        """Return the next whole message, or None on timeout/close."""
        try:
            return self._inbox.get(timeout=timeout)
        except queue.Empty:
            return None

    def close(self) -> None:
        """Tear down the peer connection and stop the loop thread. Idempotent."""
        if self._closed.is_set() and not self._loop.is_running():
            return
        self._closed.set()
        pc = self._pc
        if pc is not None and self._loop.is_running():
            try:
                fut = asyncio.run_coroutine_threadsafe(pc.close(), self._loop)
                fut.result(timeout=5)
            except Exception:  # noqa: BLE001 — shutdown must not raise
                pass
        if self._loop.is_running():
            self._loop.call_soon_threadsafe(self._loop.stop)
