"""Subagents / multi-agent collaboration (§7.6).

Nothing here touches the checkout the tests live in: every git repo is built
under ``tmp_path``. Nothing sleeps to "let a thread get going" either — every
concurrency assertion is made with a barrier, an event or a bounded poll, so the
suite proves the behaviour instead of guessing at a timing.
"""

import json
import shutil
import subprocess
import threading
import time
from pathlib import Path

import pytest

from cowork_agent.environment import LocalEnvironment
from cowork_agent.loop import KillSwitch, LoopResult, StopReason
from cowork_agent.model import MockModelClient, response_from_content
from cowork_agent.registry import ToolRegistry
from cowork_agent.runtime import SubagentConfig, build_runtime
from cowork_agent.state import StateStore
from cowork_agent.subagents import (
    ActivityMonitor,
    ChildContext,
    SubagentLimits,
    SubagentRecord,
    SubagentRegistry,
    SubagentState,
    SubagentSupervisor,
    register_subagent_tools,
)
from cowork_agent.workspace_git import GitWorkspace

# -- helpers ---------------------------------------------------------------

WAIT_S = 10.0


def _wait_until(predicate, timeout: float = WAIT_S, interval: float = 0.005) -> bool:
    """Poll a condition. Bounded, so a broken build fails instead of hanging."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(interval)
    return False


def _done(answer: str = "ok", *, iterations: int = 1) -> LoopResult:
    return LoopResult(
        reason=StopReason.FINISHED,
        final_answer=answer,
        iterations=iterations,
        session_id=1,
    )


def _supervisor(tmp_path, runner, **kwargs) -> SubagentSupervisor:
    store = kwargs.pop("store", None) or StateStore(str(tmp_path / "parent.db"))
    return SubagentSupervisor(
        parent_key=kwargs.pop("parent_key", "agent:test"),
        store=store,
        runner=runner,
        root=kwargs.pop("root", str(tmp_path / "subagents")),
        **kwargs,
    )


def _echo_runner(ctx: ChildContext) -> LoopResult:
    return _done(f"handled: {ctx.prompt}")


# -- the record / handle --------------------------------------------------


def test_record_round_trips_through_json():
    record = SubagentRecord(
        subagent_id="sa_1",
        parent_key="agent:root",
        task_id="root.s1",
        title="research",
        prompt="find the thing",
        depth=1,
        state=SubagentState.SUCCEEDED,
        result="found it",
    )
    revived = SubagentRecord.from_dict(json.loads(json.dumps(record.to_dict())))
    assert revived == record
    assert revived.state is SubagentState.SUCCEEDED


def test_record_from_dict_tolerates_unknown_fields_and_bad_state():
    data = {
        "subagent_id": "sa_2",
        "parent_key": "p",
        "task_id": "t",
        "title": "x",
        "prompt": "y",
        "depth": 1,
        "state": "not-a-state",
        "invented_later": 42,
    }
    revived = SubagentRecord.from_dict(data)
    assert revived.state is SubagentState.FAILED


def test_summary_hides_the_prompt_and_caps_the_result():
    record = SubagentRecord(
        subagent_id="sa_3",
        parent_key="p",
        task_id="t",
        title="x",
        prompt="the brief",
        depth=1,
        state=SubagentState.SUCCEEDED,
        result="A" * 20_000,
    )
    summary = record.summary()
    assert "prompt" not in summary
    assert len(summary["result"]) < 20_000


# -- one child, isolated --------------------------------------------------


def test_child_result_reaches_the_parent(tmp_path):
    supervisor = _supervisor(tmp_path, _echo_runner)
    out = supervisor.delegate([{"prompt": "read the docs", "title": "docs"}])
    assert out["ok"] is True
    assert out["subagents"][0]["state"] == "succeeded"
    assert out["subagents"][0]["result"] == "handled: read the docs"
    supervisor.shutdown()


def test_child_token_spend_reaches_the_parent(tmp_path):
    """A child's LoopResult.tokens_spent flows into its record and its
    subagent_state summary, so the app can show a per-child cost (§7.6)."""

    def spender(ctx: ChildContext) -> LoopResult:
        return LoopResult(
            reason=StopReason.FINISHED,
            final_answer="done",
            iterations=2,
            session_id=1,
            tokens_spent=4321,
        )

    supervisor = _supervisor(tmp_path, spender)
    out = supervisor.delegate([{"prompt": "crunch", "title": "worker"}])
    supervisor.shutdown()

    assert out["subagents"][0]["tokens_spent"] == 4321
    record = supervisor.records()[0]
    assert record.tokens_spent == 4321
    # A zero-spend child omits the field (kept out of the model-facing summary).


def test_zero_spend_child_omits_tokens_in_the_summary(tmp_path):
    supervisor = _supervisor(tmp_path, _echo_runner)  # _done -> tokens_spent 0
    out = supervisor.delegate([{"prompt": "x", "title": "t"}])
    supervisor.shutdown()
    assert "tokens_spent" not in out["subagents"][0]


def test_child_gets_its_own_task_id_db_and_session(tmp_path):
    seen: list[ChildContext] = []

    def runner(ctx: ChildContext) -> LoopResult:
        seen.append(ctx)
        return _done()

    supervisor = _supervisor(tmp_path, runner, task_id="root")
    supervisor.delegate("do a thing")
    supervisor.shutdown()

    ctx = seen[0]
    assert ctx.task_id != "root" and ctx.task_id.startswith("root.")
    assert ctx.db_path.endswith("state.db")
    assert ctx.subagent_id in ctx.db_path  # its own file, not the parent's
    assert ctx.session_key == f"subagent:{ctx.subagent_id}"
    assert ctx.depth == 1


def test_child_runs_a_real_runtime_isolated_from_the_parent(tmp_path):
    """The real wiring: own task id -> own environment, own database, own
    session, and the child's answer arrives as the parent's tool result."""
    task_ids: list[str] = []
    events: list[dict] = []

    def env_factory(task_id: str):
        task_ids.append(task_id)
        return LocalEnvironment()

    config = SubagentConfig(
        model_factory=lambda: MockModelClient(["the child's answer"]),
        env_factory=env_factory,
        task_id="root",
        root=str(tmp_path / "kids"),
        on_event=events.append,
    )
    parent_model = MockModelClient(
        [
            '<tool_call>{"name":"delegate_task","arguments":{"tasks":'
            '[{"prompt":"summarise the file","title":"kid"}]}}</tool_call>',
            "parent is done",
        ]
    )
    loop = build_runtime(
        parent_model,
        db_path=str(tmp_path / "parent.db"),
        workspace=str(tmp_path / "ws"),
        version_workspace=False,
        enable_terminal=False,
        subagents=config,
    )
    result = loop.run("root", "delegate this")
    assert result.reason is StopReason.FINISHED

    tool_rows = [
        m.content
        for m in loop.store.get_conversation(result.session_id)
        if m.role == "tool"
    ]
    assert "the child's answer" in json.dumps(tool_rows)

    # Its own environment, built from its own task id.
    assert len(task_ids) == 1 and task_ids[0] != "root"
    # Its own database, not the parent's.
    child_dbs = list((tmp_path / "kids").glob("*/state.db"))
    assert len(child_dbs) == 1
    assert child_dbs[0] != tmp_path / "parent.db"
    child_store = StateStore(str(child_dbs[0]))
    child_session = child_store.resolve_session(
        f"subagent:{config.supervisor.records()[0].subagent_id}"
    )
    assert child_session is not None
    assert child_store.get_conversation(child_session)  # its own history

    # Live streaming reached the parent.
    kinds = {event["type"] for event in events}
    assert "subagent_state" in kinds
    assert "subagent_output" in kinds
    deltas = [
        event["payload"]["text"]
        for event in events
        if event["type"] == "subagent_output"
        and event["payload"].get("type") == "delta"
    ]
    assert "the child's answer" in deltas
    config.supervisor.shutdown()


def test_max_child_tokens_caps_a_looping_child(tmp_path):
    """A child that never finishes and reports token usage stops at its token
    budget instead of running to max_iterations — the §7.6 cost guard for a
    fan-out the parent has stopped waiting on."""
    ECHO = '<tool_call>{"name":"echo","arguments":{}}</tool_call>'

    class Spender:
        def __init__(self):
            self.calls = 0

        def complete(self, messages):
            self.calls += 1
            r = response_from_content(ECHO)
            r.raw = dict(r.raw)
            r.raw["usage"] = {"total_tokens": 50}
            return r

    children: list[Spender] = []

    def child_model():
        c = Spender()
        children.append(c)
        return c

    def env_factory(task_id: str):
        return LocalEnvironment()

    config = SubagentConfig(
        model_factory=child_model,
        env_factory=env_factory,
        task_id="root",
        root=str(tmp_path / "kids"),
        # Cap of 120 tokens: 0 -> +50 -> 50 -> +50 -> 100 -> stop before the 4th
        # round. A child at max_iterations=30 spending 50/round would otherwise
        # run all 30.
        max_iterations=30,
        limits=SubagentLimits(max_child_tokens=120),
    )
    parent_model = MockModelClient(
        [
            '<tool_call>{"name":"delegate_task","arguments":{"tasks":'
            '[{"prompt":"loop forever","title":"kid"}]}}</tool_call>',
            "parent is done",
        ]
    )
    loop = build_runtime(
        parent_model,
        db_path=str(tmp_path / "parent.db"),
        workspace=str(tmp_path / "ws"),
        version_workspace=False,
        enable_terminal=False,
        subagents=config,
    )
    # The child's ECHO tool call misses the child's builtin registry and comes
    # back as an error result, but the loop still spends a round each time —
    # which is all this test needs: a child that never reaches a bare-text
    # answer, so only the token budget can stop it.
    result = loop.run("root", "delegate this")
    assert result.reason is StopReason.FINISHED
    assert len(children) == 1
    # Capped well below max_iterations (30). Exactly 3 rounds: the 4th is stopped.
    assert children[0].calls == 3
    config.supervisor.shutdown()


# -- batch: real concurrency ----------------------------------------------


def test_batch_children_run_concurrently(tmp_path):
    """The concurrency proof: a barrier that only opens when all three children
    are inside the runner at the same time. Sequential execution breaks it, and a
    broken barrier fails the child."""
    barrier = threading.Barrier(3)

    def runner(ctx: ChildContext) -> LoopResult:
        barrier.wait(timeout=WAIT_S)  # raises BrokenBarrierError if serialized
        return _done(ctx.title)

    supervisor = _supervisor(
        tmp_path, runner, limits=SubagentLimits(max_concurrency=3, heartbeat_s=0.05)
    )
    out = supervisor.delegate(
        [{"prompt": "a", "title": "a"}, {"prompt": "b", "title": "b"}, {"prompt": "c", "title": "c"}]
    )
    supervisor.shutdown()
    states = [entry["state"] for entry in out["subagents"]]
    assert states == ["succeeded", "succeeded", "succeeded"]
    assert {entry["result"] for entry in out["subagents"]} == {"a", "b", "c"}


def test_concurrency_limit_queues_instead_of_overrunning(tmp_path):
    """One slot: the second child waits in ``queued`` instead of starting."""
    release = threading.Event()
    live = 0
    peak = 0
    lock = threading.Lock()

    def runner(ctx: ChildContext) -> LoopResult:
        nonlocal live, peak
        with lock:
            live += 1
            peak = max(peak, live)
        release.wait(WAIT_S)
        with lock:
            live -= 1
        return _done(ctx.title)

    supervisor = _supervisor(
        tmp_path, runner, limits=SubagentLimits(max_concurrency=1, heartbeat_s=0.05)
    )
    out = supervisor.delegate(
        [{"prompt": "first", "title": "first"}, {"prompt": "second", "title": "second"}],
        wait=False,
    )
    ids = [entry["subagent_id"] for entry in out["subagents"]]

    assert _wait_until(
        lambda: supervisor.get(ids[0]).state is SubagentState.RUNNING
    ), "the first child never started"
    # The gate is the point: the second one is admitted but not running.
    assert supervisor.get(ids[1]).state is SubagentState.QUEUED

    release.set()
    records = supervisor.wait_for(ids, timeout=WAIT_S)
    supervisor.shutdown()
    assert [r.state for r in records] == [
        SubagentState.SUCCEEDED,
        SubagentState.SUCCEEDED,
    ]
    assert peak == 1  # never more than the gate allows


def test_gates_are_per_depth_level(tmp_path):
    """A shared *global* gate would deadlock: a parent holding a slot while it
    waits for a child that needs one. Each level has its own gate, so the two
    never compete."""
    supervisor = _supervisor(
        tmp_path, _echo_runner, limits=SubagentLimits(max_concurrency=2)
    )
    first = supervisor._gate(1)
    assert supervisor._gate(1) is first
    assert supervisor._gate(2) is not first
    supervisor.shutdown()


def test_batch_over_the_limit_is_refused(tmp_path):
    supervisor = _supervisor(tmp_path, _echo_runner, limits=SubagentLimits(max_batch=2))
    out = supervisor.delegate(["a", "b", "c"])
    assert out["ok"] is False
    assert "at most 2" in out["error"]
    assert supervisor.records() == []  # nothing was started
    supervisor.shutdown()


# -- depth limit ----------------------------------------------------------


def test_depth_limit_refuses_the_grandchild(tmp_path):
    """A child at the depth limit gets a sentence it can act on, not a stack
    trace, and no tool it can keep retrying."""
    supervisor = _supervisor(
        tmp_path, _echo_runner, depth=2, limits=SubagentLimits(max_depth=2)
    )
    allowed, why = supervisor.can_delegate()
    assert allowed is False
    out = supervisor.delegate("recurse forever")
    assert out["ok"] is False
    assert "depth limit" in out["error"]
    assert "max_depth=2" in out["error"]
    assert supervisor.records() == []

    registry = ToolRegistry()
    register_subagent_tools(registry, supervisor)
    assert registry.names() == []  # not even documented to the model
    supervisor.shutdown()


def test_depth_one_child_may_delegate_but_the_grandchild_may_not(tmp_path):
    child = _supervisor(tmp_path, _echo_runner, depth=1, limits=SubagentLimits(max_depth=1))
    assert child.can_delegate()[0] is False

    parent = _supervisor(
        tmp_path, _echo_runner, depth=0, limits=SubagentLimits(max_depth=1)
    )
    assert parent.can_delegate()[0] is True
    parent.shutdown()
    child.shutdown()


def test_default_limits_stop_at_depth_three(tmp_path):
    supervisor = _supervisor(tmp_path, _echo_runner, depth=2)  # defaults
    assert supervisor.limits.max_depth == 2
    assert supervisor.can_delegate()[0] is False
    supervisor.shutdown()


# -- interrupting ---------------------------------------------------------


def test_cancel_stops_a_running_child(tmp_path):
    started = threading.Event()

    def runner(ctx: ChildContext) -> LoopResult:
        started.set()
        assert _wait_until(ctx.kill_switch.interrupted, WAIT_S), "no interrupt seen"
        return LoopResult(
            reason=StopReason.INTERRUPTED, final_answer=None, iterations=2, session_id=1
        )

    supervisor = _supervisor(tmp_path, runner, limits=SubagentLimits(heartbeat_s=0.05))
    out = supervisor.delegate("long job", wait=False)
    sid = out["subagents"][0]["subagent_id"]
    assert started.wait(WAIT_S)

    assert supervisor.cancel(sid)["state"] == "stopping"
    records = supervisor.wait_for([sid], timeout=WAIT_S)
    supervisor.shutdown()
    assert records[0].state is SubagentState.CANCELLED
    assert records[0].stop_reason == "interrupted"


def test_cancelling_a_queued_child_never_starts_it(tmp_path):
    release = threading.Event()
    ran: list[str] = []

    def runner(ctx: ChildContext) -> LoopResult:
        ran.append(ctx.title)
        release.wait(WAIT_S)
        return _done()

    supervisor = _supervisor(
        tmp_path, runner, limits=SubagentLimits(max_concurrency=1, heartbeat_s=0.05)
    )
    out = supervisor.delegate(
        [{"prompt": "a", "title": "a"}, {"prompt": "b", "title": "b"}], wait=False
    )
    ids = [entry["subagent_id"] for entry in out["subagents"]]
    assert _wait_until(lambda: ran == ["a"])

    supervisor.cancel(ids[1])
    release.set()
    records = supervisor.wait_for(ids, timeout=WAIT_S)
    supervisor.shutdown()
    assert records[1].state is SubagentState.CANCELLED
    assert ran == ["a"]  # the sandbox for "b" was never opened


def test_parent_stop_cancels_the_children(tmp_path):
    """§7.1's Stop button reaches the tree: a stopped parent does not orphan the
    sandboxes it opened."""
    kill = KillSwitch()

    def runner(ctx: ChildContext) -> LoopResult:
        assert _wait_until(ctx.kill_switch.interrupted, WAIT_S)
        return LoopResult(
            reason=StopReason.INTERRUPTED, final_answer=None, iterations=1, session_id=1
        )

    supervisor = _supervisor(
        tmp_path, runner, parent_kill=kill, limits=SubagentLimits(heartbeat_s=0.02)
    )
    out = supervisor.delegate("work", wait=False)
    sid = out["subagents"][0]["subagent_id"]
    assert _wait_until(lambda: supervisor.get(sid).state is SubagentState.RUNNING)

    kill.interrupt()
    records = supervisor.wait_for([sid], timeout=WAIT_S)
    supervisor.shutdown()
    assert records[0].state is SubagentState.CANCELLED


def test_steering_a_running_child_appends_to_its_session(tmp_path):
    class _FakeLoop:
        def __init__(self, store):
            self.store = store

    delivered = threading.Event()
    child_store = StateStore(str(tmp_path / "child.db"))

    def runner(ctx: ChildContext) -> LoopResult:
        ctx.on_loop(_FakeLoop(child_store))
        assert delivered.wait(WAIT_S)
        return _done()

    supervisor = _supervisor(tmp_path, runner, limits=SubagentLimits(heartbeat_s=0.05))
    out = supervisor.delegate("work", wait=False)
    sid = out["subagents"][0]["subagent_id"]
    session_key = f"subagent:{sid}"
    assert _wait_until(lambda: supervisor.steer(sid, "use metric units")["ok"] is True)
    delivered.set()
    supervisor.wait_for([sid], timeout=WAIT_S)
    supervisor.shutdown()

    session_id = child_store.resolve_session(session_key)
    texts = [m.content["content"] for m in child_store.get_conversation(session_id)]
    assert any("use metric units" in text for text in texts)


def test_steering_a_finished_child_is_a_clean_refusal(tmp_path):
    supervisor = _supervisor(tmp_path, _echo_runner)
    out = supervisor.delegate("quick")
    sid = out["subagents"][0]["subagent_id"]
    supervisor.shutdown()
    answer = supervisor.steer(sid, "too late")
    assert answer["ok"] is False and "not running" in answer["error"]


# -- failure isolation ----------------------------------------------------


def test_a_crashing_child_takes_neither_parent_nor_siblings_down(tmp_path):
    def runner(ctx: ChildContext) -> LoopResult:
        if ctx.title == "bad":
            raise RuntimeError("boom inside the child")
        return _done(ctx.title)

    supervisor = _supervisor(
        tmp_path, runner, limits=SubagentLimits(max_concurrency=3, heartbeat_s=0.05)
    )
    out = supervisor.delegate(
        [
            {"prompt": "a", "title": "good-1"},
            {"prompt": "b", "title": "bad"},
            {"prompt": "c", "title": "good-2"},
        ]
    )
    supervisor.shutdown()
    by_title = {entry["title"]: entry for entry in out["subagents"]}
    assert by_title["bad"]["state"] == "failed"
    assert "boom inside the child" in by_title["bad"]["error"]
    assert by_title["good-1"]["state"] == "succeeded"
    assert by_title["good-2"]["state"] == "succeeded"


def test_a_child_that_runs_out_of_rounds_is_reported_as_unfinished(tmp_path):
    def runner(ctx: ChildContext) -> LoopResult:
        return LoopResult(
            reason=StopReason.MAX_ITERATIONS,
            final_answer=None,
            iterations=50,
            session_id=1,
        )

    supervisor = _supervisor(tmp_path, runner)
    out = supervisor.delegate("endless")
    supervisor.shutdown()
    entry = out["subagents"][0]
    assert entry["state"] == "failed"
    assert "max_iterations" in entry["error"]


# -- the pause cap --------------------------------------------------------


def test_wait_returns_at_the_pause_cap_with_the_children_still_running(tmp_path):
    release = threading.Event()

    def runner(ctx: ChildContext) -> LoopResult:
        release.wait(WAIT_S)
        return _done()

    supervisor = _supervisor(
        tmp_path,
        runner,
        limits=SubagentLimits(max_wait_s=0.15, heartbeat_s=0.02),
    )
    started = time.monotonic()
    out = supervisor.delegate("slow job")
    elapsed = time.monotonic() - started

    assert out["ok"] is True
    assert elapsed < WAIT_S / 2  # the parent got its turn back
    assert out["subagents"][0]["state"] == "running"
    assert "still running" in out["note"]

    release.set()
    supervisor.shutdown()


# -- the heartbeat --------------------------------------------------------


def test_the_parent_counts_as_active_while_a_child_works(tmp_path):
    """The parent produces nothing while a child runs. Without this pulse an
    inactivity timeout would kill it for waiting."""
    release = threading.Event()
    monitor = ActivityMonitor()

    def runner(ctx: ChildContext) -> LoopResult:
        release.wait(WAIT_S)
        return _done()

    supervisor = _supervisor(
        tmp_path,
        runner,
        activity=monitor,
        limits=SubagentLimits(heartbeat_s=0.02),
    )
    # wait=False: the parent is NOT blocked in wait_for, so only the heartbeat
    # can be keeping it alive.
    supervisor.delegate("slow job", wait=False)
    assert _wait_until(lambda: monitor.marks >= 3), "the heartbeat never pulsed"
    assert monitor.is_idle(0.5) is False

    release.set()
    supervisor.shutdown()


def test_the_heartbeat_stops_once_no_child_is_alive(tmp_path):
    monitor = ActivityMonitor()
    supervisor = _supervisor(
        tmp_path, _echo_runner, activity=monitor, limits=SubagentLimits(heartbeat_s=0.01)
    )
    supervisor.delegate("quick")
    supervisor.shutdown()
    assert _wait_until(lambda: supervisor.live_count() == 0)
    settled = monitor.marks
    time.sleep(0.1)
    assert monitor.marks == settled  # no thread left pulsing


def test_child_output_marks_the_parent_active(tmp_path):
    monitor = ActivityMonitor()

    def runner(ctx: ChildContext) -> LoopResult:
        ctx.emit({"type": "delta", "text": "thinking"})
        return _done()

    supervisor = _supervisor(tmp_path, runner, activity=monitor)
    before = monitor.marks
    supervisor.delegate("work")
    supervisor.shutdown()
    assert monitor.marks > before


# -- persistence ----------------------------------------------------------


def test_handles_are_reconstructed_from_the_store(tmp_path):
    db = str(tmp_path / "parent.db")
    supervisor = _supervisor(tmp_path, _echo_runner, store=StateStore(db))
    supervisor.delegate([{"prompt": "one", "title": "one"}])
    supervisor.shutdown()

    # A different process would see exactly this: only the store.
    revived = SubagentRegistry(StateStore(db), parent_key="agent:test").list()
    assert len(revived) == 1
    assert revived[0].state is SubagentState.SUCCEEDED
    assert revived[0].result == "handled: one"
    assert revived[0].title == "one"


def test_a_record_left_running_by_a_dead_process_is_reaped(tmp_path):
    db = str(tmp_path / "parent.db")
    store = StateStore(db)
    orphan = SubagentRecord(
        subagent_id="sa_orphan",
        parent_key="agent:test",
        task_id="root.s1",
        title="interrupted work",
        prompt="p",
        depth=1,
        state=SubagentState.RUNNING,
    )
    store.save_subagent(orphan.subagent_id, orphan.parent_key, orphan.to_dict())

    supervisor = _supervisor(tmp_path, _echo_runner, store=StateStore(db))
    record = supervisor.get("sa_orphan")
    supervisor.shutdown()
    assert record.state is SubagentState.FAILED
    assert "lost" in record.error and "restarted" in record.error
    assert record.stop_reason == "orphaned"


def test_records_are_scoped_to_their_parent(tmp_path):
    db = str(tmp_path / "parent.db")
    first = _supervisor(tmp_path, _echo_runner, store=StateStore(db), parent_key="agent:a")
    second = _supervisor(
        tmp_path, _echo_runner, store=StateStore(db), parent_key="agent:b"
    )
    first.delegate("a")
    second.delegate("b")
    first.shutdown()
    second.shutdown()
    assert [r.title for r in first.records()] == ["a"]
    assert [r.title for r in second.records()] == ["b"]


# -- the tools ------------------------------------------------------------


def test_delegate_tool_dispatches_through_the_registry(tmp_path):
    supervisor = _supervisor(tmp_path, _echo_runner)
    registry = ToolRegistry()
    register_subagent_tools(registry, supervisor)
    assert sorted(registry.names()) == ["delegate_task", "subagent_control"]

    result = registry.dispatch(
        "delegate_task", {"tasks": [{"prompt": "read it", "title": "read"}]}
    )
    assert result["ok"] is True
    assert result["subagents"][0]["result"] == "handled: read it"

    listing = registry.dispatch("subagent_control", {"action": "list"})
    assert listing["ok"] is True and len(listing["subagents"]) == 1
    sid = listing["subagents"][0]["subagent_id"]

    status = registry.dispatch(
        "subagent_control", {"action": "status", "subagent_id": sid}
    )
    assert status["state"] == "succeeded"
    supervisor.shutdown()


def test_delegate_tool_accepts_a_bare_prompt_and_a_bare_string(tmp_path):
    supervisor = _supervisor(tmp_path, _echo_runner)
    registry = ToolRegistry()
    register_subagent_tools(registry, supervisor)

    assert registry.dispatch("delegate_task", {"prompt": "just this"})["ok"] is True
    assert registry.dispatch("delegate_task", {"tasks": "or this"})["ok"] is True
    supervisor.shutdown()


def test_delegate_tool_rejects_junk_without_raising(tmp_path):
    supervisor = _supervisor(tmp_path, _echo_runner)
    registry = ToolRegistry()
    register_subagent_tools(registry, supervisor)

    empty = registry.dispatch("delegate_task", {"tasks": [{"title": "no prompt"}]})
    assert empty["ok"] is False and "prompt" in empty["error"]
    assert registry.dispatch("delegate_task", {"tasks": []})["ok"] is False

    unknown = registry.dispatch("subagent_control", {"action": "explode"})
    assert unknown["ok"] is False and "unknown action" in unknown["error"]
    missing = registry.dispatch("subagent_control", {"action": "cancel"})
    assert missing["ok"] is False and "subagent_id" in missing["error"]
    supervisor.shutdown()


# -- git: a branch per child (§7.7) ---------------------------------------

needs_git = pytest.mark.skipif(shutil.which("git") is None, reason="git is not installed")


def _git_out(root, *args) -> str:
    return subprocess.run(
        ["git", "-C", str(root), *args], capture_output=True, text=True, check=True
    ).stdout


@needs_git
def test_two_children_work_on_their_own_branches_and_merge_back(tmp_path):
    workspace = tmp_path / "ws"
    git = GitWorkspace.open(workspace)
    assert git is not None and git.enabled

    seen: list[ChildContext] = []

    def runner(ctx: ChildContext) -> LoopResult:
        seen.append(ctx)
        target = f"{ctx.title}.txt"
        (Path(ctx.workspace) / target).write_text(
            f"by {ctx.title}\n", encoding="utf-8"
        )
        return _done(f"wrote {target}")

    supervisor = _supervisor(
        tmp_path,
        runner,
        workspace=str(workspace),
        git=git,
        limits=SubagentLimits(max_concurrency=2, heartbeat_s=0.05),
    )
    out = supervisor.delegate(
        [{"prompt": "a", "title": "alpha"}, {"prompt": "b", "title": "beta"}]
    )
    supervisor.shutdown()

    # Each child got its own checkout on its own branch — not the parent's.
    assert {ctx.branch for ctx in seen} == {
        entry["branch"] for entry in out["subagents"]
    }
    for ctx in seen:
        assert ctx.workspace != str(workspace)
        assert ctx.branch and ctx.branch.startswith("cowork/")

    # Both results are merged into the parent's tree.
    assert all(entry["merged"] is True for entry in out["subagents"])
    assert (workspace / "alpha.txt").read_text(encoding="utf-8") == "by alpha\n"
    assert (workspace / "beta.txt").read_text(encoding="utf-8") == "by beta\n"
    # And the bookkeeping is cleaned up: no branch, no worktree left behind.
    assert git.worktree_branches() == []
    assert "cowork-worktrees" not in _git_out(workspace, "worktree", "list")


@needs_git
def test_a_colliding_child_keeps_its_branch_instead_of_half_merging(tmp_path):
    workspace = tmp_path / "ws"
    git = GitWorkspace.open(workspace)

    def runner(ctx: ChildContext) -> LoopResult:
        path = Path(ctx.workspace) / "shared.txt"
        path.write_text(f"{ctx.title} was here\n", encoding="utf-8")
        return _done(f"{ctx.title} wrote shared.txt")

    supervisor = _supervisor(
        tmp_path,
        runner,
        workspace=str(workspace),
        git=git,
        limits=SubagentLimits(max_concurrency=1, heartbeat_s=0.05),
    )
    out = supervisor.delegate(
        [{"prompt": "a", "title": "first"}, {"prompt": "b", "title": "second"}]
    )
    supervisor.shutdown()

    by_title = {entry["title"]: entry for entry in out["subagents"]}
    assert by_title["first"]["merged"] is True
    loser = by_title["second"]
    assert loser["state"] == "succeeded"  # the child did its job
    assert loser["merged"] is False  # the merge did not
    assert "shared.txt" in loser["merge_note"]
    # The work is not lost: it is still on the branch.
    assert loser["branch"] in git.worktree_branches()
    assert "second was here" in _git_out(
        workspace, "show", f"{loser['branch']}:shared.txt"
    )


@needs_git
def test_an_unfinished_child_is_not_merged_but_its_branch_is_kept(tmp_path):
    workspace = tmp_path / "ws"
    git = GitWorkspace.open(workspace)

    def runner(ctx: ChildContext) -> LoopResult:
        (Path(ctx.workspace) / "half.txt").write_text(
            "half done\n", encoding="utf-8"
        )
        raise RuntimeError("crashed halfway")

    supervisor = _supervisor(
        tmp_path, runner, workspace=str(workspace), git=git
    )
    out = supervisor.delegate("do half a job")
    supervisor.shutdown()
    entry = out["subagents"][0]
    assert entry["state"] == "failed"
    assert entry["merged"] is False
    assert "not merged" in entry["merge_note"]
    assert not (workspace / "half.txt").exists()  # never entered the parent tree
    assert entry["branch"] in git.worktree_branches()
    assert "half done" in _git_out(workspace, "show", f"{entry['branch']}:half.txt")


@needs_git
def test_child_worktrees_never_pollute_the_parent_journal_or_tree(tmp_path):
    workspace = tmp_path / "ws"
    git = GitWorkspace.open(workspace)
    git.record("write_file", {"path": "parent.txt"}, {"ok": True})

    def runner(ctx: ChildContext) -> LoopResult:
        child_git = GitWorkspace.open(
            ctx.workspace, journal_path=f".cowork/journal-{ctx.subagent_id}.jsonl"
        )
        child_git.record("write_file", {"path": "child.txt"}, {"ok": True})
        (Path(ctx.workspace) / "child.txt").write_text(
            "child\n", encoding="utf-8"
        )
        return _done("done")

    supervisor = _supervisor(tmp_path, runner, workspace=str(workspace), git=git)
    out = supervisor.delegate([{"prompt": "a", "title": "kid"}])
    supervisor.shutdown()

    assert out["subagents"][0]["merged"] is True
    # The parent's own journal is untouched by the child, which wrote its own.
    tools = [entry["tool"] for entry in git.journal_entries()]
    assert tools.count("write_file") == 1
    assert list((workspace / ".cowork").glob("journal-*.jsonl"))
    # No worktree checkout was ever committed into the workspace.
    tracked = _git_out(workspace, "ls-files")
    assert "cowork-worktrees" not in tracked


def test_without_git_the_children_share_the_workspace_and_still_run(tmp_path):
    workspace = tmp_path / "ws"
    workspace.mkdir()
    seen: list[ChildContext] = []

    def runner(ctx: ChildContext) -> LoopResult:
        seen.append(ctx)
        return _done("fine")

    supervisor = _supervisor(
        tmp_path,
        runner,
        workspace=str(workspace),
        git=None,  # version_workspace off
        limits=SubagentLimits(max_concurrency=2),
    )
    out = supervisor.delegate([{"prompt": "a", "title": "a"}, {"prompt": "b", "title": "b"}])
    supervisor.shutdown()
    assert all(entry["state"] == "succeeded" for entry in out["subagents"])
    assert all("branch" not in entry for entry in out["subagents"])
    assert {ctx.workspace for ctx in seen} == {str(workspace)}
    assert all(ctx.branch is None for ctx in seen)


@needs_git
def test_a_disabled_workspace_is_treated_as_no_git(tmp_path):
    git = GitWorkspace(tmp_path / "nope")  # never bootstrapped -> disabled
    assert git.enabled is False
    supervisor = _supervisor(tmp_path, _echo_runner, git=git)
    out = supervisor.delegate("work")
    supervisor.shutdown()
    assert out["subagents"][0]["state"] == "succeeded"


def test_a_stop_at_the_root_reaches_children_and_grandchildren(tmp_path):
    """§7.1 × §7.6, recursively: one interrupt at the root stops the child AND the
    grandchild, with nobody waiting on them and no unwinding in between.

    The tree is real — each level goes through :func:`make_child_runner`, so each
    child builds its own runtime and its own supervisor. What makes this work is
    that a child's switch is the ``parent_kill`` of its own supervisor, so the
    notification walks the whole depth in one call. The assertions right after
    ``interrupt()`` need no waiting at all, which is the property being pinned:
    the cancel is not a poll.
    """
    from cowork_agent.runtime import make_child_runner

    root_kill = KillSwitch()
    release = threading.Event()
    kills: dict[int, KillSwitch] = {}
    parked: list[str] = []
    events: list[dict] = []

    class _DelegatesThenParks:
        """Turn 1 delegates one level deeper; after that it parks, so the whole
        tree is provably alive when the stop lands. At the depth limit the
        delegation is refused and it parks one turn earlier."""

        def __init__(self) -> None:
            self._turn = 0

        def complete(self, messages):
            self._turn += 1
            if self._turn == 1:
                return MockModelClient(
                    [
                        '<tool_call>{"name":"delegate_task","arguments":'
                        '{"tasks":"go one deeper","wait":true}}</tool_call>'
                    ]
                ).complete(messages)
            parked.append("parked")
            release.wait(WAIT_S)
            return MockModelClient(["stopped mid-flight"]).complete(messages)

    config = SubagentConfig(
        model_factory=_DelegatesThenParks,
        env_factory=lambda _task_id: LocalEnvironment(),
        task_id="root",
        root=str(tmp_path / "kids"),
        limits=SubagentLimits(max_depth=2, heartbeat_s=0.02),
        version_workspace=False,
        runtime_kwargs={"enable_terminal": False},
        on_event=events.append,
    )
    real_runner = make_child_runner(config)

    def runner(ctx: ChildContext) -> LoopResult:
        # Record every level's switch as its driver thread starts.
        kills[ctx.depth] = ctx.kill_switch
        return real_runner(ctx)

    config.runner = runner

    supervisor = _supervisor(
        tmp_path,
        runner,
        parent_kill=root_kill,
        limits=config.limits,
        on_event=events.append,
        workspace=str(tmp_path / "ws"),
    )
    out = supervisor.delegate("fan out", wait=False)
    child_id = out["subagents"][0]["subagent_id"]

    # Barrier: child and grandchild both live, the grandchild parked in a turn.
    assert _wait_until(lambda: set(kills) == {1, 2}), f"tree never formed: {kills}"
    assert _wait_until(lambda: parked), "the grandchild never reached a turn"

    root_kill.interrupt()

    # No polling here on purpose: the interrupt propagates down the tree inside
    # the call that fired it.
    assert kills[1].interrupted() is True, "the child was not stopped"
    assert kills[2].interrupted() is True, "the grandchild was not stopped"

    release.set()
    records = supervisor.wait_for([child_id], timeout=WAIT_S)
    supervisor.shutdown()

    assert records[0].state is SubagentState.CANCELLED
    assert records[0].stop_reason == "interrupted"
    # The grandchild's own cancellation bubbled up through the child's stream.
    deep_states = [
        event
        for event in events
        if event.get("type") == "subagent_output"
        and (event.get("payload") or {}).get("type") == "subagent_state"
    ]
    assert any(
        state["payload"]["state"] == "cancelled" for state in deep_states
    ), f"no cancelled grandchild in the stream: {deep_states}"


def test_an_engaged_estop_stops_a_child_nobody_is_waiting_on(tmp_path):
    """The app-free stop (§7.1 tier 1) reaches the tree too: the child inherits
    the parent's sentinel path, so ``touch ESTOP`` ends it at its own next poll
    even with ``wait=false`` and no parent unwinding into it."""
    sentinel = tmp_path / "ESTOP"
    parent_kill = KillSwitch(str(sentinel))
    entered = threading.Event()

    def runner(ctx: ChildContext) -> LoopResult:
        entered.set()
        assert _wait_until(ctx.kill_switch.estop_engaged, WAIT_S), "sentinel unseen"
        return LoopResult(
            reason=StopReason.ESTOP, final_answer=None, iterations=1, session_id=1
        )

    supervisor = _supervisor(
        tmp_path, runner, parent_kill=parent_kill, limits=SubagentLimits(heartbeat_s=0.02)
    )
    out = supervisor.delegate("long job", wait=False)
    sid = out["subagents"][0]["subagent_id"]
    assert entered.wait(WAIT_S)

    sentinel.write_text("stop", encoding="utf-8")
    records = supervisor.wait_for([sid], timeout=WAIT_S)
    supervisor.shutdown()
    assert records[0].state is SubagentState.CANCELLED
    assert records[0].stop_reason == "estop"
