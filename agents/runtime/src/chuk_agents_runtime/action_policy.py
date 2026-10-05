"""Per-action approvals: the risky action classes and the per-coworker policy
(docs/WIRE_CONTRACT.md, "Per-action approvals", bead chuk_chat-mxxm).

The owner's rule stays: **everything is allowed by default.** A small set of
actions asks first, and the user decides per coworker how each class behaves:
``ask`` (the card with the options), ``allow`` (no card) or ``deny`` (refused,
no card). A browser class also keeps an allow-list of sites.

A class is decided by **structure**, never by the text of a call: the tool name,
the server that offers it and the annotation that server declared. A class that
cannot be told from the tool call alone is not here (docs/WIRE_CONTRACT.md lists
what was left out and why).

=================== ============================================== =========
class               tools                                          default
=================== ============================================== =========
``publish``         ``herenow_publish``                            ``ask``
``send_external``   ``mail_send``, ``mail_reply``                  ``ask``
``mcp_destructive`` an MCP connector tool its server marks         ``ask``
                    ``destructiveHint: true`` (not read-only)
``browser_act``     a page-changing tool of a browser MCP server   ``allow``
                    (click, type, fill, select, key, drag, upload,
                    dialog, evaluate), per site
=================== ============================================== =========

``browser_act`` starts at ``allow``: an agent that browses would otherwise ask
at the first click on every site, and the owner's rule is that only a clearly
outward or dangerous action asks. The user switches it to ``ask`` per coworker;
then every site the user allows with "always for this site" is remembered.

This module is pure data and logic. It does no I/O and imports nothing from the
loop, so the host (which keeps the policy) and the executor (which asks) use the
same definitions.
"""

from __future__ import annotations

import json
import re
from collections.abc import Callable, Mapping
from dataclasses import dataclass, field
from typing import Any

# -- classes --------------------------------------------------------------------

PUBLISH = "publish"
SEND_EXTERNAL = "send_external"
MCP_DESTRUCTIVE = "mcp_destructive"
BROWSER_ACT = "browser_act"
ACTION_CLASSES: tuple[str, ...] = (PUBLISH, SEND_EXTERNAL, MCP_DESTRUCTIVE, BROWSER_ACT)

#: The classes whose actions happen on a web site: they offer "always for this
#: site" and keep a site allow-list.
SITE_CLASSES = frozenset({BROWSER_ACT})

# -- modes ----------------------------------------------------------------------

MODE_ASK = "ask"
MODE_ALLOW = "allow"
MODE_DENY = "deny"
MODES: tuple[str, ...] = (MODE_ASK, MODE_ALLOW, MODE_DENY)

DEFAULT_MODES: dict[str, str] = {
    PUBLISH: MODE_ASK,
    SEND_EXTERNAL: MODE_ASK,
    MCP_DESTRUCTIVE: MODE_ASK,
    BROWSER_ACT: MODE_ALLOW,
}

# -- decision scopes ------------------------------------------------------------

SCOPE_ONCE = "once"
SCOPE_AGENT = "always_this_agent"
SCOPE_SITE = "always_this_site"
SCOPE_DENY = "deny"
SCOPES: tuple[str, ...] = (SCOPE_ONCE, SCOPE_AGENT, SCOPE_SITE, SCOPE_DENY)

#: The ``action`` of an ``approval_request`` for a class that has no older
#: action name of its own (``publish`` keeps ``herenow_publish``).
ACTION_APPROVAL = "action_approval"

#: Upper bound on the sites one class keeps. A larger list is cut, oldest first.
MAX_SITES = 200
MAX_SITE_LEN = 253

# -- tools ----------------------------------------------------------------------

#: The mail tools that send to an address (the full mail set). The restricted
#: run's ``mail_draft_reply`` only ever writes a draft and is not here.
MAIL_SEND_TOOLS = frozenset({"mail_send", "mail_reply"})

#: The Playwright MCP tools that change a page. Navigation, snapshots, tabs,
#: screenshots and waits only read and are not here.
BROWSER_ACT_TOOLS = frozenset(
    {
        "browser_click",
        "browser_type",
        "browser_fill_form",
        "browser_select_option",
        "browser_press_key",
        "browser_drag",
        "browser_file_upload",
        "browser_handle_dialog",
        "browser_evaluate",
        "browser_run_code",
        "browser_mouse_click_xy",
        "browser_mouse_drag_xy",
    }
)


