"""Agents wire frame — the Python twin of the Dart ``AgentsFrame``.

Every byte that crosses ``api.chuk.chat`` between a phone (controller) and a
laptop (executor) is wrapped in one of these. The relay is a **blind**
store-and-forward hop: it matches ``device_id`` to a socket and forwards the
blob verbatim. It can drop, delay or reorder frames; it can never read, forge
or replay one.

Wire format (must match the Dart source byte-for-byte):

* JSON object ``{v, kv, device_id, seq, ts, nonce, ciphertext, sig}`` — see
  ``agents_frame.dart:195`` (``toJson``).
* Header = length-prefixed fields, used verbatim as AES-GCM AAD and as the
  prefix of the signed bytes — see ``agents_frame.dart:155`` (``buildHeaderBytes``).
* Signed bytes = ``header ++ len(nonce) ++ nonce ++ len(ct) ++ ct`` — see
  ``agents_frame.dart:172`` (``buildSignedBytes``).
* ``ciphertext`` = AES-256-GCM cipher text followed by the 16-byte tag.
"""

from __future__ import annotations

import base64
import enum
import json
import struct
from dataclasses import dataclass

# --- constants (mirror agents_frame.dart:22-36) ------------------------------

# Wire format version. Bump only for a breaking change to the frame layout.
FRAME_VERSION = "1"

# AES-GCM nonce length in bytes.
NONCE_LENGTH = 12

# Ed25519 signature length in bytes.
SIGNATURE_LENGTH = 64

# AES-GCM authentication tag length in bytes, appended to ``ciphertext``.
MAC_LENGTH = 16

# Domain separator mixed into every signature and AAD, so a Agents signature
# can never be replayed as a signature for some other chuk_chat protocol.
# Matches ``_kDomain`` in agents_frame.dart:36.
_DOMAIN = "chuk.cowork.frame"


class AgentsFrameRejection(enum.Enum):
    """Why a frame was refused. Every value is a hard reject: the payload never
    reaches the executor. Mirrors ``AgentsFrameRejection`` in agents_frame.dart:41."""

    MALFORMED = "malformed"
    UNSUPPORTED_VERSION = "unsupportedVersion"
    DEVICE_NOT_APPROVED = "deviceNotApproved"
    BAD_SIGNATURE = "badSignature"
    KEY_VERSION_MISMATCH = "keyVersionMismatch"
    TIMESTAMP_OUT_OF_WINDOW = "timestampOutOfWindow"
    REPLAYED_SEQUENCE = "replayedSequence"
    DECRYPTION_FAILED = "decryptionFailed"


class AgentsFrameRejected(Exception):
    """Raised whenever a frame is refused. Carries a machine-readable
    :class:`AgentsFrameRejection` so callers can count and audit rejects."""

    def __init__(self, rejection: AgentsFrameRejection, detail: str | None = None):
        self.rejection = rejection
        # Short, non-sensitive context. Never contains plaintext, keys or nonces.
        self.detail = detail
        super().__init__(
            rejection.value if detail is None else f"{rejection.value}: {detail}"
        )


def _add_field(out: bytearray, value: bytes) -> None:
    """Length-prefixed append: 4-byte big-endian length, then the bytes.

    ``seq``/``ts`` are written as their decimal text rather than a fixed 64-bit
    integer to match the Dart side, which uses decimal text because
    ``ByteData.setUint64`` is unsupported on the web.
    Mirrors ``_addField`` in agents_frame.dart:189.
    """
    out += struct.pack(">I", len(value))
    out += value


def build_header_bytes(
    *,
    version: str,
    key_version: int,
    device_id: str,
    seq: int,
    ts: int,
) -> bytes:
    """The authenticated header — everything about the frame except the payload.

    Mirrors ``buildHeaderBytes`` in agents_frame.dart:155. Field order:
    domain, version, key_version (decimal text), device_id, seq (decimal text),
    ts (decimal text). Each field is length-prefixed, so no two distinct headers
    can serialise to the same bytes.
    """
    out = bytearray()
    _add_field(out, _DOMAIN.encode("utf-8"))
    _add_field(out, version.encode("utf-8"))
    _add_field(out, str(key_version).encode("utf-8"))
    _add_field(out, device_id.encode("utf-8"))
    _add_field(out, str(seq).encode("utf-8"))
    _add_field(out, str(ts).encode("utf-8"))
    return bytes(out)


def build_signed_bytes(*, header: bytes, nonce: bytes, ciphertext: bytes) -> bytes:
    """Exactly what the Ed25519 signature covers: header, nonce and ciphertext.

    Mirrors ``buildSignedBytes`` in agents_frame.dart:172. The header is added
    raw (it is already a sequence of length-prefixed fields); the nonce and
    ciphertext are each length-prefixed.
    """
    out = bytearray()
    out += header
    _add_field(out, nonce)
    _add_field(out, ciphertext)
    return bytes(out)


