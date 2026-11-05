"""Sandbox escalation for one call (docs/WIRE_CONTRACT.md, "Sandbox
escalation"; DeepSeek research item 28, ``packages/sandbox/sandbox/src/escalation.ts``).

The agent's sandbox can withhold ``network``, ``sudo`` and a writable
workspace (the per-agent permissions). When a command fails on such a limit,
the model may retry THAT command once with ``sandbox_permissions`` (the
narrowest wider set that suffices) plus a one-sentence ``justification``. The
user sees the justification in an ``approval_request`` of kind
``sandbox_escalation`` and answers once or deny. A grant covers that one call
only; the agent's permissions do not change.

The pieces here are pure: argument validation, the texts the model reads, the
card, and :func:`resolve_escalation`, the fail-closed order of checks that
runs BEFORE anything executes. The tools call it; the sandbox does the run
(``run_escalated``).
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

from .action_policy import SCOPE_DENY, SCOPE_ONCE, ActionDecision, ActionRequest

#: The ``action_class`` (and ``kind``) of the approval card.
SANDBOX_ESCALATION = "sandbox_escalation"

#: The names a call may ask for, narrowest first in the card.
ESCALATION_TARGETS: tuple[str, ...] = ("network", "workspace_write", "sudo")

#: The card's answers: a grant is for one call, so there is no "always".
ESCALATION_OPTIONS: tuple[str, ...] = (SCOPE_ONCE, SCOPE_DENY)

MAX_JUSTIFICATION_CHARS = 300
COMMAND_PREVIEW_CHARS = 600

#: The two schema properties ``run_command`` and ``python`` gain. Short on
#: purpose: both tools are declared on every round.
SCHEMA_PROPERTIES: dict[str, Any] = {
    "sandbox_permissions": {
        "type": "array",
        "items": {"enum": list(ESCALATION_TARGETS)},
        "description": "Retry a denied call with these; asks the user.",
    },
    "justification": {"type": "string", "description": "One sentence why."},
}

_WORDS = {"network": "internet access", "workspace_write": "write access to the workspace", "sudo": "sudo"}


def hint(subject: str = "command") -> str:
    """The line a sandbox denial carries (research item 28)."""
    return (
        f"the sandbox withholds these permissions; if they caused the failure, retry this exact {subject} "
        "once with sandbox_permissions (the narrowest that suffices) + justification; the user is asked"
    )


def rejected_text(subject: str, names: tuple[str, ...]) -> str:
    return (
        f"the user rejected escalating this {subject} to {', '.join(names)}; it stays denied, "
        "so stop and explain instead of working around it"
    )


@dataclass(frozen=True)
class Escalation:
    """What one call asked for, validated. ``requested`` empty = no escalation."""

    requested: tuple[str, ...] = ()
    justification: str = ""
    error: str | None = None


def parse_escalation(sandbox_permissions: Any, justification: Any) -> Escalation:
    """Validate the pairing the schema cannot express: both or neither, a
    non-empty sentence, only known names (research item 28)."""
    given_perms = sandbox_permissions not in (None, [], "")
    given_reason = justification not in (None, "")
    if not given_perms and not given_reason:
        return Escalation()
    if given_perms and not given_reason:
        return Escalation(error="invalid escalation: sandbox_permissions requires a justification")
    if given_reason and not given_perms:
        return Escalation(
            error="invalid escalation: justification is only valid together with sandbox_permissions"
        )
    if not isinstance(justification, str) or not justification.strip():
        return Escalation(error="invalid justification: expected a non-empty sentence")
    raw = [sandbox_permissions] if isinstance(sandbox_permissions, str) else sandbox_permissions
    if not isinstance(raw, (list, tuple)):
        return Escalation(error="invalid escalation: sandbox_permissions must be a list")
    names: list[str] = []
    for item in raw:
        if item not in ESCALATION_TARGETS:
            return Escalation(
                error=f"invalid escalation: unknown sandbox permission {str(item)[:40]!r} "
                f"(use {', '.join(ESCALATION_TARGETS)})"
            )
        if item not in names:
            names.append(item)
    ordered = tuple(n for n in ESCALATION_TARGETS if n in names)
    return Escalation(requested=ordered, justification=" ".join(justification.split())[:MAX_JUSTIFICATION_CHARS])


def withheld(env: Any) -> tuple[str, ...]:
    """What the environment withholds now; ``()`` for one that cannot say
    (then nothing can be widened, and nothing needs to be)."""
    reader = getattr(env, "withheld_permissions", None)
    if not callable(reader):
        return ()
    try:
        return tuple(n for n in reader() if n in ESCALATION_TARGETS)
    except Exception:  # noqa: BLE001
        return ()


def can_escalate(env: Any, ask: Callable[[ActionRequest], Any] | None) -> bool:
    return ask is not None and callable(getattr(env, "run_escalated", None))


def describe(tool: str, names: tuple[str, ...], justification: str, command: str) -> ActionRequest:
    """The card: what is asked, the model's reason verbatim, the command."""
    words = ", ".join(_WORDS.get(n, n) for n in names)
    preview = command if len(command) <= COMMAND_PREVIEW_CHARS else command[:COMMAND_PREVIEW_CHARS] + "…"
    return ActionRequest(
        action_class=SANDBOX_ESCALATION,
        tool=tool,
        summary=f"Run one {'script' if tool == 'python' else 'command'} with {words}: {justification}",
        details={
            "kind": SANDBOX_ESCALATION,
            "permissions": list(names),
            "justification": justification,
            "command": preview,
        },
        options=ESCALATION_OPTIONS,
    )


