"""The agent mail seal ``chuk-agent-mail-v1`` (docs/AGENT_MAIL.md §3.2).

The server seals every content field of a mail to the user's **mail key**, an
X25519 key pair. The app makes the pair and hands the private key to the host
(sealed app frame ``agent_mail_key``, §6.1). The host opens the fields here,
on its own machine. The server cannot open them.

Sealing to a public key ``R``:

1. A new ephemeral X25519 pair ``e``, ``E``.
2. ``shared = X25519(e, R)``.
3. ``key = HKDF-SHA256(ikm=shared, salt=E || R, info="chuk-agent-mail-v1", length=32)``.
4. ``nonce`` = 12 random bytes; ``ct = AES-256-GCM(key, nonce, plaintext,
   aad="chuk-agent-mail-v1")`` with the 16-byte tag at the end.
5. Text form: ``{"v":1,"epk":b64(E),"n":b64(nonce),"ct":b64(ct)}``.
6. Binary form: ``"CAM1" || E || nonce || ct``.

The host only opens. :func:`seal_text`, :func:`seal_json` and
:func:`seal_binary` exist for the test vector and for the tests' fake server.

Nothing here logs. A key never appears in a ``repr`` or an error text.
"""

from __future__ import annotations

import base64
import binascii
import hmac
import json
import os
from dataclasses import dataclass, field
from typing import Any

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric.x25519 import (
    X25519PrivateKey,
    X25519PublicKey,
)
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

#: The HKDF ``info`` and the AES-GCM associated data.
LABEL = b"chuk-agent-mail-v1"
#: The first bytes of the binary form.
BINARY_MAGIC = b"CAM1"
TEXT_VERSION = 1
KEY_LEN = 32
NONCE_LEN = 12
TAG_LEN = 16


class MailSealError(Exception):
    """A sealed value that did not open: a wrong key, a damaged envelope or
    a value that is not an envelope. The text names the problem, never a
    key or any content."""


def _b64decode(value: Any, what: str) -> bytes:
    if not isinstance(value, str) or not value:
        raise MailSealError(f"{what} is missing")
    try:
        return base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError):
        raise MailSealError(f"{what} is not base64") from None


def _b64(data: bytes) -> str:
    return base64.b64encode(data).decode("ascii")


@dataclass(frozen=True)
class MailKey:
    """The user's mail key pair: raw 32-byte X25519 keys.

    Build it with :meth:`from_b64`, which checks the pair: both keys are 32
    bytes and the public key belongs to the private key.
    """

    public_key: bytes
    private_key: bytes = field(repr=False)

    def __post_init__(self) -> None:
        if len(self.public_key) != KEY_LEN or len(self.private_key) != KEY_LEN:
            raise ValueError("a mail key is 32 bytes")
        derived = (
            X25519PrivateKey.from_private_bytes(self.private_key)
            .public_key()
            .public_bytes_raw()
        )
        if not hmac.compare_digest(derived, self.public_key):
            raise ValueError("the public key does not belong to the private key")

    @classmethod
    def from_b64(cls, public_b64: Any, private_b64: Any) -> "MailKey":
        """The pair from standard base64 text. Raises ``ValueError`` for a
        value that is not base64, not 32 bytes, or not a matching pair."""
        try:
            public = _b64decode(public_b64, "public_key")
            private = _b64decode(private_b64, "private_key")
        except MailSealError as exc:
            raise ValueError(str(exc)) from None
        return cls(public_key=public, private_key=private)

    def public_b64(self) -> str:
        return _b64(self.public_key)

    def private_b64(self) -> str:
        return _b64(self.private_key)

    def same_as(self, other: "MailKey | None") -> bool:
        return other is not None and hmac.compare_digest(
            self.private_key, other.private_key
        )

    def __repr__(self) -> str:  # never the private key
        return "MailKey(<x25519>)"


def _derive(shared: bytes, ephemeral_public: bytes, recipient_public: bytes) -> bytes:
    return HKDF(
        algorithm=hashes.SHA256(),
        length=KEY_LEN,
        salt=ephemeral_public + recipient_public,
        info=LABEL,
    ).derive(shared)


def _seal(
    plaintext: bytes,
    recipient_public: bytes,
    *,
    ephemeral_private: bytes | None = None,
    nonce: bytes | None = None,
) -> tuple[bytes, bytes, bytes]:
    if len(recipient_public) != KEY_LEN:
        raise ValueError("a mail key is 32 bytes")
    eph = (
        X25519PrivateKey.from_private_bytes(ephemeral_private)
        if ephemeral_private is not None
        else X25519PrivateKey.generate()
    )
    eph_public = eph.public_key().public_bytes_raw()
    shared = eph.exchange(X25519PublicKey.from_public_bytes(recipient_public))
    nonce = nonce if nonce is not None else os.urandom(NONCE_LEN)
    if len(nonce) != NONCE_LEN:
        raise ValueError("the nonce is 12 bytes")
    key = _derive(shared, eph_public, recipient_public)
    return eph_public, nonce, AESGCM(key).encrypt(nonce, plaintext, LABEL)


