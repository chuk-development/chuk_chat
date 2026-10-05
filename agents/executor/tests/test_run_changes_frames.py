"""What did it do, over the wire (docs/WIRE_CONTRACT.md, "What did it do: run
changes and undo", bead chuk_chat-4qry).

A task that writes files ends with a ``done`` that carries ``changes``.
``run_changes_get`` lists the run's files; ``run_undo`` reverts them as a new
commit and refuses a file a later run changed unless ``force`` is set. A
replayed ``done`` carries the same block.
"""

from __future__ import annotations

import shutil
import subprocess

import pytest

from chuk_agents_runtime import MockModelClient, tool_call_response
from chuk_agents_sandbox import LocalEnvironment

from chuk_agents_executor import ControllerSession, Executor, loopback_pair
from chuk_agents_executor.protocol import run_changes_get_payload, run_undo_payload

from wiring import paired_channel

pytestmark = pytest.mark.skipif(shutil.which("git") is None, reason="git is not installed")


SCRIPTS = {
    "write the plan": [
        tool_call_response(("write_file", {"path": "plan.md", "content": "step 1\nstep 2\n"})),
        tool_call_response(("write_file", {"path": "shared.txt", "content": "run one\n"})),
        "Wrote the plan.",
    ],
    "change it": [
        tool_call_response(("write_file", {"path": "shared.txt", "content": "run two\n"})),
        "Changed it.",
    ],
}


class _Script:
    """The model factory: every client of a task plays that task's script."""

    def __init__(self) -> None:
        self.prompt = ""

    def __call__(self) -> MockModelClient:
        return MockModelClient(list(SCRIPTS.get(self.prompt, ["Nothing to do."])))


class _Session:
    def __init__(self, tmp_path) -> None:
        self.workspace = tmp_path / "ws"
        self.workspace.mkdir(exist_ok=True)
        self.script = _Script()
        channel = paired_channel()
        controller_ep, executor_ep = loopback_pair()
        self.executor = Executor(
            name="run-changes",
            endpoint=executor_ep,
            opener=channel.executor.opener,
            sealer=channel.executor.sealer,
            environment=LocalEnvironment(workdir=str(self.workspace)),
            db_path=str(tmp_path / "state.db"),
            model_factory=self.script,
            workspace=str(self.workspace),
        )
        self.controller = ControllerSession(
            endpoint=controller_ep,
            sealer=channel.controller.sealer,
            opener=channel.controller.opener,
        )

    def __enter__(self) -> "_Session":
        self.executor.start()
        return self

    def __exit__(self, *exc) -> None:
        self.executor.stop()

    def send(self, payload: dict, timeout: float = 20.0) -> list[dict]:
        rid = self.controller.send_payload(payload)
        return self.controller.collect(rid, timeout=timeout)

    def task(self, prompt: str) -> dict:
        self.script.prompt = prompt
        events = self.send({"type": "task", "prompt": prompt, "session_key": "thread-A"})
        (done,) = [e for e in events if e["type"] == "done"]
        return done

    def one(self, payload: dict, kind: str) -> dict:
        events = self.send(payload)
        assert events and events[-1]["type"] == kind, events
        return events[-1]