@dataclass(frozen=True)
class AgentsFrame:
    """A sealed Agents frame, as it travels over the relay.

    Mirrors ``AgentsFrame`` in agents_frame.dart:96.
    """

    device_id: str
    seq: int
    ts: int
    nonce: bytes
    ciphertext: bytes  # cipher text followed by the 16-byte GCM tag
    sig: bytes
    version: str = FRAME_VERSION
    key_version: int = 1

    @property
    def header_bytes(self) -> bytes:
        return build_header_bytes(
            version=self.version,
            key_version=self.key_version,
            device_id=self.device_id,
            seq=self.seq,
            ts=self.ts,
        )

    @property
    def signed_bytes(self) -> bytes:
        return build_signed_bytes(
            header=self.header_bytes,
            nonce=self.nonce,
            ciphertext=self.ciphertext,
        )

    def to_json(self) -> dict:
        """The wire dict. Mirrors ``toJson`` in agents_frame.dart:195."""
        return {
            "v": self.version,
            "kv": self.key_version,
            "device_id": self.device_id,
            "seq": self.seq,
            "ts": self.ts,
            "nonce": base64.b64encode(self.nonce).decode("ascii"),
            "ciphertext": base64.b64encode(self.ciphertext).decode("ascii"),
            "sig": base64.b64encode(self.sig).decode("ascii"),
        }

    def to_json_string(self) -> str:
        # ``separators`` with no spaces matches Dart's ``jsonEncode`` output.
        return json.dumps(self.to_json(), separators=(",", ":"))

    def to_bytes(self) -> bytes:
        return self.to_json_string().encode("utf-8")

    # --- parsing -------------------------------------------------------------

    @classmethod
    def from_json(cls, data: dict) -> AgentsFrame:
        """Parse a frame off the wire. Strict by construction: anything that is
        not a well-formed frame raises ``MALFORMED`` rather than reaching the
        cryptographic layer. Mirrors ``AgentsFrame.fromJson`` in
        agents_frame.dart:213."""
        version = data.get("v")
        if not isinstance(version, str) or version == "":
            raise AgentsFrameRejected(
                AgentsFrameRejection.MALFORMED, "v missing or not a string"
            )
        if version != FRAME_VERSION:
            raise AgentsFrameRejected(AgentsFrameRejection.UNSUPPORTED_VERSION)

        key_version = data.get("kv")
        # bool is a subclass of int in Python; exclude it explicitly.
        if not isinstance(key_version, int) or isinstance(key_version, bool) or key_version < 1:
            raise AgentsFrameRejected(
                AgentsFrameRejection.MALFORMED, "kv missing or not a positive int"
            )

        device_id = data.get("device_id")
        if not isinstance(device_id, str) or device_id == "":
            raise AgentsFrameRejected(
                AgentsFrameRejection.MALFORMED, "device_id missing or not a string"
            )

        seq = data.get("seq")
        if not isinstance(seq, int) or isinstance(seq, bool) or seq < 0:
            raise AgentsFrameRejected(
                AgentsFrameRejection.MALFORMED, "seq missing or not a non-negative int"
            )

        ts = data.get("ts")
        if not isinstance(ts, int) or isinstance(ts, bool):
            raise AgentsFrameRejected(
                AgentsFrameRejection.MALFORMED, "ts missing or not an int"
            )

        nonce = cls._decode_base64(data.get("nonce"), "nonce")
        if len(nonce) != NONCE_LENGTH:
            raise AgentsFrameRejected(AgentsFrameRejection.MALFORMED, "nonce length")

        ciphertext = cls._decode_base64(data.get("ciphertext"), "ciphertext")
        if len(ciphertext) < MAC_LENGTH:
            raise AgentsFrameRejected(
                AgentsFrameRejection.MALFORMED, "ciphertext shorter than the GCM tag"
            )

        sig = cls._decode_base64(data.get("sig"), "sig")
        if len(sig) != SIGNATURE_LENGTH:
            raise AgentsFrameRejected(AgentsFrameRejection.MALFORMED, "sig length")

        return cls(
            version=version,
            key_version=key_version,
            device_id=device_id,
            seq=seq,
            ts=ts,
            nonce=nonce,
            ciphertext=ciphertext,
            sig=sig,
        )

    @classmethod
    def from_json_string(cls, source: str) -> AgentsFrame:
        """Parse a frame from its JSON text. Invalid JSON is ``MALFORMED``.
        Mirrors ``AgentsFrame.fromJsonString`` in agents_frame.dart:298."""
        try:
            decoded = json.loads(source)
        except (ValueError, TypeError):
            raise AgentsFrameRejected(AgentsFrameRejection.MALFORMED, "not valid JSON")
        if not isinstance(decoded, dict):
            raise AgentsFrameRejected(
                AgentsFrameRejection.MALFORMED, "not a JSON object"
            )
        return cls.from_json(decoded)

    @classmethod
    def from_bytes(cls, source: bytes) -> AgentsFrame:
        try:
            text = source.decode("utf-8")
        except UnicodeDecodeError:
            raise AgentsFrameRejected(AgentsFrameRejection.MALFORMED, "not valid UTF-8")
        return cls.from_json_string(text)

    @staticmethod
    def _decode_base64(value: object, field: str) -> bytes:
        if not isinstance(value, str):
            raise AgentsFrameRejected(
                AgentsFrameRejection.MALFORMED, f"{field} missing or not a string"
            )
        try:
            # validate=True rejects non-alphabet bytes, matching Dart's strict decode.
            return base64.b64decode(value, validate=True)
        except (ValueError, TypeError):
            raise AgentsFrameRejected(
                AgentsFrameRejection.MALFORMED, f"{field} is not valid base64"
            )
