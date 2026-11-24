"""Vault payment cards and contact info for the browser (CHAT-185).

The login vault (:mod:`.login_vault`) holds logins. This module adds two more
kinds of vault rows and the one seam that fills them into a page:

Payment cards
    The model sees only brand, last 4 digits, label and whether the card is
    the default ("Amex •••• 1005, default"). It writes a placeholder into a
    browser fill:

    - ``{{card:<id|label|default>:number}}``
    - ``:exp`` (``MM/YY``), ``:exp_month`` (``MM``), ``:exp_year`` (``YYYY``),
      ``:exp_year2`` (``YY``), ``:cvc``, ``:name``, ``:zip``

    A card is filled only

    1. in ``browser_type.text`` or ``browser_fill_form.fields[].value``;
    2. on an ``https`` page (``http`` only for localhost);
    3. into a checkout field: an ``<input>`` whose ``autocomplete`` names the
       card field (``cc-number``, ``cc-csc``, ...) or whose name / id /
       label says so, in a frame of the page itself or of a known payment
       provider (Stripe, Adyen, Braintree, ...);
    4. after the user approves it: every call that uses a card is one
       approval of the action class ``payment`` (always ask, no "always
       allow"). No approver in the run means no fill.

    The number and the security code never come back: the result of the fill
    and every later browser result of the session are masked, a screenshot
    and page scripts on that site are refused for the rest of the session,
    and the audit line holds no value.

Contact info
    The user's own addresses, phones and emails. The model MAY read them
    (``vault_contacts``). ``{{contact:<label|id>:phone}}`` (also ``name``,
    ``first_name``, ``last_name``, ``email``, ``company``, ``street``,
    ``line2``, ``city``, ``region``, ``zip``, ``country``, ``address``) is
    filled in the same browser slots on any https page, with no approval.

:class:`VaultAccess` is the seam; the executor implements it with its secrets
vault. :class:`VaultGuard` wraps the session's :class:`LoginGuard` and is
installed as the MCP ``call_guard``.
"""

from __future__ import annotations

import copy
import re
import threading
import time
from collections.abc import Callable, Mapping
from typing import Any, Protocol, runtime_checkable

from .action_policy import PAYMENT, SCOPE_DENY, SCOPE_ONCE, ActionDecision, ActionRequest
from .login_vault import (
    EVALUATE_TOOL,
    FILL_FORM_TOOL,
    SCRIPT_TOOLS,
    TYPE_TOOL,
    LoginGuard,
    Refusal,
    _probe_result,
    _slots,
    _without_slots,
    has_placeholder as has_login_placeholder,
    mask_values,
    normalize_origin,
    origin_allowed,
)
from .registry import ToolRegistry

VAULT_LIST_TOOL = "vault_list"
VAULT_CONTACTS_TOOL = "vault_contacts"
SCREENSHOT_TOOL = "browser_take_screenshot"

CARD_FIELDS = ("number", "exp", "exp_month", "exp_year", "exp_year2", "cvc", "name", "zip")
CONTACT_FIELDS = (
    "name", "first_name", "last_name", "company", "phone", "email",
    "street", "line2", "city", "region", "zip", "country", "address",
)
#: Card fields whose value the model never sees.
SECRET_CARD_FIELDS = frozenset({"number", "cvc"})

CARD_RE = re.compile(
    r"\{\{card:(?P<selector>[^{}:]+):(?P<field>" + "|".join(CARD_FIELDS) + r")\}\}"
)
CONTACT_RE = re.compile(
    r"\{\{contact:(?P<selector>[^{}:]+):(?P<field>" + "|".join(CONTACT_FIELDS) + r")\}\}"
)
_LOOSE_CARD_RE = re.compile(r"\{\{\s*card\s*:", re.IGNORECASE)
_LOOSE_CONTACT_RE = re.compile(r"\{\{\s*contact\s*:", re.IGNORECASE)

DEFAULT_SELECTOR = "default"

#: Frames of payment providers that a checkout embeds for the card fields.
PAYMENT_FRAME_HOSTS = frozenset(
    {
        "js.stripe.com",
        "checkoutshopper-live.adyen.com",
        "checkoutshopper-test.adyen.com",
        "assets.braintreegateway.com",
        "js.braintreegateway.com",
        "payments.braintree-api.com",
        "js.checkout.com",
        "web.squarecdn.com",
        "pci-connect.squareup.com",
        "js.mollie.com",
        "www.paypal.com",
    }
)

