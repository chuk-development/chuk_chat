"""Approvals on the Pydantic AI loop (docs/PYDANTIC_AI_LOOP.md, section 7).

The owner's policy: **everything is allowed by default.** Only a clearly
dangerous or outward action asks the user first. The classes that can ask are
in :mod:`chuk_agents_runtime.action_policy` (docs/WIRE_CONTRACT.md,
"Per-action approvals"): ``publish`` (here.now in ``ask`` mode),
``send_external`` (mail to an address), ``mcp_destructive`` (a connector tool
its server marks destructive) and ``browser_act`` (a page-changing browser
tool, per site; ``allow`` unless the user switches it). The user sets per
agent whether each class asks, is allowed or is refused, and a decision can
last: "always for this agent" or "always for this site".

The mechanism is Pydantic AI's own:

1. :class:`ApprovalPolicy` names the tools that ask. The toolset declares each
   of them with ``kind="unapproved"``, so Pydantic AI defers the call instead
   of running it.
2. :meth:`ApprovalPolicy.handler` is the
   :class:`~pydantic_ai.capabilities.HandleDeferredToolCalls` handler. It runs
   in the same run: for each deferred call it prepares an honest prompt (for
   here.now: a scan of what would go out), asks through the executor's
   existing gate (the ``approval_request`` / ``approval_decision`` wire pair,
   unchanged), and answers ``ToolApproved`` or ``ToolDenied``. Pydantic AI
   then runs the approved call and the run continues. No second run, no
   serialized state.

The request for a secret (``request_secrets``) is not an approval: it is an
input dialog in which the user types values, and it stays inside its tool.
"""

from __future__ import annotations

import json
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Any

import anyio
from pydantic_ai import RunContext
from pydantic_ai.tools import (
    DeferredToolRequests,
    DeferredToolResults,
    ToolApproved,
    ToolDenied,
)

from ..action_policy import (
    BROWSER_ACT_TOOLS,
    CLASS_WORDS,
    MAIL_SEND_TOOLS,
    MODE_ALLOW,
    MODE_ASK,
    MODE_DENY,
    MCP_DESTRUCTIVE,
    PUBLISH,
    SCOPE_AGENT,
    SCOPE_CHAT,
    SCOPE_ONCE,
    SCOPE_SITE,
    SEND_EXTERNAL,
    SITE_CLASSES,
    BROWSER_ACT,
    LOCAL_ACTION_TOOLS,
    LOCAL_ACTIONS,
    MODE_REVIEW_STRICT,
    REVIEW_MODES,
    SCOPE_DENY,
    ActionApprovals,
    ActionDecision,
    ActionPolicy,
    ActionRequest,
    describe_browser,
    describe_local,
    describe_mail,
    describe_mcp,
    describe_publish,
    is_destructive,
    USER_BROWSER_ACT_TOOLS,
    user_browser_tool_acts,
    with_chat_option,
)
from ..intent_check import CARD_KIND as INTENT_CARD_KIND
from ..intent_check import IntentVerdict
from ..loop import KillSwitch
from .convert import tool_call_args
from .tools import CallRecord, RegistryToolset


