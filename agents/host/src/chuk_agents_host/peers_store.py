"""The other hosts of the same account that this host may talk to (CHAT-177).

The app introduces two of its hosts to each other (docs/agents/MULTI_HOST.md,
"Phase 2"). It has a sealed channel to each one, so it makes a fresh 32-byte
pair key ``K`` and sends each host, over that channel, the other host's relay
device id, its Ed25519 public key and ``K``. The host keeps that record here,
in ``peers.json`` next to ``paired.json``.

The file is written ``0600``: ``K`` is symmetric key material. Nothing in it
is a secret of this host; the app holds every value too.
"""

from __future__ import annotations

import base64
import json
import os
import threading
import uuid
from dataclasses import dataclass
from pathlib import Path

from chuk_agents_crypto import public_key_from_base64
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

PEERS_VERSION = 1

#: The file name, next to ``paired.json`` in the state directory.
PEERS_FILE = "peers.json"

#: The two kinds of host the app knows.
KIND_PC = "pc"
KIND_CLOUD = "cloud"
KINDS = (KIND_PC, KIND_CLOUD)

#: The longest display name kept.
MAX_NAME_CHARS = 64

#: The most peers one host keeps. An account has a few computers, not hundreds.
MAX_PEERS = 32

PAIR_KEY_LENGTH = 32


class PeerError(ValueError):
    """A bad introduce frame. The message goes back to the app."""


def is_uuid4(value: object) -> bool:
    """True for a canonical lower-case uuid4, the only id the relay routes on."""
    if not isinstance(value, str):
        return False
    try:
        parsed = uuid.UUID(value)
    except ValueError:
        return False
    return parsed.version == 4 and str(parsed) == value


def clean_name(raw: object, fallback: str = "Computer") -> str:
    """A display name: printable, trimmed, at most :data:`MAX_NAME_CHARS`."""
    text = raw if isinstance(raw, str) else ""
    text = "".join(ch for ch in text if ch.isprintable()).strip()
    return text[:MAX_NAME_CHARS] or fallback


@dataclass(frozen=True)
class PeerRecord:
    """One introduced host."""

    host_id: str
    public_key: Ed25519PublicKey
    pair_key: bytes
    name: str
    kind: str

    def public_key_b64(self) -> str:
        return base64.b64encode(self.public_key.public_bytes_raw()).decode("ascii")

    def summary(self) -> dict:
        """The record without key material, for the app and the logs."""
        return {"peer_host_id": self.host_id, "name": self.name, "kind": self.kind}


def parse_introduce(payload: dict, *, own_host_id: str) -> PeerRecord:
    """Read a ``host_peer_introduce`` frame into a record, or raise
    :class:`PeerError` with a short reason."""
    host_id = payload.get("peer_host_id")
    if not is_uuid4(host_id):
        raise PeerError("peer_host_id must be a uuid4")
    if host_id == own_host_id:
        raise PeerError("a host cannot be its own peer")
    try:
        public_key = public_key_from_base64(str(payload.get("peer_public_key") or ""))
    except (ValueError, TypeError):
        raise PeerError("peer_public_key must be a base64 Ed25519 key") from None
    try:
        pair_key = base64.b64decode(str(payload.get("pair_key") or ""), validate=True)
    except (ValueError, TypeError):
        raise PeerError("pair_key must be base64") from None
    if len(pair_key) != PAIR_KEY_LENGTH:
        raise PeerError("pair_key must be 32 bytes")
    kind = payload.get("kind")
    return PeerRecord(
        host_id=host_id,
        public_key=public_key,
        pair_key=pair_key,
        name=clean_name(payload.get("name")),
        kind=kind if kind in KINDS else KIND_PC,
    )


class PeerStore:
    """Loads and saves ``peers.json``. Thread-safe: the app's frames and the
    relay reader both read it."""

    def __init__(self, path: Path) -> None:
        self._path = Path(path)
        self._lock = threading.Lock()
        self._peers: dict[str, PeerRecord] = self._load()

    @property
    def path(self) -> Path:
        return self._path

    def get(self, host_id: str) -> PeerRecord | None:
        with self._lock:
            return self._peers.get(host_id)

    def all(self) -> list[PeerRecord]:
        with self._lock:
            return sorted(self._peers.values(), key=lambda p: (p.name.lower(), p.host_id))

    def put(self, record: PeerRecord) -> None:
        """Add or replace one peer (a second introduce rotates the key)."""
        with self._lock:
            if record.host_id not in self._peers and len(self._peers) >= MAX_PEERS:
                raise PeerError(f"this host keeps at most {MAX_PEERS} peers")
            self._peers[record.host_id] = record
            self._save()

    def remove(self, host_id: str) -> bool:
        with self._lock:
            if self._peers.pop(host_id, None) is None:
                return False
            self._save()
            return True

    # -- file ----------------------------------------------------------------

    def _load(self) -> dict[str, PeerRecord]:
        """The stored peers. A corrupt file or a bad row is no peer, not a crash."""
        try:
            data = json.loads(self._path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return {}
        if not isinstance(data, dict) or data.get("version") != PEERS_VERSION:
            return {}
        out: dict[str, PeerRecord] = {}
        for row in data.get("peers") or []:
            if not isinstance(row, dict):
                continue
            try:
                record = PeerRecord(
                    host_id=row["host_id"],
                    public_key=public_key_from_base64(row["ed25519_pub_b64"]),
                    pair_key=base64.b64decode(row["pair_key_b64"], validate=True),
                    name=clean_name(row.get("name")),
                    kind=row.get("kind") if row.get("kind") in KINDS else KIND_PC,
                )
            except (KeyError, TypeError, ValueError):
                continue
            if is_uuid4(record.host_id) and len(record.pair_key) == PAIR_KEY_LENGTH:
                out[record.host_id] = record
        return out

    def _save(self) -> None:
        self._path.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "version": PEERS_VERSION,
            "peers": [
                {
                    "host_id": p.host_id,
                    "ed25519_pub_b64": p.public_key_b64(),
                    "pair_key_b64": base64.b64encode(p.pair_key).decode("ascii"),
                    "name": p.name,
                    "kind": p.kind,
                }
                for p in self._peers.values()
            ],
        }
        tmp = self._path.with_suffix(self._path.suffix + ".tmp")
        fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, separators=(",", ":"))
        os.replace(tmp, self._path)