#: Audit outcomes (the login audit file, ``entry_id`` ``card:<id>``).
OUTCOME_FILLED = "filled"
OUTCOME_DECLINED = "declined"

# -- cards ----------------------------------------------------------------------

BRAND_NAMES = {
    "amex": "Amex",
    "visa": "Visa",
    "mastercard": "Mastercard",
    "discover": "Discover",
    "diners": "Diners Club",
    "jcb": "JCB",
    "unionpay": "UnionPay",
    "maestro": "Maestro",
    "card": "Card",
}


def card_digits(value: Any) -> str:
    """The digits of a card number; spaces and dashes are dropped. ``""``
    when anything else is in it."""
    if not isinstance(value, str):
        return ""
    text = re.sub(r"[\s-]", "", value)
    return text if text.isdigit() else ""


def luhn_ok(number: str) -> bool:
    if not number.isdigit() or not 12 <= len(number) <= 19:
        return False
    total = 0
    for i, ch in enumerate(reversed(number)):
        d = int(ch)
        if i % 2:
            d *= 2
            if d > 9:
                d -= 9
        total += d
    return total % 10 == 0


def card_brand(number: str) -> str:
    """The brand key (see :data:`BRAND_NAMES`) from the number's prefix."""
    n = number
    if n[:2] in ("34", "37"):
        return "amex"
    if n[:1] == "4":
        return "visa"
    if n[:2] in ("51", "52", "53", "54", "55") or (len(n) >= 4 and 2221 <= int(n[:4]) <= 2720):
        return "mastercard"
    if n.startswith("6011") or n.startswith("65") or (len(n) >= 3 and 644 <= int(n[:3]) <= 649):
        return "discover"
    if n[:2] in ("36", "38") or (len(n) >= 3 and 300 <= int(n[:3]) <= 305):
        return "diners"
    if len(n) >= 4 and 3528 <= int(n[:4]) <= 3589:
        return "jcb"
    if n[:2] == "62":
        return "unionpay"
    if n[:2] in ("50", "56", "57", "58") or n[:1] == "6":
        return "maestro"
    return "card"


def card_display(entry: Mapping) -> str:
    """``Amex •••• 1005`` from a public card row."""
    brand = BRAND_NAMES.get(str(entry.get("brand") or ""), "Card")
    return f"{brand} •••• {entry.get('last4') or '????'}"


def number_variants(number: str) -> list[str]:
    """The renderings of a number a page can show: digits, groups of four
    with spaces or dashes, and the Amex 4-6-5 grouping."""
    out = [number]
    fours = [number[i : i + 4] for i in range(0, len(number), 4)]
    groupings = [fours]
    if len(number) == 15:
        groupings.append([number[:4], number[4:10], number[10:]])
    for groups in groupings:
        for sep in (" ", "-", " "):
            joined = sep.join(groups)
            if joined not in out:
                out.append(joined)
    return out


def card_secret_values(card: Mapping) -> dict[str, str]:
    """name -> value of everything a card fill must never show again."""
    card_id = str(card.get("id") or "")
    out: dict[str, str] = {}
    number = str(card.get("number") or "")
    if number:
        for i, variant in enumerate(number_variants(number)):
            out[f"card:{card_id}:number" + (f"#{i}" if i else "")] = variant
    cvc = str(card.get("cvc") or "")
    if cvc:
        out[f"card:{card_id}:cvc"] = cvc
    return out


def card_field_value(card: Mapping, field: str) -> str:
    month = card.get("exp_month")
    year = card.get("exp_year")
    mm = f"{int(month):02d}" if isinstance(month, int) else ""
    yyyy = f"{int(year):04d}" if isinstance(year, int) else ""
    if field == "number":
        return str(card.get("number") or "")
    if field == "exp":
        return f"{mm}/{yyyy[-2:]}" if mm and yyyy else ""
    if field == "exp_month":
        return mm
    if field == "exp_year":
        return yyyy
    if field == "exp_year2":
        return yyyy[-2:]
    if field in ("cvc", "name", "zip"):
        return str(card.get(field) or "")
    return ""


