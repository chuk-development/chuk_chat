"""CoWork secure pairing — SAS-authenticated X25519 with a hash commitment.

Python twin of ``cowork_pairing.dart``. Implements §15 of the platform plan:
establish an E2E channel key **and** mutual device trust between the desktop app
(joiner) and the Python client (initiator) using a short human code, such that
even a malicious relay/backend cannot MITM or spoof, and a stolen code cannot
hijack the client.

The primitive is the ZRTP / Signal-safety-number pattern, built only from
X25519 + HKDF-SHA256 + SHA-256 (all present in ``cryptography``). A PAKE was
rejected for lack of a maintained Dart implementation; SAS + commitment gives
equivalent MITM resistance for a single-use short code.

## Byte-exact cross-language contract (the Dart twin must match this)

All multi-byte lengths are big-endian. All labels are ASCII, no terminator.

Roles
    * **initiator** = the Python client. Ephemeral X25519 key ``(a, A)``.
    * **joiner**    = the desktop app.   Ephemeral X25519 key ``(b, B)``.
    * ``A`` and ``B`` are the 32-byte **raw** X25519 public keys.

Pairing code ``PC``
    ``PC = f"{channel_id}-{digits}"`` — the exact UTF-8 string. ``channel_id``
    routes on the relay; ``digits`` is the human secret. Both are folded into
    the SAS as the whole ``PC`` string's UTF-8 bytes.

Commitment
    ``commitment = SHA-256( COMMIT_LABEL ‖ A )`` — 32 bytes. Domain-separated
    so it can never collide with some other SHA-256 use. (§15 writes ``H(A)``;
    the domain prefix is the one concrete choice made here, documented so both
    sides match.)

Shared secret and transcript
    ``K_raw = X25519(priv, peer_pub)``  — 32 raw bytes, identical on both sides.
    ``T = A ‖ B``                       — 64 bytes, **initiator public first**,
                                          regardless of which side computes it.

Channel key (the key that later seals frames, §14)
    ``channel_key = HKDF-SHA256(ikm=K_raw, salt="", info=CHANNEL_KEY_INFO, 32)``
    — reuses :func:`cowork_crypto.channel_key.derive_channel_key` verbatim, so
    pairing yields exactly the key the frame codec expects.

Key-confirmation MACs (the pairing code is the authenticator)
    ``MAC_d = HKDF-SHA256(ikm=K_raw, salt="", info=CONFIRM_D_LABEL ‖ T ‖ PC, 32)``
    ``MAC_c = HKDF-SHA256(ikm=K_raw, salt="", info=CONFIRM_C_LABEL ‖ T ‖ PC, 32)``
    The joiner (desktop) sends ``MAC_d``; the initiator verifies it. The
    initiator (client) sends ``MAC_c``; the joiner verifies it.

    **Why ``PC`` is folded in.** Our UX types the code one way — the user reads
    ``PC`` off the client and types it into the desktop — with no step where a
    human compares a SAS across both screens. A relaying attacker can complete
    two ECDH legs, one ``K`` with each honest side, and knows every ``K`` and
    ``T`` on the wire; with a MAC over ``T`` alone it would recompute a valid
    MAC per leg and pass both confirmation checks. The one thing it never sees
    is ``PC`` (out of band). Folding ``PC`` into the MAC makes both honest MACs
    unforgeable unless the peer holds the same code, so security does **not**
    rest on any human SAS comparison. A MITM (two different ``K_raw``, or the
    wrong ``PC``) fails the constant-time check → abort, and no channel key is
    ever handed out.

SAS (optional display value only)
    ``sas_bytes = HKDF-SHA256(ikm=K_raw, salt="", info=SAS_LABEL ‖ T ‖ PC, 8)``
    ``SAS = ( int_be(sas_bytes) mod 10**digits )`` left-zero-padded to ``digits``
    decimal characters. It MAY be shown for reassurance, but the protocol's
    MITM resistance no longer depends on anyone comparing it;
    :meth:`Pairing.confirm_peer_sas` is an optional helper, not part of the
    happy path.

Device-key approval (bootstraps mutual device trust, §8 default-deny)
    Each side reveals its long-term Ed25519 device public key under ``K``:
    ``proof = Ed25519.sign( DEVICE_PROOF_LABEL ‖ T ‖ device_id_utf8 )`` and
    ``mac   = HKDF-SHA256(ikm=K_raw, salt="", info=LBL ‖ T ‖ ed_pub ‖ id ‖ PC, 32)``
    where ``LBL`` is ``DEVICE_D_LABEL`` for the joiner and ``DEVICE_C_LABEL``
    for the initiator. ``PC`` is folded in for the same reason as the confirm
    MACs. The receiver checks the MAC (binds the key to this live session under
    the shared code, constant-time) and the signature (proves possession of the
    private key over this transcript), then locally approves the peer into
    :class:`ApprovedDevices`.

Every verification is constant-time. The session is single-use and expires; any
step after completion, abort, or expiry is refused. No usable channel key is
ever exposed unless both confirmation MACs verified.
"""

