"""Seal and open CoWork frames — Python twin of ``cowork_frame_codec.dart``.

AES-256-GCM under the injected CoWork **channel key** (see ``channel_key.py`` —
per §14 this is a fresh X25519-derived key, *not* the chat account key), with an
Ed25519 signature by the sending device's own key.

The opener applies its defences in this order (matching the Dart
``CoworkFrameOpener``):

1. **Local approval** — is ``device_id`` in the approved set? Default deny.
2. **Signature** — Ed25519 against that locally approved key, before decrypt.
3. **Key version** — ``kv`` must name the key this receiver holds.
4. **Replay** — ``ts`` window, then strictly monotonic ``seq`` per device.
5. **Decrypt** — AES-256-GCM, header as AAD.

Every step is a hard reject; there is no path that accepts a frame whose signing
key is not approved.
"""

from __future__ import annotations

import os
import time
from collections.abc import Callable

from cryptography.exceptions import InvalidSignature, InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from .approved_devices import ApprovedDevices
from .device_keys import DeviceIdentity
from .frame import (
    FRAME_VERSION,
    MAC_LENGTH,
    NONCE_LENGTH,
    CoworkFrame,
    CoworkFrameRejected,
    CoworkFrameRejection,
    build_header_bytes,
    build_signed_bytes,
)
from .replay_guard import DEFAULT_WINDOW_MS, ReplayGuard


def _default_now_ms() -> int:
    return int(time.time() * 1000)


class CoworkFrameSealer:
    """Seals outgoing CoWork frames. One sealer per outbound stream; it owns the
    ``seq`` counter, which must be strictly monotonic for the peer's replay guard
    to accept anything — so a daemon restart must restore ``next_seq`` from
    storage rather than start over. Mirrors ``CoworkFrameSealer``."""

    def __init__(
        self,
        *,
        channel_key: bytes,
        key_version: int,
        device_id: str,
        signing_identity: DeviceIdentity,
        next_seq: int = 0,
        now_ms: Callable[[], int] | None = None,
        rand: Callable[[int], bytes] | None = None,
    ):
        if len(channel_key) != 32:
            raise ValueError("channel_key must be 32 bytes (AES-256)")
        if next_seq < 0:
            raise ValueError("next_seq must be non-negative")
        self._aesgcm = AESGCM(channel_key)
        self._key_version = key_version
        self._device_id = device_id
        self._identity = signing_identity
        self._next_seq = next_seq
        self._now_ms = now_ms or _default_now_ms
        self._rand = rand or os.urandom

    @property
    def next_seq(self) -> int:
        """The ``seq`` the next :meth:`seal` will use. Persist across restarts."""
        return self._next_seq

    @property
    def device_id(self) -> str:
        return self._device_id

    def seal(self, plaintext: bytes) -> CoworkFrame:
        """Seal ``plaintext`` into a frame ready for the relay. Mirrors ``seal``."""
        seq = self._next_seq
        self._next_seq += 1
        ts = self._now_ms()
        nonce = self._rand(NONCE_LENGTH)

        # The header is AAD, not payload: it travels in the clear but is bound
        # into the tag, so a ciphertext cannot be lifted onto a different frame.
        header = build_header_bytes(
            version=FRAME_VERSION,
            key_version=self._key_version,
            device_id=self._device_id,
            seq=seq,
            ts=ts,
        )

        # AESGCM.encrypt returns cipher text followed by the 16-byte tag — the
        # exact layout the Dart side builds by concatenating cipherText + mac.
        ciphertext = self._aesgcm.encrypt(nonce, plaintext, header)

        sig = self._identity.sign(
            build_signed_bytes(header=header, nonce=nonce, ciphertext=ciphertext)
        )

        return CoworkFrame(
            version=FRAME_VERSION,
            key_version=self._key_version,
            device_id=self._device_id,
            seq=seq,
            ts=ts,
            nonce=nonce,
            ciphertext=ciphertext,
            sig=sig,
        )

    def seal_bytes(self, plaintext: bytes) -> bytes:
        """Seal and serialise straight to wire bytes."""
        return self.seal(plaintext).to_bytes()

    def seal_text(self, plaintext: str) -> CoworkFrame:
        return self.seal(plaintext.encode("utf-8"))


