"""CoWork reconnect handshake — authenticated resume with no pairing code.

Python twin of ``cowork_reconnect.dart``. Once a first pairing (§15) has
completed, **both** sides persist a trust record: their own long-term Ed25519
device identity, the peer's ``device_id`` + approved Ed25519 public key, the
stable ``channel_id`` and the established channel key. From then on a reconnect
must not ask the human for a code again — but it must still be safe against an
imposter that holds neither long-term private key.

This module is that reconnect. It is a **mutual signed-nonce challenge**: each
side proves possession of its persisted long-term Ed25519 private key over a
transcript that binds both fresh nonces and the channel id, and verifies the
peer's proof against the *stored* approved public key. No pairing code, no SAS,
no ephemeral ECDH — the channel key is the one already stored from pairing, and
it plugs into :class:`CoworkFrameSealer` / :class:`CoworkFrameOpener` exactly as
after a fresh pairing.

## Byte-exact cross-language contract (the Dart twin must match this)

All labels are ASCII, no terminator. Roles keep the §15 naming so the flow rides
the same relay: **initiator** = the host (executor), **joiner** = the app
(controller).

Nonces
    ``N_i`` — the initiator's 32 random bytes.
    ``N_j`` — the joiner's 32 random bytes.

Reconnect transcript
    ``RT = N_i ‖ N_j`` — 64 bytes, **initiator nonce first**, on both sides.

What each side signs (with its long-term Ed25519 device key)
    ``proof_i = Ed25519.sign( RECONNECT_I_LABEL ‖ channel_id ‖ RT )``  (host)
    ``proof_j = Ed25519.sign( RECONNECT_J_LABEL ‖ channel_id ‖ RT )``  (app)

    The label differs per role, so a signature made by one side can never be
    replayed as the other side's (no reflection). ``RT`` binds both nonces, so a
    signature captured from an earlier session — with different nonces — fails to
    verify here. ``channel_id`` binds the proof to this pairing. Each side
    verifies the peer's signature against the **stored** approved public key; an
    imposter that does not hold the peer's long-term private key cannot produce a
    signature that verifies, so the handshake aborts and no channel is resumed.

Message flow (three messages, hand-carried through the relay)
    1. initiator → ``reconnect-hello``    : ``channel_id``, ``device_id``, ``N_i``
    2. joiner    → ``reconnect-response`` : ``device_id``, ``N_j``, ``proof_j``
    3. initiator → ``reconnect-confirm``  : ``proof_i``

    The initiator authenticates the joiner at message 2 (verifying ``proof_j``)
    before it signs; the joiner authenticates the initiator at message 3
    (verifying ``proof_i``). If either verification fails the session aborts.

Every failure is a hard stop; a session that has authenticated or aborted refuses
any further step.
"""

from __future__ import annotations

import base64
import enum
import hmac
import secrets

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

from .device_keys import DeviceIdentity

# --- byte-exact protocol constants (mirror cowork_reconnect.dart) ------------

# Ed25519 proof label prefixes. ASCII, no terminator, one per signing role.
RECONNECT_I_LABEL = b"cowork/reconnect/proof-i"  # signed by the initiator (host)
RECONNECT_J_LABEL = b"cowork/reconnect/proof-j"  # signed by the joiner (app)

# Reconnect nonce length in bytes.
RECONNECT_NONCE_LENGTH = 32


class ReconnectRole(enum.Enum):
    """Which side of the reconnect this session drives. Same naming as §15."""

    INITIATOR = "initiator"  # the host (executor)
    JOINER = "joiner"  # the app (controller)


class ReconnectState(enum.Enum):
    """Ordered lifecycle. Any use after ``AUTHENTICATED`` / ``ABORTED`` is
    refused."""

    CREATED = "created"
    HELLO_SENT = "helloSent"  # initiator only
    RESPONSE_SENT = "responseSent"  # joiner only
    AUTHENTICATED = "authenticated"
    ABORTED = "aborted"


class ReconnectRejection(enum.Enum):
    """Why a reconnect step was refused. Every value is a hard stop."""

    WRONG_STATE = "wrongState"
    MALFORMED = "malformed"
    CHANNEL_MISMATCH = "channelMismatch"
    WRONG_PEER = "wrongPeer"
    BAD_SIGNATURE = "badSignature"


class ReconnectError(Exception):
    """Raised whenever a reconnect step is refused, carrying a machine-readable
    :class:`ReconnectRejection`. A failure moves the session to ``ABORTED``."""

    def __init__(self, rejection: ReconnectRejection, detail: str | None = None):
        self.rejection = rejection
        self.detail = detail
        super().__init__(
            rejection.value if detail is None else f"{rejection.value}: {detail}"
        )


# --- pure, side-effect-free helpers (shared by both roles + vectors) ---------