from __future__ import annotations

import base64
import enum
import hmac
import secrets
from collections.abc import Callable

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric.x25519 import (
    X25519PrivateKey,
    X25519PublicKey,
)
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

from .approved_devices import ApprovedDevices
from .channel_key import derive_channel_key
from .device_keys import (
    PUBLIC_KEY_LENGTH,
    DeviceIdentity,
    public_key_from_base64,
)

# --- byte-exact protocol constants (mirror cowork_pairing.dart) --------------

# HKDF ``info`` label prefixes. ASCII, no terminator. Bump the trailing version
# only for a breaking change to a derivation.
SAS_LABEL = b"cowork/pairing/sas"
CONFIRM_D_LABEL = b"cowork/pairing/confirm-d"
CONFIRM_C_LABEL = b"cowork/pairing/confirm-c"
DEVICE_D_LABEL = b"cowork/pairing/device-d"
DEVICE_C_LABEL = b"cowork/pairing/device-c"
DEVICE_PROOF_LABEL = b"cowork/pairing/device-proof"

# SHA-256 domain prefix for the commitment H(A).
COMMIT_LABEL = b"cowork/pairing/commit-v1"

# HKDF-SHA256 extract salt. Empty per RFC 5869 (== HashLen zero bytes). Kept
# explicit and identical to ``channel_key.py`` (salt=None) so both languages and
# both modules agree.
HKDF_SALT = b""

# X25519 raw public key length in bytes.
X25519_PUBLIC_LENGTH = 32

# SHA-256 commitment length in bytes.
COMMITMENT_LENGTH = 32

# Confirmation / device MAC length in bytes.
MAC_LENGTH = 32

# Bytes drawn from HKDF to fold down into the decimal SAS. 8 bytes = 64 bits of
# entropy before the ``mod 10**digits``, far more than the ~20-bit code needs.
SAS_HKDF_BYTES = 8

# Default number of decimal digits in the human SAS / pairing code.
DEFAULT_SAS_DIGITS = 6

# Default pairing-code lifetime in milliseconds (~2 minutes, §15).
DEFAULT_EXPIRY_MS = 120_000

# Bytes of randomness behind the routing ``channel_id`` (hex-encoded).
_CHANNEL_ID_BYTES = 8


class PairingRole(enum.Enum):
    """Which side of the ceremony this session drives."""

    INITIATOR = "initiator"  # the Python client
    JOINER = "joiner"  # the desktop app


