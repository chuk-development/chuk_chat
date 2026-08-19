"""The agent loop (§7.1).

- Continue-vs-finish is **structural**: a model turn with tool calls executes
  the tools and continues; a bare-text turn is the final answer and stops. No
  text-pattern heuristics.
- **Dual-counter termination**: a hard ``max_iterations`` ceiling plus a
  refundable :class:`IterationBudget`. Housekeeping rounds ``.refund()`` so they
  don't burn the model's real thinking budget while termination stays
  guaranteed.
- **Two-tier kill switch**: a file-sentinel ESTOP that pauses new work (a stat
  error counts as engaged) plus a thread-flag interrupt. The interrupt is polled
  at the loop top, again after the model turn returns, and again before each
  tool call of a multi-call turn — and it also *notifies* registered cancellers
  (:meth:`KillSwitch.on_interrupt`), which is how the work already in flight (a
  running command, a whole subagent tree) is aborted instead of waited out.
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

from .context import ContextLadder, total_tokens_from_usage
from .model import ModelClient, ModelResponse
from .registry import ToolRegistry
from .state import StateStore


#: Stands in for a tool result the run was stopped before reaching. The row has
#: to exist — an assistant turn whose tool call has no result is a malformed
#: conversation for the next session that reads it.
INTERRUPTED_TOOL_RESULT = "not run: the run was stopped before this tool started"


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
    cancels the loop at the next top-of-loop poll.

    The thread flag is also **observable**: :meth:`on_interrupt` registers a
    cancel action that runs the moment :meth:`interrupt` fires. Polling alone
    only ends the loop *between* rounds, so a run sitting in a ten-minute
    ``run_command`` would keep the user waiting; a listener is what lets the
    executor kill the process in flight and what makes one Stop reach a whole
    subagent tree at once (§7.6) instead of one level per unwind.

    The file-sentinel ESTOP has no listener by nature — nobody signals a file —
    so it is only seen by the polls. That is the documented difference between
    the two tiers: ESTOP pauses new work, the interrupt cancels work in flight.

    **ESTOP without the app** (the second way to stop a run, §7.1): create the
    sentinel file the executor was started with, e.g.
    ``touch ~/.cowork/ESTOP``. Every loop in this process — the parent run and
    every subagent — stops at its next top-of-loop poll and reports
    ``StopReason.ESTOP``. Delete the file to allow new work again. It needs no
    phone, no relay and no network: a shell on the machine is enough.
    """

    def __init__(self, estop_path: str | os.PathLike | None = None) -> None:
        self._estop_path = os.fspath(estop_path) if estop_path is not None else None
        self._interrupt = threading.Event()
        self._lock = threading.Lock()
        self._listeners: list[Callable[[], None]] = []

    @property
    def estop_path(self) -> str | None:
        return self._estop_path

    # thread-flag interrupt
    def interrupt(self) -> None:
        """Set the flag and run every registered cancel action, once.

        Listeners run on the calling thread — the one that pressed Stop — so the
        cancel has already happened by the time this returns. A listener that
        raises is swallowed: one broken canceller must not stop the others from
        running, and the flag is set either way.
        """
        with self._lock:
            if self._interrupt.is_set():
                return  # already stopping; never fire the listeners twice
            self._interrupt.set()
            listeners = list(self._listeners)
        for listener in listeners:
            _fire(listener)

    def on_interrupt(self, listener: Callable[[], None]) -> None:
        """Register a cancel action for :meth:`interrupt`.

        Registering after the interrupt already fired runs the listener
        immediately — otherwise a child whose runtime was built one instant too
        late would quietly keep running.
        """
        with self._lock:
            already = self._interrupt.is_set()
            if not already:
                self._listeners.append(listener)
        if already:
            _fire(listener)

    def clear_interrupt(self) -> None:
        with self._lock:
            self._interrupt.clear()

    def interrupted(self) -> bool:
        return self._interrupt.is_set()

    def wait_interrupted(self, timeout: float | None = None) -> bool:
        """Block until the interrupt fires. Returns False on timeout."""
        return self._interrupt.wait(timeout)

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


