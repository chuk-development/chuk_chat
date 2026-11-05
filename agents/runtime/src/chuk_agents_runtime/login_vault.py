"""Login vault for the browser (Hermes H32; docs/WIRE_CONTRACT.md, "Login vault").

The user saves a login (username, password, optional TOTP key) for ONE exact
origin (``https://github.com``). The model never sees the password. It writes
a placeholder into a browser tool call:

- ``{{login:https://github.com:username}}``
- ``{{login:https://github.com:password}}``
- ``{{login:https://github.com:totp}}`` (the current RFC 6238 code)
- ``{{login:https://github.com#work:password}}`` picks one of several logins
  of the origin by label, id or username.

The placeholders are resolved at ONE seam: :attr:`MCPManager.call_guard`
(:mod:`chuk_agents_runtime.mcp_client`), just before the call reaches the
browser server. The guard here:

1. allows placeholders only in ``browser_type.text`` and in
   ``browser_fill_form.fields[].value``. A placeholder anywhere else in an
   MCP call (``browser_navigate``, ``browser_evaluate``, another server) refuses
   the call. Native tools (``run_command``, ``python``, files) never reach this
   code, so a placeholder there stays plain text;
2. reads the current tab URL fresh (``browser_tabs list``) and resolves only
   when its origin equals the login's origin exactly (scheme, host, port; no
   subdomain match; ``https`` only, ``http`` only for localhost);
3. probes every target field (``browser_evaluate`` on its ``ref``): its
   document's origin must equal the login's origin too (a cross-origin
   iframe on the right page is refused), and a password goes only into an
   ``<input type="password">``;
4. calls the browser with a resolved COPY of the arguments (the model's own
   arguments, which the transcript and the tool events store, keep the
   placeholder text);
5. reads the page URL again after the call; a page that left the origin
   during the fill stops the fill with an error;
6. masks every resolved password, TOTP code and username in the result (also
   their JSON / JS escaped forms), and writes one audit line (never a value);
7. after a fill, refuses ``browser_evaluate`` / ``browser_run_code`` on that
   origin for the rest of the session: such a script could read the field.

This module knows nothing about storage or frames. :class:`LoginVaultAccess`
is the seam; the executor implements it with its secrets vault.
"""

from __future__ import annotations

import base64
import copy
import hashlib
import hmac
import re
import json
import struct
import threading
import time
from collections.abc import Callable, Mapping
from typing import Any, Protocol, runtime_checkable
from urllib.parse import parse_qs, unquote, urlsplit

from .registry import ToolRegistry
from .secrets import _variants
from .takeover import current_tab_url

LOGIN_VAULT_LIST_TOOL = "login_vault_list"

FIELD_USERNAME = "username"
FIELD_PASSWORD = "password"
FIELD_TOTP = "totp"
FIELDS = (FIELD_USERNAME, FIELD_PASSWORD, FIELD_TOTP)

#: Audit outcomes.
OUTCOME_FILLED = "filled"
OUTCOME_REFUSED_ORIGIN = "refused_origin"
OUTCOME_UNKNOWN_ENTRY = "unknown_entry"
OUTCOME_AMBIGUOUS = "ambiguous_entry"
OUTCOME_REFUSED_TOOL = "refused_tool"
OUTCOME_NO_PAGE = "no_page"
OUTCOME_REFUSED_FRAME = "refused_frame"
OUTCOME_REFUSED_FIELD = "refused_field"
OUTCOME_NAVIGATED = "navigated_during_fill"
OUTCOME_REFUSED_SCRIPT = "refused_script"

#: The browser tools and the argument slots where a placeholder is resolved.
TYPE_TOOL = "browser_type"
FILL_FORM_TOOL = "browser_fill_form"
TAB_TOOL = "browser_tabs"
EVALUATE_TOOL = "browser_evaluate"
#: Tools that run page script the model wrote. After a fill they could read
#: the password straight out of the field, so on an origin the vault filled
#: they are refused for the rest of the session.
SCRIPT_TOOLS = frozenset({EVALUATE_TOOL, "browser_run_code", "browser_run_code_unsafe"})