# -- contacts ---------------------------------------------------------------------


def _primary(rows: Any, key: str) -> str:
    if not isinstance(rows, list):
        return ""
    clean = [r for r in rows if isinstance(r, Mapping) and r.get(key)]
    for row in clean:
        if row.get("primary"):
            return str(row[key])
    return str(clean[0][key]) if clean else ""


def contact_field_value(contact: Mapping, field: str) -> str:
    address = contact.get("address") if isinstance(contact.get("address"), Mapping) else {}
    name = str(contact.get("name") or "").strip()
    if field == "name":
        return name
    if field == "first_name":
        return name.split(" ", 1)[0] if name else ""
    if field == "last_name":
        return name.rsplit(" ", 1)[1] if " " in name else ""
    if field == "company":
        return str(contact.get("company") or "")
    if field == "phone":
        return _primary(contact.get("phones"), "number")
    if field == "email":
        return _primary(contact.get("emails"), "address")
    if field in ("street", "line2", "city", "region", "zip", "country"):
        return str(address.get(field) or "")
    if field == "address":
        return one_line_address(address)
    return ""


def one_line_address(address: Mapping) -> str:
    street = ", ".join(p for p in (address.get("street"), address.get("line2")) if p)
    town = " ".join(p for p in (address.get("zip"), address.get("city")) if p)
    return ", ".join(p for p in (street, town, address.get("region"), address.get("country")) if p)


def contact_summary(contact: Mapping) -> str:
    """``Home — Jane Appleseed · (555) 010-2001``."""
    label = str(contact.get("label") or "Contact")
    rest = [p for p in (contact.get("name"), contact_field_value(contact, "phone")) if p]
    return label + (" — " + " · ".join(str(p) for p in rest) if rest else "")


# -- the access seam ------------------------------------------------------------------


@runtime_checkable
class VaultAccess(Protocol):
    """What the guard and the tools need, beside :class:`LoginVaultAccess`."""

    def card_entries(self) -> list[dict]:
        """Public rows only: ``id, brand, last4, label, is_default, ...``.
        Never a number or a security code."""
        ...

    def card_full(self, card_id: str) -> dict | None:
        """The full card (with ``number`` and ``cvc``), or ``None``."""
        ...

    def card_used(self, card_id: str) -> None: ...

    def contact_entries(self) -> list[dict]:
        """The user's contact rows, in full (the model may read them)."""
        ...


def has_vault_placeholder(obj: Any) -> bool:
    """True when any string in ``obj`` (nested) looks like a card or contact
    placeholder."""
    if isinstance(obj, str):
        return bool(_LOOSE_CARD_RE.search(obj) or _LOOSE_CONTACT_RE.search(obj))
    if isinstance(obj, Mapping):
        return any(has_vault_placeholder(v) for v in obj.values())
    if isinstance(obj, (list, tuple)):
        return any(has_vault_placeholder(v) for v in obj)
    return False


def _pick_card(access: Any, selector: str) -> dict:
    rows = [r for r in (access.card_entries() or []) if isinstance(r, Mapping)]
    wanted = selector.strip().lower()
    if wanted == DEFAULT_SELECTOR:
        found = [r for r in rows if r.get("is_default")]
        if not found:
            raise Refusal(
                "there is no default payment method. Call vault_list to see the saved "
                "cards and name one: {{card:<id>:number}}.",
                "unknown_entry",
            )
    else:
        found = [
            r
            for r in rows
            if wanted in (str(r.get("id") or "").lower(), str(r.get("label") or "").lower())
        ]
    if not found:
        raise Refusal(
            f"no saved card '{selector}'. Call vault_list to see the saved cards.",
            "unknown_entry",
        )
    if len(found) > 1:
        raise Refusal(
            f"{len(found)} saved cards match '{selector}'. Use the card id from vault_list.",
            "ambiguous_entry",
        )
    full = access.card_full(str(found[0].get("id") or ""))
    if not isinstance(full, Mapping):
        raise Refusal(f"no saved card '{selector}'.", "unknown_entry")
    return {**dict(full), **{k: found[0].get(k) for k in ("brand", "last4", "is_default")}}


