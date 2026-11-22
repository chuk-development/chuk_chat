"""Seal and open the bodies of ``peer`` frames between two hosts (CHAT-177).

The relay carries a host-to-host frame as ``{"type": "peer",
"target_device_id", "body"}`` and does not read ``body``. This module makes
``body``: one Agents frame (:mod:`chuk_agents_crypto.frame`, the same wire
shape as an app frame) sealed with the pair key ``K`` the app gave both hosts.

- AES-256-GCM under ``K``; the frame header is the AAD.
- Ed25519 signature by the sender's long-term host key (``host_device.key``).
- ``device_id`` in the header is the sender's relay device id. The receiver
  also checks that it is the ``from_device_id`` the relay put on the frame.
- Replay guard: a ``ts`` window plus a sliding window of seen ``seq`` values.
  A strict "higher than the last" rule (the app channel's rule) would drop a
  frame that the relay delivered out of order across two replicas; the window
  accepts that frame once and refuses it the second time.

A sender's ``seq`` starts at the current time in microseconds, so a host that
restarts keeps going above the numbers its peer has seen.

A plaintext larger than :data:`SINGLE_FRAME_MAX_BYTES` is cut into ``fragment``
payloads (the app's shape, :func:`chuk_agents_executor.protocol.fragment_plaintexts`),
one sealed frame each, so no relay frame passes the 1 MB cap.
"""

from __future__ import annotations

import json
import threading
import time
from collections.abc import Callable
from typing import Any

from chuk_agents_crypto import (
    AgentsFrame,
    AgentsFrameRejected,
    AgentsFrameRejection,
    AgentsFrameSealer,
    DeviceIdentity,
)
from chuk_agents_executor.protocol import FragmentAssembler, fragment_plaintexts
from cryptography.exceptions import InvalidSignature, InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from .peers_store import PeerRecord

#: The key version of every peer frame. The pair key rotates by a new
#: introduce, not by a version bump.
PEER_KEY_VERSION = 1

#: A plaintext up to this size goes as one frame. Sealed, it is base64 inside
#: the frame JSON: 700 000 bytes become about 933 400 characters, under the
#: relay's 1 MB cap with room for the header.
SINGLE_FRAME_MAX_BYTES = 700_000

#: The slice of one fragment. The slice is base64 in the fragment payload and
#: that payload is base64 again in the sealed frame: 512 KiB -> about 932 KB.
FRAGMENT_SLICE_BYTES = 512 * 1024

#: How far ``ts`` may be from the local clock, either way. Wider than the app
#: channel's 60 s: two computers of one user can drift more than a phone and
#: its server do. The ``seq`` window still refuses a second copy.
REPLAY_WINDOW_MS = 300_000

#: How many ``seq`` values below the highest one are still accepted once.
SEQ_WINDOW = 4096


class PeerReplayGuard:
    """A ``ts`` window plus a sliding window of seen ``seq`` values."""

    def __init__(
        self,
        *,
        window_ms: int = REPLAY_WINDOW_MS,
        seq_window: int = SEQ_WINDOW,
        now_ms: Callable[[], int] | None = None,
    ) -> None:
        self._window_ms = window_ms
        self._seq_window = seq_window
        self._now_ms = now_ms or (lambda: int(time.time() * 1000))
        self._max: int | None = None
        self._seen: set[int] = set()

    def check(self, frame: AgentsFrame) -> None:
        if abs(self._now_ms() - frame.ts) > self._window_ms:
            raise AgentsFrameRejected(AgentsFrameRejection.TIMESTAMP_OUT_OF_WINDOW)
        if self._max is not None:
            if frame.seq <= self._max - self._seq_window or frame.seq in self._seen:
                raise AgentsFrameRejected(AgentsFrameRejection.REPLAYED_SEQUENCE)

    def commit(self, frame: AgentsFrame) -> None:
        self.check(frame)
        self._seen.add(frame.seq)
        if self._max is None or frame.seq > self._max:
            self._max = frame.seq
            floor = self._max - self._seq_window
            if len(self._seen) > self._seq_window:
                self._seen = {s for s in self._seen if s > floor}