def _open(key: MailKey, eph_public: bytes, nonce: bytes, ct: bytes) -> bytes:
    if len(eph_public) != KEY_LEN:
        raise MailSealError("the ephemeral key is not 32 bytes")
    if len(nonce) != NONCE_LEN:
        raise MailSealError("the nonce is not 12 bytes")
    if len(ct) < TAG_LEN:
        raise MailSealError("the ciphertext is too short")
    try:
        shared = X25519PrivateKey.from_private_bytes(key.private_key).exchange(
            X25519PublicKey.from_public_bytes(eph_public)
        )
        aead_key = _derive(shared, eph_public, key.public_key)
        return AESGCM(aead_key).decrypt(nonce, ct, LABEL)
    except InvalidTag:
        raise MailSealError("the value does not open with this mail key") from None
    except ValueError:
        # A low-order ephemeral key gives an all-zero shared secret.
        raise MailSealError("the ephemeral key is not usable") from None


# -- the text form -------------------------------------------------------------


def seal_text(
    plaintext: bytes,
    recipient_public: bytes,
    *,
    ephemeral_private: bytes | None = None,
    nonce: bytes | None = None,
) -> dict[str, Any]:
    """The text envelope of ``plaintext``. Fixed ``ephemeral_private`` and
    ``nonce`` only for the test vector."""
    eph_public, nonce, ct = _seal(
        plaintext, recipient_public, ephemeral_private=ephemeral_private, nonce=nonce
    )
    return {"v": TEXT_VERSION, "epk": _b64(eph_public), "n": _b64(nonce), "ct": _b64(ct)}


def open_text(envelope: Any, key: MailKey) -> bytes:
    """The plaintext of a text envelope: a dict, or the JSON text of one."""
    if isinstance(envelope, (str, bytes)):
        try:
            envelope = json.loads(envelope)
        except (ValueError, UnicodeDecodeError):
            raise MailSealError("the envelope is not JSON") from None
    if not isinstance(envelope, dict):
        raise MailSealError("the envelope is not an object")
    if envelope.get("v") != TEXT_VERSION or isinstance(envelope.get("v"), bool):
        raise MailSealError("unknown envelope version")
    return _open(
        key,
        _b64decode(envelope.get("epk"), "epk"),
        _b64decode(envelope.get("n"), "n"),
        _b64decode(envelope.get("ct"), "ct"),
    )


def seal_json(doc: dict[str, Any], recipient_public: bytes) -> dict[str, Any]:
    """The text envelope of a JSON document, as the server stores
    ``sealed_summary`` and ``sealed_body`` (for the tests' fake server)."""
    return seal_text(json.dumps(doc, ensure_ascii=False).encode("utf-8"), recipient_public)


def open_json(envelope: Any, key: MailKey) -> dict[str, Any]:
    """A sealed JSON document (``sealed_summary``, ``sealed_body``,
    ``agent_note_sealed``) as a dict. A plaintext that is not a JSON object
    is refused like a wrong key: the host never shows half-decoded bytes."""
    plain = open_text(envelope, key)
    try:
        doc = json.loads(plain.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        raise MailSealError("the sealed document is not JSON") from None
    if not isinstance(doc, dict):
        raise MailSealError("the sealed document is not an object")
    return doc


# -- the binary form (attachment objects) --------------------------------------


def seal_binary(
    plaintext: bytes,
    recipient_public: bytes,
    *,
    ephemeral_private: bytes | None = None,
    nonce: bytes | None = None,
) -> bytes:
    eph_public, nonce, ct = _seal(
        plaintext, recipient_public, ephemeral_private=ephemeral_private, nonce=nonce
    )
    return BINARY_MAGIC + eph_public + nonce + ct


def open_binary(blob: bytes, key: MailKey) -> bytes:
    if not isinstance(blob, (bytes, bytearray)):
        raise MailSealError("the object is not bytes")
    data = bytes(blob)
    head = len(BINARY_MAGIC)
    if data[:head] != BINARY_MAGIC:
        raise MailSealError("the object is not a sealed attachment")
    eph_public = data[head : head + KEY_LEN]
    nonce = data[head + KEY_LEN : head + KEY_LEN + NONCE_LEN]
    ct = data[head + KEY_LEN + NONCE_LEN :]
    return _open(key, eph_public, nonce, ct)


__all__ = [
    "BINARY_MAGIC",
    "LABEL",
    "MailKey",
    "MailSealError",
    "open_binary",
    "open_json",
    "open_text",
    "seal_binary",
    "seal_json",
    "seal_text",
]
