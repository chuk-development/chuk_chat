"""Goal mode (DeepSeek harness idea 41, docs/WIRE_CONTRACT.md "Goal mode").

One durable completion objective per session. The model creates it with
``set_goal`` and changes it with ``update_goal`` (exact ``goal_id`` +
``revision``: compare-and-set, so a stale view never wins). While the goal
is **active** and **armed**, the executor's goal driver
(``chuk_agents_executor.goal_driver``) answers each natural ``done`` with one
more ``<goal_round>`` task of the same session, up to ``max_rounds``.

Two states, kept apart on purpose:

- **phase** (``active`` / ``paused`` / ``blocked`` / ``complete``) is durable:
  it is stored in ``session_features`` and survives a restart.
- **activation** (``armed`` / ``disarmed``) is process-local
  (:class:`GoalArming`). A restarted host starts with nothing armed, so a
  goal comes back DISARMED and never resumes on its own. The user resumes it
  (``goal_control`` from the app, or "continue" in a chat turn, which lets the
  model call ``update_goal`` with ``resume``).

``blocked`` is accepted in a goal round only after the SAME blocker was
reported in 3 consecutive rounds (:data:`BLOCKED_AFTER_ROUNDS`); difficulty
is not a blocker. When a goal round marks the goal ``complete`` or
``blocked``, the next model step gets a wrap-up note and no tools: one final
report with evidence, then the run ends.
"""

from __future__ import annotations

import json
import re
import threading
import time
import uuid
from dataclasses import dataclass, field
from typing import Any, Callable

from .registry import ToolRegistry
from .sources import SOURCE_GOAL
from .state import StateStore

FEATURE_KIND = "goal"

PHASE_ACTIVE = "active"
PHASE_PAUSED = "paused"
PHASE_BLOCKED = "blocked"
PHASE_COMPLETE = "complete"
PHASES = (PHASE_ACTIVE, PHASE_PAUSED, PHASE_BLOCKED, PHASE_COMPLETE)

ARMED = "armed"
DISARMED = "disarmed"

#: Rounds a goal may run when ``set_goal`` names no cap.
DEFAULT_MAX_ROUNDS = 50
#: The highest cap the model may ask for.
MAX_ROUNDS_LIMIT = 500
#: The same blocker in this many consecutive goal rounds before ``blocked``.
BLOCKED_AFTER_ROUNDS = 3
#: Two blocker texts are "the same" at this token overlap (Jaccard).
SAME_BLOCKER_OVERLAP = 0.6

MAX_OBJECTIVE_CHARS = 2_000
MAX_REASON_CHARS = 1_000

#: ``blocked_reason.code`` values.
BLOCK_MODEL = "model-reported"
BLOCK_ROUND_LIMIT = "round-limit"


def goal_round_prompt(goal: dict, round_no: int) -> str:
    """The follow-up task the driver submits after a natural ``done``."""
    return (
        "<goal_round>\n"
        f"Objective: {json.dumps(goal.get('objective', ''), ensure_ascii=False)}\n"
        f"Goal: id {goal.get('id')}, revision {goal.get('revision')}\n"
        f"Round: {round_no}/{goal.get('max_rounds')}\n\n"
        "Continue working toward the objective in this same session. Treat the current "
        "workspace, tool results, and durable session state as authoritative; inspect them "
        "instead of assuming earlier narration is still current. Make concrete progress and "
        "verify the result. Before claiming completion, gather evidence that the whole "
        "objective is achieved, then call update_goal with action complete. If work remains, "
        "leave the goal active for the next round. Use action blocked only when the same "
        f"concrete blocking condition has stopped you for {BLOCKED_AFTER_ROUNDS} rounds in a "
        "row; difficulty, uncertainty or remaining work is not blocked.\n"
        "</goal_round>"
    )


_GROUNDING = (
    "Report only what earlier rounds and tool results in this session actually establish; "
    "when a detail is not in the session, say so instead of inventing it. "
)