def _pick_contact(access: Any, selector: str) -> dict:
    rows = [r for r in (access.contact_entries() or []) if isinstance(r, Mapping)]
    wanted = selector.strip().lower()
    found = [
        r for r in rows if wanted in (str(r.get("id") or "").lower(), str(r.get("label") or "").lower())
    ]
    if not found:
        raise Refusal(
            f"no saved contact '{selector}'. Call vault_contacts to see them.", "unknown_entry"
        )
    if len(found) > 1:
        raise Refusal(f"{len(found)} contacts match '{selector}'. Use the id.", "ambiguous_entry")
    return dict(found[0])


# -- checkout fields ----------------------------------------------------------------

#: Read on the target element in its own frame: origin, kind, autocomplete
#: and the words that name the field (name, id, placeholder, aria-label).
_CARD_PROBE = (
    "(el) => ({origin: el.ownerDocument.location.origin, "
    "tag: String(el.tagName || '').toLowerCase(), "
    "type: String(el.getAttribute('type') || el.type || '').toLowerCase(), "
    "autocomplete: String(el.getAttribute('autocomplete') || '').toLowerCase(), "
    "hint: [el.name, el.id, el.getAttribute('placeholder'), el.getAttribute('aria-label'), "
    "el.getAttribute('data-elements-stable-field-name')].filter(Boolean).join(' ')"
    ".toLowerCase().slice(0, 300)})"
)

_AUTOCOMPLETE = {
    "number": ("cc-number",),
    "exp": ("cc-exp",),
    "exp_month": ("cc-exp-month", "cc-exp"),
    "exp_year": ("cc-exp-year", "cc-exp"),
    "exp_year2": ("cc-exp-year", "cc-exp"),
    "cvc": ("cc-csc",),
    "name": ("cc-name", "name"),
    "zip": ("postal-code",),
}
_HINTS = {
    "number": re.compile(r"card|\bcc|credit|kredit|karte|\bpan\b"),
    "exp": re.compile(r"exp|valid|ablauf|g(?:ü|ue)ltig|mm\s*/\s*(?:yy|jj)"),
    "exp_month": re.compile(r"month|monat|exp|\bmm\b"),
    "exp_year": re.compile(r"year|jahr|exp|\byy|\bjj"),
    "exp_year2": re.compile(r"year|jahr|exp|\byy|\bjj"),
    "cvc": re.compile(r"cvc|cvv|csc|\bcid\b|security|sicherheit|pr(?:ü|ue)f|verification"),
    "name": re.compile(r"name|holder|inhaber"),
    "zip": re.compile(r"zip|postal|\bpost|\bplz"),
}
_INPUT_TYPES = frozenset({"", "text", "tel", "number", "password"})


def checkout_field_ok(field: str, probe: Mapping) -> bool:
    """True when the probed element is a checkout field for ``field``."""
    if probe.get("tag") != "input" or probe.get("type") not in _INPUT_TYPES:
        return False
    if probe.get("type") == "password" and field != "cvc":
        return False
    tokens = str(probe.get("autocomplete") or "").split()
    if any(t in _AUTOCOMPLETE.get(field, ()) for t in tokens):
        return True
    if any(t.startswith("cc-") for t in tokens):
        return False  # a card field of another kind
    return bool(_HINTS[field].search(str(probe.get("hint") or "")))


def frame_ok(page_origin: str, frame_origin: str | None) -> bool:
    """The field lives in the page itself or in a known payment frame."""
    if not frame_origin:
        return False
    if frame_origin == page_origin:
        return True
    if not frame_origin.startswith("https://"):
        return False
    host = frame_origin[len("https://") :]
    return host in PAYMENT_FRAME_HOSTS


def describe_payment(card: Mapping, page_origin: str, frames: list[str], fields: list[str]) -> ActionRequest:
    site = page_origin.split("://", 1)[-1]
    shown = card_display(card)
    details: dict[str, Any] = {
        "kind": "payment",
        "card": shown,
        "card_id": str(card.get("id") or ""),
        "label": str(card.get("label") or ""),
        "page": page_origin,
        "fields": list(fields),
    }
    other = sorted({f for f in frames if f and f != page_origin})
    if other:
        details["payment_frames"] = other
    return ActionRequest(
        PAYMENT,
        "browser_fill",
        f"Pay with {shown} on {site}",
        details,
        site=site,
        options=(SCOPE_ONCE, SCOPE_DENY),
    )


