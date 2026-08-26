"""Subagents / multi-agent collaboration (§7.6).

A ``delegate_task`` tool spawns isolated child agents — one at a time or a whole
batch in parallel — and a ``subagent_control`` tool lists, inspects, steers and
interrupts them. Everything here is mechanism; the wiring that turns a child into
a real runtime lives in :mod:`cowork_agent.runtime`, which is what keeps this
module free of an import cycle and testable against a fake runner.

Five properties, each enforced here rather than hoped for:

1. **A child is isolated, not a thread sharing the parent's world.** Every child
   gets its own ``task_id``, its own state database (its own session, its own
   history) and its own ``Environment`` built from that task id — so with the
   container backend a batch of subagents is a batch of containers for free
   (§6). Hermes runs subagents as in-process threads over one shared
   environment; the thread here is only the *driver*, the work happens in the
   child's own sandbox.
2. **The handle survives a restart.** Every state transition is written to the
   ``subagents`` table of the parent's SQLite store, so the Flutter app can list
   subagents (state / progress / result / error) after the process died, and a
   record left ``running`` by a killed process is reaped into ``failed`` instead
   of lingering as a lie.
3. **A parent waiting on children is active, not idle.** A heartbeat pulses an
   :class:`ActivityMonitor` for as long as at least one child is alive, so the
   inactivity timeout that exists to kill stalled runs cannot kill a parent that
   is doing the most useful thing it can do — waiting.
4. **Bounded by depth, by concurrency, by pause and by token spend.** A
   per-child ``max_child_tokens`` caps what one child may spend (§7.6 — a parent
   that fans out and stops waiting must not let a looping child burn credits
   unwatched); ``max_depth`` stops a child
   from recursively spawning a tree; a **per-level** semaphore caps how many
   children run at once *at each depth* (per level, not global, because a global
   gate deadlocks the moment parents hold slots while waiting for children);
   ``max_wait_s`` bounds how long one ``delegate_task`` call may park the parent.
5. **A child cannot take the parent or its siblings down.** The driver thread
   catches everything, records it as that child's failure, and leaves the rest of
   the batch running. Each child owns a :class:`~cowork_agent.loop.KillSwitch`,
   so the §7.1 Stop button reaches one child, all children, or the whole tree.
   The tree case is wired, not polled: a supervisor given a ``parent_kill``
   registers on it (``KillSwitch.on_interrupt``), and because a child's own
   switch is the ``parent_kill`` of *its* supervisor, one interrupt at the root
   walks down to the last grandchild in a single call — even for children
   nobody is waiting on.

**Git (§7.7).** With a versioned workspace each child works in its own git
worktree on its own branch, and a successful child is merged back into the
parent's branch. Two children therefore never write the same index, and a
conflicting pair fails loudly with the branch kept for inspection instead of
half-merging. Without versioning the children share the parent's workspace
directory — the run still works, which is the point, but a parallel batch that
edits the same files has nothing protecting it, which is the honest reason to
leave versioning on.
"""

from __future__ import annotations

import re
import threading
import time
import uuid
from collections.abc import Callable, Sequence
from dataclasses import asdict, dataclass
from enum import Enum
from pathlib import Path
from typing import Any, Protocol

from .loop import KillSwitch, LoopResult, StopReason
from .registry import ToolRegistry
from .state import StateStore
from .workspace_git import GitWorkspace, WorktreeInfo

# -- limits ----------------------------------------------------------------

#: Maximum depth of a spawned child. The root run is depth 0, so the default
#: allows a child (depth 1) and a grandchild (depth 2) and refuses the next
#: level. Two is what a real plan needs — a lead that fans work out, and a
#: worker that splits off one subtask it discovered — while anything deeper is,
#: in practice, a model that has started recursing instead of working.
DEFAULT_MAX_DEPTH = 2

#: Children running at once **per depth level**. Four is the useful width of a
#: fan-out on one laptop: each child is a container with its own model stream, so
#: the ceiling is host RAM and token spend long before it is CPU. Worst case is
#: ``max_concurrency * max_depth`` live children (8 by default), because each
#: level has its own gate.
DEFAULT_MAX_CONCURRENCY = 4

#: Tasks one ``delegate_task`` call may open. Higher than the concurrency gate on
#: purpose — the surplus queues — but low enough that a model cannot open fifty
#: sandboxes with one malformed argument.
DEFAULT_MAX_BATCH = 6

#: Pause cap: how long one ``delegate_task`` call may block the parent. On expiry
#: the call returns the handles with the children still running, so the parent
#: keeps its turn instead of hanging forever on a wedged child.
DEFAULT_MAX_WAIT_S = 900.0

