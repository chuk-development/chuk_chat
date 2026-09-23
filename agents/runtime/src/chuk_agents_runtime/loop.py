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
  goes on the wire passes through :class:`~chuk_agents_runtime.context.ContextLadder`
  first — stale reasoning stripped, then dedup/truncate and (under real pressure,
  with an aux model configured) a summary of the middle.
"""

from __future__ import annotations

import json
import os
import threading
import time
from collections.abc import Callable, Sequence
from dataclasses import dataclass, field
from enum import Enum

from .context import (
    ContextLadder,
    estimate_message_tokens,
    estimate_tokens,
    total_tokens_from_usage,
)
from .model import ModelClient, ModelResponse, ToolCall
from .registry import ToolRegistry
from .state import StateStore
from .tool_events import tool_event_fields
from .tools import FINISH_TOOL
from .trace import get_tracer, set_round


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
    ``touch ~/.agents/ESTOP``. Every loop in this process — the parent run and
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


@dataclass(frozen=True)
class TurnRecord:
    """What the turn observer gets once per finished task (§12 memory): the
    prompt, the outcome and which tools ran. No transcript — the observer reads
    the store if it needs more."""

    session_key: str
    session_id: int
    user_message: str
    final_answer: str | None
    reason: StopReason
    tool_names: tuple[str, ...] = ()


@dataclass
class RunTimings:
    """Where a run's wall clock went, in milliseconds.

    This is the answer to "the turn took four minutes, which part?" and it is
    recorded on the ``runs`` row, so a slow run can be diagnosed afterwards
    without reconstructing timestamps from ``messages.created_at`` by hand.

    The buckets do not have to add up to the run's wall time — a run also waits
    on things nobody times — but every bucket that IS timed is here.
    """

    #: Number of model calls (``ModelClient.complete``) the run made.
    model_calls: int = 0
    #: Total time inside those calls, retries included.
    model_wait_ms: float = 0.0
    #: Total time building the outbound payload: history read + context ladder,
    #: including a tier-2/3 aux-model summarisation, which is itself a model
    #: call and is one of the two things that can hide inside a long turn.
    prepare_ms: float = 0.0
    #: Total time inside tool dispatch.
    tool_ms: float = 0.0
    #: Total time the memory recall spent before the first round.
    recall_ms: float = 0.0
    #: Model attempts that were thrown away and asked again. Each one was paid
    #: for at the provider, so this is a cost figure, not only a latency one.
    retries: int = 0
    #: Time burned by those dead attempts.
    retry_ms: float = 0.0

    def as_row(self) -> dict[str, int]:
        """Integer milliseconds for the ``runs`` row."""
        return {
            "model_calls": int(self.model_calls),
            "model_wait_ms": int(self.model_wait_ms),
            "prepare_ms": int(self.prepare_ms),
            "tool_ms": int(self.tool_ms),
            "recall_ms": int(self.recall_ms),
            "retries": int(self.retries),
            "retry_ms": int(self.retry_ms),
        }


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
    #: Where the wall clock went (§ run record). Always present; all zeros for a
    #: run that made no model call.
    timings: RunTimings = field(default_factory=RunTimings)


def _tool_schema_tokens(tools: object) -> int:
    """Roughly what the ``tools`` array costs on every single request. It rides
    on each call, so a bloated tool set is a per-round tax and belongs in the
    trace next to the prompt estimate."""
    if not tools:
        return 0
    try:
        return estimate_tokens(json.dumps(tools, default=str))
    except (TypeError, ValueError):
        return 0


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
        system_prompt_upgrade: Callable[[str], str] | None = None,
        context_providers: Sequence[Callable[[], list[dict]]] | None = None,
        context_ladder: ContextLadder | None = None,
        debug_observer: Callable[[dict], None] | None = None,
        tool_event_observer: Callable[[dict], None] | None = None,
        persist_filter: Callable[[dict], dict] | None = None,
        recall_provider: Callable[[str], list[dict]] | None = None,
        turn_observer: Callable[[TurnRecord], None] | None = None,
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
        self._system_prompt_upgrade = system_prompt_upgrade
        self._context_providers = list(context_providers or [])
        self._ladder = context_ladder
        # Optional debug tap (a UI "copy raw context" feature). Fired once per
        # model round with the EXACT outbound message list and the ladder's stats,
        # so the app can show what really went on the wire. ``None`` -> not built,
        # not called: zero overhead on a normal run.
        self._debug_observer = debug_observer
        # The ONE source of live ``tool`` events (docs/WIRE_CONTRACT.md, "Tool
        # events and timestamps"): fired once per native tool call, after its
        # result is known, with the fields of :func:`tool_event_fields`. The
        # environment's shell hook is NOT a tool event any more — a
        # ``write_file`` is one card, not the printf/base64 helper commands it
        # runs. ``None`` -> not called. A raising observer is swallowed.
        self._tool_event_observer = tool_event_observer
        # The store-write chokepoint (docs/WIRE_CONTRACT.md, "Secrets"): every
        # row this loop writes — system, user, assistant, tool, context —
        # passes through it first, so a value that reached the model's TEXT
        # (a user who pasted a key, a model that echoes one) is masked before
        # it is persisted and before the next round re-reads it. ``None`` ->
        # rows are written as they are.
        self._persist_filter = persist_filter
        # Memory (§12), both directions. ``recall_provider(prompt)`` runs once
        # per task, right after the user's row: whatever it returns (context
        # messages, ``role_tag`` = row role) is appended so the model sees what
        # it learned before. ``turn_observer(record)`` runs once per task, after
        # the loop decided the outcome, so the turn's facts can be extracted
        # without the model having to remember to call a tool. Both best-effort.
        self._recall_provider = recall_provider
        self._turn_observer = turn_observer

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

    def _append(self, session_id: int, role: str, content: dict) -> int:
        """The one write path for message rows: ``persist_filter`` first."""
        if self._persist_filter is not None:
            try:
                content = self._persist_filter(content)
            except Exception:  # noqa: BLE001 — a broken filter must not lose the row...
                # ...but must not let an unfiltered row through either. Keep the
                # shape (role, ids) and drop the text.
                content = {
                    k: (v if k in ("role", "tool_call_id", "name") else None)
                    for k, v in content.items()
                }
        return self._store.append_message(session_id, role, content)

    def _outbound_messages(self, session_id: int) -> list[dict]:
        """The payload for one model call: the full stored history, run through
        the context ladder. Without a ladder this is the history verbatim."""
        tracer = get_tracer()
        read_started = time.monotonic()
        messages = _to_model_messages(self._store, session_id)
        if tracer.enabled:
            tracer.emit(
                "history_loaded",
                messages=len(messages),
                ms=round((time.monotonic() - read_started) * 1000, 3),
            )
        if self._system_prompt_upgrade is not None:
            messages = [
                {**message, "content": self._system_prompt_upgrade(message["content"])}
                if message.get("role") == "system"
                and isinstance(message.get("content"), str)
                else message
                for message in messages
            ]
        if self._ladder is None:
            return messages
        return self._ladder.prepare(messages)

    def run(
        self, session_key: str, user_message: str, *, regenerate: bool = False
    ) -> LoopResult:
        """Run one task to completion.

        ``regenerate`` means "replace the last answer", not "ask again": the
        app's Retry button sends the same prompt a second time. Without it the
        conversation keeps every attempt, so the model is handed a history in
        which the user asked the same question four times, and the client shows
        the question four times on replay (docs/WIRE_CONTRACT.md, ``task``).
        """
        store = self._store
        tracer = get_tracer()
        run_started = time.monotonic()
        timings = RunTimings()
        if tracer.enabled:
            set_round(0)
            tracer.emit(
                "task_received",
                prompt_chars=len(user_message or ""),
                regenerate=bool(regenerate),
                max_iterations=self._max_iterations,
                text=tracer.text(user_message),
            )
        session_id = store.route(session_key)
        if regenerate:
            # Drop the turn being retried — the old user row and the answer it
            # produced — so the prompt appended below takes its place.
            store.drop_last_user_turn(session_id)

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
                self._append(
                    session_id, "system", {"role": "system", "content": resolved}
                )

        self._append(session_id, "user", {"role": "user", "content": user_message})
        timings.recall_ms = self._inject_recall(session_id, user_message)

        iterations = 0
        tools_used: list[str] = []
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
            if tracer.enabled:
                set_round(iterations)
                tracer.emit("round_start", iteration=iterations)

            # Built once here so the debug tap can report the EXACT list sent, and
            # so the ladder's ``last_stats`` (set inside ``prepare``) matches it.
            prepare_started = time.monotonic()
            outbound = self._outbound_messages(session_id)
            model_started = time.monotonic()
            timings.prepare_ms += (model_started - prepare_started) * 1000
            if tracer.enabled:
                self._trace_prepare(tracer, outbound, model_started - prepare_started)
            try:
                response: ModelResponse = self._model.complete(outbound)
            except Exception:
                timings.model_calls += 1
                timings.model_wait_ms += (time.monotonic() - model_started) * 1000
                # A model call that dies *while we are interrupting* died because
                # of the interrupt: a cancelled socket, a closed stream. Report
                # the stop, not a crash. Any other failure is a real error and
                # still propagates.
                if self._kill.interrupted():
                    reason = StopReason.INTERRUPTED
                    break
                raise
            timings.model_calls += 1
            timings.model_wait_ms += (time.monotonic() - model_started) * 1000
            model_timing = response.raw.get("timing")
            if isinstance(model_timing, dict):
                attempts = int(model_timing.get("attempts") or 1)
                if attempts > 1:
                    timings.retries += attempts - 1
                    timings.retry_ms += float(model_timing.get("wasted_ms") or 0.0)

            # Debug tap (§ "copy raw context"): the outbound payload and the
            # ladder's stats for this round. Guarded so a broken sink cannot abort
            # a real run.
            if self._debug_observer is not None:
                self._emit_debug(session_key, iterations, outbound, {
                    "context_prepare_ms": (model_started - prepare_started) * 1000,
                    "model_complete_ms": (time.monotonic() - model_started) * 1000,
                    "model": response.raw.get("timing"),
                    "usage": response.raw.get("usage"),
                    "tps": response.raw.get("tps"),
                })

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
                finish_summary: str | None = None
                for call in response.tool_calls:
                    # One turn can carry several tool calls, and each one can be
                    # a long command. Stop between them too, or a Stop would wait
                    # out the whole batch. Every call still gets a result row, so
                    # a resumed session has no assistant turn with a dangling
                    # tool call in it.
                    started_at = time.time()
                    tool_started = time.monotonic()
                    if tracer.enabled:
                        tracer.emit(
                            "tool_start",
                            tool=call.name,
                            call_id=call.id,
                            args_chars=len(str(call.arguments)),
                            text=tracer.text(
                                str(call.arguments) if call.arguments else None
                            ),
                        )
                    if self._kill.interrupted():
                        result: object = INTERRUPTED_TOOL_RESULT
                        raised = True
                    else:
                        raised = False
                        result = self._registry.dispatch(call.name, call.arguments)
                        # Explicit terminal action: a `finish` call ends the run
                        # with its summary as the final answer. Its tool result
                        # is still recorded below (audit trail); the loop just
                        # stops after this batch. Structural bare-text stays as
                        # the fallback terminator.
                        if call.name == FINISH_TOOL and finish_summary is None:
                            args = (
                                call.arguments
                                if isinstance(call.arguments, dict)
                                else {}
                            )
                            finish_summary = str(args.get("summary", "")) or (
                                response.text or ""
                            )
                    self._append(
                        session_id,
                        "tool",
                        {
                            "role": "tool",
                            "tool_call_id": call.id,
                            "name": call.name,
                            "content": result,
                        },
                    )
                    tool_ms = (time.monotonic() - tool_started) * 1000
                    timings.tool_ms += tool_ms
                    if tracer.enabled:
                        tracer.emit(
                            "tool_end",
                            tool=call.name,
                            call_id=call.id,
                            ms=round(tool_ms, 3),
                            ok=not raised,
                            result_chars=len(str(result)),
                            text=tracer.text(str(result) if result is not None else None),
                        )
                    self._emit_tool(
                        call, result, started_at=started_at, raised=raised
                    )
                    tools_used.append(call.name)
                # The interrupt wins over a `finish` in the same batch: a run the
                # user stopped reports INTERRUPTED, not FINISHED.
                if self._kill.interrupted():
                    reason = StopReason.INTERRUPTED
                    break
                if finish_summary is not None:
                    final_answer = finish_summary
                    reason = StopReason.FINISHED
                    break
                self._drain_context(session_id)
                continue  # tool calls -> feed results back, loop again

            # bare text -> final answer, stop
            final_answer = response.text
            reason = StopReason.FINISHED
            break

        outcome = LoopResult(
            reason=reason,
            final_answer=final_answer,
            iterations=iterations,
            session_id=session_id,
            tokens_spent=self._tokens_spent,
            timings=timings,
        )
        if tracer.enabled:
            tracer.emit(
                "run_finished",
                reason=reason.value,
                iterations=iterations,
                tokens_spent=self._tokens_spent,
                total_ms=round((time.monotonic() - run_started) * 1000, 3),
                tools=len(tools_used),
                **{k: v for k, v in timings.as_row().items()},
            )
        self._observe_turn(session_key, user_message, outcome, tools_used)
        return outcome

    def _trace_prepare(self, tracer, outbound: list[dict], elapsed: float) -> None:
        """The two phases that hide inside "preparing the payload": the ladder's
        pass over the history, and the payload that came out of it.

        The ladder is the other thing that can burn minutes in a turn — a
        tier-2/3 pass calls the aux model — so its tier, pressure and
        before/after token counts are on their own line, not folded into one
        opaque ``prepare_ms``.
        """
        ladder = self._ladder
        if ladder is not None:
            stats = ladder.last_stats
            tracer.emit(
                "ladder_pass",
                ms=round(elapsed * 1000, 3),
                tier=stats.tier,
                pressure=round(float(stats.pressure), 4),
                tokens_before=stats.tokens_before,
                tokens_after=stats.tokens_after,
                dropped=max(0, int(stats.tokens_before) - int(stats.tokens_after)),
            )
        else:
            tracer.emit("ladder_pass", ms=round(elapsed * 1000, 3), tier=0)
        estimated = sum(estimate_message_tokens(m) for m in outbound)
        tools = getattr(self._model, "traced_tools", None)
        tracer.emit(
            "payload_prepared",
            messages=len(outbound),
            prompt_tokens_est=estimated,
            tool_schema_tokens=_tool_schema_tokens(tools),
            tools=len(tools or ()),
        )

    def _inject_recall(self, session_id: int, user_message: str) -> float:
        """Append the memory recall for this task (a context row, never a
        system message). A failing provider costs the recall, not the run.

        Returns the milliseconds it took. The recall is a whole retrieval stack
        behind one call — in the run that started this work it cost 74.6 s on
        its own and nobody knew — so it is timed and traced like a model call.
        """
        if self._recall_provider is None:
            return 0.0
        tracer = get_tracer()
        started = time.monotonic()
        if tracer.enabled:
            tracer.emit("memory_recall_start", prompt_chars=len(user_message or ""))
        failed: str | None = None
        messages: list[dict] = []
        try:
            messages = self._recall_provider(user_message) or []
        except Exception as exc:  # noqa: BLE001 — recall must never break a run
            failed = type(exc).__name__
        written = 0
        chars = 0
        for message in messages:
            if not isinstance(message, dict) or not message.get("content"):
                continue
            written += 1
            chars += len(str(message.get("content")))
            self._append(
                session_id,
                str(message.get("role_tag") or "memory"),
                {k: v for k, v in message.items() if k != "role_tag"},
            )
        elapsed_ms = (time.monotonic() - started) * 1000
        if tracer.enabled:
            tracer.emit(
                "memory_recall_end",
                ms=round(elapsed_ms, 3),
                messages=written,
                chars=chars,
                failed=failed,
            )
        return elapsed_ms

    def _observe_turn(
        self,
        session_key: str,
        user_message: str,
        outcome: LoopResult,
        tools_used: list[str],
    ) -> None:
        if self._turn_observer is None:
            return
        try:
            self._turn_observer(
                TurnRecord(
                    session_key=session_key,
                    session_id=outcome.session_id,
                    user_message=user_message,
                    final_answer=outcome.final_answer,
                    reason=outcome.reason,
                    tool_names=tuple(tools_used),
                )
            )
        except Exception:  # noqa: BLE001 — a memory sink must never take the run down
            pass

    def _emit_tool(
        self, call: ToolCall, result: object, *, started_at: float, raised: bool
    ) -> None:
        """Hand the tool observer one finished tool call in the wire shape
        (``tool_event_fields``). Guarded: a UI sink must never take the run
        down."""
        if self._tool_event_observer is None:
            return
        try:
            self._tool_event_observer(
                tool_event_fields(
                    name=call.name,
                    arguments=call.arguments,
                    result=result,
                    call_id=call.id,
                    started_at=started_at,
                    completed_at=time.time(),
                    raised=raised,
                )
            )
        except Exception:  # noqa: BLE001 — a UI sink error must not abort a run
            pass

    def _emit_debug(
        self, session_key: str, round_no: int, outbound: list[dict], timing: dict
    ) -> None:
        """Hand the debug observer one round's raw context, in the fixed contract
        shape. Stats come from the ladder's ``last_stats``; with no ladder they
        are zeros at tier 0. A raising observer is swallowed — a debug sink must
        never take the run down."""
        ladder = self._ladder
        if ladder is not None:
            ls = ladder.last_stats
            stats = {
                "tier": ls.tier,
                "pressure": ls.pressure,
                "tokens_before": ls.tokens_before,
                "tokens_after": ls.tokens_after,
            }
        else:
            stats = {"tier": 0, "pressure": 0.0, "tokens_before": 0, "tokens_after": 0}
        stats["timing"] = timing
        try:
            self._debug_observer(  # type: ignore[misc]
                {
                    "type": "debug_context",
                    "session_key": session_key,
                    "round": round_no,
                    "messages": outbound,
                    "stats": stats,
                }
            )
        except Exception:  # noqa: BLE001 — a debug sink error must not abort a run
            pass

    def _drain_context(self, session_id: int) -> None:
        """Append whatever a tool asked to add to the conversation — today, a
        skill body (§11). The row role records where it came from; the wire role
        inside the content stays a normal turn, because a mid-conversation
        system message would overwrite the frozen system prompt."""
        for provider in self._context_providers:
            for message in provider():
                self._append(
                    session_id, message.get("role_tag", "context"),
                    {k: v for k, v in message.items() if k != "role_tag"},
                )

    def _persist_assistant(self, session_id: int, response: ModelResponse) -> None:
        content: dict = {"role": "assistant"}
        if response.text is not None:
            content["content"] = response.text
        # The model's thinking for this turn, kept so a replay can show the
        # thinking block again (``StateStore.replay_events``). It is a stored
        # field only: ``_assistant_turn`` never sends it back to the model, and
        # the context ladder ignores unknown keys.
        reasoning = response.raw.get("reasoning") if response.raw else None
        if isinstance(reasoning, str) and reasoning.strip():
            content["reasoning"] = reasoning
        if response.has_tool_calls:
            content["tool_calls"] = [
                {
                    "id": c.id,
                    "type": "function",
                    "function": {"name": c.name, "arguments": c.arguments},
                }
                for c in response.tool_calls
            ]
        self._append(session_id, "assistant", content)