# -- the guard -----------------------------------------------------------------------


class VaultGuard:
    """The session's MCP ``call_guard``: card and contact placeholders here,
    everything else through the wrapped :class:`LoginGuard`.

    ``approver(request)`` asks the user for one ``payment`` action and returns
    an :class:`ActionDecision` or a bool; it may raise ``PermissionError`` with
    a message for the model (payments are off for this agent). ``None`` = no
    one can approve, so no card is filled.
    """

    def __init__(
        self,
        access: Any,
        *,
        login: LoginGuard | None = None,
        session_key: str = "",
        approver: Callable[[ActionRequest], Any] | None = None,
        clock: Callable[[], float] = time.time,
    ) -> None:
        self._access = access
        self._login = login or LoginGuard(access, session_key=session_key, clock=clock)
        self._session_key = session_key
        self.approver = approver
        self._clock = clock
        #: Values masked in every result of the session after a card fill.
        self._sticky: dict[str, str] = {}
        #: Origins a card was filled on: no screenshot there any more.
        self._card_origins: set[str] = set()
        self._lock = threading.Lock()

    @property
    def login_guard(self) -> LoginGuard:
        return self._login

    def __call__(
        self,
        manager: Any,
        server: str,
        tool: str,
        arguments: dict | None,
        invoke: Callable[[dict], dict],
    ) -> dict:
        args = arguments if isinstance(arguments, dict) else {}
        if getattr(self._login._internal, "depth", 0):
            return invoke(args)
        if tool == SCREENSHOT_TOOL and self._card_origins:
            origin = normalize_origin(self._login._page_url(manager, server))
            if origin is None or origin in self._card_origins:
                self._audit(tool, origin or "", "", [], "refused_screenshot")
                return {
                    "ok": False,
                    "server": server,
                    "tool": tool,
                    "error": (
                        f"{tool} is blocked on {origin or 'an unknown page'} after a saved card "
                        "was filled there: the image could show the card. Use browser_snapshot."
                    ),
                }
        if not has_vault_placeholder(args):
            return self._masked(self._login(manager, server, tool, args, invoke))
        try:
            return self._masked(self._fill(manager, server, tool, args, invoke))
        except Refusal as refusal:
            self._audit(tool, refusal.origin, refusal.entry_id, [], refusal.outcome)
            return {"ok": False, "server": server, "tool": tool, "error": str(refusal)}

    # -- internals ---------------------------------------------------------------

    def _masked(self, result: Any) -> Any:
        with self._lock:
            sticky = dict(self._sticky)
        return mask_values(result, sticky) if sticky else result

    def _fill(
        self, manager: Any, server: str, tool: str, args: dict, invoke: Callable[[dict], dict]
    ) -> dict:
        if tool not in (TYPE_TOOL, FILL_FORM_TOOL) or has_vault_placeholder(
            _without_slots(tool, args)
        ):
            raise Refusal(
                "card and contact placeholders work only in the 'text' of browser_type and "
                "the 'value' of browser_fill_form fields. This call was not sent.",
                "refused_tool",
            )
        if has_login_placeholder(args):
            raise Refusal(
                "fill a saved login and a saved card or contact in separate calls.",
                "refused_tool",
            )
        resolved = copy.deepcopy(args)
        slots = _slots(tool, resolved)
        card_slots: list[tuple[Any, Any, list[tuple[str, str]]]] = []
        any_contact = False
        for container, key in slots:
            text = container[key]
            rest = CONTACT_RE.sub("", CARD_RE.sub("", text))
            if _LOOSE_CARD_RE.search(rest) or _LOOSE_CONTACT_RE.search(rest):
                raise Refusal(
                    "malformed vault placeholder. Use {{card:<id|default>:number}} (fields: "
                    + ", ".join(CARD_FIELDS)
                    + ") or {{contact:<label>:phone}} (fields: "
                    + ", ".join(CONTACT_FIELDS)
                    + ").",
                    "unknown_entry",
                )
            cards = [(m.group("selector"), m.group("field")) for m in CARD_RE.finditer(text)]
            if cards:
                card_slots.append((container, key, cards))
            if CONTACT_RE.search(text):
                any_contact = True
        if not card_slots and not any_contact:
            raise Refusal("malformed vault placeholder.", "unknown_entry")

        page_url = self._login._page_url(manager, server)
        page_origin = normalize_origin(page_url) if page_url else None
        if page_origin is None or not origin_allowed(page_origin):
            raise Refusal(
                "saved cards and contacts are filled only on an https page; the page URL "
                f"is {page_origin or 'unknown'}.",
                "refused_origin",
                page_origin or "",
            )

        # Cards: one card per call, checked fields, then the user's approval.
        card: dict | None = None
        fields_used: list[str] = []
        frames: list[str] = []
        if card_slots:
            selectors = {sel.strip().lower() for _c, _k, cards in card_slots for sel, _f in cards}
            if len(selectors) > 1:
                raise Refusal("use one saved card per call.", "ambiguous_entry", page_origin)
            card = _pick_card(self._access, next(iter(selectors)))
            entry_id = f"card:{card.get('id')}"
            for container, _key, cards in card_slots:
                ref = container.get("ref") if isinstance(container, dict) else None
                probe = self._probe(manager, server, ref, container.get("element"))
                if probe is None:
                    raise Refusal(
                        "the checkout field could not be checked (no element ref, or the "
                        "page did not answer). Take a browser_snapshot and pass the field's ref.",
                        "refused_frame",
                        page_origin,
                        entry_id,
                    )
                frame_origin = normalize_origin(probe.get("origin"))
                if not frame_ok(page_origin, frame_origin):
                    raise Refusal(
                        f"a saved card goes only into a field of {page_origin} or of a known "
                        f"payment provider; this field is in {frame_origin or 'an unknown frame'}.",
                        "refused_frame",
                        page_origin,
                        entry_id,
                    )
                frames.append(frame_origin or "")
                for _sel, field in cards:
                    if not checkout_field_ok(field, probe):
                        raise Refusal(
                            f"the card {field} goes only into a checkout field for it "
                            "(an <input> with autocomplete cc-*, or named for it). "
                            "This field is not one.",
                            "refused_field",
                            page_origin,
                            entry_id,
                        )
                    if field not in fields_used:
                        fields_used.append(field)
                    if not card_field_value(card, field):
                        raise Refusal(
                            f"the saved card has no {field}.", "unknown_entry", page_origin, entry_id
                        )
            self._approve(card, page_origin, frames, fields_used, entry_id)

        # Resolve.
        secret_values: dict[str, str] = card_secret_values(card) if card else {}

        def card_value(m: re.Match) -> str:
            assert card is not None
            return card_field_value(card, m.group("field"))

        def contact_value(m: re.Match) -> str:
            contact = _pick_contact(self._access, m.group("selector"))
            value = contact_field_value(contact, m.group("field"))
            if not value:
                raise Refusal(
                    f"the contact '{m.group('selector')}' has no {m.group('field')}.",
                    "unknown_entry",
                    page_origin,
                )
            return value

        for container, key in slots:
            text = CONTACT_RE.sub(contact_value, container[key])
            container[key] = CARD_RE.sub(card_value, text)

        if card is not None:
            with self._lock:
                self._sticky.update(secret_values)
                self._card_origins.add(page_origin)
            self._login.mark_filled(page_origin)
        result = invoke(resolved)
        result = mask_values(result, secret_values) if secret_values else result
        after_url = self._login._page_url(manager, server)
        after_origin = normalize_origin(after_url) if after_url else None
        if after_origin != page_origin:
            if card is not None:
                self._audit(tool, page_origin, f"card:{card.get('id')}", fields_used, "navigated_during_fill")
            return {
                "ok": False,
                "server": server,
                "tool": tool,
                "error": (
                    f"the page left {page_origin} during the fill (now {after_origin or 'unknown'}). "
                    "The fill is stopped; check the page with browser_snapshot."
                ),
            }
        failed = isinstance(result, dict) and result.get("ok") is False
        if card is not None:
            try:
                self._access.card_used(str(card.get("id") or ""))
            except Exception:  # noqa: BLE001 — bookkeeping never fails the fill
                pass
            self._audit(
                tool, page_origin, f"card:{card.get('id')}", fields_used,
                "fill_failed" if failed else OUTCOME_FILLED,
            )
        if isinstance(result, dict) and not failed:
            info: dict[str, Any] = {"origin": page_origin}
            if card is not None:
                info["card"] = card_display(card)
                info["card_fields"] = list(fields_used)
            result = {**result, "vault": info}
        return result

    def _approve(
        self, card: Mapping, page_origin: str, frames: list[str], fields: list[str], entry_id: str
    ) -> None:
        request = describe_payment(card, page_origin, frames, fields)
        if self.approver is None:
            raise Refusal(
                "paying with a saved card needs the user's approval, but no one can approve "
                "it in this run. The card was not filled.",
                "unattended",
                page_origin,
                entry_id,
            )
        try:
            answer = self.approver(request)
        except PermissionError as exc:
            raise Refusal(str(exc), OUTCOME_DECLINED, page_origin, entry_id) from None
        except Exception:  # noqa: BLE001 — a failed ask is a no
            answer = False
        approved = answer.approved if isinstance(answer, ActionDecision) else answer is True
        if not approved:
            raise Refusal(
                "the user declined the payment: the card was not filled. Do not retry; "
                "ask the user what to do instead.",
                OUTCOME_DECLINED,
                page_origin,
                entry_id,
            )

    def _probe(self, manager: Any, server: str, ref: Any, element: Any) -> dict | None:
        if not isinstance(ref, str) or not ref.strip():
            return None
        args = {
            "function": _CARD_PROBE,
            "ref": ref,
            "element": element if isinstance(element, str) and element else "checkout field",
        }
        try:
            result = self._login._own_call(manager, server, EVALUATE_TOOL, args)
        except Exception:  # noqa: BLE001 — unknown field means no fill
            return None
        if not isinstance(result, dict) or not result.get("ok"):
            return None
        base = _probe_result(result.get("content"))
        if base is None:
            return None
        raw = _raw_probe(result.get("content"))
        base["autocomplete"] = str(raw.get("autocomplete") or "").lower()
        base["hint"] = str(raw.get("hint") or "").lower()[:300]
        return base

    def _audit(self, tool: str, origin: str, entry_id: str, kinds: list[str], outcome: str) -> None:
        record = {
            "ts": round(self._clock(), 3),
            "session_key": self._session_key,
            "origin": origin,
            "entry_id": entry_id,
            "fields": list(kinds),
            "tool": tool,
            "outcome": outcome,
        }
        audit = getattr(self._access, "login_audit", None)
        if callable(audit):
            try:
                audit(record)
            except Exception:  # noqa: BLE001 — the audit never fails the call
                pass