class CoworkFrameOpener:
    """Opens incoming CoWork frames. Mirrors ``CoworkFrameOpener``."""

    def __init__(
        self,
        *,
        channel_key: bytes,
        key_version: int,
        approved_devices: ApprovedDevices,
        replay_window_ms: int = DEFAULT_WINDOW_MS,
        now_ms: Callable[[], int] | None = None,
        last_seq_by_device: dict[str, int] | None = None,
    ):
        if len(channel_key) != 32:
            raise ValueError("channel_key must be 32 bytes (AES-256)")
        self._aesgcm = AESGCM(channel_key)
        self._key_version = key_version
        self._approved = approved_devices
        self._replay_window_ms = replay_window_ms
        self._now_ms = now_ms or _default_now_ms
        self._guards: dict[str, ReplayGuard] = {
            device_id: ReplayGuard(
                window_ms=replay_window_ms, now_ms=self._now_ms, last_seq=seq
            )
            for device_id, seq in (last_seq_by_device or {}).items()
        }

    @property
    def approved_devices(self) -> ApprovedDevices:
        """The live local trust store. Revoking takes effect on the next frame."""
        return self._approved

    @property
    def last_seq_by_device(self) -> dict[str, int]:
        """Highest accepted ``seq`` per device. Persist to survive a restart;
        pass back via ``last_seq_by_device``."""
        return {
            device_id: guard.last_seq
            for device_id, guard in self._guards.items()
            if guard.last_seq is not None
        }

    def open(self, frame: CoworkFrame | bytes | str) -> bytes:
        """Verify and decrypt ``frame``, or raise ``CoworkFrameRejected``.

        Accepts a parsed :class:`CoworkFrame`, raw wire bytes, or the JSON text.
        """
        if isinstance(frame, (bytes, bytearray)):
            frame = CoworkFrame.from_bytes(bytes(frame))
        elif isinstance(frame, str):
            frame = CoworkFrame.from_json_string(frame)

        if frame.version != FRAME_VERSION:
            raise CoworkFrameRejected(CoworkFrameRejection.UNSUPPORTED_VERSION)

        # 1. Local approval. Default deny: an empty store has no entries, so
        #    every lookup misses and every frame dies here.
        public_key = self._approved.lookup(frame.device_id)
        if public_key is None:
            raise CoworkFrameRejected(CoworkFrameRejection.DEVICE_NOT_APPROVED)

        # 2. Signature, before decryption.
        try:
            public_key.verify(frame.sig, frame.signed_bytes)
        except InvalidSignature:
            raise CoworkFrameRejected(CoworkFrameRejection.BAD_SIGNATURE)

        # 3. Key version. Only meaningful now the signature has vouched for it —
        #    ``kv`` is attacker-controlled bytes until then.
        if frame.key_version != self._key_version:
            raise CoworkFrameRejected(CoworkFrameRejection.KEY_VERSION_MISMATCH)

        # 4. Replay: ts window, then monotonic seq. Checked, not yet committed.
        guard = self._guards.get(frame.device_id)
        if guard is None:
            guard = ReplayGuard(window_ms=self._replay_window_ms, now_ms=self._now_ms)
            self._guards[frame.device_id] = guard
        guard.check(frame)

        # 5. Decrypt. The header must match bit for bit or the tag fails.
        try:
            cleartext = self._aesgcm.decrypt(
                frame.nonce, frame.ciphertext, frame.header_bytes
            )
        except InvalidTag:
            # AESGCM raises InvalidTag on a wrong key, wrong AAD, or mangled bytes.
            raise CoworkFrameRejected(CoworkFrameRejection.DECRYPTION_FAILED)

        # 6. Burn the sequence only now the frame is genuinely deliverable. The
        #    re-check inside commit() closes the race between two frames.
        guard.commit(frame)
        return cleartext

    def open_text(self, frame: CoworkFrame | bytes | str) -> str:
        return self.open(frame).decode("utf-8")


# --- convenience free functions ---------------------------------------------


def seal(
    plaintext: bytes,
    *,
    channel_key: bytes,
    key_version: int,
    device_id: str,
    signing_identity: DeviceIdentity,
    seq: int = 0,
    now_ms: Callable[[], int] | None = None,
    rand: Callable[[int], bytes] | None = None,
) -> bytes:
    """Seal one ``plaintext`` into wire ``frame_bytes``. A thin wrapper over
    :class:`CoworkFrameSealer` for one-shot use."""
    sealer = CoworkFrameSealer(
        channel_key=channel_key,
        key_version=key_version,
        device_id=device_id,
        signing_identity=signing_identity,
        next_seq=seq,
        now_ms=now_ms,
        rand=rand,
    )
    return sealer.seal_bytes(plaintext)


def open(
    frame_bytes: bytes,
    *,
    channel_key: bytes,
    key_version: int,
    approved_devices: ApprovedDevices,
    replay_window_ms: int = DEFAULT_WINDOW_MS,
    now_ms: Callable[[], int] | None = None,
    last_seq_by_device: dict[str, int] | None = None,
) -> bytes:
    """Open wire ``frame_bytes`` back to ``plaintext``, or raise
    ``CoworkFrameRejected``. A thin wrapper over :class:`CoworkFrameOpener`."""
    opener = CoworkFrameOpener(
        channel_key=channel_key,
        key_version=key_version,
        approved_devices=approved_devices,
        replay_window_ms=replay_window_ms,
        now_ms=now_ms,
        last_seq_by_device=last_seq_by_device,
    )
    return opener.open(frame_bytes)
