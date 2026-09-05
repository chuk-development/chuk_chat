"""Secrets the model can use but never read (docs/WIRE_CONTRACT.md, "Secrets").

The user owns one set of named secrets (``PEXELS_API_KEY``, ...). The model
can ask for a name with ``request_secrets`` and use the value from inside a
script, because the value is an environment variable of the child process that
``run_command`` / ``python`` start. The model never sees the value:

- the tool results are status maps (``{"NAME": "set" | "missing"}``), never
  values, lengths or prefixes;
- :class:`Scrubber` replaces every value in every text that flows back toward
  the model or the store with ``[REDACTED:<NAME>]`` — raw, base64, base64url
  and URL-encoded. It is installed at ONE seam, the registry's dispatch
  result (:attr:`~cowork_agent.registry.ToolRegistry.result_filter`), so a
  tool result, a read file, a subagent's output and an error text all pass
  through the same filter. The executor installs the same scrubber on its
  frame sealer, so the app sees masks too.

This module knows nothing about frames or storage. :class:`SecretsAccess` is
the seam: the executor implements it with its vault and its round-trip to the
app; tests implement it with a dict.
"""

from __future__ import annotations

import base64
import re
import threading
from collections.abc import Callable, Iterable, Mapping
from typing import Any, Protocol, runtime_checkable
from urllib.parse import quote

from .registry import ToolRegistry

#: Tool names, kept here so the executor and the prompt agree on one string.
REQUEST_SECRETS_TOOL = "request_secrets"
LIST_SECRETS_TOOL = "list_secrets"

#: Status words the model gets. Nothing else is ever returned about a secret.
STATUS_SET = "set"
STATUS_MISSING = "missing"

#: A value shorter than this is not masked: a three-letter value would mask
#: every "abc" in every output and make the transcript unreadable, while it is
#: no secret worth the name. Matches the contract.
REDACT_MIN_LEN = 8

#: Environment variable name shape. Also what the vault accepts.
NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")

#: How many names one request may carry. A model that asks for fifty keys at
#: once is not asking, it is enumerating.
MAX_NAMES_PER_REQUEST = 16

#: The purpose text is shown to the user in the dialog; bounded so a runaway
#: model cannot push a novel into it.
MAX_PURPOSE_CHARS = 300


def valid_name(name: object) -> bool:
    """True when ``name`` can be an environment variable name."""
    return isinstance(name, str) and 0 < len(name) <= 128 and bool(NAME_RE.match(name))


@runtime_checkable
class SecretsAccess(Protocol):
    """What the tools and the scrubber need from whoever holds the secrets."""

    def names(self) -> list[str]:
        """The names the user has set, sorted."""
        ...

    def env(self) -> dict[str, str]:
        """Name -> value, for the child process env. Never shown to the model."""
        ...

    def request(self, names: list[str], purpose: str) -> dict[str, str]:
        """Ask the user for ``names``; block until answered, cancelled or
        timed out. Returns the status map for exactly these names."""
        ...


# -- the scrubber --------------------------------------------------------------


def _variants(value: str) -> list[str]:
    """Every rendering of ``value`` the scrubber masks. The raw value first;
    the encoded forms only when they differ from it and are long enough to
    be unambiguous."""
    out = [value]
    raw = value.encode("utf-8")
    for candidate in (
        base64.b64encode(raw).decode("ascii"),
        base64.b64encode(raw).decode("ascii").rstrip("="),
        base64.urlsafe_b64encode(raw).decode("ascii"),
        base64.urlsafe_b64encode(raw).decode("ascii").rstrip("="),
        quote(value, safe=""),
    ):
        if candidate != value and len(candidate) >= REDACT_MIN_LEN and candidate not in out:
            out.append(candidate)
    return out


class Scrubber:
    """Masks secret values in text and in nested tool results.

    Built over a ``values`` callable so it follows the live set: a secret the
    user adds mid-run (through ``request_secrets``) is masked from the next
    tool result on. The compiled pattern is cached per value set.
    """

    def __init__(self, values: Callable[[], Mapping[str, str]]) -> None:
        self._values = values
        self._lock = threading.Lock()
        self._cache_key: tuple[tuple[str, str], ...] | None = None
        self._pattern: re.Pattern[str] | None = None
        self._by_variant: dict[str, str] = {}

    @staticmethod
    def mask(name: str) -> str:
        return f"[REDACTED:{name}]"

    def _compiled(self) -> re.Pattern[str] | None:
        try:
            current = self._values() or {}
        except Exception:  # noqa: BLE001 — a broken provider masks nothing, never raises
            current = {}
        items = tuple(
            sorted(
                (str(name), str(value))
                for name, value in current.items()
                if isinstance(value, str) and len(value) >= REDACT_MIN_LEN
            )
        )
        with self._lock:
            if items == self._cache_key:
                return self._pattern
            by_variant: dict[str, str] = {}
            for name, value in items:
                for variant in _variants(value):
                    # A variant two secrets share masks as the first name; the
                    # value is hidden either way.
                    by_variant.setdefault(variant, name)
            self._cache_key = items
            self._by_variant = by_variant
            if not by_variant:
                self._pattern = None
                return None
            # Longest first, so a value that contains another value is
            # replaced whole and not as a mask with a tail.
            alternatives = sorted(by_variant, key=len, reverse=True)
            self._pattern = re.compile("|".join(re.escape(v) for v in alternatives))
            return self._pattern

    def scrub_text(self, text: str) -> str:
        pattern = self._compiled()
        if pattern is None or not text:
            return text
        by_variant = self._by_variant
        return pattern.sub(lambda m: self.mask(by_variant[m.group(0)]), text)

    def scrub_obj(self, obj: Any) -> Any:
        """Recursively mask every string in a dict / list / tuple. Other
        types pass through untouched. Keys are not scrubbed (a key is a field
        name, never a value)."""
        if isinstance(obj, str):
            return self.scrub_text(obj)
        if isinstance(obj, dict):
            return {k: self.scrub_obj(v) for k, v in obj.items()}
        if isinstance(obj, list):
            return [self.scrub_obj(v) for v in obj]
        if isinstance(obj, tuple):
            return tuple(self.scrub_obj(v) for v in obj)
        return obj

    @property
    def active(self) -> bool:
        """True when at least one value is long enough to be masked."""
        return self._compiled() is not None