def _raw_probe(content: Any) -> dict:
    import json

    if isinstance(content, dict):
        return content
    if isinstance(content, str):
        text = content.split("### Result", 1)[1] if "### Result" in content else content
        start = text.find("{")
        if start >= 0:
            try:
                data, _ = json.JSONDecoder().raw_decode(text[start:])
                return data if isinstance(data, dict) else {}
            except ValueError:
                return {}
    return {}


# -- the model tools ------------------------------------------------------------------

VAULT_LIST_SCHEMA = {
    "type": "object",
    "description": (
        "List what the user saved in the vault: logins, payment cards and contact info, "
        "with counts. Cards show only brand, last 4 digits, label and the default; you "
        "never see a card number or security code. To pay, write {{card:<id>:number}}, "
        ":exp, :exp_month, :exp_year, :cvc, :name or :zip ({{card:default:...}} = the "
        "default card) as browser_fill_form value (one call for the whole checkout) or "
        "browser_type text; the user approves every card fill. Contacts: "
        "{{contact:<label>:phone}} (also name, email, street, city, zip, country, address)."
    ),
    "properties": {
        "kind": {
            "type": "string",
            "enum": ["all", "logins", "payments", "contacts"],
            "description": "Which rows to list. Default all.",
        }
    },
    "required": [],
}