def reconnect_transcript(nonce_i: bytes, nonce_j: bytes) -> bytes:
    """``RT = N_i ‖ N_j`` — 64 bytes, initiator nonce first, always."""
    if len(nonce_i) != RECONNECT_NONCE_LENGTH or len(nonce_j) != RECONNECT_NONCE_LENGTH:
        raise ValueError("nonces must be 32 bytes each")
    return nonce_i + nonce_j


def reconnect_signed_bytes(label: bytes, channel_id: str, transcript: bytes) -> bytes:
    """The exact bytes a role signs: ``label ‖ channel_id ‖ RT``."""
    return label + channel_id.encode("utf-8") + transcript


def _b64(raw: bytes) -> str:
    return base64.b64encode(raw).decode("ascii")


def _unb64(value: object, label: str) -> bytes:
    if not isinstance(value, str):
        raise ReconnectError(ReconnectRejection.MALFORMED, f"{label} missing or not a string")
    try:
        return base64.b64decode(value, validate=True)
    except (ValueError, TypeError):
        raise ReconnectError(ReconnectRejection.MALFORMED, f"{label} is not valid base64")


class ReconnectHandshake:
    """A single-use, code-free reconnect handshake state machine for one role.

    Construct with :meth:`initiator` (host) or :meth:`joiner` (app). Each side is
    seeded from its persisted trust record: its own :class:`DeviceIdentity`, the
    stored ``channel_id``, and the peer's ``device_id`` + approved Ed25519 public
    key. The channel key is not touched here — the caller already holds it from
    storage and uses it once :attr:`authenticated` is true.
    """

    def __init__(
        self,
        *,
        role: ReconnectRole,
        device_id: str,
        device_identity: DeviceIdentity,
        peer_device_id: str,
        peer_public_key: Ed25519PublicKey,
        channel_id: str,
        nonce: bytes | None = None,
    ):
        if device_id == "":
            raise ValueError("device_id must not be empty")
        if peer_device_id == "":
            raise ValueError("peer_device_id must not be empty")
        if nonce is not None and len(nonce) != RECONNECT_NONCE_LENGTH:
            raise ValueError("nonce must be 32 bytes")
        self._role = role
        self._device_id = device_id
        self._identity = device_identity
        self._peer_device_id = peer_device_id
        self._peer_public_key = peer_public_key
        self._channel_id = channel_id
        self._nonce = nonce if nonce is not None else secrets.token_bytes(RECONNECT_NONCE_LENGTH)

        self._state = ReconnectState.CREATED
        self._peer_nonce: bytes | None = None

    # --- constructors --------------------------------------------------------

    @classmethod
    def initiator(
        cls,
        *,
        device_id: str,
        device_identity: DeviceIdentity,
        peer_device_id: str,
        peer_public_key: Ed25519PublicKey,
        channel_id: str,
        nonce: bytes | None = None,
    ) -> ReconnectHandshake:
        """Start a reconnect as the host — it sends the first ``hello``."""
        return cls(
            role=ReconnectRole.INITIATOR,
            device_id=device_id,
            device_identity=device_identity,
            peer_device_id=peer_device_id,
            peer_public_key=peer_public_key,
            channel_id=channel_id,
            nonce=nonce,
        )

    @classmethod
    def joiner(
        cls,
        *,
        device_id: str,
        device_identity: DeviceIdentity,
        peer_device_id: str,
        peer_public_key: Ed25519PublicKey,
        channel_id: str,
        nonce: bytes | None = None,
    ) -> ReconnectHandshake:
        """Join a reconnect as the app — it answers the host's ``hello``."""
        return cls(
            role=ReconnectRole.JOINER,
            device_id=device_id,
            device_identity=device_identity,
            peer_device_id=peer_device_id,
            peer_public_key=peer_public_key,
            channel_id=channel_id,
            nonce=nonce,
        )

    # --- observable state ----------------------------------------------------

    @property
    def role(self) -> ReconnectRole:
        return self._role

    @property
    def state(self) -> ReconnectState:
        return self._state

    @property
    def channel_id(self) -> str:
        return self._channel_id

    @property
    def peer_device_id(self) -> str:
        return self._peer_device_id

    @property
    def authenticated(self) -> bool:
        return self._state is ReconnectState.AUTHENTICATED

    # --- guards --------------------------------------------------------------

    def _require(self, expected: ReconnectState) -> None:
        if self._state in (ReconnectState.AUTHENTICATED, ReconnectState.ABORTED):
            raise ReconnectError(ReconnectRejection.WRONG_STATE, self._state.value)
        if self._state != expected:
            raise ReconnectError(
                ReconnectRejection.WRONG_STATE,
                f"expected {expected.value}, in {self._state.value}",
            )

    def _abort(self) -> None:
        self._state = ReconnectState.ABORTED
        self._peer_nonce = None

    def _sign(self, label: bytes) -> bytes:
        assert self._peer_nonce is not None
        transcript = self._current_transcript()
        return self._identity.sign(
            reconnect_signed_bytes(label, self._channel_id, transcript)
        )

    def _verify_peer(self, label: bytes, signature: bytes) -> None:
        transcript = self._current_transcript()
        message = reconnect_signed_bytes(label, self._channel_id, transcript)
        try:
            self._peer_public_key.verify(signature, message)
        except InvalidSignature:
            self._abort()
            raise ReconnectError(ReconnectRejection.BAD_SIGNATURE)

    def _current_transcript(self) -> bytes:
        assert self._peer_nonce is not None
        if self._role is ReconnectRole.INITIATOR:
            return reconnect_transcript(self._nonce, self._peer_nonce)
        return reconnect_transcript(self._peer_nonce, self._nonce)

    def _check_peer_device(self, wire_device_id: object) -> None:
        if not isinstance(wire_device_id, str) or wire_device_id == "":
            raise ReconnectError(ReconnectRejection.MALFORMED, "device_id")
        if not hmac.compare_digest(
            wire_device_id.encode("utf-8"), self._peer_device_id.encode("utf-8")
        ):
            self._abort()
            raise ReconnectError(ReconnectRejection.WRONG_PEER)

    # --- initiator steps -----------------------------------------------------

    def create_hello(self) -> dict:
        """[initiator] Publish the challenge: our ``device_id``, ``channel_id``
        and fresh nonce ``N_i``."""
        if self._role is not ReconnectRole.INITIATOR:
            raise ReconnectError(ReconnectRejection.WRONG_STATE, "initiator only")
        self._require(ReconnectState.CREATED)
        msg = {
            "type": "reconnect-hello",
            "channel_id": self._channel_id,
            "device_id": self._device_id,
            "nonce": _b64(self._nonce),
        }
        self._state = ReconnectState.HELLO_SENT
        return msg

    def on_response(self, msg: dict) -> dict:
        """[initiator] Verify the joiner's proof against the stored key, then
        sign our own proof and return the ``confirm``."""
        if self._role is not ReconnectRole.INITIATOR:
            raise ReconnectError(ReconnectRejection.WRONG_STATE, "initiator only")
        self._require(ReconnectState.HELLO_SENT)
        if msg.get("type") != "reconnect-response":
            raise ReconnectError(ReconnectRejection.MALFORMED, "expected reconnect-response")
        self._check_peer_device(msg.get("device_id"))
        peer_nonce = _unb64(msg.get("nonce"), "nonce")
        if len(peer_nonce) != RECONNECT_NONCE_LENGTH:
            raise ReconnectError(ReconnectRejection.MALFORMED, "nonce length")
        self._peer_nonce = peer_nonce
        sig_j = _unb64(msg.get("sig"), "sig")
        self._verify_peer(RECONNECT_J_LABEL, sig_j)
        proof_i = self._sign(RECONNECT_I_LABEL)
        self._state = ReconnectState.AUTHENTICATED
        return {"type": "reconnect-confirm", "sig": _b64(proof_i)}

    # --- joiner steps --------------------------------------------------------

    def on_hello(self, msg: dict) -> dict:
        """[joiner] Adopt the initiator's nonce, sign our proof, and answer with
        our nonce ``N_j`` + proof."""
        if self._role is not ReconnectRole.JOINER:
            raise ReconnectError(ReconnectRejection.WRONG_STATE, "joiner only")
        self._require(ReconnectState.CREATED)
        if msg.get("type") != "reconnect-hello":
            raise ReconnectError(ReconnectRejection.MALFORMED, "expected reconnect-hello")
        if msg.get("channel_id") != self._channel_id:
            raise ReconnectError(ReconnectRejection.CHANNEL_MISMATCH)
        self._check_peer_device(msg.get("device_id"))
        peer_nonce = _unb64(msg.get("nonce"), "nonce")
        if len(peer_nonce) != RECONNECT_NONCE_LENGTH:
            raise ReconnectError(ReconnectRejection.MALFORMED, "nonce length")
        self._peer_nonce = peer_nonce
        proof_j = self._sign(RECONNECT_J_LABEL)
        self._state = ReconnectState.RESPONSE_SENT
        return {
            "type": "reconnect-response",
            "device_id": self._device_id,
            "nonce": _b64(self._nonce),
            "sig": _b64(proof_j),
        }

    def on_confirm(self, msg: dict) -> None:
        """[joiner] Verify the initiator's proof against the stored key. On
        success the reconnect is authenticated and the stored channel key
        resumes the E2E channel."""
        if self._role is not ReconnectRole.JOINER:
            raise ReconnectError(ReconnectRejection.WRONG_STATE, "joiner only")
        self._require(ReconnectState.RESPONSE_SENT)
        if msg.get("type") != "reconnect-confirm":
            raise ReconnectError(ReconnectRejection.MALFORMED, "expected reconnect-confirm")
        sig_i = _unb64(msg.get("sig"), "sig")
        self._verify_peer(RECONNECT_I_LABEL, sig_i)
        self._state = ReconnectState.AUTHENTICATED
