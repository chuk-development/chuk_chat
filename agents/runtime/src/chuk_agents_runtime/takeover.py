"""Browser takeover: ``request_takeover`` (docs/WIRE_CONTRACT.md, "Browser takeover").

The agent's sandbox browser reaches a step only the user can do: a login, a
2FA code, a CAPTCHA. Without this tool the model can only write "please log
in" into its answer, and the run ends. With it, the model calls
``request_takeover``, the run WAITS, the app shows one card "<Coworker> needs
you in the browser" with a button that opens the live view, the user does the
step, and the run goes on.

This module is the agent-side half: the schema, the argument checks, the
registration, and two pure helpers the executor uses to watch the page while
the run waits (:func:`current_tab_url`, :class:`TakeoverWatch`). The wait
itself, the ``approval_request`` frame and the push are the executor's.

The two halves meet at :class:`TakeoverBackend`. The executor binds one to
the task's stream and session and gives it to ``build_runtime``. Its
``available`` is the tool's ``check_fn``: the tool is offered only while the
agent's own sandbox browser is the target, never the user's own browser over
the extension (the user is already at that one).
"""

from __future__ import annotations

import re
from typing import Any, Protocol
from urllib.parse import urlsplit

from .registry import ToolRegistry

TAKEOVER_TOOL = "request_takeover"

KIND_LOGIN = "login"
KIND_TWO_FACTOR = "two_factor"
KIND_CAPTCHA = "captcha"
KIND_OTHER = "other"
TAKEOVER_KINDS = (KIND_LOGIN, KIND_TWO_FACTOR, KIND_CAPTCHA, KIND_OTHER)

STATUS_DONE = "done"
STATUS_SKIPPED = "skipped"
STATUS_TIMEOUT = "timeout"
STATUS_STOPPED = "stopped"
TAKEOVER_STATUSES = (STATUS_DONE, STATUS_SKIPPED, STATUS_TIMEOUT, STATUS_STOPPED)

#: The card shows one short line; a longer text is cut.
MAX_REASON_CHARS = 200
#: A DNS name is at most 253 characters.
MAX_SITE_CHARS = 253


class TakeoverBackend(Protocol):
    """What the tool needs from the executor, bound to ONE run.

    ``available`` is True while the agent's sandbox browser is the target.
    ``request`` blocks until the user is done, skips, the wait times out or
    the run stops, and answers ``{"status": <one of TAKEOVER_STATUSES>}``.
    """

    def available(self) -> bool: ...

    def request(self, kind: str, site: str, reason: str) -> dict: ...


REQUEST_TAKEOVER_SCHEMA = {
    "type": "object",
    "description": (
        "Hand the browser to the user for one step that only the user can do: "
        "a login, a 2FA code, a CAPTCHA or a similar check. The user sees a "
        "card in the app, opens the live browser view, does the step and "
        "taps Done. This call waits until then (up to 15 minutes). Call it "
        "when the page asks for a login, a code or a CAPTCHA, instead of "
        "giving up or asking the user in your answer. Never type a password "
        "or a code yourself. Returns {'status': 'done'} when the user "
        "finished: take a fresh browser_snapshot and continue. 'skipped' "
        "means the user does not want to do it: continue without that page "
        "or say what you could not reach. 'timeout' means nobody answered. "
        "'stopped' means the run is ending."
    ),
    "properties": {
        "kind": {
            "type": "string",
            "enum": list(TAKEOVER_KINDS),
            "description": "What the user must do: login, two_factor, captcha or other.",
        },
        "site": {
            "type": "string",
            "description": (
                "The host name the browser is on, for example "
                "'accounts.google.com'. Leave empty to use the current page."
            ),
        },
        "reason": {
            "type": "string",
            "description": (
                "One short line for the card, for example "
                "'GitHub asks for the 2FA code'."
            ),
        },
    },
    "required": ["kind"],
}

#: What the model reads next to each status.
_NOTES = {
    STATUS_DONE: "The user finished the step. Take a fresh browser_snapshot and continue.",
    STATUS_SKIPPED: (
        "The user skipped the step. Do not ask again in this turn. Continue "
        "without that page, or say what you could not reach."
    ),
    STATUS_TIMEOUT: (
        "Nobody answered in time. Say in your answer which step needs the "
        "user, so they can do it later."
    ),
    STATUS_STOPPED: "The run is stopping.",
}


def _error(message: str) -> dict:
    return {"ok": False, "error": message}


def _clip(value: Any, limit: int) -> str:
    if not isinstance(value, str):
        return ""
    text = " ".join(value.split())
    if len(text) > limit:
        text = text[: limit - 1].rstrip() + "…"
    return text


def clean_site(value: Any) -> str:
    """A host name from what the model passed: a bare host or a whole URL."""
    text = _clip(value, 2048)
    if not text:
        return ""
    host = host_of(text if "://" in text else f"https://{text}")
    return host[:MAX_SITE_CHARS]


def make_request_takeover_handler(backend: TakeoverBackend):
    def request_takeover(kind: str = "", site: str = "", reason: str = "") -> Any:
        level = kind.strip().lower() if isinstance(kind, str) else ""
        if level not in TAKEOVER_KINDS:
            return _error("kind must be one of: " + ", ".join(TAKEOVER_KINDS))
        try:
            if not backend.available():
                return _error(
                    "the browser takeover is not available: the agent's own "
                    "browser is not the one in use. Ask the user in your answer."
                )
        except Exception:  # noqa: BLE001 — a probe that raises means "no"
            return _error("the browser takeover is not available right now")
        result = backend.request(level, clean_site(site), _clip(reason, MAX_REASON_CHARS))
        status = result.get("status") if isinstance(result, dict) else None
        if status not in TAKEOVER_STATUSES:
            message = result.get("error") if isinstance(result, dict) else None
            return _error(str(message or "the takeover could not be started"))
        # Status and a hint only: never a password, never page content.
        return {"status": status, "note": _NOTES[status]}

    return request_takeover