VAULT_CONTACTS_SCHEMA = {
    "type": "object",
    "description": (
        "Read the user's own contact info from the vault (name, addresses, phones and "
        "emails with the primary one). Fill it into a form with {{contact:<label>:<field>}}."
    ),
    "properties": {
        "label": {"type": "string", "description": "Only this contact (label or id)."}
    },
    "required": [],
}


def _logins(access: Any) -> list[dict]:
    lister = getattr(access, "login_entries", None)
    rows = lister() if callable(lister) else []
    return [
        {
            "id": str(e.get("id") or ""),
            "origin": str(e.get("origin") or ""),
            "username": str(e.get("username") or ""),
            "label": str(e.get("label") or ""),
        }
        for e in rows or []
        if isinstance(e, Mapping)
    ]


def _payments(access: Any) -> list[dict]:
    lister = getattr(access, "card_entries", None)
    rows = lister() if callable(lister) else []
    out = []
    for e in rows or []:
        if not isinstance(e, Mapping):
            continue
        shown = card_display(e) + (", default" if e.get("is_default") else "")
        # Only these four facts; never the number, expiry or security code.
        out.append(
            {
                "id": str(e.get("id") or ""),
                "card": shown,
                "label": str(e.get("label") or ""),
                "default": bool(e.get("is_default")),
            }
        )
    return out


