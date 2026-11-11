"""The goal driver (docs/WIRE_CONTRACT.md, "Goal mode"; DeepSeek harness
``goal-round-driver``): one ``<goal_round>`` task after each natural ``done``
while the goal is active and armed, never after a restart on its own."""

from __future__ import annotations

from chuk_agents_runtime.goal import (
    PHASE_BLOCKED,
    PHASE_PAUSED,
    GoalArming,
    GoalController,
    load_goal,
)
from chuk_agents_runtime.state import StateStore

from chuk_agents_executor.goal_driver import GoalDriver

KEY = "thread-1"


class _FakeExecutor:
    def __init__(self) -> None:
        self.live = False
        self.submitted: list[tuple[str, str, dict]] = []
        self.persisted: list[tuple[str, dict]] = []

    def submit_task(self, session_key, prompt, meta):
        self.submitted.append((session_key, prompt, meta))
        return f"run-{len(self.submitted)}"

    def has_live_run(self, session_key):
        return self.live

    def live_request_id(self, session_key):
        return None

    def _persist_event(self, session_key, payload):
        self.persisted.append((session_key, payload))

    def _event(self, request_id, payload):  # pragma: no cover - no live stream here
        pass


def _setup(tmp_path, max_rounds=3):
    db = str(tmp_path / "state.db")
    ex = _FakeExecutor()
    driver = GoalDriver(ex, db)
    store = StateStore(db)
    GoalController(store=store, session_key=KEY, arming=driver.arming).create("Ship it", max_rounds)
    return db, ex, driver, store


def test_a_natural_done_starts_the_next_round(tmp_path):
    _db, ex, driver, store = _setup(tmp_path)
    goal = driver.after_run(KEY, reason="finished", origin="app")
    assert goal["continues"] is True and goal["rounds_started"] == 1
    [(key, prompt, meta)] = ex.submitted
    assert key == KEY and prompt.startswith("<goal_round>") and "Round: 1/3" in prompt
    assert meta == {"origin": "goal", "goal_id": goal["id"], "goal_round": 1}


def test_the_cap_blocks_the_goal_with_round_limit(tmp_path):
    _db, ex, driver, store = _setup(tmp_path, max_rounds=2)
    for _ in range(2):
        assert driver.after_run(KEY, reason="finished", origin="goal")["continues"] is True
    goal = driver.after_run(KEY, reason="finished", origin="goal")
    assert goal["continues"] is False and goal["phase"] == PHASE_BLOCKED
    assert goal["blocked_reason"]["code"] == "round-limit" and goal["needs_user"] is True
    assert len(ex.submitted) == 2
    frames = [p for _k, p in ex.persisted if p["type"] == "goal"]
    assert frames[-1]["goal"]["phase"] == PHASE_BLOCKED


def test_after_a_restart_nothing_continues_until_the_user_resumes(tmp_path):
    db, _ex, _driver, _store = _setup(tmp_path)
    ex = _FakeExecutor()
    restarted = GoalDriver(ex, db)  # a new process: nothing armed
    goal = restarted.after_run(KEY, reason="finished", origin="app")
    assert goal["activation"] == "disarmed" and goal["continues"] is False
    assert ex.submitted == []
    view, error = restarted.control(KEY, "resume")
    assert error is None and view["continues"] is True
    assert len(ex.submitted) == 1


def test_users_queued_work_goes_first(tmp_path):
    _db, ex, driver, _store = _setup(tmp_path)
    goal = driver.after_run(KEY, reason="finished", origin="app", others_live=True)
    assert goal["continues"] is False and goal["waiting"] is True
    assert ex.submitted == []


def test_a_stopped_goal_round_pauses_and_another_end_only_disarms(tmp_path):
    _db, ex, driver, store = _setup(tmp_path)
    goal = driver.after_run(KEY, reason="interrupted", origin="goal")
    assert goal["phase"] == PHASE_PAUSED and goal["continues"] is False
    assert ex.submitted == []
    view, error = driver.control(KEY, "resume")
    assert error is None and len(ex.submitted) == 1
    goal = driver.after_run(KEY, reason="max_iterations", origin="goal")
    assert goal["phase"] == "active" and goal["activation"] == "disarmed"


def test_control_clear_and_unknown_action(tmp_path):
    _db, _ex, driver, store = _setup(tmp_path)
    assert driver.control(KEY, "explode")[1]
    view, error = driver.control(KEY, "clear")
    assert error is None and view is None and load_goal(store, KEY) is None
