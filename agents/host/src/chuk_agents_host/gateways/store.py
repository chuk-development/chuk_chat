"""State of one gateway on disk (CHAT-184, docs/agents/GATEWAYS.md).

Two files per gateway under ``<host state>/gateways/``:

- ``<name>.json`` (mode 0600): the paired user ids, the pending pairing
  codes (only their SHA-256), the route of each chat (agent and thread) and
  the poll offset. Not secret, but private: it says who may talk to the host.
- ``<name>-token.enc`` (mode 0600): the bot token, AES-256-GCM under a key
  derived from the host identity with a label of its own (the pattern of
  ``agent_mail_key.enc``). The token is never in the JSON file, a log line or
  an exception text.

The CLI (``agents-host telegram pair``) and the running host write the same
JSON file from two processes, so every change is read-modify-write under an
``flock`` on ``<name>.lock``.
"""

from __future__ import annotations

import base64
import contextlib
import fcntl
import hashlib
import hmac
import json
import os
import secrets
import threading
import time
from pathlib import Path
from typing import Any, Callable, Iterator

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

GATEWAYS_DIR = "gateways"

#: A pairing code lives this long and works once.
PAIRING_TTL_SECONDS = 10 * 60
#: At most this many codes wait at the same time; a new one drops the oldest.
MAX_PENDING_CODES = 5
#: No 0/O or 1/I: a code is read from one screen and typed on another.
CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
CODE_LENGTH = 8

_TOKEN_FILE_VERSION = 1
_TOKEN_AAD = b"chuk-agents/gateway-token/v1"


def gateway_token_key(identity: Any, gateway: str) -> bytes:
    """32 bytes for AES-256-GCM over ``<gateway>-token.enc``, derived from the
    host identity's private seed under a label per gateway."""
    label = f"cowork/host/gateway-{gateway}-token-at-rest/v1".encode("ascii")
    return HKDF(algorithm=hashes.SHA256(), length=32, salt=None, info=label).derive(
        identity.export_private_seed()
    )


def normalize_code(raw: Any) -> str:
    """``abcd-efgh`` / ``ABCD EFGH`` / ``abcdefgh`` -> ``ABCDEFGH``."""
    return "".join(ch for ch in str(raw or "").upper() if ch.isalnum())


def _code_hash(code: str) -> str:
    return hashlib.sha256(normalize_code(code).encode("ascii", "ignore")).hexdigest()