class PairingState(enum.Enum):
    """Ordered lifecycle. Illegal transitions and any use after a terminal
    state (``COMPLETED`` / ``ABORTED``) are refused."""

    CREATED = "created"
    COMMIT_SENT = "commitSent"  # initiator only
    COMMIT_RECEIVED = "commitReceived"  # joiner only
    PUBKEY_SENT = "pubkeySent"  # joiner only
    KEY_ESTABLISHED = "keyEstablished"  # K + SAS derived, MACs not yet checked
    CONFIRMED = "confirmed"  # both confirmation MACs verified
    COMPLETED = "completed"  # peer device key approved
    ABORTED = "aborted"


class PairingRejection(enum.Enum):
    """Why a pairing step was refused. Every value is a hard stop."""

    WRONG_STATE = "wrongState"
    EXPIRED = "expired"
    CONSUMED = "consumed"
    MALFORMED = "malformed"
    CHANNEL_MISMATCH = "channelMismatch"
    COMMITMENT_MISMATCH = "commitmentMismatch"
    SAS_MISMATCH = "sasMismatch"
    MAC_MISMATCH = "macMismatch"
    BAD_DEVICE_PROOF = "badDeviceProof"


class PairingError(Exception):
    """Raised whenever a pairing step is refused, carrying a machine-readable
    :class:`PairingRejection`. Any failure past key establishment first moves
    the session to ``ABORTED`` and discards key material."""

    def __init__(self, rejection: PairingRejection, detail: str | None = None):
        self.rejection = rejection
        self.detail = detail
        super().__init__(
            rejection.value if detail is None else f"{rejection.value}: {detail}"
        )


# --- pure, side-effect-free crypto helpers (shared by both roles + vectors) --


def _hkdf(ikm: bytes, info: bytes, length: int) -> bytes:
    return HKDF(
        algorithm=hashes.SHA256(),
        length=length,
        salt=HKDF_SALT or None,
        info=info,
    ).derive(ikm)


def commitment(public_a: bytes) -> bytes:
    """``SHA-256(COMMIT_LABEL ‖ A)`` — the initiator's binding commitment to
    its ephemeral public key ``A``. 32 bytes."""
    if len(public_a) != X25519_PUBLIC_LENGTH:
        raise ValueError("public_a must be a 32-byte X25519 public key")
    digest = hashes.Hash(hashes.SHA256())
    digest.update(COMMIT_LABEL)
    digest.update(public_a)
    return digest.finalize()


def transcript(public_a: bytes, public_b: bytes) -> bytes:
    """``T = A ‖ B`` — 64 bytes, initiator public first, always."""
    if len(public_a) != X25519_PUBLIC_LENGTH or len(public_b) != X25519_PUBLIC_LENGTH:
        raise ValueError("public keys must be 32 raw X25519 bytes")
    return public_a + public_b


def derive_sas(k_raw: bytes, t: bytes, pairing_code: str, digits: int) -> str:
    """The decimal SAS both sides compute and a human compares out of band."""
    out = _hkdf(k_raw, SAS_LABEL + t + pairing_code.encode("utf-8"), SAS_HKDF_BYTES)
    value = int.from_bytes(out, "big") % (10**digits)
    return str(value).zfill(digits)


def derive_confirm_mac(k_raw: bytes, label: bytes, t: bytes, pairing_code: str) -> bytes:
    """A key-confirmation MAC: ``HKDF(K_raw, label ‖ T ‖ PC, 32)``.

    ``PC`` (the pairing code) is folded in so the out-of-band, one-way-typed
    human code authenticates the channel. Without it a relaying attacker who
    completes two ECDH legs (one ``K`` with each honest side) could recompute a
    valid MAC for each leg and pass both confirmation checks. Folding ``PC`` —
    which the attacker never sees — makes both honest MACs unforgeable unless
    the peer holds the same code. This removes the need for a human to compare a
    SAS across two screens; our UX has no such step.
    """
    return _hkdf(k_raw, label + t + pairing_code.encode("utf-8"), MAC_LENGTH)


