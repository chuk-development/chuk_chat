"""The host's relay identity and its account token, persisted 0600.

Two things the host needs *before* anything is provisioned, so both live next to
``paired.json`` in the workspace and are written with the same ``0600`` care as
the device seed:

- ``device_id`` — the uuid4 the cloud relay routes on. Random and opaque by
  contract (the relay refuses anything but a uuid4, because a uuid1 would carry
  this machine's MAC address). It is *not* the host's crypto device id; that one
  is ``cowork-host`` and never leaves a sealed payload.
- ``token`` — the ``account_authentication`` set §15 step 7 hands over: the whole
  thing (``access_token``, ``refresh_token``, ``user_id``, ``supabase_url``,
  ``anon_key``, ``expires_at``), because the access token expires in an hour and
  the *refresh* token is what lets this host keep running for months with the app
  closed (docs/WIRE_CONTRACT.md, bead cowork-c91).

This file stores; it does not refresh. Refreshing is the existing
:class:`~chuk_agents_runtime.SupabaseSession` machinery and its three freshness paths —
the app re-provisions, the host asks with ``reprovision_request``, or (with
nobody attached) the host refreshes itself and reports
``account_session_rotated``. The host writes the rotated pair back through here
so the *next* process start still holds a usable refresh token.

Why a file of its own rather than a field in ``paired.json``: the trust record is
written once per pairing and is exactly what the app already knows, while this is
rewritten on every rotation and holds a live credential. Different lifetimes,
different blast radius, one ``0600`` file each.
"""

from __future__ import annotations

import json
import os
import uuid
from pathlib import Path
from typing import Any

ACCOUNT_VERSION = 1

#: The fields of an ``account_authentication`` payload worth keeping. Everything
#: else in that frame is envelope, not credential.
TOKEN_FIELDS = (
    "access_token",
    "refresh_token",
    "user_id",
    "supabase_url",
    "anon_key",
    "expires_at",
)


def token_subset(payload: dict[str, Any]) -> dict[str, Any]:
    """The credential fields of an ``account_authentication`` payload.

    Copied field by field on purpose: a future frame may grow keys that have no
    business sitting in a file on disk.
    """
    out: dict[str, Any] = {}
    for key in TOKEN_FIELDS:
        value = payload.get(key)
        if value is None or value == "":
            continue
        out[key] = value
    return out


class AccountStore:
    """Loads and saves ``account.json``: the relay device id and the account token."""

    def __init__(self, path: Path) -> None:
        self._path = Path(path)
        self._data: dict[str, Any] | None = None

    @property
    def path(self) -> Path:
        return self._path

    # -- reading ---------------------------------------------------------

    def _load(self) -> dict[str, Any]:
        if self._data is not None:
            return self._data
        data: dict[str, Any] = {}
        if self._path.exists():
            try:
                parsed = json.loads(self._path.read_text(encoding="utf-8"))
            except (ValueError, OSError):
                parsed = None
            if isinstance(parsed, dict) and parsed.get("version") == ACCOUNT_VERSION:
                data = parsed
        self._data = data
        return data

    def device_id(self) -> str:
        """This host's stable relay device id, minted and persisted on first use.

        Stable matters: the relay keys an executor by it, so a new id on every
        launch would look like a new machine to every controller. uuid4
        specifically, because the relay refuses anything else: ``device_id`` is
        the one field it reads in cleartext, and a uuid1 would hand it this
        machine's MAC address.
        """
        data = self._load()
        existing = data.get("device_id")
        if isinstance(existing, str) and _is_uuid4(existing):
            return existing
        device_id = str(uuid.uuid4())
        data["device_id"] = device_id
        self._write(data)
        return device_id

    def token(self) -> dict[str, Any] | None:
        """The stored ``account_authentication`` set, or ``None`` when this host
        has never been provisioned (so it must still bootstrap by pairing)."""
        token = self._load().get("token")
        if not isinstance(token, dict):
            return None
        access = token.get("access_token")
        refresh = token.get("refresh_token")
        if not isinstance(access, str) or not access:
            return None
        if not isinstance(refresh, str) or not refresh:
            return None
        return dict(token)

    def access_token(self) -> str | None:
        """The stored access token — what the relay handshake carries. It may be
        expired; the caller refreshes through the session, never here."""
        token = self.token()
        if token is None:
            return None
        access = token.get("access_token")
        return access if isinstance(access, str) and access else None

    @property
    def has_token(self) -> bool:
        return self.token() is not None

    # -- writing ---------------------------------------------------------

    def save_token(self, payload: dict[str, Any]) -> bool:
        """Persist the credential fields of an ``account_authentication`` (or a
        rotated pair). Returns True when something changed on disk.

        Merged, not replaced: a rotation frame carries the token pair but not
        necessarily ``supabase_url`` / ``anon_key``, and losing those would leave
        the next process start unable to refresh at all.
        """
        if not isinstance(payload, dict):
            return False
        fresh = token_subset(payload)
        if not fresh.get("access_token") or not fresh.get("refresh_token"):
            return False
        data = self._load()
        current = data.get("token")
        merged = dict(current) if isinstance(current, dict) else {}
        merged.update(fresh)
        if merged == current:
            return False
        data["token"] = merged
        self._write(data)
        return True

    def clear_token(self) -> bool:
        """Forget the account token (the un-pair action). The device id stays: it
        is not a credential, and keeping it stable keeps the relay's routing sane."""
        data = self._load()
        if "token" not in data:
            return False
        data.pop("token", None)
        self._write(data)
        return True

    def _write(self, data: dict[str, Any]) -> None:
        data["version"] = ACCOUNT_VERSION
        self._path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self._path.with_suffix(self._path.suffix + ".tmp")
        fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(data, handle, separators=(",", ":"))
        os.replace(tmp, self._path)
        self._data = data


def _is_uuid4(value: str) -> bool:
    try:
        return uuid.UUID(value).version == 4
    except (ValueError, AttributeError, TypeError):
        return False
