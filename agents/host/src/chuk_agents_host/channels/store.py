"""The channel store: per-coworker channel state, encrypted at rest.

One record per coworker (keyed by the app's agent id, which is also the
coworker's ``session_key``) and per channel kind. A record holds the bot
token, whether the user turned the channel on, the one linked chat and the
poll offset.

The bot token is a secret. It is not in the user's secret set
(:class:`chuk_agents_executor.SecretsVault`) on purpose: that set is replaced
whole by every ``secrets`` frame of the app, and it is handed to every sandbox
process as environment. A coworker must not be able to read the token of its
own bot. So this store is a second file, ``channels.enc``, sealed with
AES-256-GCM under a key that HKDF derives from the host identity under its own
label. Nothing else on disk names the token; logs never do.
"""

from __future__ import annotations

import base64
import copy
import json
import logging
import os
import threading
from pathlib import Path
from typing import Any

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

logger = logging.getLogger(__name__)

#: The file in the host state directory.
FILE_NAME = "channels.enc"
AT_REST_VERSION = 1
_LABEL = b"cowork/host/channels-at-rest/v1"
_NONCE_LEN = 12
KEY_LEN = 32


def channels_at_rest_key(identity: Any) -> bytes:
    """32 bytes for AES-256-GCM, derived from the host identity's seed.

    Its own HKDF label, so this key is not the secret vault's key."""
    return HKDF(algorithm=hashes.SHA256(), length=KEY_LEN, salt=None, info=_LABEL).derive(
        identity.export_private_seed()
    )


class ChannelStore:
    """Thread-safe ``{agent_id: {kind: record}}`` with an encrypted file.

    ``path`` or ``key`` ``None`` keeps the store in memory only (tests). A
    file that does not open under the key is treated as empty and is left on
    disk; the next save overwrites it.
    """

    def __init__(self, *, path: str | os.PathLike | None, key: bytes | None) -> None:
        if key is not None and len(key) != KEY_LEN:
            raise ValueError(f"at-rest key must be {KEY_LEN} bytes")
        self._path = Path(path) if path is not None else None
        self._key = key
        self._lock = threading.Lock()
        self._records: dict[str, dict[str, dict]] = {}
        self._load()

    # -- records -------------------------------------------------------------

    def get(self, agent_id: str, kind: str) -> dict:
        """A copy of one record; ``{}`` when there is none."""
        with self._lock:
            return copy.deepcopy(self._records.get(agent_id, {}).get(kind, {}))

    def all(self, kind: str) -> dict[str, dict]:
        """``agent_id -> record`` copies for one channel kind."""
        with self._lock:
            return {
                agent_id: copy.deepcopy(kinds[kind])
                for agent_id, kinds in self._records.items()
                if kind in kinds
            }

    def update(self, agent_id: str, kind: str, **fields: Any) -> dict:
        """Merge ``fields`` into one record (``None`` deletes a field), save,
        and return a copy of the result."""
        with self._lock:
            record = self._records.setdefault(agent_id, {}).setdefault(kind, {})
            for name, value in fields.items():
                if value is None:
                    record.pop(name, None)
                else:
                    record[name] = value
            result = copy.deepcopy(record)
        self._save()
        return result

    def remove(self, agent_id: str, kind: str) -> None:
        with self._lock:
            kinds = self._records.get(agent_id)
            if not kinds or kind not in kinds:
                return
            kinds.pop(kind, None)
            if not kinds:
                self._records.pop(agent_id, None)
        self._save()

    # -- at rest -------------------------------------------------------------

    def _save(self) -> bool:
        path, key = self._path, self._key
        if path is None or key is None:
            return False
        with self._lock:
            plain = json.dumps(self._records, separators=(",", ":")).encode("utf-8")
        try:
            nonce = os.urandom(_NONCE_LEN)
            sealed = AESGCM(key).encrypt(nonce, plain, _LABEL)
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
        except Exception as exc:  # noqa: BLE001 — the state stays in memory
            logger.warning("could not write the channel store: %s", type(exc).__name__)
            return False

    def _load(self) -> None:
        path, key = self._path, self._key
        if path is None or key is None or not path.exists():
            return
        try:
            record = json.loads(path.read_text(encoding="utf-8"))
            if not isinstance(record, dict) or record.get("version") != AT_REST_VERSION:
                return
            nonce = base64.b64decode(record["nonce"], validate=True)
            sealed = base64.b64decode(record["ciphertext"], validate=True)
            data = json.loads(AESGCM(key).decrypt(nonce, sealed, _LABEL).decode("utf-8"))
        except Exception as exc:  # noqa: BLE001 — an unreadable file is an empty store
            logger.warning("could not read the channel store: %s", type(exc).__name__)
            return
        if not isinstance(data, dict):
            return
        clean: dict[str, dict[str, dict]] = {}
        for agent_id, kinds in data.items():
            if isinstance(agent_id, str) and isinstance(kinds, dict):
                clean[agent_id] = {
                    str(k): v for k, v in kinds.items() if isinstance(v, dict)
                }
        with self._lock:
            self._records = clean


__all__ = ["ChannelStore", "FILE_NAME", "channels_at_rest_key"]