# -- the tools -----------------------------------------------------------------

REQUEST_SECRETS_SCHEMA = {
    "type": "object",
    "description": (
        "Ask the user for one or more secrets (API keys, tokens) by NAME. The "
        "user types the values into a dialog; you never see them. After this "
        "call, a name that is 'set' is available as an environment variable of "
        "that name inside `run_command` and `python`. Use it as os.environ['NAME'] "
        "or $NAME. Never print a value: it is masked on the way back."
    ),
    "properties": {
        "names": {
            "type": "array",
            "items": {"type": "string"},
            "description": (
                "Environment-variable style names, e.g. [\"PEXELS_API_KEY\"]."
            ),
        },
        "purpose": {
            "type": "string",
            "description": "One line for the user: what the keys are needed for.",
        },
    },
    "required": ["names", "purpose"],
}

LIST_SECRETS_SCHEMA = {
    "type": "object",
    "description": (
        "List the names of the secrets the user has already set. Returns "
        "names and the status 'set' only, never values."
    ),
    "properties": {},
    "required": [],
}


def status_map(names: Iterable[str], present: Iterable[str]) -> dict[str, str]:
    """``{name: "set" | "missing"}`` for ``names``. The only shape the model
    ever gets about a secret."""
    have = set(present)
    return {name: (STATUS_SET if name in have else STATUS_MISSING) for name in names}


def make_request_secrets_handler(access: SecretsAccess):
    def request_secrets(names: list, purpose: str = "") -> dict:
        if isinstance(names, str):
            names = [names]
        if not isinstance(names, list):
            return {"error": "names must be a list of environment variable names"}
        cleaned: list[str] = []
        for name in names:
            if not valid_name(name):
                return {
                    "error": (
                        f"invalid secret name {str(name)[:40]!r}: use letters, "
                        "digits and underscores, e.g. PEXELS_API_KEY"
                    )
                }
            if name not in cleaned:
                cleaned.append(name)
        if not cleaned:
            return {"error": "names is empty"}
        if len(cleaned) > MAX_NAMES_PER_REQUEST:
            return {"error": f"at most {MAX_NAMES_PER_REQUEST} names per request"}
        text = " ".join(str(purpose or "").split())[:MAX_PURPOSE_CHARS]
        result = access.request(cleaned, text)
        # Defensive: whatever the access returned, the model gets a status map
        # over exactly the names it asked for and nothing else.
        have = [n for n, s in (result or {}).items() if s == STATUS_SET]
        return status_map(cleaned, have)

    return request_secrets


def make_list_secrets_handler(access: SecretsAccess):
    def list_secrets() -> dict:
        names = sorted(access.names())
        return {"secrets": status_map(names, names), "count": len(names)}

    return list_secrets


def register_secrets_tools(registry: ToolRegistry, access: SecretsAccess | None) -> None:
    """Register ``request_secrets`` and ``list_secrets``, and install the
    scrubber on the registry's dispatch result. With no access, nothing is
    registered and the prompt does not mention secrets."""
    if access is None:
        return
    registry.register(
        REQUEST_SECRETS_TOOL, REQUEST_SECRETS_SCHEMA, make_request_secrets_handler(access)
    )
    registry.register(LIST_SECRETS_TOOL, LIST_SECRETS_SCHEMA, make_list_secrets_handler(access))
    registry.result_filter = Scrubber(access.env).scrub_obj


class DictSecrets:
    """A :class:`SecretsAccess` over a plain dict. For tests and for a host
    that has no app to ask: ``request`` answers from what is there."""

    def __init__(self, values: Mapping[str, str] | None = None) -> None:
        self._values: dict[str, str] = {
            k: v for k, v in (values or {}).items() if valid_name(k) and v
        }
        self.requests: list[tuple[list[str], str]] = []

    def names(self) -> list[str]:
        return sorted(self._values)

    def env(self) -> dict[str, str]:
        return dict(self._values)

    def set(self, name: str, value: str) -> None:
        if valid_name(name) and value:
            self._values[name] = value

    def request(self, names: list[str], purpose: str) -> dict[str, str]:
        self.requests.append((list(names), purpose))
        return status_map(names, self._values)
