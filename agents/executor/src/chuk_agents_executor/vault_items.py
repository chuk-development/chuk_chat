"""Payment cards and contact info of the host vault (CHAT-185).

Pure checks and views. :class:`~chuk_agents_executor.secrets.SecretsVault`
stores the rows in the same encrypted at-rest file as the logins; the frames
in :mod:`chuk_agents_executor.vault_frames` change them; the browser fill is
:class:`chuk_agents_runtime.vault.VaultGuard`.

A stored card: ``{id, brand, number, exp_month, exp_year, cvc, name, zip,
label, created_at, last_used_at}``. The public view drops ``number`` and
``cvc`` and adds ``last4``. A stored contact: ``{id, label, name, company,
phones: [{number, primary}], emails: [{address, primary}], address: {street,
line2, city, region, zip, country}, created_at, updated_at}``.
"""

from __future__ import annotations

import os
import time
from collections.abc import Mapping
from typing import Any

from chuk_agents_runtime.vault import card_brand, card_digits, luhn_ok

MAX_CARDS = 64
MAX_CONTACTS = 64
MAX_ROWS = 10
MAX_TEXT = 200
MAX_LABEL_CHARS = 80
ADDRESS_KEYS = ("street", "line2", "city", "region", "zip", "country")


class VaultItemError(ValueError):
    """A card or contact the vault refuses. The message never holds a value."""


def now_ms() -> int:
    return int(time.time() * 1000)


def new_id() -> str:
    return os.urandom(8).hex()


def _text(value: Any, limit: int = MAX_TEXT) -> str:
    if value is None:
        return ""
    if not isinstance(value, str):
        raise VaultItemError("text fields must be strings")
    return " ".join(value.split())[:limit]


def _int(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, str) and value.strip().isdigit():
        return int(value.strip())
    return None


# -- cards ----------------------------------------------------------------------


def card_update(current: Mapping | None, payload: Mapping) -> dict:
    """The card after an app ``payment_vault_set``. ``current`` is the stored
    card (an update) or ``None`` (a new card). A field the payload leaves out
    keeps its stored value; a new card needs ``number`` and an expiry."""
    card = dict(current) if current else {
        "id": new_id(), "brand": "card", "number": "", "exp_month": None, "exp_year": None,
        "cvc": "", "name": "", "zip": "", "label": "", "created_at": now_ms(), "last_used_at": None,
    }
    if "number" in payload or current is None:
        number = card_digits(payload.get("number"))
        if not luhn_ok(number):
            raise VaultItemError("number is not a valid card number")
        card["number"] = number
        card["brand"] = card_brand(number)
    if "exp_month" in payload or current is None:
        month = _int(payload.get("exp_month"))
        if month is None or not 1 <= month <= 12:
            raise VaultItemError("exp_month must be 1 to 12")
        card["exp_month"] = month
    if "exp_year" in payload or current is None:
        year = _int(payload.get("exp_year"))
        if year is not None and 0 <= year < 100:
            year += 2000
        if year is None or not 2000 <= year <= 2100:
            raise VaultItemError("exp_year must be a year like 2029")
        card["exp_year"] = year
    if "cvc" in payload:
        cvc = payload.get("cvc")
        if cvc in (None, ""):
            card["cvc"] = ""
        elif isinstance(cvc, str) and cvc.strip().isdigit() and 3 <= len(cvc.strip()) <= 4:
            card["cvc"] = cvc.strip()
        else:
            raise VaultItemError("cvc must be 3 or 4 digits")
    for key in ("name", "zip"):
        if key in payload:
            card[key] = _text(payload.get(key))
    if "label" in payload:
        card["label"] = _text(payload.get("label"), MAX_LABEL_CHARS)
    return card


def card_public(card: Mapping, default_id: str | None) -> dict:
    """What the app may see: everything but the number and the security code."""
    number = str(card.get("number") or "")
    return {
        "id": card["id"],
        "brand": card.get("brand") or "card",
        "last4": number[-4:],
        "label": card.get("label") or "",
        "exp_month": card.get("exp_month"),
        "exp_year": card.get("exp_year"),
        "name": card.get("name") or "",
        "zip": card.get("zip") or "",
        "has_cvc": bool(card.get("cvc")),
        "is_default": card["id"] == default_id,
        "created_at": card.get("created_at"),
        "last_used_at": card.get("last_used_at"),
    }