def is_destructive(annotations: Mapping[str, Any] | None) -> bool:
    """True when an MCP server declared a tool destructive: an explicit
    ``destructiveHint: true`` and no ``readOnlyHint: true``.

    Only the explicit flag counts. The MCP spec reads a missing hint as
    "may be destructive", but that would put almost every connector tool behind
    a card, against the owner's rule. A server that lies the other way loses
    nothing it had before this feature."""
    if not isinstance(annotations, Mapping):
        return False
    return annotations.get("destructiveHint") is True and annotations.get("readOnlyHint") is not True


# -- sites ----------------------------------------------------------------------

_SITE_RE = re.compile(r"^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)*$")


def normalize_site(value: Any) -> str | None:
    """The canonical form of a site: a lower-case host name without ``www.``,
    port or trailing dot. A URL is accepted and reduced to its host. ``None``
    for anything that is not a host name."""
    if not isinstance(value, str):
        return None
    text = value.strip().lower()
    if "://" in text:
        text = text.split("://", 1)[1]
    text = text.split("/", 1)[0].split("?", 1)[0].split("#", 1)[0]
    if "@" in text:
        text = text.rsplit("@", 1)[1]
    if text.startswith("["):
        return None  # an IPv6 literal is not a site the user picks
    text = text.split(":", 1)[0].rstrip(".")
    if text.startswith("www."):
        text = text[4:]
    if not text or len(text) > MAX_SITE_LEN or not _SITE_RE.match(text):
        return None
    return text


def site_matches(site: str, allowed: str) -> bool:
    """``site`` is ``allowed`` or a subdomain of it (``api.github.com`` under
    ``github.com``). Both are normalized forms."""
    return site == allowed or site.endswith("." + allowed)


# -- the policy -----------------------------------------------------------------


class ActionPolicyError(ValueError):
    """A stored entry or a ``set`` the policy refuses. Nothing changes."""