#: Heartbeat period while children are alive.
DEFAULT_HEARTBEAT_S = 5.0

#: Default per-child token spend cap (prompt + completion), or ``None`` for no
#: cap. A subagent is the one place an unbounded run is most likely — a parent
#: fans out work and stops waiting, so a wedged or looping child would otherwise
#: burn credits with nobody watching. ``None`` keeps the historical behaviour
#: (bounded only by iterations); an executor sets a real number to cap spend.
DEFAULT_MAX_CHILD_TOKENS: int | None = None

#: How long a wait keeps running after the children were told to stop, so the
#: caller sees the cancellation instead of a stale "running".
CANCEL_GRACE_S = 30.0

#: A child's final answer as handed to the parent model.
RESULT_TEXT_CAP = 6000

#: A child's error text.
ERROR_TEXT_CAP = 500

#: Progress (streamed-event count) is written to the store at most this often.
PROGRESS_WRITE_INTERVAL_S = 1.0

_SAFE_ID = re.compile(r"[^A-Za-z0-9_.-]+")


def _sanitize_id(value: str) -> str:
    """Task ids become container names, branch names and directory names."""
    clean = _SAFE_ID.sub("-", value).strip("-.")
    return clean or "task"


def _cap(text: str, limit: int) -> str:
    if len(text) <= limit:
        return text
    return text[:limit] + f"…[+{len(text) - limit} chars]"


class SubagentState(str, Enum):
    QUEUED = "queued"
    RUNNING = "running"
    SUCCEEDED = "succeeded"
    FAILED = "failed"
    CANCELLED = "cancelled"

    @property
    def terminal(self) -> bool:
        return self in (
            SubagentState.SUCCEEDED,
            SubagentState.FAILED,
            SubagentState.CANCELLED,
        )


@dataclass(frozen=True)
class SubagentLimits:
    """Depth, concurrency and pause caps. See the module constants for why."""

    max_depth: int = DEFAULT_MAX_DEPTH
    max_concurrency: int = DEFAULT_MAX_CONCURRENCY
    max_batch: int = DEFAULT_MAX_BATCH
    max_wait_s: float = DEFAULT_MAX_WAIT_S
    heartbeat_s: float = DEFAULT_HEARTBEAT_S
    #: Per-child token spend cap (prompt + completion). ``None`` = uncapped.
    max_child_tokens: int | None = DEFAULT_MAX_CHILD_TOKENS


# -- the serializable handle ------------------------------------------------


@dataclass
class SubagentRecord:
    """One child, as the app sees it and as the store keeps it.

    Plain data on purpose: it round-trips through JSON, so the Flutter app can
    render a subagent list from the store alone and a relaunch reconstructs every
    handle without any in-process state.
    """

    subagent_id: str
    parent_key: str
    task_id: str
    title: str
    prompt: str
    depth: int
    state: SubagentState = SubagentState.QUEUED
    created_at: float = 0.0
    started_at: float | None = None
    finished_at: float | None = None
    events: int = 0
    iterations: int = 0
    #: Tokens (prompt + completion) this child spent, from its LoopResult. Lets
    #: the app show a per-child cost next to the run's own (§7.6).
    tokens_spent: int = 0
    result: str | None = None
    error: str | None = None
    stop_reason: str | None = None
    branch: str | None = None
    workspace: str | None = None
    db_path: str | None = None
    merged: bool = False
    merge_note: str | None = None

    # -- serialisation ---------------------------------------------------
    def to_dict(self) -> dict:
        data = asdict(self)
        data["state"] = self.state.value
        return data

    @classmethod
    def from_dict(cls, data: dict) -> "SubagentRecord":
        raw = dict(data)
        state = raw.get("state", SubagentState.QUEUED.value)
        try:
            raw["state"] = SubagentState(state)
        except ValueError:
            raw["state"] = SubagentState.FAILED
        fields = {f for f in cls.__dataclass_fields__}  # tolerate schema drift
        return cls(**{k: v for k, v in raw.items() if k in fields})

    # -- the compact form the model reads --------------------------------
    def summary(self) -> dict:
        """What goes back to the model: identity, state, outcome. No prompt echo,
        no timestamps — the model wrote the prompt and cannot use epoch floats."""
        out: dict[str, Any] = {
            "subagent_id": self.subagent_id,
            "title": self.title,
            "state": self.state.value,
        }
        if self.tokens_spent > 0:
            out["tokens_spent"] = self.tokens_spent
        if self.result is not None:
            out["result"] = _cap(self.result, RESULT_TEXT_CAP)
        if self.error is not None:
            out["error"] = _cap(self.error, ERROR_TEXT_CAP)
        if self.branch:
            out["branch"] = self.branch
            out["merged"] = self.merged
        if self.merge_note:
            out["merge_note"] = self.merge_note
        return out