def wrapup_text(objective: str, blocked_reason: str | None = None) -> str:
    """The closing-message note after a goal round marked the goal complete
    or blocked. The step that follows has no tools."""
    heading = f"Objective: {json.dumps(objective, ensure_ascii=False)}\n"
    if blocked_reason is None:
        return (
            "<goal_complete>\n" + heading
            + "The goal is marked complete and this autonomous run is ending. Write the closing "
            "message to the user now: state the outcome, summarize what was done and how it was "
            "verified, and point to the concrete results (files, commits, or other artifacts). "
            + _GROUNDING
            + "Note anything the user should review or do next. Address the user directly. Do "
            "not call any more tools in this run; further work waits for the user's next "
            "instruction.\n</goal_complete>"
        )
    return (
        "<goal_blocked>\n" + heading
        + f"Blocked: {json.dumps(blocked_reason, ensure_ascii=False)}\n"
        "The goal is marked blocked and this autonomous run is ending. Write the closing "
        "message to the user now: state what has been completed so far, describe the concrete "
        "blocking condition and what you tried, and say exactly what you need from the user to "
        "continue. " + _GROUNDING
        + "Address the user directly. Do not call any more tools in this run; further work "
        "waits for the user's next instruction.\n</goal_blocked>"
    )


class GoalArming:
    """Which goals may continue on their own: process-local, never stored.

    One instance per executor process. A new process has none armed, which
    is the whole "after a restart a goal comes back disarmed" rule."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._armed: dict[str, str] = {}

    def arm(self, session_key: str, goal_id: str) -> None:
        with self._lock:
            self._armed[session_key] = goal_id

    def disarm(self, session_key: str) -> None:
        with self._lock:
            self._armed.pop(session_key, None)

    def armed(self, session_key: str, goal_id: str | None) -> bool:
        with self._lock:
            return bool(goal_id) and self._armed.get(session_key) == goal_id


def goal_view(doc: dict | None, arming: GoalArming | None, session_key: str) -> dict | None:
    """The wire shape of a goal (the ``goal`` frame's ``goal`` field)."""
    if not doc:
        return None
    armed = arming is not None and arming.armed(session_key, doc.get("id"))
    phase = doc.get("phase")
    view: dict[str, Any] = {
        "id": doc.get("id"),
        "revision": int(doc.get("revision") or 1),
        "objective": doc.get("objective") or "",
        "phase": phase,
        "activation": ARMED if armed and phase == PHASE_ACTIVE else DISARMED,
        "rounds_started": int(doc.get("rounds_started") or 0),
        "max_rounds": int(doc.get("max_rounds") or DEFAULT_MAX_ROUNDS),
        # The inbox's "needs you": the goal waits on the user.
        "needs_user": phase == PHASE_BLOCKED,
        "updated_at": doc.get("updated_at"),
    }
    if isinstance(doc.get("blocked_reason"), dict):
        view["blocked_reason"] = dict(doc["blocked_reason"])
    return view


def load_goal(store: StateStore, session_key: str) -> dict | None:
    return store.load_feature(session_key, FEATURE_KIND)


class GoalError(Exception):
    """A refused goal change; the text goes to the model as the tool error."""


def _words(text: str) -> set[str]:
    return set(re.findall(r"[a-z0-9]+", text.lower()))


def same_blocker(a: str, b: str) -> bool:
    """Whether two blocker reports name the same condition. Token overlap,
    so a reworded report of one condition still counts."""
    wa, wb = _words(a), _words(b)
    if not wa or not wb:
        return a.strip().lower() == b.strip().lower()
    return len(wa & wb) / len(wa | wb) >= SAME_BLOCKER_OVERLAP


def _clip(value: Any, limit: int) -> str:
    text = value.strip() if isinstance(value, str) else ""
    return text[:limit]


def _cap(value: Any) -> int | None:
    if value is None or value == "" or value == 0:
        return None
    try:
        cap = int(value)
    except (TypeError, ValueError):
        raise GoalError("max_rounds must be a whole number") from None
    if cap < 1 or cap > MAX_ROUNDS_LIMIT:
        raise GoalError(f"max_rounds must be between 1 and {MAX_ROUNDS_LIMIT}")
    return cap


@dataclass
class GoalController:
    """The goal of ONE session, as one run sees it.

    ``goal_round`` is the round number when this run IS a goal round (the
    driver started it), else ``None``. ``direct_user`` is True for a run the
    user started from the app: only such a run may pause or resume (the
    harness "direct human" rule). ``on_change`` gets the wire view after
    every stored change (the executor sends the ``goal`` frame)."""

    store: StateStore
    session_key: str
    arming: GoalArming
    goal_round: int | None = None
    direct_user: bool = True
    default_max_rounds: int = DEFAULT_MAX_ROUNDS
    blocked_after: int = BLOCKED_AFTER_ROUNDS
    on_change: Callable[[dict | None], None] | None = None
    _pending: list[dict] = field(default_factory=list)
    _lock: threading.Lock = field(default_factory=threading.Lock)

    # -- reads ---------------------------------------------------------------

    def current(self) -> dict | None:
        return load_goal(self.store, self.session_key)

    def view(self, doc: dict | None = None) -> dict | None:
        return goal_view(doc if doc is not None else self.current(), self.arming, self.session_key)

    # -- the context provider (wrap-up) --------------------------------------

    def pending_context(self) -> list[dict]:
        """The wrap-up row after a goal round marked complete / blocked. It
        asks the loop for one last step without tools (``final_step``)."""
        with self._lock:
            out, self._pending = self._pending, []
        return out

    def _queue_wrapup(self, doc: dict, blocked_reason: str | None) -> None:
        with self._lock:
            self._pending.append(
                {
                    "role_tag": "context",
                    "role": "user",
                    "source": SOURCE_GOAL,
                    "final_step": True,
                    "content": wrapup_text(doc.get("objective") or "", blocked_reason),
                }
            )

    def _changed(self, doc: dict | None) -> None:
        if self.on_change is None:
            return
        try:
            self.on_change(goal_view(doc, self.arming, self.session_key))
        except Exception:  # noqa: BLE001 — a UI sink never fails a goal change
            pass

    # -- writes --------------------------------------------------------------

    def create(self, objective: str, max_rounds: Any = None) -> dict:
        text = _clip(objective, MAX_OBJECTIVE_CHARS)
        if not text:
            raise GoalError("objective must be a non-empty description of the finished state")
        cap = _cap(max_rounds) or self.default_max_rounds
        now = time.time()

        def change(current: dict | None):
            if current and current.get("phase") in (PHASE_ACTIVE, PHASE_PAUSED):
                raise GoalError(
                    f"a goal already exists (id {current.get('id')}, revision "
                    f"{current.get('revision')}, phase {current.get('phase')}). Use "
                    "update_goal with action edit to change it, or complete it first."
                )
            doc = {
                "id": "g_" + uuid.uuid4().hex[:10],
                "revision": 1,
                "objective": text,
                "phase": PHASE_ACTIVE,
                "max_rounds": cap,
                "rounds_started": 0,
                "blocked_reason": None,
                "blocker": None,
                "created_at": now,
                "updated_at": now,
            }
            return doc, doc

        doc = self.store.update_feature(self.session_key, FEATURE_KIND, change)
        # A new goal is armed: the driver continues it after this run.
        self.arming.arm(self.session_key, doc["id"])
        self._changed(doc)
        return doc

    def update(
        self,
        goal_id: Any,
        revision: Any,
        action: str,
        *,
        objective: Any = None,
        max_rounds: Any = None,
        blocked_reason: Any = None,
    ) -> tuple[dict | None, str | None]:
        """Apply one ``update_goal``. Returns the stored document (``None``
        after ``clear``) and a note for the model, or raises
        :class:`GoalError`."""
        try:
            rev = int(revision)
        except (TypeError, ValueError):
            raise GoalError("revision must be the whole number get_goal returned") from None
        gid = goal_id.strip() if isinstance(goal_id, str) else ""
        if not gid or rev < 1:
            raise GoalError("goal_id must be non-empty and revision a positive number")
        action = (action or "").strip().lower()
        if action in ("pause", "resume") and not self.direct_user:
            raise GoalError(
                f"{action} needs a direct request from the user; it cannot happen in an "
                "automatic goal round"
            )
        reason = _clip(blocked_reason, MAX_REASON_CHARS)
        if action == "blocked" and not reason:
            raise GoalError("blocked_reason is required with action blocked")
        new_objective = _clip(objective, MAX_OBJECTIVE_CHARS)
        new_cap = _cap(max_rounds)
        note: dict[str, str | None] = {"text": None}

        def change(current: dict | None):
            if not current:
                raise GoalError("there is no goal; create one with set_goal")
            if current.get("id") != gid or int(current.get("revision") or 0) != rev:
                raise GoalError(
                    f"stale goal reference: the current goal is id {current.get('id')}, "
                    f"revision {current.get('revision')}, phase {current.get('phase')}. "
                    "Use those exact values."
                )
            doc = dict(current)
            phase = doc.get("phase")
            now = time.time()
            if action == "clear":
                return None, None
            if action == "edit":
                if not new_objective and new_cap is None:
                    raise GoalError("edit needs objective and/or max_rounds")
                if new_objective:
                    doc["objective"] = new_objective
                if new_cap is not None:
                    doc["max_rounds"] = new_cap
            elif action == "pause":
                if phase != PHASE_ACTIVE:
                    raise GoalError(f"only an active goal can be paused (phase {phase})")
                doc["phase"] = PHASE_PAUSED
            elif action == "resume":
                if phase == PHASE_COMPLETE:
                    raise GoalError("a complete goal cannot be resumed; set a new goal")
                if int(doc.get("rounds_started") or 0) >= int(doc.get("max_rounds") or 0):
                    raise GoalError(
                        f"the goal used all {doc.get('max_rounds')} rounds; raise max_rounds "
                        "with action edit first"
                    )
                doc["phase"] = PHASE_ACTIVE
                doc["blocked_reason"] = None
                doc["blocker"] = None
            elif action == "complete":
                if phase == PHASE_COMPLETE:
                    raise GoalError("the goal is already complete")
                doc["phase"] = PHASE_COMPLETE
                doc["blocked_reason"] = None
            elif action == "blocked":
                if phase != PHASE_ACTIVE:
                    raise GoalError(f"only an active goal can be blocked (phase {phase})")
                if self.goal_round is not None:
                    streak = self._streak(doc.get("blocker"), reason)
                    doc["blocker"] = {"text": reason, "round": self.goal_round, "streak": streak}
                    if streak < self.blocked_after:
                        # Not a lifecycle change: the revision stays.
                        doc["updated_at"] = now
                        note["text"] = (
                            f"Not blocked yet: this blocker was reported in {streak} of "
                            f"{self.blocked_after} consecutive goal rounds. The goal stays "
                            "active. Try a different approach in this round; report blocked "
                            "again only if the same condition still stops you next round."
                        )
                        return doc, doc
                doc["phase"] = PHASE_BLOCKED
                doc["blocked_reason"] = {"code": BLOCK_MODEL, "message": reason}
            else:
                raise GoalError(
                    "action must be one of: edit, pause, resume, complete, blocked, clear"
                )
            doc["revision"] = rev + 1
            doc["updated_at"] = now
            return doc, doc

        doc = self.store.update_feature(self.session_key, FEATURE_KIND, change)
        if note["text"] is not None:
            return doc, note["text"]
        if doc is None:
            self.arming.disarm(self.session_key)
            self._changed(None)
            return None, "The goal is cleared."
        if action == "resume" or (action == "edit" and doc["phase"] == PHASE_ACTIVE
                                  and self.arming.armed(self.session_key, doc["id"])):
            self.arming.arm(self.session_key, doc["id"])
        if doc["phase"] != PHASE_ACTIVE:
            self.arming.disarm(self.session_key)
        if action in ("complete", "blocked") and self.goal_round is not None:
            self._queue_wrapup(doc, reason if action == "blocked" else None)
        self._changed(doc)
        return doc, None

    def _streak(self, previous: Any, reason: str) -> int:
        if not isinstance(previous, dict) or self.goal_round is None:
            return 1
        prev_round = previous.get("round")
        if not same_blocker(str(previous.get("text") or ""), reason):
            return 1
        if prev_round == self.goal_round:
            return int(previous.get("streak") or 1)
        if prev_round == self.goal_round - 1:
            return int(previous.get("streak") or 1) + 1
        return 1


# -- the tools -----------------------------------------------------------------

SET_GOAL_SCHEMA = {
    "type": "object",
    "description": (
        "Set a durable goal that keeps this session working across automatic "
        "rounds until it is achieved. Use it when the user asks for a long-running "
        "objective; not for single-turn work."
    ),
    "properties": {
        "objective": {"type": "string", "description": "The concrete finished state."},
        "max_rounds": {"type": "integer", "description": "Round cap (default 50)."},
    },
    "required": ["objective"],
}

UPDATE_GOAL_SCHEMA = {
    "type": "object",
    "description": (
        "Change the goal. Needs the exact goal_id and revision. complete: only with "
        "evidence the whole objective is done. blocked: only after the same blocker "
        "stopped 3 rounds in a row. pause/resume: only when the user asks."
    ),
    "properties": {
        "goal_id": {"type": "string"},
        "revision": {"type": "integer"},
        "action": {
            "type": "string",
            "enum": ["edit", "pause", "resume", "complete", "blocked", "clear"],
        },
        "objective": {"type": "string", "description": "New objective (edit)."},
        "max_rounds": {"type": "integer", "description": "New cap (edit)."},
        "blocked_reason": {"type": "string", "description": "The blocker (blocked)."},
    },
    "required": ["goal_id", "revision", "action"],
}

GET_GOAL_SCHEMA = {
    "type": "object",
    "description": "Read the current goal with the id and revision update_goal needs.",
    "properties": {},
}


def _result(controller: GoalController, doc: dict | None, note: str | None = None) -> dict:
    out: dict[str, Any] = {"ok": True, "goal": controller.view(doc) if doc else None}
    if note:
        out["note"] = note
    return out


def register_goal_tools(registry: ToolRegistry, controller: GoalController | None) -> None:
    """``set_goal`` / ``update_goal`` / ``get_goal`` for one session.
    Deferred behind ``search_tools`` (the prompt budget); a direct call by
    exact name still runs. ``None`` registers nothing."""
    if controller is None:
        return

    def set_goal(objective: str = "", max_rounds: Any = None) -> dict:
        try:
            doc = controller.create(objective, max_rounds)
        except GoalError as exc:
            return {"ok": False, "error": str(exc)}
        return _result(
            controller,
            doc,
            "Goal set. Work toward it now; after this turn the session continues in "
            "automatic goal rounds until you mark it complete.",
        )

    def update_goal(
        goal_id: str = "",
        revision: Any = None,
        action: str = "",
        objective: Any = None,
        max_rounds: Any = None,
        blocked_reason: Any = None,
    ) -> dict:
        try:
            doc, note = controller.update(
                goal_id,
                revision,
                action,
                objective=objective,
                max_rounds=max_rounds,
                blocked_reason=blocked_reason,
            )
        except GoalError as exc:
            return {"ok": False, "error": str(exc)}
        if note and doc is not None and doc.get("phase") == PHASE_ACTIVE and action == "blocked":
            return {"ok": False, "error": note, "goal": controller.view(doc)}
        return _result(controller, doc, note)

    def get_goal() -> dict:
        return {"ok": True, "goal": controller.view()}

    registry.register("set_goal", SET_GOAL_SCHEMA, set_goal, deferrable=True)
    registry.register("update_goal", UPDATE_GOAL_SCHEMA, update_goal, deferrable=True)
    registry.register("get_goal", GET_GOAL_SCHEMA, get_goal, deferrable=True)


# -- the driver's half: one round, a round limit ---------------------------------


def admit_round(store: StateStore, session_key: str, arming: GoalArming) -> tuple[str, dict | None]:
    """Decide what follows a natural ``done`` of ``session_key``.

    Returns ``("round", goal)`` with ``rounds_started`` already counted (the
    caller submits :func:`goal_round_prompt`), ``("limit", goal)`` when the
    cap is used up (the goal is now ``blocked`` with ``round-limit``), or
    ``("none", goal)`` when nothing continues (no goal, not active, not
    armed)."""
    outcome: dict[str, str] = {"kind": "none"}

    def change(current: dict | None):
        if not current or current.get("phase") != PHASE_ACTIVE:
            return current, current
        if not arming.armed(session_key, current.get("id")):
            return current, current
        doc = dict(current)
        cap = int(doc.get("max_rounds") or DEFAULT_MAX_ROUNDS)
        started = int(doc.get("rounds_started") or 0)
        now = time.time()
        if started >= cap:
            doc["phase"] = PHASE_BLOCKED
            doc["blocked_reason"] = {
                "code": BLOCK_ROUND_LIMIT,
                "message": f"The goal used all {cap} rounds without being completed.",
            }
            doc["revision"] = int(doc.get("revision") or 1) + 1
            doc["updated_at"] = now
            outcome["kind"] = "limit"
            return doc, doc
        doc["rounds_started"] = started + 1
        doc["updated_at"] = now
        outcome["kind"] = "round"
        return doc, doc

    doc = store.update_feature(session_key, FEATURE_KIND, change)
    if outcome["kind"] == "limit":
        arming.disarm(session_key)
    return outcome["kind"], doc


def interrupt_goal(
    store: StateStore, session_key: str, arming: GoalArming, *, pause: bool
) -> dict | None:
    """A goal round was stopped (``pause=True``: the goal is paused, the
    user's stop wins) or the run ended some other way (only disarmed).
    Returns the changed document, or ``None`` when nothing changed."""
    doc = load_goal(store, session_key)
    if not doc or doc.get("phase") != PHASE_ACTIVE:
        return None
    was_armed = arming.armed(session_key, doc.get("id"))
    arming.disarm(session_key)
    if not pause:
        return doc if was_armed else None

    def change(current: dict | None):
        if not current or current.get("phase") != PHASE_ACTIVE:
            return current, None
        new = dict(current)
        new["phase"] = PHASE_PAUSED
        new["revision"] = int(new.get("revision") or 1) + 1
        new["updated_at"] = time.time()
        return new, new

    return store.update_feature(session_key, FEATURE_KIND, change)


def control_goal(
    store: StateStore, session_key: str, arming: GoalArming, action: str
) -> tuple[dict | None, str | None]:
    """The user's ``goal_control`` from the app: ``pause`` / ``resume`` /
    ``clear``. Returns the goal after the change and an error text."""
    doc = load_goal(store, session_key)
    if not doc:
        return None, "no goal"
    controller = GoalController(store=store, session_key=session_key, arming=arming)
    if action == "resume" and doc.get("phase") == PHASE_ACTIVE:
        # Active but disarmed (after a restart): only arm it.
        arming.arm(session_key, doc["id"])
        return doc, None
    try:
        new, _note = controller.update(doc.get("id"), doc.get("revision"), action)
    except GoalError as exc:
        return doc, str(exc)
    return new, None