#: Run on the target element (``browser_evaluate`` with its ``ref``): the
#: origin of the document the element lives in (an iframe has its own), and
#: what kind of field it is. ``document.location`` is unforgeable, so a
#: cross-origin frame cannot claim the top page's origin.
_PROBE_FUNCTION = (
    "(el) => ({origin: el.ownerDocument.location.origin, "
    "tag: String(el.tagName || '').toLowerCase(), "
    "type: String(el.getAttribute('type') || el.type || '').toLowerCase()})"
)

#: Hosts where ``http`` is accepted (local test pages). Everything else is
#: ``https`` only: a password must not travel in clear text.
LOCAL_HOSTS = frozenset({"localhost", "127.0.0.1", "::1"})

PLACEHOLDER_RE = re.compile(
    r"\{\{login:(?P<origin>[A-Za-z][A-Za-z0-9+.\-]*://[^\s{}#]+?)"
    r"(?:#(?P<selector>[^{}]+?))?:(?P<field>username|password|totp)\}\}"
)
#: Anything that looks like a login placeholder, also a malformed one. Used
#: to refuse a call that carries one where none may be.
_LOOSE_RE = re.compile(r"\{\{\s*login:", re.IGNORECASE)


# -- origins ------------------------------------------------------------------


def normalize_origin(url: Any) -> str | None:
    """``scheme://host[:port]`` in lower case, the default port dropped.
    ``None`` for anything that is not an http(s) URL with a host."""
    if not isinstance(url, str) or not url.strip():
        return None
    try:
        parts = urlsplit(url.strip())
        scheme = (parts.scheme or "").lower()
        host = (parts.hostname or "").lower()
        port = parts.port
    except ValueError:
        return None
    if scheme not in ("http", "https") or not host:
        return None
    if parts.username is not None or parts.password is not None:
        return None
    if (scheme, port) in (("https", 443), ("http", 80)):
        port = None
    shown = f"[{host}]" if ":" in host else host
    return f"{scheme}://{shown}" + (f":{port}" if port is not None else "")


def origin_allowed(origin: str | None) -> bool:
    """True for an ``https`` origin, or an ``http`` origin on localhost."""
    if not origin:
        return False
    try:
        parts = urlsplit(origin)
    except ValueError:
        return False
    if parts.scheme == "https":
        return True
    return parts.scheme == "http" and (parts.hostname or "") in LOCAL_HOSTS


def clean_origin(value: Any) -> str | None:
    """The stored form of an origin the app sent, or ``None`` when the vault
    must refuse it (no URL, a path-only value, plain http on a public host)."""
    origin = normalize_origin(value)
    return origin if origin_allowed(origin) else None


# -- TOTP (RFC 6238 over RFC 4226) -----------------------------------------------


def parse_totp_secret(value: Any) -> dict | None:
    """``{"key": bytes, "digits": int, "period": int, "algorithm": str}`` from a
    base32 key (spaces and lower case allowed) or an ``otpauth://totp/...`` URI.
    ``None`` when it does not decode."""
    if not isinstance(value, str) or not value.strip():
        return None
    text = value.strip()
    digits, period, algorithm = 6, 30, "sha1"
    if text.lower().startswith("otpauth://"):
        try:
            parts = urlsplit(text)
        except ValueError:
            return None
        if (parts.hostname or "").lower() != "totp":
            return None
        query = {k.lower(): v[-1] for k, v in parse_qs(parts.query).items() if v}
        text = unquote(query.get("secret", ""))
        try:
            digits = int(query.get("digits", 6))
            period = int(query.get("period", 30))
        except ValueError:
            return None
        algorithm = query.get("algorithm", "sha1").lower()
    if algorithm not in ("sha1", "sha256", "sha512") or not 6 <= digits <= 10 or period <= 0:
        return None
    key_text = re.sub(r"[\s-]", "", text).upper()
    if not key_text or not re.fullmatch(r"[A-Z2-7]+=*", key_text):
        return None
    key_text = key_text.rstrip("=")
    key_text += "=" * (-len(key_text) % 8)
    try:
        key = base64.b32decode(key_text)
    except (ValueError, base64.binascii.Error):
        return None
    if not key:
        return None
    return {"key": key, "digits": digits, "period": period, "algorithm": algorithm}