class SubagentRegistry:
    """Persistent registry of handles, backed by the parent's state store.

    Reads reconstruct a :class:`SubagentRecord` from the row, so a handle is
    never only in RAM.
    """

    def __init__(self, store: StateStore, *, parent_key: str) -> None:
        self._store = store
        self._parent_key = parent_key

    @property
    def parent_key(self) -> str:
        return self._parent_key

    def put(self, record: SubagentRecord) -> None:
        self._store.save_subagent(
            record.subagent_id, record.parent_key, record.to_dict()
        )

    def get(self, subagent_id: str) -> SubagentRecord | None:
        data = self._store.load_subagent(subagent_id)
        return SubagentRecord.from_dict(data) if data else None

    def list(self, *, parent_key: str | None = None) -> list[SubagentRecord]:
        key = self._parent_key if parent_key is None else parent_key
        return [
            SubagentRecord.from_dict(row)
            for row in self._store.list_subagents(parent_key=key)
        ]


# -- parent-activity heartbeat ---------------------------------------------


class ActivityMonitor:
    """The seam an inactivity timeout reads.

    A parent blocked on children produces no tokens and touches no tool, so any
    timeout watching *output* would kill it. It watches this instead, and the
    supervisor pulses it while children are alive.
    """

    def __init__(self, *, clock: Callable[[], float] = time.monotonic) -> None:
        self._clock = clock
        self._lock = threading.Lock()
        self._last = clock()
        self._marks = 0

    def mark_active(self) -> None:
        with self._lock:
            self._last = self._clock()
            self._marks += 1

    @property
    def last_active(self) -> float:
        with self._lock:
            return self._last

    @property
    def marks(self) -> int:
        """How many times activity was reported. Tests assert on this; a UI can
        use it as a crude progress pulse."""
        with self._lock:
            return self._marks

    def idle_for(self) -> float:
        with self._lock:
            return max(0.0, self._clock() - self._last)

    def is_idle(self, timeout: float) -> bool:
        return self.idle_for() > timeout


# -- the child seam --------------------------------------------------------


@dataclass
class ChildContext:
    """Everything a child needs, and nothing of the parent's.

    The supervisor builds this; a :class:`ChildRunner` turns it into a real
    runtime. Tests pass a fake runner and never build one.
    """

    subagent_id: str
    task_id: str
    title: str
    prompt: str
    depth: int
    session_key: str
    db_path: str
    workspace: str | None
    branch: str | None
    kill_switch: KillSwitch
    emit: Callable[[dict], None]
    limits: SubagentLimits
    gates: dict[int, threading.BoundedSemaphore]
    root: str
    #: Called by the runner with the built loop, so the supervisor can steer a
    #: running child (append a message to its session) without owning its wiring.
    on_loop: Callable[[Any], None] = lambda loop: None


class ChildRunner(Protocol):
    def __call__(self, ctx: ChildContext) -> LoopResult: ...


_TERMINAL_STATE = {
    StopReason.FINISHED: SubagentState.SUCCEEDED,
    StopReason.INTERRUPTED: SubagentState.CANCELLED,
    StopReason.ESTOP: SubagentState.CANCELLED,
    StopReason.MAX_ITERATIONS: SubagentState.FAILED,
    StopReason.BUDGET_EXHAUSTED: SubagentState.FAILED,
    StopReason.TOKEN_BUDGET_EXHAUSTED: SubagentState.FAILED,
}


# -- the supervisor --------------------------------------------------------


