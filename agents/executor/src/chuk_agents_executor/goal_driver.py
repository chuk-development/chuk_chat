"""The goal driver (docs/WIRE_CONTRACT.md, "Goal mode"; DeepSeek harness
``packages/goal/goal-round-driver``).

After every run of a session the executor asks the driver what follows. While
the session's goal is ``active`` and ``armed`` and the run ended naturally
(``finished``), the driver counts one more round and submits a
``<goal_round>`` task of the same session (origin ``goal``). It never starts
a round:

- while another run of the session is queued or in flight (the user's work
  goes first; that run's end asks again);
- for a goal that is disarmed: after a restart nothing is armed, so a goal
  never resumes on its own;
- past the cap: the goal then becomes ``blocked`` with code ``round-limit``.

A stopped goal round pauses the goal (the user's stop wins); any other run
that did not end naturally only disarms it.

The class talks to the executor through four methods (``submit_task``,
``has_live_run``, ``_persist_event``, ``live_request_id``), so the tests drive
it with a fake.
"""

from __future__ import annotations

import logging
import os
import threading
from typing import Any

from chuk_agents_runtime.goal import (
    PHASE_ACTIVE,
    GoalArming,
    admit_round,
    control_goal,
    goal_round_prompt,
    goal_view,
    interrupt_goal,
    load_goal,
)
from chuk_agents_runtime.state import StateStore

from .protocol import goal_payload

logger = logging.getLogger(__name__)

ORIGIN_GOAL = "goal"

#: Run ends that pause a goal round (the user's stop, the e-stop, the guard).
STOP_REASONS = frozenset({"interrupted", "estop", "timeout"})

#: The operator's default round cap (``AGENTS_GOAL_MAX_ROUNDS``).
ENV_MAX_ROUNDS = "AGENTS_GOAL_MAX_ROUNDS"


def default_max_rounds() -> int:
    from chuk_agents_runtime.goal import DEFAULT_MAX_ROUNDS, MAX_ROUNDS_LIMIT

    raw = os.environ.get(ENV_MAX_ROUNDS, "").strip()
    try:
        value = int(raw) if raw else DEFAULT_MAX_ROUNDS
    except ValueError:
        return DEFAULT_MAX_ROUNDS
    return max(1, min(MAX_ROUNDS_LIMIT, value))


class GoalDriver:
    def __init__(self, executor: Any, db_path: str, arming: GoalArming | None = None) -> None:
        self._executor = executor
        self._db_path = db_path
        self.arming = arming or GoalArming()
        self._lock = threading.Lock()
        self.rounds_submitted = 0

    # -- the store ------------------------------------------------------------

    def _store(self) -> StateStore:
        return StateStore(self._db_path)

    def view(self, session_key: str) -> dict | None:
        store = self._store()
        try:
            return goal_view(load_goal(store, session_key), self.arming, session_key)
        finally:
            store.close()

    def _announce(self, session_key: str, doc: dict | None) -> dict | None:
        """Persist a ``goal`` frame for a change made outside a run's stream
        (the replay carries it), and send it live when a run of the session
        has an open stream."""
        view = goal_view(doc, self.arming, session_key)
        payload = goal_payload(session_key, view)
        try:
            self._executor._persist_event(session_key, payload)
        except Exception:  # noqa: BLE001 — the frame is best effort
            pass
        try:
            request_id = self._executor.live_request_id(session_key)
            if request_id:
                self._executor._event(request_id, payload)
        except Exception:  # noqa: BLE001
            pass
        return view

    # -- after a run ------------------------------------------------------------

    def after_run(
        self,
        session_key: str,
        *,
        reason: str,
        origin: str,
        others_live: bool = False,
    ) -> dict | None:
        """What follows the end of one run. Returns the goal view for the
        ``done`` frame (with ``continues``), or ``None`` without a goal."""
        with self._lock:
            store = self._store()
            try:
                doc = load_goal(store, session_key)
                if not doc:
                    return None
                if reason != "finished":
                    changed = interrupt_goal(
                        store,
                        session_key,
                        self.arming,
                        pause=origin == ORIGIN_GOAL and reason in STOP_REASONS,
                    )
                    if changed is not None:
                        doc = load_goal(store, session_key)
                        view = self._announce(session_key, doc)
                    else:
                        view = goal_view(doc, self.arming, session_key)
                    return {**view, "continues": False} if view else None
                if doc.get("phase") != PHASE_ACTIVE or not self.arming.armed(
                    session_key, doc.get("id")
                ):
                    view = goal_view(doc, self.arming, session_key)
                    return {**view, "continues": False} if view else None
                if others_live:
                    # The user's queued work goes first; its end asks again.
                    view = goal_view(doc, self.arming, session_key)
                    return {**view, "continues": False, "waiting": True} if view else None
                kind, doc = admit_round(store, session_key, self.arming)
            finally:
                store.close()
            if kind == "limit":
                view = self._announce(session_key, doc)
                return {**view, "continues": False} if view else None
            if kind != "round" or doc is None:
                view = goal_view(doc, self.arming, session_key)
                return {**view, "continues": False} if view else None
            round_no = int(doc.get("rounds_started") or 0)
            prompt = goal_round_prompt(doc, round_no)
            try:
                run_id = self._executor.submit_task(
                    session_key,
                    prompt,
                    {"origin": ORIGIN_GOAL, "goal_id": doc.get("id"), "goal_round": round_no},
                )
            except Exception as exc:  # noqa: BLE001 — a host that cannot run disarms
                logger.info("goal round for %s not started: %s", session_key, type(exc).__name__)
                run_id = None
            if not run_id:
                self.arming.disarm(session_key)
                view = self._announce(session_key, doc)
                return {**view, "continues": False} if view else None
            self.rounds_submitted += 1
            view = goal_view(doc, self.arming, session_key)
            return {**view, "continues": True} if view else None

    # -- the user's control -------------------------------------------------------

    def control(self, session_key: str, action: str) -> tuple[dict | None, str | None]:
        """``goal_control`` from the app. A resume of an idle session starts
        the next round at once (nothing else would)."""
        if action not in ("pause", "resume", "clear"):
            return self.view(session_key), "action must be pause, resume or clear"
        with self._lock:
            store = self._store()
            try:
                doc, error = control_goal(store, session_key, self.arming, action)
            finally:
                store.close()
        if error is not None:
            return goal_view(doc, self.arming, session_key), error
        view = self._announce(session_key, doc)
        if action == "resume" and not self._executor.has_live_run(session_key):
            follow = self.after_run(session_key, reason="finished", origin="app")
            if follow is not None:
                view = follow
        return view, None