def _device_mac(
    k_raw: bytes,
    label: bytes,
    t: bytes,
    ed_pub: bytes,
    device_id: str,
    pairing_code: str,
) -> bytes:
    return _hkdf(
        k_raw,
        label + t + ed_pub + device_id.encode("utf-8") + pairing_code.encode("utf-8"),
        MAC_LENGTH,
    )


def _device_proof_message(t: bytes, device_id: str) -> bytes:
    return DEVICE_PROOF_LABEL + t + device_id.encode("utf-8")


def _b64(raw: bytes) -> str:
    return base64.b64encode(raw).decode("ascii")


def _unb64(value: object, label: str) -> bytes:
    if not isinstance(value, str):
        raise PairingError(PairingRejection.MALFORMED, f"{label} missing or not a string")
    try:
        return base64.b64decode(value, validate=True)
    except (ValueError, TypeError):
        raise PairingError(PairingRejection.MALFORMED, f"{label} is not valid base64")


def _default_now_ms() -> int:
    import time

    return int(time.time() * 1000)


class Pairing:
    """A single-use pairing session state machine for one role.

    Construct with :meth:`initiator` (Python client) or :meth:`joiner` (desktop
    app). Each message-handling method consumes a JSON-serialisable ``dict`` and
    returns the next one to put on the wire (or ``None``). The wire messages are
    plain dicts by design: they ride the real relay later, but here they are
    passed hand to hand so they can be tested directly.
    """

    def __init__(
        self,
        *,
        role: PairingRole,
        device_id: str,
        device_identity: DeviceIdentity,
        ephemeral_private: X25519PrivateKey,
        channel_id: str,
        pairing_code: str,
        sas_digits: int,
        expires_at_ms: int,
        now_ms: Callable[[], int],
        approved_devices: ApprovedDevices,
    ):
        if device_id == "":
            raise ValueError("device_id must not be empty")
        self._role = role
        self._device_id = device_id
        self._identity = device_identity
        self._ephemeral_private = ephemeral_private
        self._ephemeral_public = ephemeral_private.public_key().public_bytes_raw()
        self._channel_id = channel_id
        self._pairing_code = pairing_code
        self._sas_digits = sas_digits
        self._expires_at_ms = expires_at_ms
        self._now_ms = now_ms
        self._approved = approved_devices

        self._state = PairingState.CREATED
        # Filled in as the ceremony proceeds. Cleared to None on abort.
        self._peer_public: bytes | None = None
        self._commitment: bytes | None = None  # joiner: the received commitment
        self._k_raw: bytes | None = None
        self._channel_key: bytes | None = None
        self._sas: str | None = None
        self._peer_device_id: str | None = None
        # The device-key exchange is bidirectional; the session only completes
        # once we have both sent our own key and approved the peer's.
        self._sent_device_key = False
        self._approved_peer = False

    # --- constructors --------------------------------------------------------

    @classmethod
    def initiator(
        cls,
        *,
        device_id: str,
        device_identity: DeviceIdentity,
        sas_digits: int = DEFAULT_SAS_DIGITS,
        expiry_ms: int = DEFAULT_EXPIRY_MS,
        now_ms: Callable[[], int] | None = None,
        approved_devices: ApprovedDevices | None = None,
        # Injected only for deterministic vectors / tests:
        ephemeral_private: X25519PrivateKey | None = None,
        channel_id: str | None = None,
        digits: str | None = None,
    ) -> Pairing:
        """Start a pairing session as the Python client. Generates the ephemeral
        ``(a, A)`` and the single-use pairing code, and fixes the expiry."""
        if sas_digits < 1:
            raise ValueError("sas_digits must be >= 1")
        now = now_ms or _default_now_ms
        channel_id = channel_id or secrets.token_hex(_CHANNEL_ID_BYTES)
        if "-" in channel_id:
            raise ValueError("channel_id must not contain '-'")
        digits = digits if digits is not None else _random_digits(sas_digits)
        if len(digits) != sas_digits or not digits.isdigit():
            raise ValueError("digits must be exactly sas_digits decimal characters")
        pairing_code = f"{channel_id}-{digits}"
        return cls(
            role=PairingRole.INITIATOR,
            device_id=device_id,
            device_identity=device_identity,
            ephemeral_private=ephemeral_private if ephemeral_private is not None else X25519PrivateKey.generate(),
            channel_id=channel_id,
            pairing_code=pairing_code,
            sas_digits=sas_digits,
            expires_at_ms=now() + expiry_ms,
            now_ms=now,
            approved_devices=approved_devices if approved_devices is not None else ApprovedDevices.empty(),
        )

    @classmethod
    def joiner(
        cls,
        *,
        device_id: str,
        device_identity: DeviceIdentity,
        pairing_code: str,
        now_ms: Callable[[], int] | None = None,
        approved_devices: ApprovedDevices | None = None,
        # Injected only for deterministic vectors / tests:
        ephemeral_private: X25519PrivateKey | None = None,
    ) -> Pairing:
        """Join a pairing session as the desktop app, from the human-entered
        pairing code. The expiry is carried in the initiator's commit; the
        joiner adopts it in :meth:`on_commit`."""
        channel_id, sep, digits = pairing_code.rpartition("-")
        if sep == "" or channel_id == "" or digits == "" or not digits.isdigit():
            raise PairingError(PairingRejection.MALFORMED, "pairing code")
        now = now_ms or _default_now_ms
        return cls(
            role=PairingRole.JOINER,
            device_id=device_id,
            device_identity=device_identity,
            ephemeral_private=ephemeral_private if ephemeral_private is not None else X25519PrivateKey.generate(),
            channel_id=channel_id,
            pairing_code=pairing_code,
            sas_digits=len(digits),
            expires_at_ms=0,  # set from the commit
            now_ms=now,
            approved_devices=approved_devices if approved_devices is not None else ApprovedDevices.empty(),
        )

    # --- observable state ----------------------------------------------------

    @property
    def role(self) -> PairingRole:
        return self._role

    @property
    def state(self) -> PairingState:
        return self._state

    @property
    def pairing_code(self) -> str:
        """The full ``PC`` — initiator displays it, joiner echoes it."""
        return self._pairing_code

    @property
    def channel_id(self) -> str:
        return self._channel_id

    @property
    def sas(self) -> str:
        """The short authentication string, available once ``K`` is derived.
        Compared out of band by the human; exposing it before confirmation is
        the whole point of a SAS."""
        if self._sas is None:
            raise PairingError(PairingRejection.WRONG_STATE, "SAS not derived yet")
        return self._sas

    @property
    def approved_devices(self) -> ApprovedDevices:
        return self._approved

    @property
    def peer_device_id(self) -> str | None:
        return self._peer_device_id

    @property
    def channel_key(self) -> bytes:
        """The 32-byte CoWork channel key — **only** after both confirmation
        MACs verified. Before that, or after an abort, this raises: no usable
        channel key is ever committed on a mismatch."""
        if self._state in (PairingState.CONFIRMED, PairingState.COMPLETED) and self._channel_key is not None:
            return self._channel_key
        raise PairingError(
            PairingRejection.WRONG_STATE,
            "channel key is not available until both MACs verify",
        )

    # --- guards --------------------------------------------------------------

    def _require(self, expected: PairingState) -> None:
        if self._state in (PairingState.COMPLETED, PairingState.ABORTED):
            raise PairingError(PairingRejection.CONSUMED, self._state.value)
        if self._state != expected:
            raise PairingError(
                PairingRejection.WRONG_STATE,
                f"expected {expected.value}, in {self._state.value}",
            )

    def _check_not_expired(self) -> None:
        if self._expires_at_ms and self._now_ms() > self._expires_at_ms:
            self._abort()
            raise PairingError(PairingRejection.EXPIRED)

    def _abort(self) -> None:
        self._state = PairingState.ABORTED
        # Discard all key material so nothing usable survives a failed ceremony.
        self._k_raw = None
        self._channel_key = None

    # --- initiator steps -----------------------------------------------------

    def create_commit(self) -> dict:
        """[initiator] Publish the commitment ``H(A)`` and the routing id."""
        if self._role is not PairingRole.INITIATOR:
            raise PairingError(PairingRejection.WRONG_STATE, "initiator only")
        self._require(PairingState.CREATED)
        self._check_not_expired()
        msg = {
            "type": "commit",
            "channel_id": self._channel_id,
            "commitment": _b64(commitment(self._ephemeral_public)),
            "expires_at": self._expires_at_ms,
            "sas_digits": self._sas_digits,
        }
        self._state = PairingState.COMMIT_SENT
        return msg

    def on_pubkey(self, msg: dict) -> dict:
        """[initiator] Receive the joiner's ``B``, derive ``K`` and the SAS, and
        reveal ``A``."""
        if self._role is not PairingRole.INITIATOR:
            raise PairingError(PairingRejection.WRONG_STATE, "initiator only")
        self._require(PairingState.COMMIT_SENT)
        self._check_not_expired()
        if msg.get("type") != "pubkey":
            raise PairingError(PairingRejection.MALFORMED, "expected pubkey")
        peer_b = _unb64(msg.get("pubkey"), "pubkey")
        if len(peer_b) != X25519_PUBLIC_LENGTH:
            raise PairingError(PairingRejection.MALFORMED, "pubkey length")
        self._peer_public = peer_b
        self._establish_key(public_a=self._ephemeral_public, public_b=peer_b)
        self._state = PairingState.KEY_ESTABLISHED
        return {"type": "reveal", "pubkey": _b64(self._ephemeral_public)}

    def on_confirm_d(self, msg: dict) -> dict:
        """[initiator] Verify the joiner's ``MAC_d`` (constant-time) and send
        ``MAC_c``."""
        if self._role is not PairingRole.INITIATOR:
            raise PairingError(PairingRejection.WRONG_STATE, "initiator only")
        self._require(PairingState.KEY_ESTABLISHED)
        self._check_not_expired()
        if msg.get("type") != "confirm-d":
            raise PairingError(PairingRejection.MALFORMED, "expected confirm-d")
        self._verify_confirm(msg, CONFIRM_D_LABEL)
        self._state = PairingState.CONFIRMED
        assert self._k_raw is not None
        t = self._current_transcript()
        return {
            "type": "confirm-c",
            "mac": _b64(
                derive_confirm_mac(self._k_raw, CONFIRM_C_LABEL, t, self._pairing_code)
            ),
        }

    # --- joiner steps --------------------------------------------------------

    def on_commit(self, msg: dict) -> None:
        """[joiner] Store the commitment and adopt the initiator's expiry."""
        if self._role is not PairingRole.JOINER:
            raise PairingError(PairingRejection.WRONG_STATE, "joiner only")
        self._require(PairingState.CREATED)
        if msg.get("type") != "commit":
            raise PairingError(PairingRejection.MALFORMED, "expected commit")
        if msg.get("channel_id") != self._channel_id:
            raise PairingError(PairingRejection.CHANNEL_MISMATCH)
        received = _unb64(msg.get("commitment"), "commitment")
        if len(received) != COMMITMENT_LENGTH:
            raise PairingError(PairingRejection.MALFORMED, "commitment length")
        expires_at = msg.get("expires_at")
        if not isinstance(expires_at, int) or isinstance(expires_at, bool):
            raise PairingError(PairingRejection.MALFORMED, "expires_at")
        self._expires_at_ms = expires_at
        self._check_not_expired()
        self._commitment = received
        self._state = PairingState.COMMIT_RECEIVED

    def create_pubkey(self) -> dict:
        """[joiner] Send ephemeral ``B``."""
        if self._role is not PairingRole.JOINER:
            raise PairingError(PairingRejection.WRONG_STATE, "joiner only")
        self._require(PairingState.COMMIT_RECEIVED)
        self._check_not_expired()
        self._state = PairingState.PUBKEY_SENT
        return {"type": "pubkey", "pubkey": _b64(self._ephemeral_public)}

    def on_reveal(self, msg: dict) -> dict:
        """[joiner] Receive ``A``, check ``H(A) == commitment`` (constant-time),
        derive ``K`` + SAS, and send ``MAC_d``."""
        if self._role is not PairingRole.JOINER:
            raise PairingError(PairingRejection.WRONG_STATE, "joiner only")
        self._require(PairingState.PUBKEY_SENT)
        self._check_not_expired()
        if msg.get("type") != "reveal":
            raise PairingError(PairingRejection.MALFORMED, "expected reveal")
        peer_a = _unb64(msg.get("pubkey"), "pubkey")
        if len(peer_a) != X25519_PUBLIC_LENGTH:
            raise PairingError(PairingRejection.MALFORMED, "pubkey length")
        assert self._commitment is not None
        if not hmac.compare_digest(commitment(peer_a), self._commitment):
            self._abort()
            raise PairingError(PairingRejection.COMMITMENT_MISMATCH)
        self._peer_public = peer_a
        self._establish_key(public_a=peer_a, public_b=self._ephemeral_public)
        self._state = PairingState.KEY_ESTABLISHED
        assert self._k_raw is not None
        t = self._current_transcript()
        return {
            "type": "confirm-d",
            "mac": _b64(
                derive_confirm_mac(self._k_raw, CONFIRM_D_LABEL, t, self._pairing_code)
            ),
        }

    def on_confirm_c(self, msg: dict) -> None:
        """[joiner] Verify the initiator's ``MAC_c`` (constant-time)."""
        if self._role is not PairingRole.JOINER:
            raise PairingError(PairingRejection.WRONG_STATE, "joiner only")
        self._require(PairingState.KEY_ESTABLISHED)
        self._check_not_expired()
        if msg.get("type") != "confirm-c":
            raise PairingError(PairingRejection.MALFORMED, "expected confirm-c")
        self._verify_confirm(msg, CONFIRM_C_LABEL)
        self._state = PairingState.CONFIRMED

    # --- shared: SAS out-of-band comparison ----------------------------------

    def confirm_peer_sas(self, peer_sas: str) -> None:
        """**Optional** constant-time compare of the peer's SAS with ours.

        Provided only for UIs that want to *display* a matching short string for
        reassurance. It is not required for security and not part of the happy
        path: the confirmation MACs already fold ``PC`` in, so a wrong code or a
        relaying MITM is caught there and aborts before this is ever called."""
        if self._sas is None:
            raise PairingError(PairingRejection.WRONG_STATE, "SAS not derived yet")
        if not hmac.compare_digest(peer_sas.encode("utf-8"), self._sas.encode("utf-8")):
            self._abort()
            raise PairingError(PairingRejection.SAS_MISMATCH)

    # --- shared: device-key approval exchange --------------------------------

    def create_device_key(self) -> dict:
        """Reveal our own Ed25519 device public key, authenticated under ``K``.
        Callable once the confirmation MACs verified (``CONFIRMED``)."""
        self._require(PairingState.CONFIRMED)
        self._check_not_expired()
        if self._sent_device_key:
            raise PairingError(PairingRejection.WRONG_STATE, "device key already sent")
        self._sent_device_key = True
        assert self._k_raw is not None
        t = self._current_transcript()
        ed_pub = self._identity.public_key_bytes()
        label = DEVICE_D_LABEL if self._role is PairingRole.JOINER else DEVICE_C_LABEL
        result = {
            "type": "device-key",
            "device_id": self._device_id,
            "ed25519_pub": self._identity.export_public_key_base64(),
            "proof": _b64(self._identity.sign(_device_proof_message(t, self._device_id))),
            "mac": _b64(
                _device_mac(
                    self._k_raw, label, t, ed_pub, self._device_id, self._pairing_code
                )
            ),
        }
        self._maybe_complete()
        return result

    def on_peer_device_key(self, msg: dict) -> None:
        """Verify the peer's device-key message under ``K`` and its self-
        signature, then locally approve it (§8 default-deny). Completes the
        session on success."""
        self._require(PairingState.CONFIRMED)
        self._check_not_expired()
        if msg.get("type") != "device-key":
            raise PairingError(PairingRejection.MALFORMED, "expected device-key")
        peer_device_id = msg.get("device_id")
        if not isinstance(peer_device_id, str) or peer_device_id == "":
            raise PairingError(PairingRejection.MALFORMED, "device_id")
        ed_pub_raw = _unb64(msg.get("ed25519_pub"), "ed25519_pub")
        if len(ed_pub_raw) != PUBLIC_KEY_LENGTH:
            raise PairingError(PairingRejection.MALFORMED, "ed25519_pub length")
        proof = _unb64(msg.get("proof"), "proof")
        mac = _unb64(msg.get("mac"), "mac")

        assert self._k_raw is not None
        t = self._current_transcript()
        # The peer's role is the opposite of ours, so its label is too.
        label = DEVICE_C_LABEL if self._role is PairingRole.JOINER else DEVICE_D_LABEL
        expected_mac = _device_mac(
            self._k_raw, label, t, ed_pub_raw, peer_device_id, self._pairing_code
        )
        if not hmac.compare_digest(mac, expected_mac):
            self._abort()
            raise PairingError(PairingRejection.MAC_MISMATCH)

        peer_ed = public_key_from_base64(_b64(ed_pub_raw))
        try:
            peer_ed.verify(proof, _device_proof_message(t, peer_device_id))
        except InvalidSignature:
            self._abort()
            raise PairingError(PairingRejection.BAD_DEVICE_PROOF)

        self._approved.approve(peer_device_id, peer_ed)
        self._peer_device_id = peer_device_id
        self._approved_peer = True
        self._maybe_complete()

    def _maybe_complete(self) -> None:
        """Move to ``COMPLETED`` once both directions of the device-key exchange
        are done — we have revealed our key and approved the peer's."""
        if self._sent_device_key and self._approved_peer:
            self._state = PairingState.COMPLETED

    # --- internals -----------------------------------------------------------

    def _current_transcript(self) -> bytes:
        assert self._peer_public is not None
        if self._role is PairingRole.INITIATOR:
            return transcript(self._ephemeral_public, self._peer_public)
        return transcript(self._peer_public, self._ephemeral_public)

    def _establish_key(self, *, public_a: bytes, public_b: bytes) -> None:
        peer_public = X25519PublicKey.from_public_bytes(self._peer_public)  # type: ignore[arg-type]
        self._k_raw = self._ephemeral_private.exchange(peer_public)
        self._channel_key = derive_channel_key(self._ephemeral_private, peer_public)
        t = transcript(public_a, public_b)
        self._sas = derive_sas(self._k_raw, t, self._pairing_code, self._sas_digits)

    def _verify_confirm(self, msg: dict, label: bytes) -> None:
        assert self._k_raw is not None
        mac = _unb64(msg.get("mac"), "mac")
        expected = derive_confirm_mac(
            self._k_raw, label, self._current_transcript(), self._pairing_code
        )
        if not hmac.compare_digest(mac, expected):
            self._abort()
            raise PairingError(PairingRejection.MAC_MISMATCH)


def _random_digits(n: int) -> str:
    return "".join(str(secrets.randbelow(10)) for _ in range(n))
