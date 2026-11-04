"""Plan mode (DeepSeek harness idea 46, docs/WIRE_CONTRACT.md "Plan mode").

While plan mode is on, the agent explores and plans and does not change
anything. The rules reach the model as ONE appended context row per task
(``source: plan``), never as a change of the system prompt or of the tool
list: both stay the same bytes, so the provider's prefix cache survives a
switch into plan mode and out of it.

The agent ends plan mode itself with ``exit_plan_mode(plan)``: the executor
shows the plan as an ``approval_request`` with ``action: plan_review`` and
the options Approve / Keep planning. Approve turns plan mode off and the
agent carries the plan out; Keep planning returns the user's feedback as
the tool error, and the agent revises the plan and presents it again.

The state is per session and durable (``session_features``, kind ``plan``):
it is set by the ``plan`` flag of a ``task`` frame or a ``/plan`` prefix.
"""

from __future__ import annotations

import re
import time
from dataclasses import dataclass
from typing import Any, Callable, Protocol

from .registry import ToolRegistry
from .sources import SOURCE_PLAN
from .state import StateStore

FEATURE_KIND = "plan"
EXIT_PLAN_MODE = "exit_plan_mode"

#: The answers of the review card.
DECISION_APPROVE = "approve"
DECISION_KEEP_PLANNING = "keep_planning"
DECISION_TIMEOUT = "timeout"
DECISION_STOPPED = "stopped"

MAX_PLAN_CHARS = 60_000
MAX_FEEDBACK_CHARS = 4_000

#: The plan-mode rules, from the harness bundle (``cordis.patch.yml``, the
#: ``plan-mode`` section), with this runtime's tool names.
PLAN_RULES = (
    "[plan mode] You are in plan mode. Stay in plan mode until the user approves your plan "
    "through exit_plan_mode or switches plan mode off. Imperative language to implement "
    "changes means plan the implementation, not execute it. A user's conversational "
    "agreement, including an answer confirming something you asked, approves nothing and "
    "does not end plan mode; fold the confirmed decision into the plan and submit it through "
    "exit_plan_mode.\n\n"
    "Explore first. Use non-mutating reads, searches, static analysis, and checks to ground "
    "the plan in the actual repository. Do not edit or write files, change configuration, "
    "run formatters or code generation that rewrites tracked files, commit, or otherwise "
    "carry out the plan. Prefer existing functions and patterns over new machinery.\n\n"
    "The tool catalog stays the same across modes for request-cache stability. These "
    "plan-mode rules override any later tool description or guidance that suggests using "
    "mutation tools; those tools remain listed only to keep the request shape stable. Do not "
    "use todo_write to track this planning phase: it tracks implementation after an approved "
    "plan, while the plan itself belongs in exit_plan_mode.\n\n"
    "Resolve discoverable facts by inspection. Use ask_user only for user-owned choices or "
    "material ambiguity that inspection cannot answer. Do not ask the user where code lives "
    "or how current behavior works when you can find out.\n\n"
    "Make the plan decision-complete: state the goal and success criteria; group "
    "implementation changes by subsystem; identify public API, schema, and data-flow "
    "changes; cover edge cases, failure modes, tests, acceptance criteria, and explicit "
    "assumptions. Keep it concise enough to review but detailed enough that another "
    "engineer can implement it without making design decisions.\n\n"
    "When ready, call exit_plan_mode with the complete plan markdown, starting with a # "
    "title. Make exit_plan_mode the only and final tool call in that assistant response: it "
    "presents the plan for approval, and implementation begins only after approval. Do not "
    "paste the final plan as a plain reply or ask \"should I proceed?\" through prose or "
    "ask_user. If review rejects it, incorporate the feedback and present again. If the "
    "review channel is unavailable or aborted, stay in plan mode and ask the user to switch "
    "modes manually; do not proceed with implementation."
)

PLAN_PREFIX = "/plan"


def parse_plan_prefix(prompt: str) -> tuple[bool | None, str]:
    """``/plan <message>`` enters plan mode, ``/plan off <message>`` leaves
    it. Returns the switch (``None``: no prefix) and the prompt without it."""
    if not isinstance(prompt, str):
        return None, prompt
    match = re.match(r"^\s*/plan(?:\s+|$)", prompt)
    if match is None:
        return None, prompt
    rest = prompt[match.end():]
    off = re.match(r"^off(?:\s+|$)", rest)
    if off is not None:
        rest = rest[off.end():].strip()
        return False, rest or "Plan mode is off."
    rest = rest.strip()
    return True, rest or "Plan mode is on. Explore and plan; present the plan with exit_plan_mode."


