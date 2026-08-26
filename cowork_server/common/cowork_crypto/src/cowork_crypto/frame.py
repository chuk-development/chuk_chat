"""CoWork wire frame — the Python twin of the Dart ``CoworkFrame``.

Every byte that crosses ``api.chuk.chat`` between a phone (controller) and a
laptop (executor) is wrapped in one of these. The relay is a **blind**
store-and-forward hop: it matches ``device_id`` to a socket and forwards the
blob verbatim. It can drop, delay or reorder frames; it can never read, forge
or replay one.

Wire format (must match the Dart source byte-for-byte):

* JSON object ``{v, kv, device_id, seq, ts, nonce, ciphertext, sig}`` — see
  ``cowork_frame.dart:195`` (``toJson``).
* Header = length-prefixed fields, used verbatim as AES-GCM AAD and as the
  prefix of the signed bytes — see ``cowork_frame.dart:155`` (``buildHeaderBytes``).
* Signed bytes = ``header ++ len(nonce) ++ nonce ++ len(ct) ++ ct`` — see
  ``cowork_frame.dart:172`` (``buildSignedBytes``).
* ``ciphertext`` = AES-256-GCM cipher text followed by the 16-byte tag.
"""

from __future__ import annotations

import base64
import enum
import json
import struct
from dataclasses import dataclass

# --- constants (mirror cowork_frame.dart:22-36) ------------------------------

# Wire format version. Bump only for a breaking change to the frame layout.
FRAME_VERSION = "1"

# AES-GCM nonce length in bytes.
NONCE_LENGTH = 12

# Ed25519 signature length in bytes.
SIGNATURE_LENGTH = 64

# AES-GCM authentication tag length in bytes, appended to ``ciphertext``.
MAC_LENGTH = 16

# Domain separator mixed into every signature and AAD, so a CoWork signature
# can never be replayed as a signature for some other chuk_chat protocol.
# Matches ``_kDomain`` in cowork_frame.dart:36.
_DOMAIN = "chuk.cowork.frame"


class CoworkFrameRejection(enum.Enum):
    """Why a frame was refused. Every value is a hard reject: the payload never
    reaches the executor. Mirrors ``CoworkFrameRejection`` in cowork_frame.dart:41."""

    MALFORMED = "malformed"
    UNSUPPORTED_VERSION = "unsupportedVersion"
    DEVICE_NOT_APPROVED = "deviceNotApproved"
    BAD_SIGNATURE = "badSignature"
    KEY_VERSION_MISMATCH = "keyVersionMismatch"
    TIMESTAMP_OUT_OF_WINDOW = "timestampOutOfWindow"
    REPLAYED_SEQUENCE = "replayedSequence"
    DECRYPTION_FAILED = "decryptionFailed"


class CoworkFrameRejected(Exception):
    """Raised whenever a frame is refused. Carries a machine-readable
    :class:`CoworkFrameRejection` so callers can count and audit rejects."""

    def __init__(self, rejection: CoworkFrameRejection, detail: str | None = None):
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
    Mirrors ``_addField`` in cowork_frame.dart:189.
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

    Mirrors ``buildHeaderBytes`` in cowork_frame.dart:155. Field order:
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

    Mirrors ``buildSignedBytes`` in cowork_frame.dart:172. The header is added
    raw (it is already a sequence of length-prefixed fields); the nonce and
    ciphertext are each length-prefixed.
    """
    out = bytearray()
    out += header
    _add_field(out, nonce)
    _add_field(out, ciphertext)
    return bytes(out)


@dataclass(frozen=True)
class CoworkFrame:
    """A sealed CoWork frame, as it travels over the relay.

    Mirrors ``CoworkFrame`` in cowork_frame.dart:96.
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
        """The wire dict. Mirrors ``toJson`` in cowork_frame.dart:195."""
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
    def from_json(cls, data: dict) -> CoworkFrame:
        """Parse a frame off the wire. Strict by construction: anything that is
        not a well-formed frame raises ``MALFORMED`` rather than reaching the
        cryptographic layer. Mirrors ``CoworkFrame.fromJson`` in
        cowork_frame.dart:213."""
        version = data.get("v")
        if not isinstance(version, str) or version == "":
            raise CoworkFrameRejected(
                CoworkFrameRejection.MALFORMED, "v missing or not a string"
            )
        if version != FRAME_VERSION:
            raise CoworkFrameRejected(CoworkFrameRejection.UNSUPPORTED_VERSION)

        key_version = data.get("kv")
        # bool is a subclass of int in Python; exclude it explicitly.
        if not isinstance(key_version, int) or isinstance(key_version, bool) or key_version < 1:
            raise CoworkFrameRejected(
                CoworkFrameRejection.MALFORMED, "kv missing or not a positive int"
            )

        device_id = data.get("device_id")
        if not isinstance(device_id, str) or device_id == "":
            raise CoworkFrameRejected(
                CoworkFrameRejection.MALFORMED, "device_id missing or not a string"
            )

        seq = data.get("seq")
        if not isinstance(seq, int) or isinstance(seq, bool) or seq < 0:
            raise CoworkFrameRejected(
                CoworkFrameRejection.MALFORMED, "seq missing or not a non-negative int"
            )

        ts = data.get("ts")
        if not isinstance(ts, int) or isinstance(ts, bool):
            raise CoworkFrameRejected(
                CoworkFrameRejection.MALFORMED, "ts missing or not an int"
            )

        nonce = cls._decode_base64(data.get("nonce"), "nonce")
        if len(nonce) != NONCE_LENGTH:
            raise CoworkFrameRejected(CoworkFrameRejection.MALFORMED, "nonce length")

        ciphertext = cls._decode_base64(data.get("ciphertext"), "ciphertext")
        if len(ciphertext) < MAC_LENGTH:
            raise CoworkFrameRejected(
                CoworkFrameRejection.MALFORMED, "ciphertext shorter than the GCM tag"
            )

        sig = cls._decode_base64(data.get("sig"), "sig")
        if len(sig) != SIGNATURE_LENGTH:
            raise CoworkFrameRejected(CoworkFrameRejection.MALFORMED, "sig length")

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
    def from_json_string(cls, source: str) -> CoworkFrame:
        """Parse a frame from its JSON text. Invalid JSON is ``MALFORMED``.
        Mirrors ``CoworkFrame.fromJsonString`` in cowork_frame.dart:298."""
        try:
            decoded = json.loads(source)
        except (ValueError, TypeError):
            raise CoworkFrameRejected(CoworkFrameRejection.MALFORMED, "not valid JSON")
        if not isinstance(decoded, dict):
            raise CoworkFrameRejected(
                CoworkFrameRejection.MALFORMED, "not a JSON object"
            )
        return cls.from_json(decoded)

    @classmethod
    def from_bytes(cls, source: bytes) -> CoworkFrame:
        try:
            text = source.decode("utf-8")
        except UnicodeDecodeError:
            raise CoworkFrameRejected(CoworkFrameRejection.MALFORMED, "not valid UTF-8")
        return cls.from_json_string(text)

    @staticmethod
    def _decode_base64(value: object, field: str) -> bytes:
        if not isinstance(value, str):
            raise CoworkFrameRejected(
                CoworkFrameRejection.MALFORMED, f"{field} missing or not a string"
            )
        try:
            # validate=True rejects non-alphabet bytes, matching Dart's strict decode.
            return base64.b64decode(value, validate=True)
        except (ValueError, TypeError):
            raise CoworkFrameRejected(
                CoworkFrameRejection.MALFORMED, f"{field} is not valid base64"
            )