def _write_private(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + f".{os.getpid()}.tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as handle:
        handle.write(data)
    os.replace(tmp, path)


class GatewayStore:
    """The JSON state of one gateway. Every public method reads the file
    fresh, so a code the CLI wrote is seen by the running host at once."""

    def __init__(
        self,
        state_dir: str | os.PathLike,
        name: str,
        *,
        clock: Callable[[], float] = time.time,
    ) -> None:
        self._dir = Path(state_dir) / GATEWAYS_DIR
        self._path = self._dir / f"{name}.json"
        self._lock_path = self._dir / f"{name}.lock"
        self._clock = clock
        self._lock = threading.Lock()

    @property
    def path(self) -> Path:
        return self._path

    # -- file access -------------------------------------------------------

    @contextlib.contextmanager
    def _locked(self) -> Iterator[dict]:
        """Yield the state for change; it is written back on a clean exit."""
        with self._lock:
            self._dir.mkdir(parents=True, exist_ok=True)
            fd = os.open(self._lock_path, os.O_RDWR | os.O_CREAT, 0o600)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX)
                data = self._read()
                yield data
                _write_private(self._path, json.dumps(data, indent=1, sort_keys=True).encode())
            finally:
                fcntl.flock(fd, fcntl.LOCK_UN)
                os.close(fd)

    def _read(self) -> dict:
        try:
            data = json.loads(self._path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            data = {}
        if not isinstance(data, dict):
            data = {}
        for key in ("paired", "routes"):
            if not isinstance(data.get(key), dict):
                data[key] = {}
        if not isinstance(data.get("codes"), list):
            data["codes"] = []
        return data

    def snapshot(self) -> dict:
        with self._lock:
            return self._read()

    # -- pairing -----------------------------------------------------------

    def new_pairing_code(self) -> str:
        """Mint a one-time code, keep only its hash, return it as ``XXXX-XXXX``."""
        code = "".join(secrets.choice(CODE_ALPHABET) for _ in range(CODE_LENGTH))
        now = self._clock()
        with self._locked() as data:
            codes = [c for c in data["codes"] if float(c.get("expires", 0)) > now]
            codes.append({"hash": _code_hash(code), "expires": now + PAIRING_TTL_SECONDS})
            data["codes"] = codes[-MAX_PENDING_CODES:]
        return f"{code[:4]}-{code[4:]}"

    def redeem_code(self, raw: Any, user_id: int | str, name: str = "") -> bool:
        """Pair ``user_id`` when ``raw`` is a live code. The code is used up."""
        code = normalize_code(raw)
        if len(code) != CODE_LENGTH:
            return False
        wanted = _code_hash(code)
        now = self._clock()
        with self._locked() as data:
            live = [c for c in data["codes"] if float(c.get("expires", 0)) > now]
            hit = next(
                (c for c in live if hmac.compare_digest(str(c.get("hash", "")), wanted)),
                None,
            )
            data["codes"] = [c for c in live if c is not hit]
            if hit is None:
                return False
            data["paired"][str(user_id)] = {"name": str(name)[:80], "paired_at": now}
            return True

    def is_paired(self, user_id: int | str) -> bool:
        return str(user_id) in self.snapshot()["paired"]

    def paired(self) -> dict[str, dict]:
        return dict(self.snapshot()["paired"])

    def unpair(self, user_id: int | str) -> bool:
        with self._locked() as data:
            return data["paired"].pop(str(user_id), None) is not None

    # -- routes and offset ---------------------------------------------------

    def route(self, chat_id: int | str) -> dict | None:
        row = self.snapshot()["routes"].get(str(chat_id))
        return dict(row) if isinstance(row, dict) else None

    def set_route(self, chat_id: int | str, route: dict) -> None:
        with self._locked() as data:
            data["routes"][str(chat_id)] = route

    def offset(self) -> int:
        try:
            return int(self.snapshot().get("offset") or 0)
        except (TypeError, ValueError):
            return 0

    def set_offset(self, offset: int) -> None:
        with self._locked() as data:
            data["offset"] = int(offset)


class TokenStore:
    """The bot token at rest, sealed. Without a key it holds nothing."""

    def __init__(self, path: str | os.PathLike, key: bytes | None) -> None:
        if key is not None and len(key) != 32:
            raise ValueError("the at-rest key is 32 bytes")
        self._path = Path(path)
        self._key = key

    @property
    def path(self) -> Path:
        return self._path

    def get(self) -> str | None:
        if self._key is None or not self._path.exists():
            return None
        try:
            record = json.loads(self._path.read_text(encoding="utf-8"))
            if record.get("version") != _TOKEN_FILE_VERSION:
                return None
            nonce = base64.b64decode(record["nonce"], validate=True)
            sealed = base64.b64decode(record["ciphertext"], validate=True)
            token = AESGCM(self._key).decrypt(nonce, sealed, _TOKEN_AAD).decode("utf-8")
        except Exception:  # noqa: BLE001 — a bad file is no token
            return None
        return token or None

    def put(self, token: str) -> None:
        if self._key is None:
            raise ValueError("no at-rest key")
        token = (token or "").strip()
        if not token:
            raise ValueError("empty token")
        nonce = os.urandom(12)
        record = {
            "version": _TOKEN_FILE_VERSION,
            "nonce": base64.b64encode(nonce).decode("ascii"),
            "ciphertext": base64.b64encode(
                AESGCM(self._key).encrypt(nonce, token.encode("utf-8"), _TOKEN_AAD)
            ).decode("ascii"),
        }
        _write_private(self._path, json.dumps(record).encode("utf-8"))

    def clear(self) -> bool:
        try:
            self._path.unlink()
            return True
        except FileNotFoundError:
            return False
