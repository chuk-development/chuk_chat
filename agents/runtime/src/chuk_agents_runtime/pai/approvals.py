"""Approvals on the Pydantic AI loop (docs/PYDANTIC_AI_LOOP.md, section 7).

The owner's policy: **everything is allowed by default.** Only a clearly
dangerous or outward action asks the user first. Today that is one tool,
``herenow_publish`` in ``ask`` mode (a public URL on the open internet).
Payments and messages sent on the user's behalf (SMS, mail) join the policy
when those tools exist; nothing else ever asks.

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


@dataclass
class ApprovalPolicy:
    """Which tools ask, and how. Empty = nothing asks (the default)."""

    rules: dict[str, ApprovalRule] = field(default_factory=dict)
    kill: KillSwitch | None = None
    #: Where a finished-without-running result is recorded, so the loop
    #: stores the same tool result the native tool returned.
    toolset: RegistryToolset | None = None

    def requires_approval(self, name: str) -> bool:
        return name in self.rules

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
            approvals[call.tool_call_id] = await self._decide(call.tool_call_id, rule, args)
        if not approvals:
            return None
        return requests.build_results(approvals=approvals)

    async def _decide(
        self, call_id: str, rule: ApprovalRule, args: dict
    ) -> ToolApproved | ToolDenied:
        if self.kill is not None and (self.kill.interrupted() or self.kill.estop_engaged()):
            return self._deny(call_id, rule.declined(args, "stopped"))
        try:
            request = await anyio.to_thread.run_sync(rule.prepare, args)
        except Exception as exc:  # noqa: BLE001 — a failed preflight is a no
            return self._deny(
                call_id, rule.declined(args, f"{type(exc).__name__}: {exc}")
            )
        if isinstance(request, dict):
            # The preflight already answered (a scan error): that is the result.
            return self._deny(call_id, request)
        if rule.ask is None:
            return self._deny(call_id, rule.declined(args, "unattended"))
        try:
            approved = await anyio.to_thread.run_sync(
                rule.ask, request, abandon_on_cancel=True
            )
        except Exception as exc:  # noqa: BLE001 — a gate failure is a denial
            return self._deny(
                call_id, rule.declined(args, f"approval failed: {type(exc).__name__}: {exc}")
            )
        if approved:
            return ToolApproved()
        return self._deny(call_id, rule.declined(args, "declined"))

    def _deny(self, call_id: str, result: dict) -> ToolDenied:
        if self.toolset is not None:
            record = self.toolset.calls.setdefault(call_id, CallRecord(started_at=0.0))
            record.result = result
        return ToolDenied(message=json.dumps(result, separators=(",", ":")))


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
        return {"ok": False, "path": path, "error": reason}

    return ApprovalRule(prepare=prepare, ask=gate, declined=declined)


__all__ = ["ApprovalPolicy", "ApprovalRule", "herenow_rule"]