@dataclass
class ApprovalRule:
    """How one tool asks.

    ``prepare(args)`` builds what the user is shown (it may do I/O, it runs on
    a worker thread). It returns either the request object for ``ask``, or a
    ``dict`` — a finished tool result that ends the call without asking (the
    here.now scan failed, so there is nothing to approve).

    ``ask(request)`` blocks until the user answers and returns ``True`` for an
    explicit yes. ``None`` means nobody can answer in this run.

    ``declined(args, reason)`` is the tool result the model gets for a no.
    """

    prepare: Callable[[dict], Any]
    ask: Callable[[Any], bool] | None
    declined: Callable[[dict, str], dict]
    #: The action class (``chuk_agents_runtime.action_policy``) when the rule
    #: follows a per-agent policy; ``None`` is the old rule that always asks.
    action_class: str | None = None
    #: The run's binding: the live policy, where a lasting decision is stored,
    #: and the browser's current site. ``None`` with ``action_class`` set means
    #: the class defaults hold and nothing is remembered.
    approvals: ActionApprovals | None = None
    #: ``True`` when the user's own setting already said "do not ask" for this
    #: class (here.now in ``auto`` mode): ``ask`` then reads as ``allow``, and
    #: only a ``deny`` still stops the call.
    ask_means_allow: bool = False
    #: ``applies(args)``: ``False`` when this one call does not act at all and
    #: runs without the policy (``browser_tabs list`` in the user's browser).
    #: ``None`` = every call of the tool is checked.
    applies: Callable[[dict], bool] | None = None
    #: ``site_of(args)``: the site this call acts on, when it is not the page
    #: the browser shows (``browser_navigate`` -> the host of its URL).
    #: ``None`` from it, or no callable, means the browser's current site.
    site_of: Callable[[dict], str | None] | None = None
    #: ``reviewer(args)`` -> :class:`~chuk_agents_runtime.auto_review.ReviewVerdict`
    #: for a class in a review mode (docs/WIRE_CONTRACT.md, "Auto review").
    #: ``None`` in a review mode = every call asks the user.
    reviewer: Callable[[dict], Any] | None = None

    def mode(self, site: str | None = None) -> str:
        """``ask`` / ``allow`` / ``deny`` for one call, from the live policy."""
        if self.action_class is None:
            return MODE_ASK
        if self.approvals is None:
            mode = ActionPolicy().evaluate(self.action_class, site)
        else:
            mode = self.approvals.current().evaluate(self.action_class, site)
        if mode == MODE_ASK and self.ask_means_allow:
            return MODE_ALLOW
        return mode

    def defers(self) -> bool:
        """Whether the call must stop for the handler at all. A class set to
        ``allow`` runs like any other tool; a site class in ``ask`` defers, so
        the handler can check the site."""
        return self.mode() != MODE_ALLOW