class SubagentSupervisor:
    """Owns the children of one agent run.

    One supervisor per agent (root or child). A child's own supervisor shares the
    ``gates`` dict with the whole tree, so the concurrency ceiling is a property
    of the tree, not of one node.
    """

    def __init__(
        self,
        *,
        parent_key: str,
        store: StateStore,
        runner: ChildRunner,
        root: str,
        depth: int = 0,
        task_id: str = "task",
        limits: SubagentLimits | None = None,
        workspace: str | None = None,
        git: GitWorkspace | None = None,
        gates: dict[int, threading.BoundedSemaphore] | None = None,
        on_event: Callable[[dict], None] | None = None,
        activity: ActivityMonitor | None = None,
        parent_kill: KillSwitch | None = None,
    ) -> None:
        self._registry = SubagentRegistry(store, parent_key=parent_key)
        self._runner = runner
        self._root = Path(root)
        self._depth = depth
        self._task_id = _sanitize_id(task_id)
        self._limits = limits or SubagentLimits()
        self._workspace = workspace
        self._git = git if (git is not None and git.enabled) else None
        self._gates = gates if gates is not None else {}
        self._gates_lock = threading.Lock()
        self._on_event = on_event
        self._activity = activity or ActivityMonitor()
        self._parent_kill = parent_kill

        self._cond = threading.Condition()
        self._live: dict[str, _LiveChild] = {}
        self._threads: list[threading.Thread] = []
        self._counter = 0
        self._pulse: threading.Thread | None = None
        self._pulse_stop = threading.Event()

        # A record that still claims to be running has no driver behind it: this
        # supervisor is new, so whoever was driving it is gone. Say that, instead
        # of leaving a handle that lies about work being in flight.
        self._reap_orphans()

        # One Stop must reach the WHOLE tree, at once. Waiting for the parent's
        # loop to unwind before cancelling children stops one level per unwind,
        # and a parent that is not waiting on its children (``wait=false``) never
        # unwinds into them at all. Listening on the parent's switch instead
        # makes the cancel recursive by construction: each child's own switch is
        # the ``parent_kill`` of its own supervisor, so the notification walks
        # down to the last grandchild in one call.
        if parent_kill is not None:
            parent_kill.on_interrupt(self._on_parent_interrupt)

    # -- introspection ---------------------------------------------------
    @property
    def limits(self) -> SubagentLimits:
        return self._limits

    @property
    def depth(self) -> int:
        return self._depth

    @property
    def activity(self) -> ActivityMonitor:
        return self._activity

    @property
    def gates(self) -> dict[int, threading.BoundedSemaphore]:
        return self._gates

    @property
    def registry(self) -> SubagentRegistry:
        return self._registry

    def records(self) -> list[SubagentRecord]:
        return self._registry.list()

    def get(self, subagent_id: str) -> SubagentRecord | None:
        return self._registry.get(subagent_id)

    def live_count(self) -> int:
        with self._cond:
            return len(self._live)

    # -- spawning --------------------------------------------------------
    def can_delegate(self) -> tuple[bool, str]:
        child_depth = self._depth + 1
        if child_depth > self._limits.max_depth:
            return False, (
                f"delegation refused: depth limit reached (max_depth="
                f"{self._limits.max_depth}). You are a subagent at depth "
                f"{self._depth}; a subagent this deep must do the work itself "
                "instead of delegating it."
            )
        return True, ""

    def delegate(
        self,
        tasks: Sequence[Any] | str | dict,
        *,
        wait: bool = True,
        timeout: float | None = None,
    ) -> dict:
        """Start one child or a batch, optionally waiting for the batch.

        Never raises: every refusal comes back as ``{"ok": False, "error": ...}``
        so the model reads a sentence, not a traceback.
        """
        allowed, why = self.can_delegate()
        if not allowed:
            return {"ok": False, "error": why}

        try:
            specs = _normalize_tasks(tasks)
        except ValueError as exc:
            return {"ok": False, "error": str(exc)}
        if not specs:
            return {"ok": False, "error": "no tasks given"}
        if len(specs) > self._limits.max_batch:
            return {
                "ok": False,
                "error": (
                    f"batch of {len(specs)} refused: at most "
                    f"{self._limits.max_batch} subagents per call. Split the "
                    "work or delegate in waves."
                ),
            }

        records: list[SubagentRecord] = []
        try:
            for prompt, title in specs:
                records.append(self._start(prompt, title))
        except Exception as exc:  # noqa: BLE001 — a half-open batch is worse
            for record in records:
                self.cancel(record.subagent_id)
            return {
                "ok": False,
                "error": f"could not start the batch: {type(exc).__name__}: {exc}",
            }
        if not wait:
            return {
                "ok": True,
                "waited": False,
                "subagents": [r.summary() for r in records],
                "note": (
                    "The subagents are running. Use subagent_control to check "
                    "on them or to stop them."
                ),
            }

        budget = self._limits.max_wait_s if timeout is None else float(timeout)
        budget = min(budget, self._limits.max_wait_s)
        finished = self.wait_for([r.subagent_id for r in records], timeout=budget)
        pending = [r for r in finished if not r.state.terminal]
        out: dict[str, Any] = {
            "ok": True,
            "waited": True,
            "subagents": [r.summary() for r in finished],
        }
        if pending:
            out["note"] = (
                f"{len(pending)} subagent(s) are still running after "
                f"{budget:.0f}s. Their results are not in yet — check them with "
                "subagent_control, or stop them."
            )
        return out

    def _start(self, prompt: str, title: str | None) -> SubagentRecord:
        self._counter += 1
        subagent_id = f"sa_{uuid.uuid4().hex[:12]}"
        child_depth = self._depth + 1
        task_id = _sanitize_id(f"{self._task_id}.s{self._counter}-{subagent_id[3:9]}")
        home = self._root / subagent_id
        home.mkdir(parents=True, exist_ok=True)

        branch: str | None = None
        worktree: WorktreeInfo | None = None
        workspace = self._workspace
        if self._git is not None:
            worktree = self._git.create_worktree(f"cowork/{task_id}")
            if worktree is not None:
                branch, workspace = worktree.branch, worktree.path

        record = SubagentRecord(
            subagent_id=subagent_id,
            parent_key=self._registry.parent_key,
            task_id=task_id,
            title=title or _default_title(prompt),
            prompt=prompt,
            depth=child_depth,
            state=SubagentState.QUEUED,
            created_at=time.time(),
            branch=branch,
            workspace=workspace,
            db_path=str(home / "state.db"),
        )
        self._registry.put(record)

        # The child inherits the parent's file sentinel, so an engaged ESTOP stops
        # it at its own next poll instead of only when the parent unwinds into it.
        # Without that, a child nobody is waiting on outlives the ``touch``.
        kill = KillSwitch(
            self._parent_kill.estop_path if self._parent_kill is not None else None
        )
        if self._parent_stopped():
            # Opened while the parent was already stopping (a queued batch, a
            # racing delegate call): pre-interrupt it so ``_drive`` finishes it
            # without ever building a sandbox or a model stream.
            kill.interrupt()
        ctx = ChildContext(
            subagent_id=subagent_id,
            task_id=task_id,
            title=record.title,
            prompt=prompt,
            depth=child_depth,
            session_key=f"subagent:{subagent_id}",
            db_path=str(home / "state.db"),
            workspace=workspace,
            branch=branch,
            kill_switch=kill,
            emit=lambda payload, sid=subagent_id: self._on_child_output(sid, payload),
            limits=self._limits,
            gates=self._gates,
            root=str(home),
        )
        live = _LiveChild(record=record, ctx=ctx, kill=kill, worktree=worktree)
        ctx.on_loop = live.bind_loop

        with self._cond:
            self._live[subagent_id] = live
            self._cond.notify_all()
        self._start_pulse()
        self._emit_state(record)

        thread = threading.Thread(
            target=self._drive,
            args=(live,),
            name=f"subagent-{subagent_id}",
            daemon=True,
        )
        self._threads = [t for t in self._threads if t.is_alive()]
        self._threads.append(thread)
        thread.start()
        return record

    # -- the driver thread ------------------------------------------------
    def _drive(self, live: "_LiveChild") -> None:
        record = live.record
        gate = self._gate(record.depth)
        gate.acquire()
        try:
            # Cancelled while it was queued: never start the sandbox at all.
            if live.kill.interrupted():
                self._finish(live, SubagentState.CANCELLED, stop_reason="interrupted")
                return
            record.state = SubagentState.RUNNING
            record.started_at = time.time()
            self._persist(live, force=True)
            self._emit_state(record)
            result = self._runner(live.ctx)
        except BaseException as exc:  # noqa: BLE001 — a child may not take us down
            self._finish(
                live,
                SubagentState.FAILED,
                error=f"{type(exc).__name__}: {exc}",
            )
        else:
            self._settle(live, result)
        finally:
            gate.release()
            with self._cond:
                self._live.pop(record.subagent_id, None)
                self._cond.notify_all()
            self._stop_pulse_if_idle()

    def _settle(self, live: "_LiveChild", result: LoopResult) -> None:
        record = live.record
        state = _TERMINAL_STATE.get(result.reason, SubagentState.FAILED)
        error: str | None = None
        if state is SubagentState.FAILED:
            error = (
                f"the subagent stopped without finishing (reason="
                f"{result.reason.value}, {result.iterations} rounds)"
            )
        self._finish(
            live,
            state,
            result=result.final_answer,
            error=error,
            stop_reason=result.reason.value,
            iterations=result.iterations,
            tokens_spent=result.tokens_spent,
        )

    def _finish(
        self,
        live: "_LiveChild",
        state: SubagentState,
        *,
        result: str | None = None,
        error: str | None = None,
        stop_reason: str | None = None,
        iterations: int = 0,
        tokens_spent: int = 0,
    ) -> None:
        record = live.record
        record.state = state
        record.finished_at = time.time()
        record.result = _cap(result, RESULT_TEXT_CAP) if result else None
        record.error = _cap(error, ERROR_TEXT_CAP) if error else None
        record.stop_reason = stop_reason
        record.iterations = iterations
        record.tokens_spent = tokens_spent
        self._collect_git(live)
        self._persist(live, force=True)
        self._emit_state(record)

    def _collect_git(self, live: "_LiveChild") -> None:
        """Merge a finished child's branch back (§7.7).

        Only a success is merged: half-done work from a cancelled or crashed
        child stays on its branch, where it can be read, and out of the parent's
        tree, where it would be indistinguishable from work that was meant.
        """
        worktree = live.worktree
        record = live.record
        if self._git is None or worktree is None:
            return
        if record.state is not SubagentState.SUCCEEDED:
            record.merge_note = (
                f"not merged ({record.state.value}); the work is kept on branch "
                f"{worktree.branch}"
            )
            self._git.release_worktree(worktree, keep_branch=True)
            return
        outcome = self._git.merge_worktree(
            worktree, message=f"subagent: {record.title}"
        )
        record.merged = bool(outcome.get("ok"))
        if not record.merged:
            record.merge_note = _cap(
                str(outcome.get("error") or "merge failed"), ERROR_TEXT_CAP
            )
            conflicts = outcome.get("conflicts")
            if conflicts:
                record.merge_note += f" (conflicts: {', '.join(conflicts[:10])})"

    # -- gates -----------------------------------------------------------
    def _gate(self, depth: int) -> threading.BoundedSemaphore:
        """One gate per depth level.

        Per level and not global on purpose: a parent that holds a slot while it
        waits for its own children would, under a single global gate, sit on the
        slot its child needs — the textbook nested-semaphore deadlock. Per level
        the worst case is ``max_concurrency * max_depth`` live children, which is
        the number the defaults were picked against.
        """
        with self._gates_lock:
            gate = self._gates.get(depth)
            if gate is None:
                gate = threading.BoundedSemaphore(max(1, self._limits.max_concurrency))
                self._gates[depth] = gate
            return gate

    # -- waiting ---------------------------------------------------------
    def wait_for(
        self, subagent_ids: Sequence[str], *, timeout: float | None = None
    ) -> list[SubagentRecord]:
        """Block until each id is terminal, the timeout expires, or the parent is
        stopped. Pulses the activity monitor throughout — this is the wait that
        must not look like an idle process."""
        deadline = None if timeout is None else time.monotonic() + timeout
        wanted = list(subagent_ids)
        stopping = False
        while True:
            self._activity.mark_active()
            if not stopping and self._parent_stopped():
                # The parent's Stop reaches the children, and then this wait
                # keeps running for a moment: the caller asked what happened, and
                # "still running" would be a worse answer than the truth one
                # round later. It is bounded, so a wedged child cannot hold the
                # parent here.
                self.cancel_all(reason="parent stopped")
                stopping = True
                grace = time.monotonic() + CANCEL_GRACE_S
                deadline = grace if deadline is None else min(deadline, grace)
            with self._cond:
                if not any(sid in self._live for sid in wanted):
                    break
                remaining = None
                if deadline is not None:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        break
                slice_s = min(self._limits.heartbeat_s, remaining or self._limits.heartbeat_s)
                self._cond.wait(max(0.01, slice_s))
        self._activity.mark_active()
        out: list[SubagentRecord] = []
        for sid in wanted:
            record = self._registry.get(sid)
            if record is not None:
                out.append(record)
        return out

    def _on_parent_interrupt(self) -> None:
        """The parent was stopped: cancel every child of this node right now.

        Idempotent, and safe to reach a supervisor that has no children yet —
        a child started after this point sees the same flag through
        :meth:`_drive`'s queued-cancel check and never opens a sandbox.
        """
        self.cancel_all(reason="parent stopped")

    def _parent_stopped(self) -> bool:
        kill = self._parent_kill
        if kill is None:
            return False
        return kill.interrupted() or kill.estop_engaged()

    # -- heartbeat -------------------------------------------------------
    def _start_pulse(self) -> None:
        """Keep pulsing while children are alive even when the parent is *not*
        waiting (``wait=false``): the parent is then working, but a child alone
        must still count as this run being alive."""
        if self._pulse is not None and self._pulse.is_alive():
            return
        self._pulse_stop.clear()
        self._pulse = threading.Thread(
            target=self._pulse_loop, name="subagent-heartbeat", daemon=True
        )
        self._pulse.start()

    def _pulse_loop(self) -> None:
        interval = max(0.01, self._limits.heartbeat_s)
        while not self._pulse_stop.is_set():
            if self.live_count() == 0:
                return
            self._activity.mark_active()
            self._pulse_stop.wait(interval)

    def _stop_pulse_if_idle(self) -> None:
        if self.live_count() == 0:
            self._pulse_stop.set()

    # -- control ---------------------------------------------------------
    def cancel(self, subagent_id: str) -> dict:
        """Interrupt one child (§7.1, per child). The child's loop sees the flag
        at its next top-of-loop poll and stops."""
        with self._cond:
            live = self._live.get(subagent_id)
        if live is not None:
            live.kill.interrupt()
            return {
                "ok": True,
                "subagent_id": subagent_id,
                "state": "stopping",
            }
        record = self._registry.get(subagent_id)
        if record is None:
            return {"ok": False, "error": f"no such subagent: {subagent_id}"}
        return {
            "ok": True,
            "subagent_id": subagent_id,
            "state": record.state.value,
            "note": "already finished",
        }

    def cancel_all(self, *, reason: str = "cancelled") -> dict:
        with self._cond:
            live = list(self._live.values())
        for child in live:
            child.kill.interrupt()
        return {"ok": True, "stopping": [c.record.subagent_id for c in live], "reason": reason}

    def steer(self, subagent_id: str, message: str) -> dict:
        """Send a mid-run instruction to a running child.

        The child's loop rebuilds its outbound messages from its own store on
        every round, so an appended user turn is picked up on the next round —
        steering needs no new channel, only the child's session.
        """
        text = (message or "").strip()
        if not text:
            return {"ok": False, "error": "message is empty"}
        with self._cond:
            live = self._live.get(subagent_id)
        if live is None:
            return {
                "ok": False,
                "error": f"subagent {subagent_id} is not running; nothing to steer",
            }
        target = live.loop
        if target is None:
            return {
                "ok": False,
                "error": "the subagent has not started its session yet; retry",
            }
        try:
            store = target.store
            session_id = store.route(live.ctx.session_key)
            store.append_message(
                session_id,
                "user",
                {"role": "user", "content": f"[steering from your parent] {text}"},
            )
        except Exception as exc:  # noqa: BLE001 — report, never raise at the model
            return {"ok": False, "error": f"{type(exc).__name__}: {exc}"}
        self._activity.mark_active()
        return {"ok": True, "subagent_id": subagent_id, "delivered": True}

    def shutdown(self, *, join_timeout: float = 5.0) -> None:
        """Stop every child and join the driver threads. Called when the parent
        run ends — an orphaned child would keep a sandbox alive."""
        self.cancel_all(reason="shutdown")
        for thread in list(self._threads):
            thread.join(join_timeout)
        self._threads = [t for t in self._threads if t.is_alive()]
        self._pulse_stop.set()

    # -- events & persistence --------------------------------------------
    def _on_child_output(self, subagent_id: str, payload: dict) -> None:
        """One streamed event from a child, on its way to the parent's feed."""
        self._activity.mark_active()
        with self._cond:
            live = self._live.get(subagent_id)
        if live is not None:
            live.record.events += 1
            self._persist(live)
        self._publish(
            {
                "type": "subagent_output",
                "subagent_id": subagent_id,
                "title": live.record.title if live else "",
                "depth": live.record.depth if live else self._depth + 1,
                "payload": payload,
            }
        )

    def _emit_state(self, record: SubagentRecord) -> None:
        self._publish({"type": "subagent_state", **record.summary()})

    def _publish(self, event: dict) -> None:
        sink = self._on_event
        if sink is None:
            return
        try:
            sink(event)
        except Exception:  # noqa: BLE001 — a broken observer is not a failed run
            return

    def _persist(self, live: "_LiveChild", *, force: bool = False) -> None:
        """Write the handle. Progress is throttled — a write per streamed delta
        would be a SQLite transaction per delta — but every state change is
        written immediately, because that is what the app renders."""
        now = time.monotonic()
        if not force and now - live.last_write < PROGRESS_WRITE_INTERVAL_S:
            return
        live.last_write = now
        try:
            self._registry.put(live.record)
        except Exception:  # noqa: BLE001 — the run matters more than the mirror
            return

    def _reap_orphans(self) -> None:
        for record in self._registry.list():
            if record.state.terminal:
                continue
            record.state = SubagentState.FAILED
            record.finished_at = time.time()
            record.error = (
                "lost: no live driver holds this subagent any more — the run "
                "ended or the process restarted while it was working, so its "
                "result cannot be recovered"
            )
            record.stop_reason = "orphaned"
            try:
                self._registry.put(record)
            except Exception:  # noqa: BLE001
                continue