def test_done_lists_changes_and_undo_reverts_the_run(tmp_path):
    with _Session(tmp_path) as session:
        done = session.task("write the plan")
        assert done["changes"] == {"files": 2, "additions": 3, "deletions": 0, "undone": 0}
        run_one = done["run_id"]

        listed = session.one(run_changes_get_payload(run_id=run_one), "run_changes")
        assert listed["run_id"] == run_one and listed["session_key"] == "thread-A"
        assert {(f["path"], f["change"]) for f in listed["files"]} == {
            ("plan.md", "added"),
            ("shared.txt", "added"),
        }
        assert listed["undoable"] is True
        assert len(listed["commits"]) == 2

        # session_key alone = that thread's latest run.
        latest = session.one(run_changes_get_payload(session_key="thread-A"), "run_changes")
        assert latest["run_id"] == run_one

        # A second run changes one of the files: that one now conflicts.
        done_two = session.task("change it")
        assert done_two["changes"]["files"] == 1
        refused = session.one(run_undo_payload(run_id=run_one), "run_undo_result")
        assert refused["ok"] is False and refused["code"] == "conflicts"
        assert refused["conflicts"] == [
            {"path": "shared.txt", "reason": "changed_later", "runs": [done_two["run_id"]]}
        ]
        assert (session.workspace / "plan.md").exists()

        some = session.one(run_undo_payload(run_id=run_one, paths=["plan.md"]), "run_undo_result")
        assert some["ok"] is True and some["reverted"] == ["plan.md"]
        assert some["changes"]["undone"] == 1
        assert not (session.workspace / "plan.md").exists()
        assert (session.workspace / "shared.txt").read_text(encoding="utf-8") == "run two\n"

        forced = session.one(run_undo_payload(run_id=run_one, force=True), "run_undo_result")
        assert forced["ok"] is True and forced["reverted"] == ["shared.txt"]
        assert not (session.workspace / "shared.txt").exists()

        # A run that changed nothing carries no ``changes``.
        done_three = session.task("anything?")
        assert "changes" not in done_three
        nothing = session.one(run_changes_get_payload(run_id=done_three["run_id"]), "run_changes")
        assert nothing["files"] == [] and nothing["reason"] == "no_changes"

        # The replayed done of run one says what is left: everything undone.
        events = session.send({"type": "replay", "session_key": "thread-A", "after_id": 0})
        replayed = {e["run_id"]: e for e in events if e["type"] == "done" and e.get("run_id")}
        assert replayed[run_one]["changes"]["undone"] == 2
        assert replayed[done_two["run_id"]]["changes"]["files"] == 1
        assert "changes" not in replayed[done_three["run_id"]]

    # History was never rewritten: every undo is a commit.
    log = subprocess.run(
        ["git", "-C", str(session.workspace), "log", "--format=%B"],
        capture_output=True, text=True, check=True,
    ).stdout
    assert log.count(f"undo-of: {run_one}") == 2


def test_unknown_run_and_no_git_workspace(tmp_path):
    with _Session(tmp_path) as session:
        missing = session.one(run_changes_get_payload(run_id="nope"), "run_changes")
        assert missing["reason"] == "not_found" and missing["undoable"] is False
        undo = session.one(run_undo_payload(run_id="nope"), "run_undo_result")
        assert undo["ok"] is False and undo["code"] == "not_found"

        done = session.task("write the plan")
        # The workspace loses its history (or never had one).
        shutil.rmtree(session.workspace / ".git")
        listed = session.one(run_changes_get_payload(run_id=done["run_id"]), "run_changes")
        assert listed["reason"] == "no_history" and listed["files"] == []
        result = session.one(run_undo_payload(run_id=done["run_id"]), "run_undo_result")
        assert result["ok"] is False and result["code"] == "no_history"
        assert "Nothing to undo" in result["error"]
        assert not (session.workspace / ".git").exists()


@pytest.mark.parametrize("bad", ["plan.md", None, {"path": "plan.md"}, 3])
def test_undo_refuses_paths_that_is_not_a_list(tmp_path, bad):
    with _Session(tmp_path) as session:
        done = session.task("write the plan")
        payload = run_undo_payload(run_id=done["run_id"])
        payload["paths"] = bad
        refused = session.one(payload, "run_undo_result")
        assert refused["ok"] is False and refused["code"] == "failed"
        assert refused["error"] == "paths must be a list of file paths."
        assert refused["reverted"] == [] and refused["session_key"] == "thread-A"
        # Nothing was reverted: a bad ``paths`` never widens to the whole run.
        assert (session.workspace / "plan.md").exists()
        assert (session.workspace / "shared.txt").exists()

        # No ``paths`` key at all still means every file.
        everything = session.one(run_undo_payload(run_id=done["run_id"]), "run_undo_result")
        assert everything["ok"] is True
        assert everything["reverted"] == ["plan.md", "shared.txt"]
