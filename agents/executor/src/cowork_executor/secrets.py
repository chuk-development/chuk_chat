"""The host's secret vault (docs/WIRE_CONTRACT.md, "Secrets").

One set of named secrets per user, global for every agent and session on this
host. The app owns it and sends the FULL set in a ``secrets`` frame — after
every provision, after every change, and as the answer to a
``secret_request``. The vault replaces what it holds with each frame (last
frame wins), keeps the values in memory, and writes them at rest under a key
the host derives from its own device identity, so a host restart with no app
attached still has the set.

What leaves this module:

- ``env()`` — name -> value, for the child process of ``run_command`` /
  ``python`` (and for cowork-94's watcher processes). The only reader of the
  values.
- ``names()`` / ``status(names)`` — what the model may learn.
- ``scrubber()`` — a :class:`cowork_agent.Scrubber` over the live values, the
  one the executor installs on its frame sealer.

Never logged, never in the runs/messages database, never in a workspace file.
"""

from __future__ import annotations

import base64
import json
import logging
import os
import threading
from collections.abc import Iterable, Mapping
from pathlib import Path

from cowork_agent import Scrubber, status_map, valid_name
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

logger = logging.getLogger(__name__)

AT_REST_VERSION = 1
_NONCE_LEN = 12
_KEY_LEN = 32

#: A ceiling on one value. Keys and tokens are short; a "value" of a megabyte
#: is a file someone pasted by mistake, and the scrubber would then compile a
#: pattern of that size for every dispatch.
MAX_VALUE_CHARS = 8192
MAX_ENTRIES = 256


def clean_entries(entries: object) -> dict[str, str]:
    """Filter a frame's ``entries`` down to what the vault accepts: a valid
    environment-variable name and a non-empty string value. Everything else
    is dropped silently — a malformed entry must not cost the rest."""
    out: dict[str, str] = {}
    if not isinstance(entries, list):
        return out
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        name = entry.get("name")
        value = entry.get("value")
        if not valid_name(name) or not isinstance(value, str) or not value:
            continue
        if len(value) > MAX_VALUE_CHARS:
            continue
        out[name] = value
        if len(out) >= MAX_ENTRIES:
            break
    return out