@dataclass
class _LiveChild:
    record: SubagentRecord
    ctx: ChildContext
    kill: KillSwitch
    worktree: WorktreeInfo | None = None
    loop: Any | None = None
    last_write: float = 0.0

    def bind_loop(self, loop: Any) -> None:
        self.loop = loop


def _default_title(prompt: str) -> str:
    first = prompt.strip().splitlines()[0] if prompt.strip() else "subagent"
    return _cap(first, 60)


def _normalize_tasks(tasks: Any) -> list[tuple[str, str | None]]:
    """Accept the three shapes a model actually sends: a string, one object, or a
    list of either."""
    if tasks is None:
        return []
    if isinstance(tasks, (str, dict)):
        tasks = [tasks]
    if not isinstance(tasks, (list, tuple)):
        raise ValueError("tasks must be a list of task objects or strings")
    out: list[tuple[str, str | None]] = []
    for item in tasks:
        if isinstance(item, str):
            prompt, title = item.strip(), None
        elif isinstance(item, dict):
            prompt = str(item.get("prompt") or item.get("task") or "").strip()
            raw_title = item.get("title")
            title = str(raw_title).strip() if raw_title else None
        else:
            raise ValueError("each task must be an object with a prompt, or a string")
        if not prompt:
            raise ValueError("each task needs a non-empty prompt")
        out.append((prompt, title))
    return out