def clean_cards(raw: Any) -> dict[str, dict]:
    """The cards of an at-rest record; a malformed row is dropped."""
    out: dict[str, dict] = {}
    if not isinstance(raw, list):
        return out
    for row in raw:
        if not isinstance(row, dict) or not isinstance(row.get("id"), str) or not row["id"]:
            continue
        try:
            card = card_update(None, row)
        except VaultItemError:
            continue
        card["id"] = row["id"]
        card["cvc"] = row.get("cvc") if isinstance(row.get("cvc"), str) else ""
        for key in ("created_at", "last_used_at"):
            card[key] = row.get(key) if isinstance(row.get(key), int) else None
        out[card["id"]] = card
        if len(out) >= MAX_CARDS:
            break
    return out


# -- contacts ---------------------------------------------------------------------


def _rows(raw: Any, key: str) -> list[dict]:
    if raw is None:
        return []
    if not isinstance(raw, list):
        raise VaultItemError(f"{key}s must be a list")
    out: list[dict] = []
    for item in raw[:MAX_ROWS]:
        if isinstance(item, str):
            item = {key: item}
        if not isinstance(item, Mapping):
            raise VaultItemError(f"each {key} must be an object")
        value = _text(item.get(key))
        if not value:
            continue
        out.append({key: value, "primary": item.get("primary") is True})
    # Exactly one primary when there are rows: the first marked one, else the first.
    first = next((i for i, r in enumerate(out) if r["primary"]), 0)
    for i, row in enumerate(out):
        row["primary"] = i == first
    return out


def contact_update(current: Mapping | None, payload: Mapping) -> dict:
    """The contact after an app ``contact_vault_set``. Left-out fields keep
    their stored value; ``phones`` / ``emails`` / ``address`` replace whole."""
    contact = dict(current) if current else {
        "id": new_id(), "label": "", "name": "", "company": "", "phones": [], "emails": [],
        "address": {k: "" for k in ADDRESS_KEYS}, "created_at": now_ms(), "updated_at": None,
    }
    if "label" in payload or current is None:
        label = _text(payload.get("label"), MAX_LABEL_CHARS)
        if not label:
            raise VaultItemError("label is required (for example Home or Work)")
        if ":" in label or "{" in label or "}" in label:
            raise VaultItemError("label must not contain ':' or braces")
        contact["label"] = label
    for key in ("name", "company"):
        if key in payload:
            contact[key] = _text(payload.get(key))
    if "phones" in payload:
        contact["phones"] = _rows(payload.get("phones"), "number")
    if "emails" in payload:
        contact["emails"] = _rows(payload.get("emails"), "address")
    if "address" in payload:
        raw = payload.get("address") or {}
        if not isinstance(raw, Mapping):
            raise VaultItemError("address must be an object")
        contact["address"] = {k: _text(raw.get(k)) for k in ADDRESS_KEYS}
    contact["updated_at"] = now_ms()
    return contact


def clean_contacts(raw: Any) -> dict[str, dict]:
    out: dict[str, dict] = {}
    if not isinstance(raw, list):
        return out
    for row in raw:
        if not isinstance(row, dict) or not isinstance(row.get("id"), str) or not row["id"]:
            continue
        try:
            contact = contact_update(None, row)
        except VaultItemError:
            continue
        contact["id"] = row["id"]
        for key in ("created_at", "updated_at"):
            contact[key] = row.get(key) if isinstance(row.get(key), int) else None
        out[contact["id"]] = contact
        if len(out) >= MAX_CONTACTS:
            break
    return out


__all__ = [
    "ADDRESS_KEYS",
    "MAX_CARDS",
    "MAX_CONTACTS",
    "VaultItemError",
    "card_public",
    "card_update",
    "clean_cards",
    "clean_contacts",
    "contact_update",
]