def register_takeover_tool(registry: ToolRegistry, backend: TakeoverBackend | None) -> None:
    """Register ``request_takeover`` against one run-bound backend. ``None``
    registers nothing (no executor, no app to show the card).

    Deferred behind ``search_tools`` (bead chuk_chat-b3g4): a takeover is
    rare. The prompt's research section names the tool, and an unsearched
    call still runs (the loop dispatches it and records the discovery)."""
    if backend is None:
        return
    registry.register(
        TAKEOVER_TOOL,
        REQUEST_TAKEOVER_SCHEMA,
        make_request_takeover_handler(backend),
        check_fn=backend.available,
        deferrable=True,
    )


# -- watching the page while the run waits ----------------------------------------

_URL_RE = re.compile(r"https?://[^\s()<>\[\]\"']+")
_PAGE_URL_RE = re.compile(r"Page URL:\s*(https?://\S+)")
_TAB_LINE_RE = re.compile(r"^\s*-\s*\d+:")


def current_tab_url(text: Any) -> str | None:
    """The current tab's URL from a Playwright MCP ``browser_tabs list``
    answer (``- 0: (current) [Title](https://…)``), or from its ``Page URL:``
    line. ``None`` when the text names no page."""
    if not isinstance(text, str) or not text:
        return None
    lines = text.splitlines()
    tabs = [line for line in lines if _TAB_LINE_RE.match(line)]
    for line in tabs:
        if "(current)" in line:
            found = _URL_RE.findall(line)
            if found:
                return found[-1]
    match = _PAGE_URL_RE.search(text)
    if match:
        return match.group(1).rstrip(").,")
    if len(tabs) == 1:
        found = _URL_RE.findall(tabs[0])
        if found:
            return found[-1]
    return None


def host_of(url: str | None) -> str:
    """The lower-case host name of ``url``, or ``""``."""
    if not url:
        return ""
    try:
        return (urlsplit(url).hostname or "").lower()
    except ValueError:
        return ""


#: Host labels and path words of a sign-in or check page. A URL is matched
#: word by word, so ``myaccount.google.com`` is not ``accounts.google.com``.
_AUTH_HOST_LABELS = frozenset(
    {"accounts", "login", "signin", "auth", "sso", "id", "idp", "identity", "secure"}
)
_AUTH_PATH_RE = re.compile(
    r"(^|[/_.\-?=&])("
    r"log-?in|sign-?in|sign_in|signon|auth|authorize|oauth2?|sso|saml|"
    r"2fa|mfa|two[-_]?factor|totp|otp|verify|verification|challenge|"
    r"captcha|recaptcha|checkpoint|sorry|session|password"
    r")($|[/_.\-?=&])",
    re.IGNORECASE,
)


def looks_like_auth_page(url: str | None) -> bool:
    """True when ``url`` reads as a sign-in, code or check page."""
    if not url:
        return False
    try:
        parts = urlsplit(url)
    except ValueError:
        return False
    labels = (parts.hostname or "").lower().split(".")
    if labels and labels[0] in _AUTH_HOST_LABELS:
        return True
    return bool(_AUTH_PATH_RE.search(f"{parts.path}?{parts.query}"))


class TakeoverWatch:
    """Decides, from the page URL alone, that the user finished the step.

    The page counts as done when its URL has moved away from the URL the
    takeover started on, to a URL that is not a sign-in or check page, and the
    same URL was read twice in a row (a redirect chain is not a result). A
    login that leads to a 2FA page stays open; a modal login that never
    changes the URL is never auto-resolved (the user taps Done)."""

    def __init__(self, start_url: str | None, *, confirmations: int = 2) -> None:
        self.start_url = start_url or None
        self._confirmations = max(1, int(confirmations))
        self._candidate: str | None = None
        self._seen = 0

    def observe(self, url: str | None) -> bool:
        if not url:
            return False
        if self.start_url is None:
            # Nothing to compare with: the first URL read is the start.
            self.start_url = url
            return False
        if url == self.start_url or looks_like_auth_page(url):
            self._candidate, self._seen = None, 0
            return False
        if url != self._candidate:
            self._candidate, self._seen = url, 0
        self._seen += 1
        return self._seen >= self._confirmations


class RecordingTakeoverBackend:
    """An in-memory backend for tests: records the requests, answers a fixed
    status."""

    def __init__(self, status: str = STATUS_DONE, *, available: bool = True) -> None:
        self.status = status
        self.is_available = available
        self.requests: list[dict] = []

    def available(self) -> bool:
        return self.is_available

    def request(self, kind: str, site: str, reason: str) -> dict:
        self.requests.append({"kind": kind, "site": site, "reason": reason})
        return {"status": self.status}


__all__ = [
    "KIND_CAPTCHA",
    "KIND_LOGIN",
    "KIND_OTHER",
    "KIND_TWO_FACTOR",
    "MAX_REASON_CHARS",
    "REQUEST_TAKEOVER_SCHEMA",
    "RecordingTakeoverBackend",
    "STATUS_DONE",
    "STATUS_SKIPPED",
    "STATUS_STOPPED",
    "STATUS_TIMEOUT",
    "TAKEOVER_KINDS",
    "TAKEOVER_STATUSES",
    "TAKEOVER_TOOL",
    "TakeoverBackend",
    "TakeoverWatch",
    "clean_site",
    "current_tab_url",
    "host_of",
    "looks_like_auth_page",
    "make_request_takeover_handler",
    "register_takeover_tool",
]