# -- the tools -------------------------------------------------------------

DELEGATE_SCHEMA = {
    "type": "object",
    "description": (
        "Delegate work to subagents. Each subagent is a fresh agent in its own "
        "sandbox with its own context; give it a self-contained brief, because "
        "it cannot see this conversation. Pass several tasks to run them in "
        "parallel. Returns each subagent's result."
    ),
    "properties": {
        "tasks": {
            "type": "array",
            "description": (
                "The briefs. Each item is {\"prompt\": \"...\", \"title\": "
                "\"short label\"}."
            ),
        },
        "wait": {
            "type": "boolean",
            "description": (
                "Wait for the results (default true). False returns at once and "
                "you collect the results with subagent_control."
            ),
            "default": True,
        },
    },
    "required": ["tasks"],
}

CONTROL_SCHEMA = {
    "type": "object",
    "description": (
        "Inspect or steer your subagents: list them, read one's state and "
        "result, send a running one a correction, or stop it."
    ),
    "properties": {
        "action": {
            "type": "string",
            "description": "list | status | steer | cancel | cancel_all",
        },
        "subagent_id": {
            "type": "string",
            "description": "Which subagent (from delegate_task or list).",
        },
        "message": {
            "type": "string",
            "description": "The correction to deliver, for action=steer.",
        },
    },
    "required": ["action"],
}


