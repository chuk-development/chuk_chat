"""The job wake cap (DeepSeek harness ``maxConsecutiveWakes``,
docs/WIRE_CONTRACT.md, "The wake-up", 7).

At most ``max_consecutive_wakes`` job wakes in a row start a new task of one
session. Past the cap the wake text waits for the next run and a
``wake_capped`` notice goes out instead. A user task resets the count.
"""

from __future__ import annotations

import json

from chuk_agents_executor.shell import JOBS_DIRNAME, MAX_CONSECUTIVE_WAKES, JobWakeRouter

SESSION = "thread-1"


class _FakeExecutor:
    def __init__(self) -> None:
        self.live = False
        self.submitted: list[tuple[str, str, dict]] = []
        self.persisted: list[tuple[str, dict]] = []
        self.events: list[dict] = []

    def submit_task(self, session_key, prompt, meta):
        self.submitted.append((session_key, prompt, meta))
        return f"run-{len(self.submitted)}"

    def has_live_run(self, session_key):
        return self.live

    def live_request_id(self, session_key):
        return None

    def _persist_event(self, session_key, payload):
        self.persisted.append((session_key, payload))

    def _event(self, request_id, payload):
        self.events.append(payload)


def _job(workspace, n: int) -> dict:
    job_id = f"j{n:08x}"
    jobs = workspace / JOBS_DIRNAME
    jobs.mkdir(parents=True, exist_ok=True)
    (jobs / f"{job_id}.json").write_text(json.dumps({"session_key": SESSION, "command": "echo"}))
    (jobs / f"{job_id}.log").write_text("ok\n")
    (jobs / f"{job_id}.exit").write_text("0")
    return {"kind": "job", "job_id": job_id, "session_key": SESSION, "exit_code": 0}


def test_default_cap_is_five():
    assert MAX_CONSECUTIVE_WAKES == 5


def test_wakes_past_the_cap_post_a_notice_instead(tmp_path):
    ex = _FakeExecutor()
    sent: list[dict] = []
    router = JobWakeRouter(ex, workspace=str(tmp_path), send_host=sent.append, max_consecutive_wakes=2)
    assert router.finished(_job(tmp_path, 1)) == "task"
    assert router.finished(_job(tmp_path, 2)) == "task"
    assert router.consecutive_wakes(SESSION) == 2
    assert router.finished(_job(tmp_path, 3)) == "capped"
    assert len(ex.submitted) == 2
    notices = [p for _k, p in ex.persisted if p.get("event") == "wake_capped"]
    assert len(notices) == 1
    assert notices[0]["job_id"] == "j00000003"
    assert notices[0]["max_consecutive_wakes"] == 2
    assert any(p.get("event") == "wake_capped" for p in sent)
    # The capped wake is marked woken: a restart sweep does not wake it again.
    assert (tmp_path / JOBS_DIRNAME / "j00000003.woken").exists()
    # A run ending does not flush the held text into a new task.
    assert router.flush_after_run(SESSION) is None
    assert router.has_pending(SESSION)


def test_user_task_resets_and_its_run_gets_the_held_text(tmp_path):
    ex = _FakeExecutor()
    router = JobWakeRouter(ex, workspace=str(tmp_path), max_consecutive_wakes=1)
    assert router.finished(_job(tmp_path, 1)) == "task"
    assert router.finished(_job(tmp_path, 2)) == "capped"
    router.user_task(SESSION)
    assert router.consecutive_wakes(SESSION) == 0
    # The user's run drains the held wake text as context.
    rows = router.provider(SESSION)()
    assert len(rows) == 1 and "j00000002" in rows[0]["content"]
    # And the next wake starts a task again.
    assert router.finished(_job(tmp_path, 3)) == "task"


def test_wake_into_a_live_run_does_not_count(tmp_path):
    ex = _FakeExecutor()
    ex.live = True
    router = JobWakeRouter(ex, workspace=str(tmp_path), max_consecutive_wakes=1)
    for n in range(1, 4):
        assert router.finished(_job(tmp_path, n)) == "pending"
    assert router.consecutive_wakes(SESSION) == 0
    assert ex.submitted == []
