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
- **The system prompt freezes once per session** (§12). It may be passed as a
  callable, which is resolved when a session is seeded and never again — so a
  mid-session memory write reaches disk but not the prompt, and the prefix cache
  holds for the whole run (§7.9). The next session resolves it afresh.
- **Context providers** append messages after a tool round — the seam a skill
  body uses to enter the conversation without touching the system prompt (§11).
- **Context ladder** (§7.3): the stored history is the source of truth, but what
  goes on the wire passes through :class:`~cowork_agent.context.ContextLadder`
  first — stale reasoning stripped, then dedup/truncate and (under real pressure,
  with an aux model configured) a summary of the middle.
"""

from __future__ import annotations

import os
import threading
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from enum import Enum

from .context import ContextLadder
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
        system_prompt: str | Callable[[], str] | None = None,
        context_providers: Sequence[Callable[[], list[dict]]] | None = None,
        context_ladder: ContextLadder | None = None,
    ) -> None:
        self._model = model
        self._registry = registry
        self._store = store
        self._max_iterations = max_iterations
        self._budget = budget or IterationBudget(max_iterations)
        self._kill = kill_switch or KillSwitch()
        self._system_prompt = system_prompt
        self._context_providers = list(context_providers or [])
        self._ladder = context_ladder

    @property
    def budget(self) -> IterationBudget:
        return self._budget

    @property
    def kill_switch(self) -> KillSwitch:
        return self._kill

    @property
    def registry(self) -> ToolRegistry:
        return self._registry

    @property
    def store(self) -> StateStore:
        return self._store

    @property
    def context_ladder(self) -> ContextLadder | None:
        return self._ladder

    def _outbound_messages(self, session_id: int) -> list[dict]:
        """The payload for one model call: the full stored history, run through
        the context ladder. Without a ladder this is the history verbatim."""
        messages = _to_model_messages(self._store, session_id)
        if self._ladder is None:
            return messages
        return self._ladder.prepare(messages)

    def run(self, session_key: str, user_message: str) -> LoopResult:
        store = self._store
        session_id = store.route(session_key)

        # Seed the system prompt once per fresh session. A callable is resolved
        # HERE and only here: that single read is what freezes the memory
        # snapshot for the session (§12).
        conversation = store.get_conversation(session_id)
        if self._system_prompt and not any(
            m.content.get("role") == "system" for m in conversation
        ):
            prompt = self._system_prompt
            resolved = prompt() if callable(prompt) else prompt
            if resolved:
                store.append_message(
                    session_id, "system", {"role": "system", "content": resolved}
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
                self._outbound_messages(session_id)
            )

            # Real prompt_tokens calibrate the ladder's estimator (§7.3). Only
            # prompt tokens are read — reasoning tokens must not move pressure.
            if self._ladder is not None:
                self._ladder.record_usage(response.raw.get("usage"))

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
                self._drain_context(session_id)
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

    def _drain_context(self, session_id: int) -> None:
        """Append whatever a tool asked to add to the conversation — today, a
        skill body (§11). The row role records where it came from; the wire role
        inside the content stays a normal turn, because a mid-conversation
        system message would overwrite the frozen system prompt."""
        for provider in self._context_providers:
            for message in provider():
                self._store.append_message(
                    session_id, message.get("role_tag", "context"),
                    {k: v for k, v in message.items() if k != "role_tag"},
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