@dataclass
class ApprovalPolicy:
    """Which tools ask, and how. Empty = nothing asks (the default)."""

    rules: dict[str, ApprovalRule] = field(default_factory=dict)
    kill: KillSwitch | None = None
    #: Where a finished-without-running result is recorded, so the loop
    #: stores the same tool result the native tool returned.
    toolset: RegistryToolset | None = None
    #: The intent check (CHAT-180, :class:`~chuk_agents_runtime.intent_check.IntentGuard`):
    #: a class action that would run silently (``allow``) is first compared
    #: with the user's own words; not covered = a card. ``None`` = no check.
    intent: Any = None
    #: The run's approval audit (CHAT-180): one entry per decided card and
    #: per refused action, read and cleared by :meth:`end_run`.
    audit: list[dict] = field(default_factory=list)

    def requires_approval(self, name: str) -> bool:
        """Whether ``name`` is declared ``unapproved`` this step. Read live, so
        "always for this agent" stops the next call of the same run from
        deferring at all. A class under the intent check always defers, so
        the handler can judge it."""
        rule = self.rules.get(name)
        if rule is None:
            return False
        try:
            return rule.defers() or self._intent_on(rule)
        except Exception:  # noqa: BLE001 — an unreadable policy asks
            return True

    def _intent_on(self, rule: ApprovalRule) -> bool:
        intent = self.intent
        if intent is None or rule.action_class is None:
            return False
        try:
            return bool(intent.applies(rule.action_class))
        except Exception:  # noqa: BLE001 — an unreadable guard checks
            return True

    def end_run(self) -> list[dict]:
        """The run's audit entries (then cleared), and a fresh intent state
        for the next run."""
        entries, self.audit = list(self.audit), []
        if self.intent is not None:
            try:
                self.intent.reset()
            except Exception:  # noqa: BLE001
                pass
        return entries

    def add(self, name: str, rule: ApprovalRule) -> None:
        self.rules[name] = rule

    async def handler(
        self, ctx: RunContext[Any], requests: DeferredToolRequests
    ) -> DeferredToolResults | None:
        """The :class:`HandleDeferredToolCalls` handler: ask for each call
        named by the policy, in order, in this run."""
        approvals: dict[str, ToolApproved | ToolDenied] = {}
        for call in requests.approvals:
            rule = self.rules.get(call.tool_name)
            if rule is None:
                # Not ours to decide (a future capability's own deferral).
                continue
            args = tool_call_args(call)
            if not isinstance(args, dict):
                args = {}
            approvals[call.tool_call_id] = await self._decide(
                call.tool_call_id, rule, args, name=call.tool_name
            )
        if not approvals:
            return None
        return requests.build_results(approvals=approvals)

    async def ask_for(self, call_id: str, name: str, args: Any) -> bool | None:
        """Decide one call outside Pydantic AI's deferral, the same way the
        handler does: policy first, then the card.

        For a deferred tool the model called before it searched for it.
        Pydantic AI refuses such a call ("not available yet") before it gets
        to the approval step, so the loop asks here and runs the call itself
        (chuk_chat-3oh6). ``True`` = run it; ``False`` = do not (the result
        the model gets is already recorded in the toolset); ``None`` = no rule
        for this tool."""
        rule = self.rules.get(name)
        if rule is None:
            return None
        decided = await self._decide(
            call_id, rule, args if isinstance(args, dict) else {}, name=name
        )
        return isinstance(decided, ToolApproved)

    async def _decide(
        self, call_id: str, rule: ApprovalRule, args: dict, *, name: str = ""
    ) -> ToolApproved | ToolDenied:
        if self.kill is not None and (self.kill.interrupted() or self.kill.estop_engaged()):
            self._note(rule, None, name, "denied", "stopped")
            return self._deny(call_id, rule.declined(args, "stopped"))
        if rule.applies is not None and not _applies(rule.applies, args):
            return ToolApproved()
        site = ""
        request: Any = None
        intent: IntentVerdict | None = None
        if rule.action_class is not None:
            if rule.action_class in SITE_CLASSES and rule.approvals is not None:
                own = None
                if rule.site_of is not None:
                    own = await anyio.to_thread.run_sync(_read_site_of, rule.site_of, args)
                if own is not None:
                    site = own
                elif rule.approvals.site:
                    site = await anyio.to_thread.run_sync(_read_site, rule.approvals.site)
            mode = rule.mode(site)
            if mode == MODE_ALLOW:
                if not self._intent_on(rule):
                    return ToolApproved()
                # CHAT-180: a silent allow is first compared with the user's
                # own words. Covered = run; anything else = a card.
                try:
                    request = await anyio.to_thread.run_sync(_prepare, rule, args, site)
                except Exception as exc:  # noqa: BLE001 — a failed preflight is a no
                    return self._deny(
                        call_id, rule.declined(args, f"{type(exc).__name__}: {exc}")
                    )
                if isinstance(request, dict):
                    return self._deny(call_id, request)
                if not isinstance(request, ActionRequest):
                    return ToolApproved()
                intent = await anyio.to_thread.run_sync(_judge, self.intent, request)
                if intent.covered:
                    return ToolApproved()
                request.details = {
                    **request.details, "kind": INTENT_CARD_KIND, "intent": intent.to_dict()
                }
                request.options = (SCOPE_ONCE, SCOPE_DENY)
            if mode == MODE_DENY:
                self._note(rule, None, name, "denied", "policy")
                return self._deny(call_id, rule.declined(args, "denied_by_policy"))
        verdict = None
        if rule.action_class is not None and mode in REVIEW_MODES:
            # Auto review (research item 31): the cheap model decides first.
            verdict = await anyio.to_thread.run_sync(_review, rule, args)
            if verdict.allowed:
                return ToolApproved()
            if mode == MODE_REVIEW_STRICT and verdict.valid:
                self._note(rule, None, name, "denied", "review")
                return self._deny(call_id, rule.declined(args, _review_reason(verdict)))
        if request is None:
            try:
                request = await anyio.to_thread.run_sync(_prepare, rule, args, site)
            except Exception as exc:  # noqa: BLE001 — a failed preflight is a no
                return self._deny(
                    call_id, rule.declined(args, f"{type(exc).__name__}: {exc}")
                )
        if isinstance(request, dict):
            # The preflight already answered (a scan error): that is the result.
            return self._deny(call_id, request)
        if verdict is not None and isinstance(request, ActionRequest):
            # The card says why it asks; a review card is for this call only.
            request.details = {**request.details, "kind": "auto_review", "review": verdict.to_dict()}
            request.options = (SCOPE_ONCE, SCOPE_DENY)
        if (
            verdict is None
            and intent is None
            and isinstance(request, ActionRequest)
            and rule.approvals is not None
            and rule.approvals.chat_scope
        ):
            # CHAT-180: "allow for this chat" next to the lasting scopes.
            request.options = with_chat_option(request.options)
        if rule.ask is None:
            self._note(rule, request, name, "denied", "unattended", intent=intent)
            return self._deny(call_id, rule.declined(args, "unattended"))
        try:
            answer = await anyio.to_thread.run_sync(
                rule.ask, request, abandon_on_cancel=True
            )
        except Exception as exc:  # noqa: BLE001 — a gate failure is a denial
            return self._deny(
                call_id, rule.declined(args, f"approval failed: {type(exc).__name__}: {exc}")
            )
        decision = (
            answer
            if isinstance(answer, ActionDecision)
            else ActionDecision(approved=answer is True, scope=SCOPE_ONCE)
        )
        if not decision.approved:
            self._note(rule, request, name, "denied", "user", intent=intent)
            return self._deny(call_id, rule.declined(args, "declined"))
        if decision.scope in (SCOPE_AGENT, SCOPE_SITE, SCOPE_CHAT) and rule.action_class is not None:
            await anyio.to_thread.run_sync(_remember, rule, decision.scope, site)
        if self.intent is not None and isinstance(request, ActionRequest):
            try:
                self.intent.note_approved(request)
            except Exception:  # noqa: BLE001
                pass
        self._note(rule, request, name, "allowed", "user", scope=decision.scope, site=site, intent=intent)
        return ToolApproved()

    def _note(
        self,
        rule: ApprovalRule,
        request: Any,
        name: str,
        outcome: str,
        by: str,
        *,
        scope: str = "",
        site: str = "",
        intent: IntentVerdict | None = None,
    ) -> None:
        """One audit entry (CHAT-180). Never raises."""
        try:
            self.audit.append(
                audit_entry(
                    tool=name,
                    action_class=rule.action_class or "",
                    summary=getattr(request, "summary", "") if request is not None else "",
                    outcome=outcome,
                    by=by,
                    scope=scope,
                    site=site,
                    intent_checked=intent is not None,
                )
            )
        except Exception:  # noqa: BLE001 — the audit never fails a call
            pass

    def _deny(self, call_id: str, result: dict) -> ToolDenied:
        if self.toolset is not None:
            record = self.toolset.calls.setdefault(call_id, CallRecord(started_at=0.0))
            record.result = result
        return ToolDenied(message=json.dumps(result, separators=(",", ":")))


