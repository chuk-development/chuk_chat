"""The agent loop (§7.1), on Pydantic AI (docs/PYDANTIC_AI_LOOP.md).

The shared types come first — the kill switch, the budget, the stop reasons,
the result — then :class:`AgentLoop`, a Pydantic AI ``Agent.iter()`` driven
node by node:

- **Continue-vs-finish is structural**: a model turn with tool calls executes
  the tools and continues; a bare-text turn is the final answer and stops; a
  ``finish`` call ends the run with its summary. No text-pattern heuristics.
- **Dual-counter termination**: a hard ``max_iterations`` ceiling plus a
  refundable :class:`IterationBudget`. Housekeeping rounds ``.refund()`` so they
  don't burn the model's real thinking budget while termination stays
  guaranteed. A token budget caps a subagent's spend.
- **Two-tier kill switch**: a file-sentinel ESTOP that pauses new work (a stat
  error counts as engaged) plus a thread-flag interrupt. The interrupt fires
  the run's Pydantic AI ``CancellationToken``, so a model stream closes and a
  running tool is abandoned at once; its registered cancellers
  (:meth:`KillSwitch.on_interrupt`) kill the command in flight and a whole
  subagent tree.
- **The store is the source of truth.** Every row is written through one path
  (``persist_filter``, the secret scrubber, first) in the OpenAI-style shape
  the replay, the search and the export read. Before every model request the
  history is rebuilt from the store (a ``ProcessHistory`` capability): stored
  rows -> ``system_prompt_upgrade`` -> the context ladder (§7.3) -> Pydantic AI
  messages. A steer row, a job wake row or a skill body reaches a running turn
  this way.
- **The system prompt freezes once per session** (§12). It may be passed as a
  callable, which is resolved when a session is seeded and never again.
- **Context providers** append messages after a tool round — the seam a skill
  body uses to enter the conversation without touching the system prompt (§11).
- **Tools run one at a time, in order**, through the registry (argument
  coercion, error envelope, scrubber, workspace journal). Approvals are
  Pydantic AI deferred tools resolved in the same run (``pai.approvals``).
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import threading
import time
from collections.abc import Callable, Coroutine, Sequence
from dataclasses import dataclass, field, replace
from enum import Enum
from typing import Any

from .context import (
    ContextLadder,
    estimate_message_tokens,
    estimate_tokens,
    total_tokens_from_usage,
)
from .registry import ToolRegistry
from .state import StateStore
from .tool_events import tool_event_fields
from .tools import FINISH_TOOL
from .telemetry import get_tracer, set_round

logger = logging.getLogger(__name__)


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
    #: Prompt tokens the provider served from its cache, over all calls
    #: (``prompt_tokens_details.cached_tokens``). 0 = none or not reported.
    cached_tokens: int = 0
    #: The provider's time to the first streamed token (text, reasoning or a
    #: tool call) of the run's FIRST model call, ``prepare_ms`` of that call left out. With
    #: ``recall_ms`` and ``prepare_ms`` this is the turn's time to first token.
    #: ``None`` = not measured (a blocking client streams nothing).
    first_token_ms: float | None = None

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
            "cached_tokens": int(self.cached_tokens),
            "first_token_ms": int(self.first_token_ms or 0),
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
    #: Why a finished run has no answer, when the provider said so:
    #: ``length`` (output limit) or ``content_filter``. ``None`` otherwise.
    note: str | None = None


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


# -- the loop ------------------------------------------------------------------
# Imported here, after the shared types, because the ``pai`` parts import the
# kill switch and INTERRUPTED_TOOL_RESULT from this module.

from pydantic_ai import Agent, CancellationToken  # noqa: E402
from pydantic_ai.capabilities import HandleDeferredToolCalls, ProcessHistory  # noqa: E402
from pydantic_ai.exceptions import (  # noqa: E402
    ContentFilterError,
    RunCancelled,
    UnexpectedModelBehavior,
)
from pydantic_ai.messages import (  # noqa: E402
    ModelMessage,
    ModelResponse,
    RetryPromptPart,
    TextPart,
    ThinkingPart,
    ToolCallPart,
    ToolReturnPart,
)
from pydantic_ai.models import Model  # noqa: E402
from pydantic_ai.settings import ModelSettings  # noqa: E402
from pydantic_ai.tool_manager import ToolManager  # noqa: E402
from pydantic_ai.tools import DeferredToolRequests  # noqa: E402
from pydantic_ai.usage import UsageLimits  # noqa: E402

from .pai import disable_banner  # noqa: E402
from .pai.approvals import ApprovalPolicy  # noqa: E402
from .pai.convert import response_to_row, rows_to_messages, tool_call_args  # noqa: E402
from .pai.events import StreamMapper  # noqa: E402
from .pai.model import LEGACY_DETAILS_KEY, LegacyClientModel, is_legacy  # noqa: E402
from .pai.tools import TOOL_RETRIES, UNSET, RegistryToolset  # noqa: E402

disable_banner()

Sink = Callable[[str], None]

#: A streamed request that produced nothing at all in this time is aborted.
#: The route answers a status within 30 s and then sends keep-alives while an
#: upstream stalls, so only the first real event proves the model started.
FIRST_EVENT_TIMEOUT_S = 90.0


class ModelServiceError(RuntimeError):
    """A model call failed in a way the user can act on. ``user_message`` is
    what the app shows (the executor puts it in the error terminal)."""

    def __init__(self, user_message: str, *, status: int | None = None) -> None:
        super().__init__(user_message)
        self.user_message = user_message
        self.status = status


class FirstEventTimeout(ModelServiceError):
    def __init__(self, seconds: float) -> None:
        super().__init__(
            f"the model sent nothing for {seconds:.0f} s; try again", status=None
        )


#: HTTP statuses of the route with a message the user can act on.
_STATUS_MESSAGES = {
    402: "no credits left",
    429: "rate limited, try again shortly",
}


def model_service_error(exc: BaseException) -> ModelServiceError | None:
    """The user-facing error for a model failure, or ``None`` to re-raise it
    as it is."""
    if isinstance(exc, ModelServiceError):
        return exc
    status = getattr(exc, "status_code", None)
    message = _STATUS_MESSAGES.get(status) if isinstance(status, int) else None
    return ModelServiceError(message, status=status) if message else None


#: What the model is told, once per run, after a reply with no text and no
#: tool call (a thinking-only turn): without it the run ends with no answer.
EMPTY_REPLY_NUDGE = (
    "Your last reply was empty. Answer the user now, or call a tool if you "
    "still need one."
)

#: How long a Stop waits for a call that had started to finish on its thread,
#: so its row holds the real result. The executor kills the sandbox process on
#: the same Stop, so a command returns at once; a web call, a publish or an MCP
#: call may still complete, and its side effect must be recorded, not denied.
STOP_SETTLE_S = 10.0

#: The row of a call that started and did not finish inside the settle time.
#: It may have had its effect: the model must check, not repeat it blindly.
STOPPED_TOOL_RESULT = (
    "stopped while running; the outcome is unknown. Verify it before you retry."
)


@dataclass
class _DriveState:
    iterations: int = 0
    reason: StopReason = StopReason.FINISHED
    final_answer: str | None = None
    last_response: ModelResponse | None = None
    in_request: bool = False
    request_mark: int | None = None
    nudged: bool = False
    #: Why a turn ended with no answer (``length`` / ``content_filter``).
    stop_note: str | None = None
    #: The model this run talks to (built per run for the HTTP route).
    model: Any = None


@dataclass
class _ActiveRun:
    """Per-run state the history processor and the drivers share."""

    session_key: str
    session_id: int
    round: int = 0
    outbound: list[dict] = field(default_factory=list)
    prepare_ms: float = 0.0
    written_calls: set[str] = field(default_factory=set)


def _run_blocking(coro: Coroutine[Any, Any, Any]) -> Any:
    """Run a coroutine to completion from sync code. The executor calls
    ``run()`` on a worker thread with no event loop; a caller that already
    has a running loop in this thread gets a private thread for the run."""
    try:
        asyncio.get_running_loop()
    except RuntimeError:
        return asyncio.run(coro)
    box: dict[str, Any] = {}

    def target() -> None:
        try:
            box["value"] = asyncio.run(coro)
        except BaseException as exc:  # noqa: BLE001 — re-raised on the caller
            box["error"] = exc

    thread = threading.Thread(target=target, name="pai-loop", daemon=True)
    thread.start()
    thread.join()
    if "error" in box:
        raise box["error"]
    return box.get("value")


class AgentLoop:
    """The agent loop: one task per :meth:`run`, driven on Pydantic AI."""

    def __init__(
        self,
        model: Any,
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
        # -- Pydantic AI only -------------------------------------------
        model_settings: ModelSettings | None = None,
        on_delta: Sink | None = None,
        on_reasoning: Sink | None = None,
        approval_policy: ApprovalPolicy | None = None,
        capabilities: Sequence[Any] = (),
        usage_limits: UsageLimits | None = None,
        deferred_mode: str = "hide",
        expose_tools: bool = True,
        model_factory: Callable[[], Model] | None = None,
    ) -> None:
        if token_budget is not None and token_budget < 0:
            raise ValueError("token_budget must be >= 0")
        self._model = model
        #: Builds the model for each run (the HTTP model: its client belongs to
        #: one event loop, and each run has its own). ``None``: ``model`` is used.
        self._model_factory = model_factory
        self._pai_model: Model = (
            model if isinstance(model, Model) else LegacyClientModel(model)
        )
        self._registry = registry
        self._store = store
        self._max_iterations = max_iterations
        self._budget = budget or IterationBudget(max_iterations)
        self._token_budget = token_budget
        self._tokens_spent = 0
        self._kill = kill_switch or KillSwitch()
        self._system_prompt = system_prompt
        self._system_prompt_upgrade = system_prompt_upgrade
        self._context_providers = list(context_providers or [])
        self._ladder = context_ladder
        self._debug_observer = debug_observer
        self._tool_event_observer = tool_event_observer
        self._persist_filter = persist_filter
        self._recall_provider = recall_provider
        self._turn_observer = turn_observer
        self._model_settings = model_settings
        self._on_delta = on_delta
        self._on_reasoning = on_reasoning
        self._usage_limits = usage_limits
        self._policy = approval_policy or ApprovalPolicy()
        self._policy.kill = self._kill
        self._toolset = RegistryToolset(
            registry,
            kill=self._kill,
            requires_approval=self._policy.requires_approval,
            deferred_mode=deferred_mode,
            enabled=expose_tools,
        )
        self._policy.toolset = self._toolset
        self._extra_capabilities = list(capabilities)
        self._active: _ActiveRun | None = None
        self._agent = self._build_agent()

    # -- the facade build_runtime, the executor and the subagents use ------

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

    @property
    def agent(self) -> Agent:
        """The Pydantic AI agent (for tests and instrumentation)."""
        return self._agent

    @property
    def pai_model(self) -> Model:
        return self._pai_model

    # -- construction ----------------------------------------------------

    def _build_agent(self) -> Agent:
        capabilities: list[Any] = [ProcessHistory(self._process_history)]
        capabilities.append(HandleDeferredToolCalls(handler=self._policy.handler))
        capabilities.extend(self._extra_capabilities)
        return Agent(
            self._pai_model,
            output_type=[str, DeferredToolRequests],
            toolsets=[self._toolset],
            capabilities=capabilities,
            retries={"tools": TOOL_RETRIES, "output": 1},
            model_settings=self._model_settings,
        )

    # -- the one write path ----------------------------------------------

    def _append(self, session_id: int, role: str, content: dict) -> int:
        """Every row goes through ``persist_filter`` (the secret scrubber)
        first. A filter that raises keeps the shape and drops the text."""
        if self._persist_filter is not None:
            try:
                content = self._persist_filter(content)
            except Exception:  # noqa: BLE001
                content = {
                    k: (v if k in ("role", "tool_call_id", "name") else None)
                    for k, v in content.items()
                }
        return self._store.append_message(session_id, role, content)

    # -- what the model sees ---------------------------------------------

    def _stored_rows(self, session_id: int) -> list[dict]:
        return [m.content for m in self._store.get_conversation(session_id)]

    def _outbound_messages(self, session_id: int) -> list[dict]:
        """Stored history -> system prompt upgrade -> context ladder. The same
        pipeline as the native loop, so the model sees the same payload."""
        tracer = get_tracer()
        read_started = time.monotonic()
        messages, timestamps, turn_start = self._ladder_input(session_id)
        if tracer.enabled:
            tracer.emit(
                "history_loaded",
                messages=len(messages),
                ms=round((time.monotonic() - read_started) * 1000, 3),
            )
        if self._ladder is None:
            return messages
        return self._ladder.prepare(
            messages, session_id=session_id, timestamps=timestamps, turn_start=turn_start
        )

    def _ladder_input(self, session_id: int) -> tuple[list[dict], list[float], int]:
        """The stored rows with the system prompt upgrade applied, their
        ``created_at`` (the idle rule reads the pauses between them) and the
        index of the current task's prompt (the newest ``user`` row; recall
        and nudge rows have their own roles), before which the ladder drops
        the injected rows of earlier tasks."""
        rows = self._store.get_conversation(session_id)
        turn_start = next(
            (i for i in range(len(rows) - 1, -1, -1) if rows[i].role == "user"), 0
        )
        messages = [m.content for m in rows]
        if self._system_prompt_upgrade is not None:
            messages = [
                {**message, "content": self._system_prompt_upgrade(message["content"])}
                if message.get("role") == "system"
                and isinstance(message.get("content"), str)
                else message
                for message in messages
            ]
        return messages, [m.created_at for m in rows], turn_start

    def _plan_compaction(self, session_id: int) -> None:
        """After the run (cowork-z9mo): let the ladder start the next turn's
        summary in the background now, so that turn does not wait for it.
        Costs a history read and a tier-1 pass; never blocks on a model."""
        ladder = self._ladder
        plan = getattr(ladder, "plan_ahead", None)
        if not callable(plan):
            return
        started = time.monotonic()
        try:
            messages, _, _ = self._ladder_input(session_id)
            started_job = bool(plan(messages, session_id=session_id))
        except Exception:  # noqa: BLE001 — planning must never fail a finished run
            logger.warning("compaction planning failed", exc_info=True)
            return
        tracer = get_tracer()
        if tracer.enabled:
            tracer.emit(
                "compaction_planned",
                started=started_job,
                ms=round((time.monotonic() - started) * 1000, 3),
            )

    def _process_history(self, messages: list[ModelMessage]) -> list[ModelMessage]:
        """The ``ProcessHistory`` hook: ignore Pydantic AI's in-run list and
        send what the store holds. Runs on a worker thread (it is sync)."""
        active = self._active
        if active is None:  # pragma: no cover — only called inside a run
            return messages
        started = time.monotonic()
        outbound = self._outbound_messages(active.session_id)
        elapsed = time.monotonic() - started
        active.outbound = outbound
        active.prepare_ms = elapsed * 1000
        tracer = get_tracer()
        if tracer.enabled:
            self._trace_prepare(tracer, outbound, elapsed)
        converted = rows_to_messages(outbound, deferred=self._registry.deferred_names())
        if not converted or not hasattr(converted[-1], "parts") or converted[-1].kind != "request":
            # Pydantic AI needs the history to end in a request. The store
            # always ends in the user row or tool results by the time a model
            # request is made; this only guards a malformed old session.
            return messages
        return converted

    # -- running ---------------------------------------------------------

    def run(
        self, session_key: str, user_message: str, *, regenerate: bool = False
    ) -> LoopResult:
        """Run one task to completion. See the module docstring for the rules."""
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
                loop="pydantic_ai",
            )
        session_id = store.route(session_key)
        if regenerate:
            store.drop_last_user_turn(session_id)
        conversation = store.get_conversation(session_id)
        if self._system_prompt and not any(
            m.content.get("role") == "system" for m in conversation
        ):
            prompt = self._system_prompt
            resolved = prompt() if callable(prompt) else prompt
            if resolved:
                self._append(session_id, "system", {"role": "system", "content": resolved})
        self._append(session_id, "user", {"role": "user", "content": user_message})
        timings.recall_ms = self._inject_recall(session_id, user_message)

        active = _ActiveRun(session_key=session_key, session_id=session_id)
        self._active = active
        tools_used: list[str] = []
        try:
            reason, final_answer, iterations, note = _run_blocking(
                self._drive(active, timings, tools_used)
            )
        finally:
            self._active = None

        outcome = LoopResult(
            reason=reason,
            final_answer=final_answer,
            iterations=iterations,
            session_id=session_id,
            tokens_spent=self._tokens_spent,
            timings=timings,
            note=note,
        )
        if tracer.enabled:
            tracer.emit(
                "run_finished",
                note=note,
                reason=reason.value,
                iterations=iterations,
                tokens_spent=self._tokens_spent,
                total_ms=round((time.monotonic() - run_started) * 1000, 3),
                tools=len(tools_used),
                **timings.as_row(),
            )
        self._observe_turn(session_key, user_message, outcome, tools_used)
        self._plan_compaction(session_id)
        return outcome

    def _pre_round_stop(self, iterations: int) -> StopReason | None:
        if self._kill.interrupted():
            return StopReason.INTERRUPTED
        if self._kill.estop_engaged():
            return StopReason.ESTOP
        if iterations >= self._max_iterations:
            return StopReason.MAX_ITERATIONS
        if self._budget.exhausted():
            return StopReason.BUDGET_EXHAUSTED
        if self._token_budget is not None and self._tokens_spent >= self._token_budget:
            return StopReason.TOKEN_BUDGET_EXHAUSTED
        return None

    async def _drive(
        self, active: _ActiveRun, timings: RunTimings, tools_used: list[str]
    ) -> tuple[StopReason, str | None, int, str | None]:
        """Drive ``Agent.iter()`` one node at a time and apply the loop's
        rules between the nodes."""
        # A stop before the first round: no model call at all.
        early = self._pre_round_stop(0)
        if early is not None:
            return early, None, 0, None

        token = CancellationToken()
        self._kill.on_interrupt(token.cancel)
        history = rows_to_messages(
            self._stored_rows(active.session_id), deferred=self._registry.deferred_names()
        )
        state = _DriveState()
        tracer = get_tracer()
        # A model built for this run (the HTTP model: its client is bound to
        # this run's event loop) is closed when the run ends.
        run_model = self._model_factory() if self._model_factory is not None else self._pai_model
        state.model = run_model
        streaming = not is_legacy(run_model)
        request_log = getattr(run_model, "request_log", None)

        try:
            with ToolManager.parallel_execution_mode("sequential"):
                async with self._agent.iter(
                    None,
                    model=run_model,
                    message_history=history,
                    cancellation_token=token,
                    usage_limits=self._usage_limits or UsageLimits(request_limit=None),
                ) as run:
                    node: Any = run.next_node
                    while not Agent.is_end_node(node):
                        if Agent.is_model_request_node(node):
                            stop = self._pre_round_stop(state.iterations)
                            if stop is not None:
                                state.reason = stop
                                break
                            state.iterations += 1
                            active.round = state.iterations
                            self._budget.consume()
                            if tracer.enabled:
                                set_round(state.iterations)
                                tracer.emit("round_start", iteration=state.iterations)
                            model_started = time.monotonic()
                            mapper = StreamMapper(self._on_delta, self._on_reasoning)
                            state.request_mark = self._legacy_mark(run_model)
                            state.in_request = True
                            if request_log is not None:
                                request_log.reset()
                            try:
                                if streaming:
                                    await self._stream_request(node, run, mapper)
                                node = await run.next(node)
                            except (RunCancelled, asyncio.CancelledError):
                                raise
                            except Exception as exc:
                                state.in_request = False
                                timings.model_calls += 1
                                timings.model_wait_ms += (time.monotonic() - model_started) * 1000
                                _count_retries(request_log, timings)
                                if self._kill.interrupted():
                                    state.reason = StopReason.INTERRUPTED
                                    break
                                mapped = model_service_error(exc)
                                if mapped is not None:
                                    raise mapped from exc
                                raise
                            state.in_request = False
                            _count_retries(request_log, timings)
                            elapsed_ms = (time.monotonic() - model_started) * 1000
                            timings.model_calls += 1
                            # ``prepare_ms`` (the history rebuild) happened
                            # inside the request node; keep the buckets apart.
                            timings.prepare_ms += active.prepare_ms
                            timings.model_wait_ms += max(0.0, elapsed_ms - active.prepare_ms)
                            response = _last_response(run)
                            self._take_turn(active, state, response)
                            self._account(response, timings, active, elapsed_ms, mapper)
                            if self._kill.interrupted():
                                state.reason = StopReason.INTERRUPTED
                                break
                            continue

                        if Agent.is_call_tools_node(node):
                            response = node.model_response
                            calls = _calls(response)
                            if not calls:
                                if _no_output(response):
                                    if response.finish_reason in ("length", "content_filter"):
                                        # The provider cut the turn off (output
                                        # limit, or its filter). No retry: the
                                        # same request would end the same way.
                                        _log_cut_off(response.finish_reason)
                                        state.stop_note = response.finish_reason
                                        state.reason = StopReason.FINISHED
                                        break
                                    if not state.nudged and not self._kill.interrupted():
                                        # A turn with neither text nor a call (a
                                        # thinking-only reply) would end the run
                                        # with no answer. Ask once more. The nudge
                                        # row is written only when the retry
                                        # really follows; it is a context row,
                                        # never replayed.
                                        state.nudged = True
                                        after = await run.next(node)
                                        if Agent.is_model_request_node(after):
                                            self._append(
                                                active.session_id,
                                                "context",
                                                {"role": "user", "content": EMPTY_REPLY_NUDGE},
                                            )
                                            node = after
                                            continue
                                    state.reason = StopReason.FINISHED
                                    break
                                state.final_answer = _response_text(response)
                                state.reason = StopReason.FINISHED
                                break
                            finish_summary = _finish_summary(calls, response)
                            tool_started = time.monotonic()
                            try:
                                async with node.stream(run.ctx) as stream:
                                    async for event in stream:
                                        self._on_tool_event_part(active, calls, event, tools_used)
                            finally:
                                timings.tool_ms += (time.monotonic() - tool_started) * 1000
                            self._close_calls(active, calls, tools_used)
                            if self._kill.interrupted():
                                state.reason = StopReason.INTERRUPTED
                                break
                            if finish_summary is not None:
                                state.final_answer = finish_summary
                                state.reason = StopReason.FINISHED
                                break
                            self._drain_context(active.session_id)
                            node = await run.next(node)
                            continue

                        # UserPromptNode (and any node we do not inspect).
                        node = await run.next(node)
        except RunCancelled as exc:
            state.reason = StopReason.INTERRUPTED
            self._keep_stopped_turn(active, state, exc.all_messages())
        except asyncio.CancelledError:
            if not self._kill.interrupted():
                raise
            state.reason = StopReason.INTERRUPTED
            self._keep_stopped_turn(active, state, ())
        except (UnexpectedModelBehavior, ContentFilterError) as exc:
            # Pydantic AI gave up on a turn it could not use (an output limit
            # hit inside the thinking, a filtered reply). The old loop ended
            # such a run as finished with no answer; so does this one.
            _log_cut_off(type(exc).__name__)
            state.stop_note = type(exc).__name__
            state.reason = StopReason.FINISHED
            state.final_answer = None
        finally:
            if state.last_response is not None:
                await self._settle_inflight()
                self._close_calls(active, _calls(state.last_response), tools_used)
            if self._model_factory is not None:
                await _close_model(run_model)
        return state.reason, state.final_answer, state.iterations, state.stop_note

    async def _stream_request(self, node: Any, run: Any, mapper: StreamMapper) -> None:
        """Stream one model request into the sinks. Nothing at all within
        :data:`FIRST_EVENT_TIMEOUT_S` (the route sends keep-alives while an
        upstream stalls, so the socket alone never times out) aborts it."""
        deadline = asyncio.timeout(FIRST_EVENT_TIMEOUT_S)
        try:
            async with deadline:
                async with node.stream(run.ctx) as stream:
                    async for event in stream:
                        if mapper.first_event_ms is None:
                            deadline.reschedule(None)
                        mapper.feed(event)
        except TimeoutError as exc:
            raise FirstEventTimeout(FIRST_EVENT_TIMEOUT_S) from exc

    @staticmethod
    def _legacy_mark(model: Any) -> int | None:
        return model.requests if isinstance(model, LegacyClientModel) else None

    def _take_turn(self, active: _ActiveRun, state: _DriveState, response: ModelResponse) -> None:
        """A finished model turn: persist it and reset the per-turn call state
        (call ids are only unique within one turn)."""
        state.last_response = response
        active.written_calls.clear()
        self._toolset.calls.clear()
        self._persist_assistant(active.session_id, response)

    def _keep_stopped_turn(
        self, active: _ActiveRun, state: _DriveState, messages: Sequence[ModelMessage]
    ) -> None:
        """A Stop that landed while the model was answering. The native loop
        kept a turn the model had finished; a streamed turn keeps what was
        streamed (the user saw it). A turn with nothing in it is not stored."""
        if not state.in_request:
            return
        state.in_request = False
        response: ModelResponse | None = None
        model = state.model
        if isinstance(model, LegacyClientModel) and model.last_reply is not None:
            number, reply = model.last_reply
            if state.request_mark is not None and number > state.request_mark:
                response = reply
        if response is None and messages:
            last = messages[-1]
            if isinstance(last, ModelResponse) and last is not state.last_response:
                response = last
        if response is None or not response.parts:
            return
        # A call the Stop cut off mid-stream has half its JSON: stored, it
        # would break the session with a strict provider. It never ran.
        response = _drop_broken_calls(response)
        self._tokens_spent += _response_tokens(response)
        if not _calls(response) and not _response_text(response):
            return
        self._take_turn(active, state, response)

    async def _settle_inflight(self, grace: float = STOP_SETTLE_S) -> None:
        """Wait, up to ``grace`` in total, for the calls a Stop abandoned while
        they ran, so their rows hold the real results. A call that had not
        started is closed at once: it will never run."""
        deadline = time.monotonic() + grace
        for record in list(self._toolset.calls.values()):
            if record.result is not UNSET or record.done.is_set():
                continue
            if record.close_unstarted():
                continue
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            await asyncio.to_thread(record.done.wait, remaining)

    # -- per round -------------------------------------------------------

    def _account(
        self,
        response: ModelResponse,
        timings: RunTimings,
        active: _ActiveRun,
        elapsed_ms: float,
        mapper: StreamMapper,
    ) -> None:
        """Usage, budget refund, retry timings and the debug tap for one
        finished model request."""
        details = (response.provider_details or {}).get(LEGACY_DETAILS_KEY) or {}
        raw_usage = details.get("usage") if details else None
        if raw_usage is None and details == {}:
            usage = response.usage
            raw_usage = (
                {
                    "prompt_tokens": usage.input_tokens,
                    "completion_tokens": usage.output_tokens,
                    "total_tokens": usage.input_tokens + usage.output_tokens,
                }
                if (usage.input_tokens or usage.output_tokens)
                else None
            )
            if raw_usage is not None and usage.cache_read_tokens:
                raw_usage["cached_tokens"] = usage.cache_read_tokens
        timings.cached_tokens += cached_tokens_from_usage(raw_usage)
        if timings.first_token_ms is None and timings.model_calls == 1:
            # Text, thinking or a tool call: whatever the provider sent first.
            first = [
                v
                for v in (mapper.first_content_ms, mapper.first_reasoning_ms, mapper.first_event_ms)
                if v is not None
            ]
            if first:
                # The mapper's clock starts before the history processor
                # runs inside the request node; the provider's part is after.
                timings.first_token_ms = max(0.0, min(first) - active.prepare_ms)
        timing = details.get("timing") if details else None
        if isinstance(timing, dict):
            attempts = int(timing.get("attempts") or 1)
            if attempts > 1:
                timings.retries += attempts - 1
                timings.retry_ms += float(timing.get("wasted_ms") or 0.0)
        if self._ladder is not None:
            self._ladder.record_usage(raw_usage)
        self._tokens_spent += total_tokens_from_usage(raw_usage)
        if not details:
            self._trace_model_call(response, elapsed_ms - active.prepare_ms, mapper, raw_usage)
        if details.get("housekeeping"):
            self._budget.refund()
        if self._debug_observer is not None:
            model_timing = timing if isinstance(timing, dict) else mapper.timing()
            self._emit_debug(
                active,
                {
                    "context_prepare_ms": active.prepare_ms,
                    "model_complete_ms": max(0.0, elapsed_ms - active.prepare_ms),
                    "model": model_timing,
                    "usage": raw_usage,
                    "tps": details.get("tps") if details else None,
                },
            )

    def _trace_model_call(
        self,
        response: ModelResponse,
        total_ms: float,
        mapper: StreamMapper,
        usage: dict | None,
    ) -> None:
        """The ``model_call`` and ``usage`` trace lines for a streamed request,
        in the fields ``trace_report`` attributes the turn with (first byte =
        provider wait, the rest = generation)."""
        tracer = get_tracer()
        if not tracer.enabled:
            return
        first = mapper.first_event_ms
        tokens = [v for v in (mapper.first_content_ms, mapper.first_reasoning_ms) if v is not None]
        usage = usage or {}
        tracer.emit(
            "model_call",
            model=response.model_name,
            ok=True,
            first_frame_ms=None if first is None else round(first, 3),
            first_reasoning_ms=None if mapper.first_reasoning_ms is None else round(mapper.first_reasoning_ms, 3),
            first_content_ms=None if mapper.first_content_ms is None else round(mapper.first_content_ms, 3),
            first_token_ms=round(min(tokens), 3) if tokens else None,
            stream_ms=None if first is None else round(max(0.0, total_ms - first), 3),
            total_ms=round(max(0.0, total_ms), 3),
            attempts=1,
            prompt_tokens=usage.get("prompt_tokens"),
            completion_tokens=usage.get("completion_tokens"),
            total_tokens=usage.get("total_tokens"),
            finish_reason=response.finish_reason,
        )
        if usage:
            tracer.emit(
                "usage",
                prompt_tokens=usage.get("prompt_tokens"),
                completion_tokens=usage.get("completion_tokens"),
                total_tokens=usage.get("total_tokens"),
            )

    def _persist_assistant(self, session_id: int, response: ModelResponse) -> None:
        self._append(session_id, "assistant", response_to_row(response))

    # -- tools -----------------------------------------------------------

    def _on_tool_event_part(
        self,
        active: _ActiveRun,
        calls: list[ToolCallPart],
        event: Any,
        tools_used: list[str],
    ) -> None:
        part = getattr(event, "part", None)
        if not isinstance(part, (ToolReturnPart, RetryPromptPart)):
            if isinstance(part, ToolCallPart):
                self._trace_tool_start(part)
            return
        if getattr(event, "event_kind", "") not in ("function_tool_result",):
            return
        call = next((c for c in calls if c.tool_call_id == part.tool_call_id), None)
        if call is None:
            return
        self._write_tool_row(active, call, part, tools_used)

    def _write_tool_row(
        self,
        active: _ActiveRun,
        call: ToolCallPart,
        part: ToolReturnPart | RetryPromptPart | None,
        tools_used: list[str],
    ) -> None:
        """One ``tool`` row and one ``tool`` event per call, exactly once."""
        call_id = call.tool_call_id
        if call_id in active.written_calls:
            return
        active.written_calls.add(call_id)
        record = self._toolset.calls.get(call_id)
        raised = False
        started_at = record.started_at if record and record.started_at else time.time()
        if record is not None and record.result is not UNSET:
            result = record.result
            raised = record.raised
        elif isinstance(part, RetryPromptPart):
            args = tool_call_args(call)
            if (
                self._registry.has(call.tool_name)
                and self._registry.is_deferred(call.tool_name)
                and not self._policy.requires_approval(call.tool_name)
                and self._registry.available(call.tool_name)
            ):
                # Pydantic AI refuses a deferred tool the model has not
                # searched for. The model named it right, so it runs: the
                # stored row is its real result, and the discovery record
                # ``rows_to_messages`` adds keeps the next call from being
                # refused again. A tool behind an approval is never run here.
                result = self._registry.dispatch(
                    call.tool_name, args if isinstance(args, dict) else {}
                )
            elif self._registry.has(call.tool_name):
                # A real tool Pydantic AI refused this turn (a deferred tool
                # the model has not searched for yet): its reason, as an error.
                result = {"error": part.model_response(), "tool": call.tool_name}
            else:
                # A name no tool answers to: the registry's own envelope (with
                # the browser hint), the same row the native loop stored.
                result = self._registry.dispatch(
                    call.tool_name, args if isinstance(args, dict) else {}
                )
        elif isinstance(part, ToolReturnPart):
            result = part.content
        else:
            result = INTERRUPTED_TOOL_RESULT
            raised = True
        self._append(
            active.session_id,
            "tool",
            {
                "role": "tool",
                "tool_call_id": call_id,
                "name": call.tool_name,
                "content": result,
            },
        )
        completed_at = record.completed_at if record and record.completed_at else time.time()
        tracer = get_tracer()
        if tracer.enabled:
            tracer.emit(
                "tool_end",
                tool=call.tool_name,
                call_id=call_id,
                ms=round(max(0.0, completed_at - started_at) * 1000, 3),
                ok=not raised,
                result_chars=len(str(result)),
                text=tracer.text(str(result) if result is not None else None),
            )
        self._emit_tool(call, result, started_at=started_at, completed_at=completed_at, raised=raised)
        tools_used.append(call.tool_name)

    def _close_calls(
        self, active: _ActiveRun, calls: list[ToolCallPart], tools_used: list[str]
    ) -> None:
        """Every call of a turn gets a row: the stored conversation must never
        hold an assistant call without its result."""
        for call in calls:
            if call.tool_call_id not in active.written_calls:
                record = self._toolset.calls.get(call.tool_call_id)
                if record is not None and record.result is UNSET:
                    record.raised = True
                    record.result = (
                        INTERRUPTED_TOOL_RESULT
                        if record.close_unstarted()
                        else STOPPED_TOOL_RESULT
                    )
                self._write_tool_row(active, call, None, tools_used)

    def _trace_tool_start(self, call: ToolCallPart) -> None:
        tracer = get_tracer()
        if tracer.enabled:
            args = tool_call_args(call)
            tracer.emit(
                "tool_start",
                tool=call.tool_name,
                call_id=call.tool_call_id,
                args_chars=len(str(args)),
                text=tracer.text(str(args) if args else None),
            )

    def _emit_tool(
        self,
        call: ToolCallPart,
        result: Any,
        *,
        started_at: float,
        completed_at: float,
        raised: bool,
    ) -> None:
        if self._tool_event_observer is None:
            return
        try:
            self._tool_event_observer(
                tool_event_fields(
                    name=call.tool_name,
                    arguments=tool_call_args(call),
                    result=result,
                    call_id=call.tool_call_id,
                    started_at=started_at,
                    completed_at=completed_at,
                    raised=raised,
                )
            )
        except Exception:  # noqa: BLE001 — a UI sink error must not abort a run
            pass

    def _drain_context(self, session_id: int) -> None:
        for provider in self._context_providers:
            for message in provider():
                self._append(
                    session_id,
                    message.get("role_tag", "context"),
                    {k: v for k, v in message.items() if k != "role_tag"},
                )

    # -- memory ----------------------------------------------------------

    def _inject_recall(self, session_id: int, user_message: str) -> float:
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
        except Exception:  # noqa: BLE001
            pass

    # -- debug and trace -------------------------------------------------

    def _emit_debug(self, active: _ActiveRun, timing: dict) -> None:
        ladder = self._ladder
        if ladder is not None:
            ls = ladder.last_stats
            stats: dict[str, Any] = {
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
                    "session_key": active.session_key,
                    "round": active.round,
                    "messages": active.outbound,
                    "stats": stats,
                }
            )
        except Exception:  # noqa: BLE001
            pass

    def _trace_prepare(self, tracer: Any, outbound: list[dict], elapsed: float) -> None:
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
                summary_deferred=bool(getattr(stats, "deferred", False)),
                blocking_aux=bool(getattr(stats, "blocking_aux", False)),
                idle_dropped=int(getattr(stats, "idle_dropped", 0)),
            )
        else:
            tracer.emit("ladder_pass", ms=round(elapsed * 1000, 3), tier=0)
        estimated = sum(estimate_message_tokens(m) for m in outbound)
        tools = self._registry.openai_tools()
        tracer.emit(
            "payload_prepared",
            messages=len(outbound),
            prompt_tokens_est=estimated,
            tool_schema_tokens=_tool_schema_tokens(tools),
            tools=len(tools),
        )


# -- helpers -------------------------------------------------------------------


def _calls(response: ModelResponse) -> list[ToolCallPart]:
    return [p for p in response.parts if isinstance(p, ToolCallPart)]


def _last_response(run: Any) -> ModelResponse:
    for message in reversed(run.ctx.state.message_history):
        if isinstance(message, ModelResponse):
            return message
    return ModelResponse(parts=[])  # pragma: no cover — a request node always adds one


def _response_text(response: ModelResponse) -> str | None:
    """The turn's answer, stripped (the old client's rule): ``None`` for no
    text at all."""
    text = "".join(p.content for p in response.parts if isinstance(p, TextPart)).strip()
    return text or None


def _count_retries(request_log: Any, timings: RunTimings) -> None:
    """Requests beyond the first (SDK retries, a resend after a 401) are paid
    for at the provider: they go on the run row."""
    if request_log is None:
        return
    extra, wasted = request_log.retries()
    if extra:
        timings.retries += extra
        timings.retry_ms += wasted


async def _close_model(model: Any) -> None:
    client = getattr(model, "client", None)
    close = getattr(client, "close", None)
    if callable(close):
        try:
            await close()
        except Exception:  # noqa: BLE001 — closing must not fail a run
            pass


def _drop_broken_calls(response: ModelResponse) -> ModelResponse:
    """The response without tool calls whose arguments are not valid JSON."""
    parts = [p for p in response.parts if not (isinstance(p, ToolCallPart) and not _args_ok(p))]
    if len(parts) == len(response.parts):
        return response
    return replace(response, parts=parts)


def _args_ok(part: ToolCallPart) -> bool:
    args = part.args
    if args is None or isinstance(args, dict):
        return True
    try:
        return isinstance(json.loads(args), dict) if args.strip() else True
    except (ValueError, AttributeError):
        return False


def _response_tokens(response: ModelResponse) -> int:
    details = (response.provider_details or {}).get(LEGACY_DETAILS_KEY) or {}
    if details:
        return total_tokens_from_usage(details.get("usage"))
    usage = response.usage
    return int(usage.input_tokens or 0) + int(usage.output_tokens or 0)


def _no_output(response: ModelResponse) -> bool:
    """Pydantic AI's own test for a reply with nothing to act on: no parts,
    only empty text parts, or only thinking (plus empty text). Whitespace is
    text to Pydantic AI, so it is text here too (and strips to no answer)."""
    parts = response.parts
    if not parts:
        return True
    return all(
        isinstance(p, ThinkingPart) or (isinstance(p, TextPart) and not p.content)
        for p in parts
    )


def cached_tokens_from_usage(usage: dict | None) -> int:
    """Prompt tokens served from the provider's cache, from a usage dict in
    any of the shapes the route and the clients produce: OpenAI's
    ``prompt_tokens_details.cached_tokens``, a flat ``cached_tokens`` /
    ``cache_read_tokens``, or Anthropic's ``cache_read_input_tokens``."""
    if not isinstance(usage, dict):
        return 0
    candidates: list[Any] = []
    details = usage.get("prompt_tokens_details")
    if isinstance(details, dict):
        candidates.append(details.get("cached_tokens"))
    candidates += [
        usage.get("cached_tokens"),
        usage.get("cache_read_tokens"),
        usage.get("cache_read_input_tokens"),
    ]
    for value in candidates:
        if isinstance(value, (int, float)) and not isinstance(value, bool) and value > 0:
            return int(value)
    return 0


def _log_cut_off(reason: str | None) -> None:
    import logging

    logging.getLogger(__name__).warning(
        "model turn ended with no answer: finish_reason=%s "
        "(output limit or provider filter); the run finishes without a reply",
        reason,
    )


def _finish_summary(calls: list[ToolCallPart], response: ModelResponse) -> str | None:
    """The first ``finish`` call's summary, or the turn's text when the
    summary is empty — the native rule."""
    for call in calls:
        if call.tool_name == FINISH_TOOL:
            args = tool_call_args(call)
            summary = str(args.get("summary", "")) if isinstance(args, dict) else ""
            return summary or (_response_text(response) or "")
    return None