def first_heading(plan: str) -> str:
    for line in plan.splitlines():
        match = re.match(r"^#{1,6}\s+(.+?)\s*$", line)
        if match:
            return match.group(1)[:200]
    return ""


class PlanState:
    """The durable plan-mode switch of one session."""

    def __init__(self, store: StateStore, session_key: str) -> None:
        self.store = store
        self.session_key = session_key

    def active(self) -> bool:
        doc = self.store.load_feature(self.session_key, FEATURE_KIND)
        return bool(doc and doc.get("active"))

    def set(self, active: bool) -> bool:
        """Switch; True when the state changed."""
        before = self.active()
        if before == bool(active):
            return False
        self.store.save_feature(
            self.session_key,
            FEATURE_KIND,
            {"active": bool(active), "updated_at": time.time()},
        )
        return True

    def task_context(self) -> list[dict]:
        """The once-per-task row while plan mode is on (a loop task context
        provider)."""
        if not self.active():
            return []
        return [
            {"role_tag": "context", "role": "user", "source": SOURCE_PLAN, "content": PLAN_RULES}
        ]


class PlanReviewBackend(Protocol):
    """The executor's half: show the plan, wait for the user's decision.
    Returns ``{"decision": approve|keep_planning|timeout|stopped,
    "feedback": str}``."""

    def review(self, plan: str, title: str) -> dict: ...


EXIT_PLAN_MODE_SCHEMA = {
    "type": "object",
    "description": (
        "Plan mode only: present the complete plan (markdown, starting with a # title) "
        "for the user's review. On approval plan mode ends and you carry the plan out; "
        "otherwise the user's feedback comes back as the error: revise and present again."
    ),
    "properties": {"plan": {"type": "string"}},
    "required": ["plan"],
}


@dataclass
class PlanMode:
    """Plan mode of ONE session for one run: the state and the review."""

    state: PlanState
    backend: PlanReviewBackend | None = None
    on_change: Callable[[bool], None] | None = None

    def exit(self, plan: Any) -> dict:
        if not self.state.active():
            return {"ok": False, "error": "plan mode is not on; there is nothing to exit"}
        text = plan.strip() if isinstance(plan, str) else ""
        if not text:
            return {"ok": False, "error": "plan must be the complete plan in markdown"}
        if len(text) > MAX_PLAN_CHARS:
            return {"ok": False, "error": f"plan is longer than {MAX_PLAN_CHARS} characters; shorten it"}
        if self.backend is None:
            return {
                "ok": False,
                "error": (
                    "the review channel is unavailable. Stay in plan mode and ask the user "
                    "to switch plan mode off; do not carry out the plan."
                ),
            }
        try:
            answer = self.backend.review(text, first_heading(text))
        except Exception:  # noqa: BLE001 — never hand raw exception text to the model
            answer = {"decision": DECISION_STOPPED}
        decision = answer.get("decision") if isinstance(answer, dict) else None
        if decision == DECISION_APPROVE:
            if self.state.set(False) and self.on_change is not None:
                try:
                    self.on_change(False)
                except Exception:  # noqa: BLE001
                    pass
            return {
                "ok": True,
                "approved": True,
                "note": "The user approved the plan. Plan mode is off: carry the plan out now.",
            }
        if decision == DECISION_KEEP_PLANNING:
            feedback = answer.get("feedback") if isinstance(answer, dict) else ""
            feedback = feedback.strip()[:MAX_FEEDBACK_CHARS] if isinstance(feedback, str) else ""
            if feedback:
                message = (
                    "The user wants to keep planning. Their feedback: "
                    f"{feedback}\nRevise the plan and present it again with exit_plan_mode."
                )
            else:
                message = (
                    "The user wants to keep planning and gave no feedback. Ask what to "
                    "change, or refine the plan and present it again."
                )
            return {"ok": False, "error": message}
        return {
            "ok": False,
            "error": (
                "No review arrived (the wait ended or the run is stopping). Stay in plan "
                "mode, say the plan is waiting for review, and do not carry it out."
            ),
        }


def register_plan_tool(registry: ToolRegistry, plan: PlanMode | None) -> None:
    """``exit_plan_mode``. Always registered when the executor binds plan
    mode, whatever the mode: the tool list must not change with it (cache).
    Deferred; the plan-mode rules name it, and a direct call still runs."""
    if plan is None:
        return
    mode = plan

    def exit_plan_mode(plan: Any = "") -> dict:
        return mode.exit(plan)

    registry.register(EXIT_PLAN_MODE, EXIT_PLAN_MODE_SCHEMA, exit_plan_mode, deferrable=True)
