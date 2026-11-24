"""Host half of the vault payment cards and contacts (CHAT-185).

The app manages the rows with sealed frames (app -> host), like the login
vault (:mod:`.login_vault`):

- ``payment_vault_set {id?, number?, exp_month?, exp_year?, cvc?, name?,
  zip?, label?, make_default?}`` — a new card (no ``id``) or a change;
- ``payment_vault_delete {id}``;
- ``payment_vault_default {id}`` — ``id: null`` clears the default;
- ``payment_vault_list {}``.

Each is answered with ONE terminal ``payment_vault`` frame: ``{entries:
[{id, brand, last4, label, exp_month, exp_year, name, zip, has_cvc,
is_default, created_at, last_used_at}], default_id}``. Never a number or a
security code.

- ``contact_vault_set {id?, label, name?, company?, phones?, emails?,
  address?}``; ``contact_vault_delete {id}``; ``contact_vault_list {}``.

Each is answered with ONE terminal ``contact_vault`` frame ``{entries}``.
Every reply echoes the frame's ``request_id``.
"""

from __future__ import annotations

import logging
from typing import Any, Callable

from chuk_agents_runtime.action_policy import ActionDecision, ActionRequest
from chuk_agents_runtime.login_vault import LoginGuard
from chuk_agents_runtime.vault import VaultGuard

from .login_vault import MAX_REQUEST_ID, _NoLogins
from .secrets import SecretsVault
from .vault_items import VaultItemError

logger = logging.getLogger(__name__)

PAYMENT_VAULT_FRAMES = frozenset(
    {"payment_vault_set", "payment_vault_delete", "payment_vault_default", "payment_vault_list"}
)
CONTACT_VAULT_FRAMES = frozenset({"contact_vault_set", "contact_vault_delete", "contact_vault_list"})
VAULT_FRAMES = PAYMENT_VAULT_FRAMES | CONTACT_VAULT_FRAMES
PAYMENT_VAULT_REPLY = "payment_vault"
CONTACT_VAULT_REPLY = "contact_vault"


def payment_vault_payload(vault: SecretsVault | None, **extra: Any) -> dict:
    entries = vault.card_entries() if vault is not None else []
    default_id = vault.default_card_id if vault is not None else None
    return {"type": PAYMENT_VAULT_REPLY, "entries": entries, "default_id": default_id, **extra}


def contact_vault_payload(vault: SecretsVault | None, **extra: Any) -> dict:
    entries = vault.contact_entries() if vault is not None else []
    return {"type": CONTACT_VAULT_REPLY, "entries": entries, **extra}


def handle_vault_frame(vault: SecretsVault | None, kind: str, payload: Any) -> dict:
    """Apply one app frame and return the terminal reply. Never raises."""
    if not isinstance(payload, dict):
        payload = {}
    reply = _apply(vault, kind, payload)
    request_id = payload.get("request_id")
    if isinstance(request_id, str) and 0 < len(request_id) <= MAX_REQUEST_ID:
        reply["request_id"] = request_id
    return reply


def _apply(vault: SecretsVault | None, kind: str, payload: dict) -> dict:
    cards = kind in PAYMENT_VAULT_FRAMES
    build = payment_vault_payload if cards else contact_vault_payload
    if vault is None:
        return build(None, error="this host keeps no vault")
    body = {k: v for k, v in payload.items() if k not in ("type", "request_id")}
    try:
        if kind == "payment_vault_set":
            return build(vault, saved=vault.card_set(body))
        if kind == "payment_vault_delete":
            found = vault.card_delete(body.get("id"))
            reply = build(vault, deleted=str(body.get("id") or ""))
            if not found:
                reply["error"] = "no card with this id"
            return reply
        if kind == "payment_vault_default":
            vault.card_set_default(body.get("id"))
            return build(vault)
        if kind == "payment_vault_list":
            return build(vault)
        if kind == "contact_vault_set":
            return build(vault, saved=vault.contact_set(body))
        if kind == "contact_vault_delete":
            found = vault.contact_delete(body.get("id"))
            reply = build(vault, deleted=str(body.get("id") or ""))
            if not found:
                reply["error"] = "no contact with this id"
            return reply
        if kind == "contact_vault_list":
            return build(vault)
    except VaultItemError as exc:
        return build(vault, error=str(exc))
    except Exception as exc:  # noqa: BLE001 — a bad frame must not wedge serving
        logger.warning("vault frame failed: %s", type(exc).__name__)
        return build(vault, error="the vault could not apply this frame")
    return build(vault, error=f"unknown vault frame: {kind}")


class _NoVault(_NoLogins):
    def card_entries(self) -> list[dict]:
        return []

    def card_full(self, card_id: str) -> dict | None:
        return None

    def card_used(self, card_id: str) -> None:
        return None

    def contact_entries(self) -> list[dict]:
        return []


def vault_guard(
    vault: SecretsVault | None,
    session_key: str,
    approver: Callable[[ActionRequest], bool | ActionDecision] | None = None,
) -> VaultGuard:
    """The MCP ``call_guard`` of one session: logins, cards and contacts."""
    access = vault if vault is not None else _NoVault()
    key = str(session_key or "")
    return VaultGuard(
        access, login=LoginGuard(access, session_key=key), session_key=key, approver=approver
    )


__all__ = [
    "CONTACT_VAULT_FRAMES",
    "PAYMENT_VAULT_FRAMES",
    "VAULT_FRAMES",
    "handle_vault_frame",
    "vault_guard",
]