#: The words of one audit line, by who decided and how far it reaches.
_AUDIT_WORDS = {
    ("allowed", SCOPE_ONCE): "allowed once by the user",
    ("allowed", SCOPE_CHAT): "allowed for this chat by the user",
    ("allowed", SCOPE_AGENT): "allowed always for this agent by the user",
    ("allowed", SCOPE_SITE): "allowed always on this site by the user",
}
_AUDIT_BY = {
    "user": "declined by the user",
    "policy": "refused by the approval settings",
    "review": "refused by the automatic review",
    "unattended": "not run: nobody could approve it",
    "stopped": "not run: the run was stopped",
}


def audit_entry(
    *,
    tool: str,
    action_class: str,
    summary: str,
    outcome: str,
    by: str,
    scope: str = "",
    site: str = "",
    intent_checked: bool = False,
) -> dict:
    """One approval audit entry with its collapsed line (``text``), e.g.
    "Send a mail to a@b.c: allowed once by the user"."""
    if outcome == "allowed":
        words = _AUDIT_WORDS.get((outcome, scope), "allowed by the user")
        if scope == SCOPE_SITE and site:
            words = f"allowed always on {site} by the user"
    else:
        words = _AUDIT_BY.get(by, "not run")
    if intent_checked:
        words += " (not clearly asked for, so the user was asked)"
    label = summary or CLASS_WORDS.get(action_class, "") or tool or "action"
    entry = {
        "tool": tool,
        "action_class": action_class,
        "outcome": outcome,
        "by": by,
        "text": f"{label}: {words}",
    }
    if scope:
        entry["scope"] = scope
    if intent_checked:
        entry["intent_check"] = True
    return entry


