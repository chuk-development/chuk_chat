"""Host half of the login vault for the browser (Hermes H32).

The app manages the logins with three sealed frames (app -> host):

- ``login_vault_set {origin, username, password, totp_secret?, label?}`` —
  upsert by (origin, username);
- ``login_vault_delete {id}``;
- ``login_vault_list {}``.

Each is answered with ONE terminal ``login_vault`` frame (host -> app) that
carries the whole public list: ``{type: "login_vault", entries: [{id, origin,
username, label, has_totp, created_at, last_used_at}], ...}``. Never a
password, never a TOTP key.

The storage is :class:`~chuk_agents_executor.secrets.SecretsVault` (same
at-rest file, same key). The fill happens in
:class:`chuk_agents_runtime.login_vault.LoginGuard`, installed by the executor
as the ``call_guard`` of every session's MCP manager (:func:`login_guard`).
"""

from __future__ import annotations

import logging
from typing import Any

from chuk_agents_runtime.login_vault import LoginGuard

from .secrets import LoginVaultError, SecretsVault

logger = logging.getLogger(__name__)

LOGIN_VAULT_SET = "login_vault_set"
LOGIN_VAULT_DELETE = "login_vault_delete"
LOGIN_VAULT_LIST = "login_vault_list"
LOGIN_VAULT_FRAMES = frozenset({LOGIN_VAULT_SET, LOGIN_VAULT_DELETE, LOGIN_VAULT_LIST})
#: The terminal frame type (host -> app).
LOGIN_VAULT_REPLY = "login_vault"


def login_vault_payload(vault: SecretsVault | None, **extra: Any) -> dict:
    """The terminal ``login_vault`` frame: the public list plus ``extra``."""
    entries = vault.login_entries() if vault is not None else []
    return {"type": LOGIN_VAULT_REPLY, "entries": entries, **extra}


#: The longest ``request_id`` the host echoes back.
MAX_REQUEST_ID = 128


def handle_login_vault_frame(vault: SecretsVault | None, kind: str, payload: dict) -> dict:
    """Apply one app frame and return the terminal reply. Never raises; an
    error is a reply with ``error`` (and the unchanged list).

    The app tags each frame with a ``request_id``; the reply echoes it, so the
    app can tell the answer to its save from the answer to a list it sent at
    the same time (docs/WIRE_CONTRACT.md, "Login vault for the browser")."""
    reply = _apply_login_vault_frame(vault, kind, payload)
    request_id = payload.get("request_id") if isinstance(payload, dict) else None
    if isinstance(request_id, str) and 0 < len(request_id) <= MAX_REQUEST_ID:
        reply["request_id"] = request_id
    return reply


def _apply_login_vault_frame(vault: SecretsVault | None, kind: str, payload: dict) -> dict:
    if vault is None:
        return login_vault_payload(None, error="this host keeps no login vault")
    if not isinstance(payload, dict):
        payload = {}
    try:
        if kind == LOGIN_VAULT_SET:
            kwargs: dict[str, Any] = {
                "origin": payload.get("origin"),
                "username": payload.get("username"),
                "password": payload.get("password"),
                "label": payload.get("label"),
            }
            if "totp_secret" in payload:
                kwargs["totp_secret"] = payload.get("totp_secret")
            saved = vault.login_set(**kwargs)
            return login_vault_payload(vault, saved=saved)
        if kind == LOGIN_VAULT_DELETE:
            entry_id = payload.get("id")
            found = vault.login_delete(entry_id)
            reply = login_vault_payload(vault, deleted=str(entry_id or ""))
            if not found:
                reply["error"] = "no login with this id"
            return reply
        if kind == LOGIN_VAULT_LIST:
            return login_vault_payload(vault)
    except LoginVaultError as exc:
        return login_vault_payload(vault, error=str(exc))
    except Exception as exc:  # noqa: BLE001 — a bad frame must not wedge serving
        logger.warning("login vault frame failed: %s", type(exc).__name__)
        return login_vault_payload(vault, error="the login vault could not apply this frame")
    return login_vault_payload(vault, error=f"unknown login vault frame: {kind}")


class _NoLogins:
    """The access of a host without a vault: every placeholder is refused
    (``unknown_entry``) instead of being typed into the page as text."""

    def login_entries(self) -> list[dict]:
        return []

    def login_lookup(self, origin: str) -> list[dict]:
        return []

    def login_used(self, entry_id: str) -> None:
        return None

    def login_audit(self, record: dict) -> None:
        return None


def login_guard(vault: SecretsVault | None, session_key: str) -> LoginGuard:
    """The MCP ``call_guard`` of one session."""
    return LoginGuard(
        vault if vault is not None else _NoLogins(), session_key=str(session_key or "")
    )


__all__ = [
    "LOGIN_VAULT_FRAMES",
    "LOGIN_VAULT_REPLY",
    "handle_login_vault_frame",
    "login_guard",
    "login_vault_payload",
]