def make_delegate_handler(supervisor: SubagentSupervisor):
    def delegate_task(tasks: Any = None, wait: bool = True, prompt: str | None = None) -> dict:
        # `prompt` is accepted because a model that reads "give it a brief" will
        # sooner or later send one task as a bare prompt.
        payload = tasks if tasks is not None else prompt
        return supervisor.delegate(payload, wait=bool(wait))

    return delegate_task


def make_control_handler(supervisor: SubagentSupervisor):
    def subagent_control(
        action: str, subagent_id: str | None = None, message: str | None = None
    ) -> dict:
        verb = (action or "").strip().lower()
        if verb == "list":
            return {
                "ok": True,
                "subagents": [r.summary() for r in supervisor.records()],
            }
        if verb == "cancel_all":
            return supervisor.cancel_all()
        # The unknown verb is reported before the missing argument: told it needs
        # a subagent_id, a model will supply one and try the same wrong verb again.
        if verb not in ("status", "cancel", "steer"):
            return {
                "ok": False,
                "error": (
                    f"unknown action {verb!r}; use list, status, steer, cancel or "
                    "cancel_all"
                ),
            }
        if not subagent_id:
            return {"ok": False, "error": f"action {verb!r} needs a subagent_id"}
        if verb == "status":
            record = supervisor.get(subagent_id)
            if record is None:
                return {"ok": False, "error": f"no such subagent: {subagent_id}"}
            return {"ok": True, **record.summary()}
        if verb == "cancel":
            return supervisor.cancel(subagent_id)
        return supervisor.steer(subagent_id, message or "")

    return subagent_control


def register_subagent_tools(
    registry: ToolRegistry, supervisor: SubagentSupervisor | None
) -> None:
    """Register ``delegate_task`` + ``subagent_control``.

    A supervisor that cannot delegate (a child already at the depth limit)
    registers nothing: a tool documented to the model that always refuses costs
    prompt tokens every round and invites the model to keep trying.
    """
    if supervisor is None:
        return
    allowed, _ = supervisor.can_delegate()
    if not allowed:
        return
    registry.register("delegate_task", DELEGATE_SCHEMA, make_delegate_handler(supervisor))
    registry.register(
        "subagent_control", CONTROL_SCHEMA, make_control_handler(supervisor)
    )