def _judge(guard: Any, request: ActionRequest) -> IntentVerdict:
    """Run the intent check; any failure is "not covered" (the user is asked)."""
    if guard is None:
        return IntentVerdict(False, valid=False, reason="no intent check")
    try:
        verdict = guard.check(request)
    except Exception:  # noqa: BLE001 — fail safe: ask
        return IntentVerdict(False, valid=False, reason="the intent check failed")
    if not isinstance(verdict, IntentVerdict):
        return IntentVerdict(False, valid=False, reason="no verdict")
    return verdict


def _review(rule: ApprovalRule, args: dict) -> Any:
    from ..auto_review import ReviewVerdict

    if rule.reviewer is None:
        return ReviewVerdict(False, reason="no reviewer")
    try:
        verdict = rule.reviewer(args)
    except Exception:  # noqa: BLE001 — a failed review asks the user
        return ReviewVerdict(False, reason="the reviewer failed")
    return verdict if isinstance(verdict, ReviewVerdict) else ReviewVerdict(False, reason="no verdict")


def _review_reason(verdict: Any) -> str:
    return f"review_denied:{verdict.risk}:{verdict.reason}"


def _read_site(reader: Callable[[], str]) -> str:
    try:
        value = reader()
    except Exception:  # noqa: BLE001 — an unknown site only means no site option
        return ""
    return value if isinstance(value, str) else ""


def _read_site_of(reader: Callable[[dict], str | None], args: dict) -> str | None:
    try:
        value = reader(args)
    except Exception:  # noqa: BLE001 — fall back to the current page
        return None
    return value if isinstance(value, str) else None


def _applies(check: Callable[[dict], bool], args: dict) -> bool:
    try:
        return bool(check(args))
    except Exception:  # noqa: BLE001 — when in doubt the call is checked
        return True


def _prepare(rule: ApprovalRule, args: dict, site: str) -> Any:
    """Build the request; a class rule's ``prepare`` also takes the site."""
    if rule.action_class in SITE_CLASSES:
        return rule.prepare(args, site)  # type: ignore[call-arg]
    return rule.prepare(args)


def _remember(rule: ApprovalRule, scope: str, site: str) -> None:
    """Store a lasting decision. Best effort: a store failure costs the next
    call one more card, never this call."""
    approvals = rule.approvals
    if approvals is None or approvals.remember is None or rule.action_class is None:
        return
    try:
        approvals.remember(rule.action_class, scope, site)
    except Exception:  # noqa: BLE001
        pass


# -- the action classes -----------------------------------------------------------