@dataclass(frozen=True)
class ActionPolicy:
    """One coworker's approval policy: the modes the user set (only those;
    every other class follows :data:`DEFAULT_MODES`) and the allowed sites."""

    modes: Mapping[str, str] = field(default_factory=dict)
    sites: Mapping[str, tuple[str, ...]] = field(default_factory=dict)

    def mode(self, action_class: str) -> str:
        return self.modes.get(action_class) or DEFAULT_MODES.get(action_class, MODE_ASK)

    def site_allowed(self, action_class: str, site: str | None) -> bool:
        canon = normalize_site(site) if site else None
        if canon is None:
            return False
        return any(site_matches(canon, allowed) for allowed in self.sites.get(action_class, ()))

    def evaluate(self, action_class: str, site: str | None = None) -> str:
        """``allow`` / ``ask`` / ``deny`` for one action. An allowed site turns
        ``ask`` into ``allow``; it never turns ``deny`` into anything."""
        mode = self.mode(action_class)
        if mode == MODE_ASK and action_class in SITE_CLASSES and self.site_allowed(action_class, site):
            return MODE_ALLOW
        return mode

    def to_dict(self) -> dict[str, Any]:
        """The wire form: every class with its effective mode, every site
        class with its list, and the defaults (so the app can show "default")."""
        return {
            "classes": {cls: self.mode(cls) for cls in ACTION_CLASSES},
            "sites": {cls: list(self.sites.get(cls, ())) for cls in sorted(SITE_CLASSES)},
            "defaults": dict(DEFAULT_MODES),
        }

    def to_stored(self) -> dict[str, Any]:
        """What the host writes: only what the user set."""
        out: dict[str, Any] = {}
        if self.modes:
            out["classes"] = dict(self.modes)
        sites = {cls: list(v) for cls, v in self.sites.items() if v}
        if sites:
            out["sites"] = sites
        return out

    @classmethod
    def from_stored(cls, raw: Any) -> ActionPolicy:
        """Read one stored entry. Raises :class:`ActionPolicyError` for a bad one."""
        if raw is None:
            return cls()
        if not isinstance(raw, Mapping):
            raise ActionPolicyError("approvals must be an object")
        modes = _check_modes(raw.get("classes", {}))
        sites = _check_sites(raw.get("sites", {}))
        unknown = [k for k in raw if k not in ("classes", "sites")]
        if unknown:
            raise ActionPolicyError(f"unknown approvals key {str(unknown[0])[:40]!r}")
        return cls(modes=modes, sites=sites)

    def updated(self, partial: Any) -> ActionPolicy:
        """Apply an app ``set``: ``classes`` merges (a mode equal to the
        default is still stored, so it is the user's choice), ``sites``
        replaces the whole list of each class it names. Strict: an unknown
        class, mode or key refuses the whole change."""
        if not isinstance(partial, Mapping):
            raise ActionPolicyError("approvals must be an object")
        unknown = [k for k in partial if k not in ("classes", "sites")]
        if unknown:
            raise ActionPolicyError(f"unknown approvals key {str(unknown[0])[:40]!r}")
        modes = dict(self.modes)
        modes.update(_check_modes(partial.get("classes", {})))
        sites = dict(self.sites)
        sites.update(_check_sites(partial.get("sites", {})))
        return ActionPolicy(modes=modes, sites={k: v for k, v in sites.items() if v})

    def remembered(self, action_class: str, scope: str, site: str | None = None) -> ActionPolicy:
        """The policy after a decision with a lasting scope. ``once`` and
        ``deny`` change nothing; ``always_this_agent`` sets the class to
        ``allow``; ``always_this_site`` adds the site (site classes only)."""
        if action_class not in ACTION_CLASSES:
            return self
        if scope == SCOPE_AGENT:
            if self.modes.get(action_class) == MODE_ALLOW:
                return self
            return ActionPolicy(modes={**self.modes, action_class: MODE_ALLOW}, sites=self.sites)
        if scope == SCOPE_SITE and action_class in SITE_CLASSES:
            canon = normalize_site(site)
            if canon is None:
                return self
            current = tuple(self.sites.get(action_class, ()))
            if any(site_matches(canon, allowed) for allowed in current):
                return self
            listed = (*current, canon)[-MAX_SITES:]
            return ActionPolicy(modes=self.modes, sites={**self.sites, action_class: listed})
        return self


def _check_modes(raw: Any) -> dict[str, str]:
    if not isinstance(raw, Mapping):
        raise ActionPolicyError("approvals.classes must be an object")
    out: dict[str, str] = {}
    for key, value in raw.items():
        if key not in ACTION_CLASSES:
            raise ActionPolicyError(f"unknown action class {str(key)[:40]!r}")
        if value not in MODES:
            raise ActionPolicyError(f"mode of {key} must be ask, allow or deny")
        out[key] = value
    return out


def _check_sites(raw: Any) -> dict[str, tuple[str, ...]]:
    if not isinstance(raw, Mapping):
        raise ActionPolicyError("approvals.sites must be an object")
    out: dict[str, tuple[str, ...]] = {}
    for key, value in raw.items():
        if key not in SITE_CLASSES:
            raise ActionPolicyError(f"{str(key)[:40]!r} keeps no sites")
        if not isinstance(value, list):
            raise ActionPolicyError(f"sites of {key} must be a list")
        listed: list[str] = []
        for item in value:
            canon = normalize_site(item)
            if canon is None:
                raise ActionPolicyError(f"not a site: {str(item)[:60]!r}")
            if canon not in listed:
                listed.append(canon)
        out[key] = tuple(listed[-MAX_SITES:])
    return out


# -- one request, one decision --------------------------------------------------


def options_for(action_class: str, site: str | None = None) -> tuple[str, ...]:
    """The answers the card offers. "Always for this site" only for a site
    class and only when the site is known."""
    options = [SCOPE_ONCE, SCOPE_AGENT]
    if action_class in SITE_CLASSES and normalize_site(site):
        options.append(SCOPE_SITE)
    options.append(SCOPE_DENY)
    return tuple(options)