def _fire(listener: Callable[[], None]) -> None:
    try:
        listener()
    except Exception:  # noqa: BLE001 — a broken canceller cannot block the stop
        return


class StopReason(str, Enum):
    FINISHED = "finished"
    MAX_ITERATIONS = "max_iterations"
    BUDGET_EXHAUSTED = "budget_exhausted"
    #: A cumulative *token* spend cap was reached — used to bound a subagent's
    #: cost (§7.6). Distinct from BUDGET_EXHAUSTED, which counts iterations.
    TOKEN_BUDGET_EXHAUSTED = "token_budget_exhausted"
    ESTOP = "estop"
    INTERRUPTED = "interrupted"


@dataclass
class LoopResult:
    reason: StopReason
    final_answer: str | None
    iterations: int
    session_id: int
    #: Total tokens (prompt + completion) the run spent, as reported by the
    #: backend usage frames. Zero when the backend sent no usage. Lets a parent
    #: and the app see what a child cost (§7.6).
    tokens_spent: int = 0


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
        token_budget: int | None = None,
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
        if token_budget is not None and token_budget < 0:
            raise ValueError("token_budget must be >= 0")
        self._token_budget = token_budget
        self._tokens_spent = 0
        self._kill = kill_switch or KillSwitch()
        self._system_prompt = system_prompt
        self._context_providers = list(context_providers or [])
        self._ladder = context_ladder

    @property
    def budget(self) -> IterationBudget:
        return self._budget

    @property
    def tokens_spent(self) -> int:
        return self._tokens_spent

    @property
    def token_budget(self) -> int | None:
        return self._token_budget

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
            # A spend cap stops the run *before* the next model call, so the
            # overshoot is at most the one round that crossed the line — never a
            # further expensive turn. Checked here, accumulated after each
            # response below.
            if (
                self._token_budget is not None
                and self._tokens_spent >= self._token_budget
            ):
                reason = StopReason.TOKEN_BUDGET_EXHAUSTED
                break

            iterations += 1
            self._budget.consume()

            try:
                response: ModelResponse = self._model.complete(
                    self._outbound_messages(session_id)
                )
            except Exception:
                # A model call that dies *while we are interrupting* died because
                # of the interrupt: a cancelled socket, a closed stream. Report
                # the stop, not a crash. Any other failure is a real error and
                # still propagates.
                if self._kill.interrupted():
                    reason = StopReason.INTERRUPTED
                    break
                raise

            # Real prompt_tokens calibrate the ladder's estimator (§7.3). Only
            # prompt tokens are read — reasoning tokens must not move pressure.
            usage = response.raw.get("usage")
            if self._ladder is not None:
                self._ladder.record_usage(usage)
            # Spend accounting (§7.6): prompt + completion, for the token budget.
            # A housekeeping round still cost tokens, so it counts here even
            # though it is refunded against the iteration budget above.
            self._tokens_spent += total_tokens_from_usage(usage)

            # A housekeeping/preflight round is refunded so it does not eat the
            # model's real thinking budget (§7.1).
            if response.housekeeping:
                self._budget.refund()

            self._persist_assistant(session_id, response)

            # The interrupt may have landed while the model was working. It wins
            # here rather than one round later: a run the user stopped must not
            # report "finished" just because the turn in flight happened to be
            # the last one. The turn itself is kept — it is real history.
            if self._kill.interrupted():
                reason = StopReason.INTERRUPTED
                break

            # -- structural continue-vs-finish ------------------------
            if response.has_tool_calls:
                for call in response.tool_calls:
                    # One turn can carry several tool calls, and each one can be
                    # a long command. Stop between them too, or a Stop would wait
                    # out the whole batch. Every call still gets a result row, so
                    # a resumed session has no assistant turn with a dangling
                    # tool call in it.
                    if self._kill.interrupted():
                        result: object = INTERRUPTED_TOOL_RESULT
                    else:
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
                if self._kill.interrupted():
                    reason = StopReason.INTERRUPTED
                    break
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
            tokens_spent=self._tokens_spent,
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