def class_declined(action_class: str) -> Callable[[dict, str], dict]:
    """The tool result the model gets when a class action does not run."""
    words = CLASS_WORDS.get(action_class, "do this")

    def declined(args: dict, reason: str) -> dict:
        if reason == "unattended":
            error = (
                f"this action needs the user's approval, but no one can approve it "
                f"in this run, so it did not happen. Ask the user to {words} interactively."
            )
            return {"ok": False, "declined": True, "action_class": action_class, "error": error}
        if reason == "denied_by_policy":
            error = (
                f"this agent is not allowed to {words}: the user turned it off in the "
                "approval settings. It did not happen. Do not retry; tell the user."
            )
            return {"ok": False, "declined": True, "action_class": action_class, "error": error}
        if reason in ("declined", "stopped"):
            error = (
                f"the user declined: {words} did not happen. Do not retry it; "
                "ask the user what to do instead."
            )
            return {"ok": False, "declined": True, "action_class": action_class, "error": error}
        if reason.startswith("review_denied:"):
            _, risk, why = reason.split(":", 2)
            error = (
                f"the automatic reviewer refused this action (risk {risk})"
                + (f": {why}" if why else "")
                + ". It did not run. Do not retry it or work around it; tell the user what you "
                "wanted to do and why, so the user can do it or allow it."
            )
            return {"ok": False, "declined": True, "action_class": action_class, "review": risk, "error": error}
        return {"ok": False, "action_class": action_class, "error": reason}

    return declined


def action_rule(
    action_class: str,
    describe: Callable[..., ActionRequest],
    approvals: ActionApprovals,
) -> ApprovalRule:
    """A rule for one class tool. ``describe(args)`` (``describe(args, site)``
    for a site class) builds the card; the binding asks and remembers."""
    return ApprovalRule(
        prepare=describe,
        ask=approvals.ask,
        declined=class_declined(action_class),
        action_class=action_class,
        approvals=approvals,
    )


def action_rules(
    registry: Any, manager: Any, approvals: ActionApprovals, reviewer: Any = None
) -> dict[str, ApprovalRule]:
    """The class rules for the tools this run has, decided by structure:

    - ``send_external``: ``mail_send`` / ``mail_reply`` when registered;
    - ``browser_act``: a page-changing tool (:data:`BROWSER_ACT_TOOLS`) of a
      connected browser MCP server;
    - ``mcp_destructive``: a tool of any other connected MCP server that its
      server declared ``destructiveHint: true`` (and not read-only).
    """
    rules: dict[str, ApprovalRule] = {}
    # ``local_actions`` (docs/WIRE_CONTRACT.md, "Auto review"): commands and
    # file changes in the sandbox. Default ``allow``: no deferral, no cost.
    for name in sorted(LOCAL_ACTION_TOOLS):
        if registry.has(name):
            rule = action_rule(
                LOCAL_ACTIONS, lambda args, _n=name: describe_local(_n, args), approvals
            )
            if reviewer is not None:
                rule.reviewer = lambda args, _n=name: reviewer(_n, args)
            rules[name] = rule
    for name in sorted(MAIL_SEND_TOOLS):
        if registry.has(name):
            rules[name] = action_rule(
                SEND_EXTERNAL, lambda args, _n=name: describe_mail(_n, args), approvals
            )
    if manager is None:
        return rules
    from ..mcp_client import browser_servers, tool_name

    browsers = set(browser_servers(manager))
    for server, connection in getattr(manager, "connections", {}).items():
        try:
            alive = connection.alive()
        except Exception:  # noqa: BLE001
            alive = False
        if not alive:
            continue
        for info in getattr(connection, "tools", []):
            full = tool_name(server, info.name)
            if not registry.has(full):
                continue
            if server in browsers:
                if info.name in BROWSER_ACT_TOOLS:
                    rules[full] = action_rule(
                        BROWSER_ACT,
                        lambda args, site, _t=info.name, _u=approvals.user_browser: describe_browser(
                            _t, args, site, user_browser=_u
                        ),
                        approvals,
                    )
                elif approvals.user_browser and info.name in USER_BROWSER_ACT_TOOLS:
                    # The user's own browser: opening a page or taking over a
                    # tab happens in the user's logged-in session.
                    rule = action_rule(
                        BROWSER_ACT,
                        lambda args, site, _t=info.name: describe_browser(
                            _t, args, site, user_browser=True
                        ),
                        approvals,
                    )
                    rule.applies = lambda args, _t=info.name: user_browser_tool_acts(_t, args)
                    rules[full] = rule
                if full in rules and approvals.site_for is not None:
                    rules[full].site_of = (
                        lambda args, _t=info.name, _f=approvals.site_for: _f(_t, args)
                    )
                continue
            if is_destructive(getattr(info, "annotations", None)):
                rules[full] = action_rule(
                    MCP_DESTRUCTIVE,
                    lambda args, _f=full, _s=server, _t=info.name: describe_mcp(_f, _s, _t, args),
                    approvals,
                )
    return rules