@dataclass(frozen=True)
class Resolution:
    """``grant`` = the names to widen for this one call (may be empty: run as
    usual); ``refusal`` = the tool result when the call must not run."""

    grant: tuple[str, ...] = ()
    refusal: dict | None = None
    note: str | None = None


def resolve_escalation(
    escalation: Escalation,
    *,
    env: Any,
    ask: Callable[[ActionRequest], Any] | None,
    tool: str,
    command: str,
    subject: str = "command",
) -> Resolution:
    """The fail-closed order before anything runs: a bad pairing refuses; a
    name the box does not withhold needs nothing; a wider name needs an
    approval channel and the user's explicit yes."""
    if escalation.error:
        return Resolution(refusal={"ok": False, "error": escalation.error})
    if not escalation.requested:
        return Resolution()
    current = withheld(env)
    wider = tuple(n for n in escalation.requested if n in current)
    if not wider:
        return Resolution(
            note="sandbox_permissions ignored: this sandbox does not withhold them, so the call ran as usual"
        )
    if not callable(getattr(env, "run_escalated", None)):
        return Resolution(
            refusal={"ok": False, "error": "sandbox escalation is not supported by this sandbox"}
        )
    if ask is None:
        return Resolution(
            refusal={
                "ok": False,
                "declined": True,
                "error": "sandbox escalation requires approval, but no approval channel is available; "
                "tell the user what you need instead",
            }
        )
    try:
        answer = ask(describe(tool, wider, escalation.justification, command))
    except Exception as exc:  # noqa: BLE001 — a gate failure is a denial
        return Resolution(
            refusal={"ok": False, "declined": True, "error": f"approval failed: {type(exc).__name__}"}
        )
    approved = answer.approved if isinstance(answer, ActionDecision) else answer is True
    if not approved:
        return Resolution(
            refusal={
                "ok": False,
                "declined": True,
                "action_class": SANDBOX_ESCALATION,
                "error": rejected_text(subject, wider),
            }
        )
    return Resolution(grant=wider)


def denial_fields(env: Any, ask: Callable[[ActionRequest], Any] | None, exit_code: Any, subject: str) -> dict:
    """The ``sandbox`` field of a failed call in a box that withholds
    something: the names plus the hint to escalate. Empty when the call
    succeeded, nothing is withheld, or nobody could approve."""
    if exit_code in (0, None) or not can_escalate(env, ask):
        return {}
    names = withheld(env)
    if not names:
        return {}
    return {"sandbox": {"withheld": list(names), "hint": hint(subject)}}


__all__ = [
    "ESCALATION_OPTIONS",
    "ESCALATION_TARGETS",
    "SANDBOX_ESCALATION",
    "SCHEMA_PROPERTIES",
    "Escalation",
    "Resolution",
    "can_escalate",
    "denial_fields",
    "describe",
    "hint",
    "parse_escalation",
    "rejected_text",
    "resolve_escalation",
    "withheld",
]