class _PeerState:
    """The crypto of one peer: our sealer, the peer's key, its replay guard and
    its fragment assembler. One lock for the send side, one for the receive
    side: sealing and sending stay in ``seq`` order."""

    def __init__(self, record: PeerRecord, own_host_id: str, identity: DeviceIdentity) -> None:
        self.record = record
        self.sealer = AgentsFrameSealer(
            channel_key=record.pair_key,
            key_version=PEER_KEY_VERSION,
            device_id=own_host_id,
            signing_identity=identity,
            next_seq=time.time_ns() // 1000,
        )
        self.aesgcm = AESGCM(record.pair_key)
        self.guard = PeerReplayGuard()
        self.assembler = FragmentAssembler()
        self.send_lock = threading.Lock()
        self.recv_lock = threading.Lock()


def encode_message(message: dict[str, Any]) -> bytes:
    return json.dumps(message, separators=(",", ":")).encode("utf-8")


class PeerChannel:
    """Seals messages to peers and opens bodies from them.

    ``records`` is the peer store's lookup. The crypto state of a peer is made
    on first use and made again when its record changes (a new pair key).
    """

    def __init__(
        self,
        *,
        own_host_id: str,
        identity: DeviceIdentity,
        records: Callable[[str], PeerRecord | None],
    ) -> None:
        self._own = own_host_id
        self._identity = identity
        self._records = records
        self._states: dict[str, _PeerState] = {}
        self._lock = threading.Lock()

    def _state(self, host_id: str) -> _PeerState | None:
        record = self._records(host_id)
        with self._lock:
            if record is None:
                self._states.pop(host_id, None)
                return None
            state = self._states.get(host_id)
            if state is None or state.record != record:
                state = _PeerState(record, self._own, self._identity)
                self._states[host_id] = state
            return state

    def forget(self, host_id: str) -> None:
        with self._lock:
            self._states.pop(host_id, None)

    # -- outbound ------------------------------------------------------------

    def seal(self, host_id: str, message: dict[str, Any]) -> list[dict]:
        """The ``body`` values for one message, in send order. Raises
        :class:`KeyError` for an unknown peer."""
        state = self._state(host_id)
        if state is None:
            raise KeyError(host_id)
        encoded = encode_message(message)
        parts = (
            [encoded]
            if len(encoded) <= SINGLE_FRAME_MAX_BYTES
            else fragment_plaintexts(encoded, chunk_bytes=FRAGMENT_SLICE_BYTES)
        )
        return [state.sealer.seal(part).to_json() for part in parts]

    def send_lock(self, host_id: str) -> threading.Lock | None:
        """Held around seal + send, so frames leave in ``seq`` order."""
        state = self._state(host_id)
        return state.send_lock if state is not None else None

    # -- inbound -------------------------------------------------------------

    def open(self, from_host_id: str, body: object) -> dict[str, Any] | None:
        """The message in one ``peer`` body, ``None`` while a fragmented message
        is incomplete. Raises :class:`AgentsFrameRejected` for anything that is
        not a valid frame of a known peer; the caller drops it."""
        state = self._state(from_host_id)
        if state is None:
            raise AgentsFrameRejected(AgentsFrameRejection.DEVICE_NOT_APPROVED, "unknown peer")
        if not isinstance(body, dict):
            raise AgentsFrameRejected(AgentsFrameRejection.MALFORMED, "body is not an object")
        frame = AgentsFrame.from_json(body)
        # The relay sets ``from_device_id`` from the socket. A frame that says
        # it is from another host is refused, also with a valid signature.
        if frame.device_id != from_host_id:
            raise AgentsFrameRejected(AgentsFrameRejection.DEVICE_NOT_APPROVED, "sender mismatch")
        try:
            state.record.public_key.verify(frame.sig, frame.signed_bytes)
        except InvalidSignature:
            raise AgentsFrameRejected(AgentsFrameRejection.BAD_SIGNATURE) from None
        if frame.key_version != PEER_KEY_VERSION:
            raise AgentsFrameRejected(AgentsFrameRejection.KEY_VERSION_MISMATCH)
        with state.recv_lock:
            state.guard.check(frame)
            try:
                plaintext = state.aesgcm.decrypt(frame.nonce, frame.ciphertext, frame.header_bytes)
            except InvalidTag:
                raise AgentsFrameRejected(AgentsFrameRejection.DECRYPTION_FAILED) from None
            state.guard.commit(frame)
            try:
                message = json.loads(plaintext.decode("utf-8"))
            except (ValueError, UnicodeDecodeError):
                raise AgentsFrameRejected(AgentsFrameRejection.MALFORMED, "bad payload") from None
            if not isinstance(message, dict):
                raise AgentsFrameRejected(AgentsFrameRejection.MALFORMED, "bad payload")
            return state.assembler.add(message)