def bind_publish(rule: ApprovalRule, approvals: ActionApprovals, *, asks: bool) -> ApprovalRule:
    """Put the here.now rule under the ``publish`` class: the agent's
    policy decides first, and the card carries the class and its options.
    ``asks`` is the user's connector setting; ``auto`` (``asks=False``) keeps
    its meaning, "never ask", and only a ``deny`` stops a publish."""
    inner_prepare = rule.prepare

    def prepare(args: dict) -> Any:
        request = inner_prepare(args)
        if isinstance(request, dict):
            return request  # the scan failed: that is the result
        return describe_publish(request)

    return ApprovalRule(
        prepare=prepare,
        ask=approvals.ask,
        declined=rule.declined,
        action_class=PUBLISH,
        approvals=approvals,
        ask_means_allow=not asks,
    )


# -- here.now ------------------------------------------------------------------


def herenow_rule(env: Any, config: Any, gate: Callable[[Any], bool] | None) -> ApprovalRule:
    """The here.now publish rule: scan first (so the prompt is honest about
    what goes out), then the executor's gate. The same order and the same
    results as the gate inside the native tool."""
    from ..herenow import HereNowError, PublishRequest, _run_publisher

    def prepare(args: dict) -> Any:
        path = str(args.get("path") or "").strip()
        if not path:
            return {"ok": False, "error": "path is empty"}
        scan_args = {
            "path": path,
            "name": args.get("name"),
            "description": args.get("description"),
            "spa": bool(args.get("spa", False)),
        }
        try:
            scan = _run_publisher(env, "scan", config, scan_args)
        except HereNowError as exc:
            return {"ok": False, "path": path, "error": str(exc)}
        if not scan.get("ok"):
            return {"ok": False, "path": path, "error": scan.get("error", "scan failed")}
        return PublishRequest(
            path=path,
            name=(str(args.get("name") or "")).strip() or path,
            file_count=int(scan.get("file_count", 0)),
            total_bytes=int(scan.get("total_bytes", 0)),
            base_url=config.base_url,
        )

    def declined(args: dict, reason: str) -> dict:
        path = str(args.get("path") or "").strip()
        if reason == "unattended":
            return {
                "ok": False,
                "path": path,
                "error": (
                    "publishing needs your approval, but no one is available "
                    "to approve it in this run. Ask the user to publish it "
                    "interactively, or enable auto-approve in settings."
                ),
            }
        if reason in ("declined", "stopped"):
            return {
                "ok": False,
                "path": path,
                "declined": True,
                "error": "the user declined to publish this.",
            }
        if reason == "denied_by_policy":
            return {
                "ok": False,
                "path": path,
                "declined": True,
                "error": (
                    "this agent is not allowed to publish: the user turned it off "
                    "in the approval settings. Nothing was published."
                ),
            }
        return {"ok": False, "path": path, "error": reason}

    return ApprovalRule(prepare=prepare, ask=gate, declined=declined)


__all__ = [
    "ApprovalPolicy",
    "ApprovalRule",
    "action_rule",
    "action_rules",
    "audit_entry",
    "bind_publish",
    "class_declined",
    "herenow_rule",
]