@dataclass
class ActionRequest:
    """What the user is asked about. ``publish`` carries the here.now
    :class:`~chuk_agents_runtime.herenow.PublishRequest` (the old frame fields);
    every other class fills ``summary`` and ``details``."""

    action_class: str
    tool: str
    summary: str
    details: dict[str, Any] = field(default_factory=dict)
    site: str = ""
    options: tuple[str, ...] = ()
    publish: Any = None

    def __post_init__(self) -> None:
        if not self.options:
            self.options = options_for(self.action_class, self.site)


@dataclass(frozen=True)
class ActionDecision:
    """The user's answer. Truthy when approved, so a caller that only wants
    yes or no (the old publish gate) reads it as a bool."""

    approved: bool
    scope: str = SCOPE_ONCE

    def __bool__(self) -> bool:
        return bool(self.approved)


def parse_scope(approved: Any, scope: Any, options: tuple[str, ...] | list[str] | None) -> str:
    """The scope of one ``approval_decision``. A decision that is not an
    explicit yes is ``deny``. A yes with no scope, an unknown scope or a scope
    the request did not offer is ``once``: a decision never reaches further
    than what the card showed. An older app sends no scope: that is ``once``."""
    if approved is not True or scope == SCOPE_DENY:
        return SCOPE_DENY
    offered = tuple(options or (SCOPE_ONCE,))
    if isinstance(scope, str) and scope in offered and scope in SCOPES:
        return scope
    return SCOPE_ONCE


@dataclass
class ActionApprovals:
    """The executor's binding for one run.

    - ``policy()``: the coworker's current policy (a live read: a decision
      with a lasting scope applies to the next call of the same run).
    - ``ask(request)``: blocks until the user answers; returns an
      :class:`ActionDecision` (or a bool from an older gate).
    - ``remember(action_class, scope, site)``: store a lasting decision.
    - ``site()``: the host name of the page the agent's browser is on, or ``""``.
    """

    policy: Callable[[], ActionPolicy]
    ask: Callable[[ActionRequest], Any] | None
    remember: Callable[[str, str, str], None] | None = None
    site: Callable[[], str] | None = None

    def current(self) -> ActionPolicy:
        try:
            policy = self.policy()
        except Exception:  # noqa: BLE001 — an unreadable store falls back to the defaults
            return ActionPolicy()
        return policy if isinstance(policy, ActionPolicy) else ActionPolicy()


# -- what the card shows ---------------------------------------------------------

PREVIEW_CHARS = 300
ARGS_CHARS = 600
LABEL_CHARS = 160


def _clip(value: Any, limit: int = LABEL_CHARS) -> str:
    text = value if isinstance(value, str) else ("" if value is None else str(value))
    text = " ".join(text.split())
    return text if len(text) <= limit else text[: limit - 1] + "…"


def _addresses(value: Any) -> list[str]:
    if isinstance(value, str):
        items = value.replace(";", ",").split(",")
    elif isinstance(value, list):
        items = [v for v in value if isinstance(v, str)]
    else:
        items = []
    return [_clip(v, 120) for v in (i.strip() for i in items) if v][:10]


def describe_mail(tool: str, args: Mapping[str, Any]) -> ActionRequest:
    """``send_external``: who gets it, the subject and the start of the text."""
    text = args.get("text")
    preview = _clip(text, PREVIEW_CHARS) if isinstance(text, str) else ""
    if tool == "mail_reply":
        details: dict[str, Any] = {"reply_to": _clip(args.get("id"), 80), "preview": preview}
        return ActionRequest(SEND_EXTERNAL, tool, "Reply to a mail", details)
    to = _addresses(args.get("to"))
    cc = _addresses(args.get("cc"))
    attachments = args.get("attachments")
    details = {
        "to": to,
        "subject": _clip(args.get("subject")),
        "preview": preview,
    }
    if cc:
        details["cc"] = cc
    if isinstance(attachments, list) and attachments:
        details["attachments"] = [_clip(a, 120) for a in attachments if isinstance(a, str)][:10]
    who = ", ".join(to[:3]) + (f" and {len(to) - 3} more" if len(to) > 3 else "")
    return ActionRequest(SEND_EXTERNAL, tool, f"Send a mail to {who}" if who else "Send a mail", details)