def _contacts(access: Any) -> list[dict]:
    lister = getattr(access, "contact_entries", None)
    rows = lister() if callable(lister) else []
    return [dict(e) for e in rows or [] if isinstance(e, Mapping)]


def make_vault_list_handler(access: Any):
    def vault_list(kind: str = "all") -> dict:
        logins, payments, contacts = _logins(access), _payments(access), _contacts(access)
        counts = {
            "all": len(logins) + len(payments) + len(contacts),
            "logins": len(logins),
            "payments": len(payments),
            "contacts": len(contacts),
        }
        out: dict[str, Any] = {"counts": counts}
        if kind in ("all", "logins"):
            out["logins"] = logins
        if kind in ("all", "payments"):
            out["payments"] = payments
        if kind in ("all", "contacts"):
            out["contacts"] = [
                {"id": str(c.get("id") or ""), "label": str(c.get("label") or ""), "summary": contact_summary(c)}
                for c in contacts
            ]
        return out

    return vault_list


def make_vault_contacts_handler(access: Any):
    def vault_contacts(label: str = "") -> dict:
        rows = _contacts(access)
        wanted = (label or "").strip().lower()
        if wanted:
            rows = [
                r for r in rows if wanted in (str(r.get("id") or "").lower(), str(r.get("label") or "").lower())
            ]
        out = []
        for r in rows:
            out.append(
                {
                    "id": str(r.get("id") or ""),
                    "label": str(r.get("label") or ""),
                    "name": str(r.get("name") or ""),
                    "company": str(r.get("company") or ""),
                    "phones": [dict(p) for p in r.get("phones") or [] if isinstance(p, Mapping)],
                    "emails": [dict(p) for p in r.get("emails") or [] if isinstance(p, Mapping)],
                    "address": dict(r.get("address") or {}),
                    "address_line": one_line_address(r.get("address") or {}),
                }
            )
        return {"contacts": out, "count": len(out)}

    return vault_contacts


def register_vault_tools(registry: ToolRegistry, access: Any) -> None:
    """Register ``vault_list`` (when the access lists anything) and
    ``vault_contacts`` (when it holds contacts)."""
    if access is None:
        return
    if any(callable(getattr(access, m, None)) for m in ("card_entries", "contact_entries")):
        registry.register(
            VAULT_LIST_TOOL, VAULT_LIST_SCHEMA, make_vault_list_handler(access), deferrable=True
        )
    if callable(getattr(access, "contact_entries", None)):
        registry.register(
            VAULT_CONTACTS_TOOL,
            VAULT_CONTACTS_SCHEMA,
            make_vault_contacts_handler(access),
            deferrable=True,
        )


__all__ = [
    "BRAND_NAMES",
    "CARD_FIELDS",
    "CARD_RE",
    "CONTACT_FIELDS",
    "CONTACT_RE",
    "PAYMENT_FRAME_HOSTS",
    "VAULT_CONTACTS_TOOL",
    "VAULT_LIST_TOOL",
    "VaultAccess",
    "VaultGuard",
    "card_brand",
    "card_digits",
    "card_display",
    "card_field_value",
    "card_secret_values",
    "checkout_field_ok",
    "contact_field_value",
    "contact_summary",
    "describe_payment",
    "has_vault_placeholder",
    "luhn_ok",
    "number_variants",
    "register_vault_tools",
]