class SecretsVault:
    """Thread-safe holder of one user's secret set, with encrypted at-rest copy.

    ``key`` is the 32-byte AES-256-GCM key for the at-rest file; ``path`` the
    file. Either may be ``None`` (tests, a host without persistence): the
    vault then lives in memory only. ``load()`` is explicit so a caller can
    decide when disk is read; the host calls it once at start.
    """

    def __init__(self, *, path: str | os.PathLike | None = None, key: bytes | None = None) -> None:
        if key is not None and len(key) != _KEY_LEN:
            raise ValueError(f"at-rest key must be {_KEY_LEN} bytes")
        self._path = Path(path) if path is not None else None
        self._key = key
        self._lock = threading.Lock()
        self._values: dict[str, str] = {}
        self._revision: int = 0
        self._user_id: str = ""
        self._scrubber = Scrubber(self.env)

    # -- what the model and the tools may learn ---------------------------

    def names(self) -> list[str]:
        with self._lock:
            return sorted(self._values)

    def status(self, names: Iterable[str]) -> dict[str, str]:
        with self._lock:
            have = set(self._values)
        return status_map(list(names), have)

    @property
    def revision(self) -> int:
        with self._lock:
            return self._revision

    @property
    def user_id(self) -> str:
        with self._lock:
            return self._user_id

    def __len__(self) -> int:
        with self._lock:
            return len(self._values)

    # -- the values: only for a child process ------------------------------

    def env(self) -> dict[str, str]:
        """Name -> value. The one reader of the values. Callers hand it to a
        child process environment and hold on to nothing."""
        with self._lock:
            return dict(self._values)

    def scrubber(self) -> Scrubber:
        """The scrubber over the LIVE set (it re-reads ``env`` per call)."""
        return self._scrubber

    # -- the frame -----------------------------------------------------------

    def replace(
        self, entries: Mapping[str, str] | object, *, revision: object = None, user_id: str | None = None
    ) -> int:
        """Replace the whole set with ``entries`` (a ``secrets`` frame's list,
        or a name -> value mapping). Returns how many entries are held now.
        Last frame wins; ``revision`` is recorded, never compared."""
        if isinstance(entries, Mapping):
            values = {
                str(k): str(v)
                for k, v in entries.items()
                if valid_name(k) and isinstance(v, str) and v and len(v) <= MAX_VALUE_CHARS
            }
        else:
            values = clean_entries(entries)
        try:
            rev = int(revision) if revision is not None else 0
        except (TypeError, ValueError):
            rev = 0
        with self._lock:
            self._values = values
            self._revision = rev
            if user_id:
                self._user_id = str(user_id)
            count = len(values)
        # Names and count only. Never a value.
        logger.info("secrets replaced: %d name(s), revision %s", count, rev)
        self.save()
        return count

    def clear(self) -> None:
        self.replace({}, revision=0)

    # -- at rest -------------------------------------------------------------

    @property
    def path(self) -> Path | None:
        return self._path

    def save(self) -> bool:
        """Write the set encrypted to ``path``. No path / no key: no file.
        Best-effort: a write failure is logged (without values) and the set
        stays in memory."""
        path, key = self._path, self._key
        if path is None or key is None:
            return False
        with self._lock:
            plain = json.dumps(
                {"user_id": self._user_id, "revision": self._revision, "values": self._values},
                separators=(",", ":"),
            ).encode("utf-8")
        try:
            nonce = os.urandom(_NONCE_LEN)
            sealed = AESGCM(key).encrypt(nonce, plain, _aad())
            record = {
                "version": AT_REST_VERSION,
                "nonce": base64.b64encode(nonce).decode("ascii"),
                "ciphertext": base64.b64encode(sealed).decode("ascii"),
            }
            path.parent.mkdir(parents=True, exist_ok=True)
            tmp = path.with_suffix(path.suffix + ".tmp")
            fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                json.dump(record, handle, separators=(",", ":"))
            os.replace(tmp, path)
            return True
        except Exception as exc:  # noqa: BLE001 — the set stays in memory
            logger.warning("could not write secrets at rest: %s", type(exc).__name__)
            return False

    def load(self) -> int:
        """Read the at-rest file into memory. Returns the number of entries
        loaded; 0 when there is no file, no key, or the file does not open
        under this key (a corrupt or foreign file is treated as empty and is
        NOT deleted — the next ``secrets`` frame overwrites it)."""
        path, key = self._path, self._key
        if path is None or key is None or not path.exists():
            return 0
        try:
            record = json.loads(path.read_text(encoding="utf-8"))
            if not isinstance(record, dict) or record.get("version") != AT_REST_VERSION:
                return 0
            nonce = base64.b64decode(record["nonce"], validate=True)
            sealed = base64.b64decode(record["ciphertext"], validate=True)
            plain = AESGCM(key).decrypt(nonce, sealed, _aad())
            data = json.loads(plain.decode("utf-8"))
            values = data.get("values") if isinstance(data, dict) else None
            if not isinstance(values, dict):
                return 0
            clean = {
                str(k): str(v)
                for k, v in values.items()
                if valid_name(k) and isinstance(v, str) and v
            }
            with self._lock:
                self._values = clean
                try:
                    self._revision = int(data.get("revision") or 0)
                except (TypeError, ValueError):
                    self._revision = 0
                self._user_id = str(data.get("user_id") or "")
            logger.info("secrets loaded at rest: %d name(s)", len(clean))
            return len(clean)
        except Exception as exc:  # noqa: BLE001 — an unreadable file is an empty set
            logger.warning("could not read secrets at rest: %s", type(exc).__name__)
            return 0

    def forget_at_rest(self) -> bool:
        """Delete the at-rest file (the "forget this host" action)."""
        path = self._path
        if path is None:
            return False
        try:
            path.unlink()
            return True
        except FileNotFoundError:
            return False


def _aad() -> bytes:
    """Additional authenticated data: binds the ciphertext to this format."""
    return b"cowork/host/secrets-at-rest/v1"


__all__ = ["SecretsVault", "clean_entries", "MAX_VALUE_CHARS", "MAX_ENTRIES", "AT_REST_VERSION"]