_BROWSER_VERBS = {
    "browser_click": "Click",
    "browser_type": "Type into",
    "browser_fill_form": "Fill in a form",
    "browser_select_option": "Choose an option in",
    "browser_press_key": "Press a key",
    "browser_drag": "Drag",
    "browser_file_upload": "Upload files",
    "browser_handle_dialog": "Answer a dialog",
    "browser_evaluate": "Run a script on the page",
    "browser_run_code": "Run a script on the page",
    "browser_mouse_click_xy": "Click",
    "browser_mouse_drag_xy": "Drag",
}


def describe_browser(tool: str, args: Mapping[str, Any], site: str) -> ActionRequest:
    """``browser_act``: what is done on which site. Never the typed text or a
    form value: it can be a password, and the live view shows the page."""
    verb = _BROWSER_VERBS.get(tool, "Act")
    element = _clip(args.get("element") or args.get("startElement"))
    details: dict[str, Any] = {"browser_tool": tool}
    if element:
        details["element"] = element
    if tool == "browser_type":
        details["submit"] = args.get("submit") is True
    if tool == "browser_press_key":
        details["key"] = _clip(args.get("key"), 40)
    if tool == "browser_fill_form" and isinstance(args.get("fields"), list):
        details["fields"] = [
            _clip(f.get("name"), 80) for f in args["fields"] if isinstance(f, Mapping) and f.get("name")
        ][:20]
    if tool == "browser_handle_dialog":
        details["accept"] = args.get("accept") is True
    if tool == "browser_file_upload" and isinstance(args.get("paths"), list):
        details["files"] = [_clip(p, 120) for p in args["paths"] if isinstance(p, str)][:10]
    target = f" {element}" if element and verb in ("Click", "Type into", "Choose an option in", "Drag") else ""
    where = f" on {site}" if site else ""
    return ActionRequest(BROWSER_ACT, tool, f"{verb}{target}{where}", details, site=site)


def describe_mcp(tool: str, server: str, remote_tool: str, args: Mapping[str, Any]) -> ActionRequest:
    """``mcp_destructive``: the connector, its tool and the arguments, cut."""
    try:
        shown = json.dumps(dict(args), ensure_ascii=False, sort_keys=True, default=str)
    except (TypeError, ValueError):
        shown = ""
    if len(shown) > ARGS_CHARS:
        shown = shown[: ARGS_CHARS - 1] + "…"
    details = {"server": _clip(server, 80), "remote_tool": _clip(remote_tool, 80), "arguments": shown}
    return ActionRequest(
        MCP_DESTRUCTIVE, tool, f"{_clip(server, 80)}: {_clip(remote_tool, 80)}", details
    )


def describe_publish(publish: Any) -> ActionRequest:
    """``publish``: the here.now request, with a one-line summary."""
    name = _clip(getattr(publish, "name", "") or getattr(publish, "path", ""))
    return ActionRequest(
        PUBLISH,
        "herenow_publish",
        f"Publish {name} on the open internet" if name else "Publish on the open internet",
        {},
        publish=publish,
    )


#: What a refused action is, in words the model reads.
CLASS_WORDS = {
    PUBLISH: "publish this",
    SEND_EXTERNAL: "send this mail",
    MCP_DESTRUCTIVE: "run this connector action",
    BROWSER_ACT: "do this in the browser",
}


__all__ = [
    "ACTION_APPROVAL",
    "ACTION_CLASSES",
    "BROWSER_ACT",
    "BROWSER_ACT_TOOLS",
    "CLASS_WORDS",
    "DEFAULT_MODES",
    "MAIL_SEND_TOOLS",
    "MCP_DESTRUCTIVE",
    "MODES",
    "MODE_ALLOW",
    "MODE_ASK",
    "MODE_DENY",
    "PUBLISH",
    "SCOPES",
    "SCOPE_AGENT",
    "SCOPE_DENY",
    "SCOPE_ONCE",
    "SCOPE_SITE",
    "SEND_EXTERNAL",
    "SITE_CLASSES",
    "ActionApprovals",
    "ActionDecision",
    "ActionPolicy",
    "ActionPolicyError",
    "ActionRequest",
    "describe_browser",
    "describe_mail",
    "describe_mcp",
    "describe_publish",
    "is_destructive",
    "normalize_site",
    "options_for",
    "parse_scope",
    "site_matches",
]