def totp_code(secret: str, *, at: float | None = None) -> str | None:
    """The current TOTP code for ``secret`` (RFC 6238), or ``None`` when the
    secret does not decode."""
    params = parse_totp_secret(secret)
    if params is None:
        return None
    now = time.time() if at is None else at
    counter = int(now // params["period"])
    digest = hmac.new(
        params["key"], struct.pack(">Q", counter), getattr(hashlib, params["algorithm"])
    ).digest()
    offset = digest[-1] & 0x0F
    number = struct.unpack(">I", digest[offset : offset + 4])[0] & 0x7FFFFFFF
    return str(number % (10 ** params["digits"])).zfill(params["digits"])


# -- the access seam --------------------------------------------------------------


@runtime_checkable
class LoginVaultAccess(Protocol):
    """What the guard and the tool need from whoever holds the logins."""

    def login_entries(self) -> list[dict]:
        """Public fields only: ``id, origin, username, label, has_totp,
        created_at, last_used_at``. Never a password or a TOTP key."""
        ...

    def login_lookup(self, origin: str) -> list[dict]:
        """Full entries of ``origin`` (with ``password`` / ``totp_secret``)."""
        ...

    def login_used(self, entry_id: str) -> None:
        """Record ``last_used_at`` for ``entry_id``."""
        ...

    def login_audit(self, record: dict) -> None:
        """Append one audit record. The record holds no value."""
        ...


# -- placeholders -------------------------------------------------------------------


def has_placeholder(obj: Any) -> bool:
    """True when any string in ``obj`` (nested) looks like a login placeholder."""
    if isinstance(obj, str):
        return bool(_LOOSE_RE.search(obj))
    if isinstance(obj, Mapping):
        return any(has_placeholder(v) for v in obj.values())
    if isinstance(obj, (list, tuple)):
        return any(has_placeholder(v) for v in obj)
    return False


def _slots(tool: str, args: dict) -> list[tuple[Any, Any]]:
    """``(container, key)`` of every slot where a placeholder may be resolved."""
    if tool == TYPE_TOOL:
        return [(args, "text")] if isinstance(args.get("text"), str) else []
    if tool == FILL_FORM_TOOL and isinstance(args.get("fields"), list):
        return [
            (f, "value")
            for f in args["fields"]
            if isinstance(f, dict) and isinstance(f.get("value"), str)
        ]
    return []


def _without_slots(tool: str, args: dict) -> dict:
    """``args`` with the allowed slots blanked: what is left must hold no
    placeholder."""
    rest = copy.deepcopy(args)
    for container, key in _slots(tool, rest):
        container[key] = ""
    return rest


class Refusal(Exception):
    """The call is refused; ``str(self)`` is the tool error the model reads."""

    def __init__(self, message: str, outcome: str, origin: str = "", entry_id: str = "") -> None:
        super().__init__(message)
        self.outcome = outcome
        self.origin = origin
        self.entry_id = entry_id


def _pick(entries: list[dict], origin: str, selector: str | None) -> dict:
    if selector:
        wanted = selector.strip().lower()
        found = [
            e
            for e in entries
            if wanted
            in (
                str(e.get("id") or "").lower(),
                str(e.get("label") or "").lower(),
                str(e.get("username") or "").lower(),
            )
        ]
    else:
        found = list(entries)
    if not found:
        which = f" '{selector}'" if selector else ""
        raise Refusal(
            f"no saved login{which} for {origin}. Call {LOGIN_VAULT_LIST_TOOL} to see "
            "the saved logins, or use request_takeover so the user signs in.",
            OUTCOME_UNKNOWN_ENTRY,
            origin,
        )
    if len(found) > 1:
        labels = ", ".join(str(e.get("label") or e.get("id")) for e in found)
        raise Refusal(
            f"there are {len(found)} saved logins for {origin} ({labels}). Choose one: "
            f"{{{{login:{origin}#<label>:password}}}}.",
            OUTCOME_AMBIGUOUS,
            origin,
        )
    return found[0]


class LoginGuard:
    """The :attr:`MCPManager.call_guard` of one session.

    Called as ``guard(manager, server, tool, arguments, invoke)``; ``invoke``
    runs the real call with the arguments it gets. Returns the tool result.
    """

    def __init__(
        self,
        access: LoginVaultAccess,
        *,
        session_key: str = "",
        clock: Callable[[], float] = time.time,
    ) -> None:
        self._access = access
        self._session_key = session_key
        self._clock = clock
        #: Origins this session filled a login on (see :data:`SCRIPT_TOOLS`).
        self._filled_origins: set[str] = set()
        #: Set while the guard makes its own calls (tab list, probe), which
        #: pass straight through.
        self._internal = threading.local()

    # The seam ---------------------------------------------------------------

    def __call__(
        self,
        manager: Any,
        server: str,
        tool: str,
        arguments: dict | None,
        invoke: Callable[[dict], dict],
    ) -> dict:
        args = arguments if isinstance(arguments, dict) else {}
        if getattr(self._internal, "depth", 0):
            return invoke(args)
        if tool in SCRIPT_TOOLS and self._filled_origins and not has_placeholder(args):
            origin = normalize_origin(self._page_url(manager, server))
            if origin is None or origin in self._filled_origins:
                shown = origin or "an unknown page"
                self._audit(tool, origin or "", "", [], OUTCOME_REFUSED_SCRIPT)
                return {
                    "ok": False,
                    "server": server,
                    "tool": tool,
                    "error": (
                        f"{tool} is blocked on {shown} after a saved login was filled there: "
                        "a page script could read the password. Use browser_snapshot to "
                        "read the page instead."
                    ),
                }
        if not has_placeholder(args):
            return invoke(args)
        try:
            return self._fill(manager, server, tool, args, invoke)
        except Refusal as refusal:
            self._audit(tool, refusal.origin, refusal.entry_id, [], refusal.outcome)
            return {"ok": False, "server": server, "tool": tool, "error": str(refusal)}

    # Internals ----------------------------------------------------------------

    def _fill(
        self, manager: Any, server: str, tool: str, args: dict, invoke: Callable[[dict], dict]
    ) -> dict:
        if tool not in (TYPE_TOOL, FILL_FORM_TOOL) or has_placeholder(_without_slots(tool, args)):
            raise Refusal(
                "login placeholders work only in the 'text' of browser_type and the "
                "'value' of browser_fill_form fields. This call was not sent.",
                OUTCOME_REFUSED_TOOL,
            )
        resolved = copy.deepcopy(args)
        slots = _slots(tool, resolved)
        # Parse every placeholder first: a malformed one refuses the call.
        wanted: list[tuple[str, str | None, str]] = []
        for container, key in slots:
            text = container[key]
            matches = list(PLACEHOLDER_RE.finditer(text))
            if _LOOSE_RE.search(PLACEHOLDER_RE.sub("", text)):
                raise Refusal(
                    "malformed login placeholder. Use {{login:https://site.example:password}} "
                    "(fields: username, password, totp).",
                    OUTCOME_UNKNOWN_ENTRY,
                )
            for m in matches:
                origin = normalize_origin(m.group("origin"))
                if origin is None or not origin_allowed(origin):
                    raise Refusal(
                        f"'{m.group('origin')}' is not a login origin: use https://host[:port].",
                        OUTCOME_UNKNOWN_ENTRY,
                    )
                wanted.append((origin, m.group("selector"), m.group("field")))
        if not wanted:
            raise Refusal(
                "malformed login placeholder. Use {{login:https://site.example:password}}.",
                OUTCOME_UNKNOWN_ENTRY,
            )
        # Read the page origin fresh, right before the call.
        page_url = self._page_url(manager, server)
        page_origin = normalize_origin(page_url) if page_url else None
        first_origin = wanted[0][0]
        if page_origin is None:
            raise Refusal(
                f"the login for {first_origin} can only be filled on {first_origin}; the "
                "page URL could not be read. Open the login page first.",
                OUTCOME_NO_PAGE,
                first_origin,
            )
        for origin, _sel, _field in wanted:
            if origin != page_origin:
                raise Refusal(
                    f"the login for {origin} can only be filled on {origin}; the page is "
                    f"on {page_origin}",
                    OUTCOME_REFUSED_ORIGIN,
                    origin,
                )
        # Probe every target field: same origin as the login (no cross-origin
        # iframe), and a password only into a password input.
        for container, key in slots:
            fields = {m.group("field") for m in PLACEHOLDER_RE.finditer(container[key])}
            if not fields:
                continue
            ref = container.get("ref") if isinstance(container, dict) else None
            probe = self._probe(manager, server, ref, container.get("element"))
            if probe is None:
                raise Refusal(
                    "the target field could not be checked (no element ref, or the page "
                    "did not answer). Take a browser_snapshot and pass the field's ref.",
                    OUTCOME_REFUSED_FRAME,
                    first_origin,
                )
            frame_origin = normalize_origin(probe.get("origin"))
            if frame_origin != page_origin:
                raise Refusal(
                    f"the login for {page_origin} can only be filled into a field of "
                    f"{page_origin}; this field is in a frame of "
                    f"{frame_origin or probe.get('origin') or 'an unknown origin'}.",
                    OUTCOME_REFUSED_FRAME,
                    first_origin,
                )
            if FIELD_PASSWORD in fields and not (
                probe.get("tag") == "input" and probe.get("type") == "password"
            ):
                raise Refusal(
                    "a saved password goes only into a password field "
                    "(<input type=\"password\">). This field is not one.",
                    OUTCOME_REFUSED_FIELD,
                    first_origin,
                )
        # Resolve.
        values: dict[str, str] = {}
        used: dict[str, list[str]] = {}
        cache: dict[tuple[str, str | None], dict] = {}

        def value_for(origin: str, selector: str | None, field: str) -> str:
            key = (origin, selector)
            if key not in cache:
                cache[key] = _pick(self._access.login_lookup(origin) or [], origin, selector)
            entry = cache[key]
            entry_id = str(entry.get("id") or "")
            if field == FIELD_TOTP:
                code = totp_code(str(entry.get("totp_secret") or ""), at=self._clock())
                if code is None:
                    raise Refusal(
                        f"the saved login for {origin} has no TOTP key; use "
                        "request_takeover for the code.",
                        OUTCOME_UNKNOWN_ENTRY,
                        origin,
                        entry_id,
                    )
                value = code
            else:
                value = str(entry.get(field) or "")
                if not value:
                    raise Refusal(
                        f"the saved login for {origin} has no {field}.",
                        OUTCOME_UNKNOWN_ENTRY,
                        origin,
                        entry_id,
                    )
            kinds = used.setdefault(entry_id, [])
            if field not in kinds:
                kinds.append(field)
            values[f"login:{origin}:{field}"] = value
            return value

        for container, key in slots:
            container[key] = PLACEHOLDER_RE.sub(
                lambda m: value_for(
                    normalize_origin(m.group("origin")) or "", m.group("selector"), m.group("field")
                ),
                container[key],
            )
        result = invoke(resolved)
        result = mask_values(result, values)
        self._filled_origins.add(page_origin)
        after_url = self._page_url(manager, server)
        after_origin = normalize_origin(after_url) if after_url else None
        if after_origin != page_origin:
            for entry_id, kinds in used.items():
                self._audit(tool, page_origin, entry_id, kinds, OUTCOME_NAVIGATED)
            return {
                "ok": False,
                "server": server,
                "tool": tool,
                "error": (
                    f"the page left {page_origin} during the login fill (now "
                    f"{after_origin or 'unknown'}). The fill is stopped; check the page "
                    "with browser_snapshot before you go on."
                ),
            }
        for entry_id, kinds in used.items():
            try:
                self._access.login_used(entry_id)
            except Exception:  # noqa: BLE001 — bookkeeping never fails the fill
                pass
            self._audit(
                tool,
                page_origin,
                entry_id,
                kinds,
                OUTCOME_FILLED if not (isinstance(result, dict) and result.get("ok") is False) else "fill_failed",
            )
        if isinstance(result, dict) and result.get("ok") is not False:
            result = {**result, "login_vault": {"origin": page_origin, "filled_fields": len(values)}}
        return result

    def _own_call(self, manager: Any, server: str, tool: str, args: dict) -> Any:
        self._internal.depth = getattr(self._internal, "depth", 0) + 1
        try:
            return manager.call(server, tool, args)
        finally:
            self._internal.depth -= 1

    def _probe(self, manager: Any, server: str, ref: Any, element: Any) -> dict | None:
        """``{origin, tag, type}`` of the element ``ref`` points at, read in
        the element's own frame. ``None`` when it cannot be read."""
        if not isinstance(ref, str) or not ref.strip():
            return None
        args = {
            "function": _PROBE_FUNCTION,
            "ref": ref,
            "element": element if isinstance(element, str) and element else "login field",
        }
        try:
            result = self._own_call(manager, server, EVALUATE_TOOL, args)
        except Exception:  # noqa: BLE001 — unknown field means no fill
            return None
        if not isinstance(result, dict) or not result.get("ok"):
            return None
        return _probe_result(result.get("content"))

    def _page_url(self, manager: Any, server: str) -> str | None:
        try:
            result = self._own_call(manager, server, TAB_TOOL, {"action": "list"})
        except Exception:  # noqa: BLE001 — no page URL means no fill
            return None
        if not isinstance(result, dict) or not result.get("ok"):
            return None
        return current_tab_url(result.get("content"))

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
        try:
            self._access.login_audit(record)
        except Exception:  # noqa: BLE001 — the audit never fails the call
            pass


def _probe_result(content: Any) -> dict | None:
    """The probe's object from a ``browser_evaluate`` answer. Playwright MCP
    puts the JSON value after a ``### Result`` heading; a bare JSON object (a
    test double) works too."""
    if isinstance(content, dict):
        data = content
    elif isinstance(content, str):
        text = content
        if "### Result" in text:
            text = text.split("### Result", 1)[1]
        start = text.find("{")
        if start < 0:
            return None
        try:
            data, _end = json.JSONDecoder().raw_decode(text[start:])
        except ValueError:
            return None
    else:
        return None
    if not isinstance(data, dict) or not isinstance(data.get("origin"), str):
        return None
    return {
        "origin": data["origin"],
        "tag": str(data.get("tag") or "").lower(),
        "type": str(data.get("type") or "").lower(),
    }


def mask_values(obj: Any, values: Mapping[str, str]) -> Any:
    """Replace every resolved value in ``obj`` (nested) with ``[REDACTED:<name>]``.
    No length floor: a short password or a 6-digit code is masked too, also
    in its base64, URL, JSON and JS escaped forms. Longest value first."""
    pairs = sorted(
        {
            (variant, k)
            for k, v in values.items()
            if v
            for variant in _variants(v, min_len=1)
        },
        key=lambda p: len(p[0]),
        reverse=True,
    )
    if not pairs:
        return obj

    def one(text: str) -> str:
        for value, name in pairs:
            text = text.replace(value, f"[REDACTED:{name}]")
        return text

    def walk(o: Any) -> Any:
        if isinstance(o, str):
            return one(o)
        if isinstance(o, dict):
            return {k: walk(v) for k, v in o.items()}
        if isinstance(o, list):
            return [walk(v) for v in o]
        if isinstance(o, tuple):
            return tuple(walk(v) for v in o)
        return o

    return walk(obj)


# -- the model tool -------------------------------------------------------------------

LOGIN_VAULT_LIST_SCHEMA = {
    "type": "object",
    "description": (
        "List the browser logins the user saved (origin, username, label; never a "
        "password). To sign in on that exact origin, write "
        "{{login:<origin>:username}}, {{login:<origin>:password}} or "
        "{{login:<origin>:totp}} as browser_type text or browser_fill_form value; "
        "the host fills the value. Add #<label> after the origin to pick one of "
        "several logins."
    ),
    "properties": {},
    "required": [],
}


def make_login_vault_list_handler(access: LoginVaultAccess):
    def login_vault_list() -> dict:
        rows = []
        for entry in access.login_entries() or []:
            if not isinstance(entry, Mapping):
                continue
            rows.append(
                {
                    "origin": str(entry.get("origin") or ""),
                    "username": str(entry.get("username") or ""),
                    "label": str(entry.get("label") or ""),
                    "id": str(entry.get("id") or ""),
                    "has_totp": bool(entry.get("has_totp")),
                }
            )
        return {"logins": rows, "count": len(rows)}

    return login_vault_list


def register_login_vault_tool(registry: ToolRegistry, access: Any) -> None:
    """Register ``login_vault_list`` when ``access`` can list logins."""
    if access is None or not callable(getattr(access, "login_entries", None)):
        return
    registry.register(
        LOGIN_VAULT_LIST_TOOL,
        LOGIN_VAULT_LIST_SCHEMA,
        make_login_vault_list_handler(access),
        deferrable=True,
    )


__all__ = [
    "FIELDS",
    "LOGIN_VAULT_LIST_TOOL",
    "LoginGuard",
    "LoginVaultAccess",
    "PLACEHOLDER_RE",
    "Refusal",
    "clean_origin",
    "has_placeholder",
    "mask_values",
    "normalize_origin",
    "origin_allowed",
    "parse_totp_secret",
    "register_login_vault_tool",
    "totp_code",
]
