"""The agent loop (§7.1).

- Continue-vs-finish is **structural**: a model turn with tool calls executes
  the tools and continues; a bare-text turn is the final answer and stops. No
  text-pattern heuristics.
- **Dual-counter termination**: a hard ``max_iterations`` ceiling plus a
  refundable :class:`IterationBudget`. Housekeeping rounds ``.refund()`` so they
  don't burn the model's real thinking budget while termination stays
  guaranteed.
- **Two-tier kill switch**: a file-sentinel ESTOP that pauses new work (a stat
  error counts as engaged) plus a thread-flag interrupt polled at the loop top.
"""

from __future__ import annotations

import os
import threading
from dataclasses import dataclass
from enum import Enum

from .model import ModelClient, ModelResponse
from .registry import ToolRegistry
from .state import StateStore


class IterationBudget:
    """A refundable counter. ``consume`` on each real round, ``refund`` on a
    housekeeping round. Independent of the hard ``max_iterations`` ceiling, so
    termination stays guaranteed even with unlimited refunds capped at the
    initial budget."""

    def __init__(self, budget: int) -> None:
        if budget < 0:
            raise ValueError("budget must be >= 0")
        self._initial = budget
        self._remaining = budget

    def consume(self) -> None:
        self._remaining -= 1

    def refund(self) -> None:
        # Never refund above the starting budget — a refund gives a round back,
        # it does not mint new budget.
        self._remaining = min(self._remaining + 1, self._initial)

    @property
    def remaining(self) -> int:
        return self._remaining

    @property
    def initial(self) -> int:
        return self._initial

    def exhausted(self) -> bool:
        return self._remaining <= 0


class KillSwitch:
    """Two-tier stop. The file-sentinel ESTOP pauses *new* work; the thread flag
    cancels the loop at the next top-of-loop poll."""

    def __init__(self, estop_path: str | os.PathLike | None = None) -> None:
        self._estop_path = os.fspath(estop_path) if estop_path is not None else None
        self._interrupt = threading.Event()

    # thread-flag interrupt
    def interrupt(self) -> None:
        self._interrupt.set()

    def clear_interrupt(self) -> None:
        self._interrupt.clear()

    def interrupted(self) -> bool:
        return self._interrupt.is_set()

    # file-sentinel ESTOP — fail-safe: a stat error is treated as engaged.
    def estop_engaged(self) -> bool:
        if self._estop_path is None:
            return False
        try:
            os.stat(self._estop_path)
            return True  # the sentinel exists -> engaged
        except FileNotFoundError:
            return False
        except OSError:
            return True  # any other stat failure -> fail safe, engaged


class StopReason(str, Enum):
    FINISHED = "finished"
    MAX_ITERATIONS = "max_iterations"
    BUDGET_EXHAUSTED = "budget_exhausted"
    ESTOP = "estop"
    INTERRUPTED = "interrupted"


@dataclass
class LoopResult:
    reason: StopReason
    final_answer: str | None
    iterations: int
    session_id: int


def _to_model_messages(store: StateStore, session_id: int) -> list[dict]:
    """Rebuild the OpenAI-style message list from stored rows."""
    return [m.content for m in store.get_conversation(session_id)]


class AgentLoop:
    def __init__(
        self,
        model: ModelClient,
        registry: ToolRegistry,
        store: StateStore,
        *,
        max_iterations: int = 50,
        budget: IterationBudget | None = None,
        kill_switch: KillSwitch | None = None,
        system_prompt: str | None = None,
    ) -> None:
        self._model = model
        self._registry = registry
        self._store = store
        self._max_iterations = max_iterations
        self._budget = budget or IterationBudget(max_iterations)
        self._kill = kill_switch or KillSwitch()
        self._system_prompt = system_prompt

    @property
    def budget(self) -> IterationBudget:
        return self._budget

    @property
    def kill_switch(self) -> KillSwitch:
        return self._kill

    def run(self, session_key: str, user_message: str) -> LoopResult:
        store = self._store
        session_id = store.route(session_key)

        # Seed the system prompt once per fresh session.
        conversation = store.get_conversation(session_id)
        if self._system_prompt and not any(
            m.content.get("role") == "system" for m in conversation
        ):
            store.append_message(
                session_id, "system", {"role": "system", "content": self._system_prompt}
            )

        store.append_message(
            session_id, "user", {"role": "user", "content": user_message}
        )

        iterations = 0
        final_answer: str | None = None
        reason = StopReason.FINISHED

        while True:
            # -- top-of-loop kill poll --------------------------------
            if self._kill.interrupted():
                reason = StopReason.INTERRUPTED
                break
            if self._kill.estop_engaged():
                reason = StopReason.ESTOP
                break
            # -- dual-counter termination -----------------------------
            if iterations >= self._max_iterations:
                reason = StopReason.MAX_ITERATIONS
                break
            if self._budget.exhausted():
                reason = StopReason.BUDGET_EXHAUSTED
                break

            iterations += 1
            self._budget.consume()

            response: ModelResponse = self._model.complete(
                _to_model_messages(store, session_id)
            )

            # A housekeeping/preflight round is refunded so it does not eat the
            # model's real thinking budget (§7.1).
            if response.housekeeping:
                self._budget.refund()

            self._persist_assistant(session_id, response)

            # -- structural continue-vs-finish ------------------------
            if response.has_tool_calls:
                for call in response.tool_calls:
                    result = self._registry.dispatch(call.name, call.arguments)
                    store.append_message(
                        session_id,
                        "tool",
                        {
                            "role": "tool",
                            "tool_call_id": call.id,
                            "name": call.name,
                            "content": result,
                        },
                    )
                continue  # tool calls -> feed results back, loop again

            # bare text -> final answer, stop
            final_answer = response.text
            reason = StopReason.FINISHED
            break

        return LoopResult(
            reason=reason,
            final_answer=final_answer,
            iterations=iterations,
            session_id=session_id,
        )

    def _persist_assistant(self, session_id: int, response: ModelResponse) -> None:
        content: dict = {"role": "assistant"}
        if response.text is not None:
            content["content"] = response.text
        if response.has_tool_calls:
            content["tool_calls"] = [
                {
                    "id": c.id,
                    "type": "function",
                    "function": {"name": c.name, "arguments": c.arguments},
                }
                for c in response.tool_calls
            ]
        self._store.append_message(session_id, "assistant", content)
