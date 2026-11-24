"""CHAT-183 through the executor: run modes that stick to a chat, and the
skill self-fix after a failed run, over the real sealed loopback."""

from __future__ import annotations

import json
import sqlite3

from chuk_agents_runtime import StateStore, tool_call_response
from chuk_agents_runtime.model import ModelResponse

from chuk_agents_executor import task_payload

from test_agent_modes import KEY, _drive, _rows, _Shared, _start


def test_a_mode_sticks_to_the_chat_until_changed(tmp_path):
    executor, controller = _start(
        tmp_path,
        [
            "Found two problems.",
            tool_call_response(("write_file", {"path": "x.txt", "content": "x"})),
            "I cannot write in review mode.",
            "Normal again.",
        ],
    )
    try:
        first = _drive(controller, controller.send_task("/mode review check the PR", session_key=KEY))
        [frame] = [e for e in first if e.get("type") == "run_mode"]
        assert frame["mode"]["name"] == "review" and "error" not in frame
        user = [m.content for m in _rows(tmp_path) if m.role == "user"]
        assert user[-1]["content"] == "check the PR"
        # A follow-up without a switch: still review mode, and the stream says so.
        second = _drive(controller, controller.send_task("also check the tests", session_key=KEY))
        assert [e["mode"]["name"] for e in second if e.get("type") == "run_mode"] == ["review"]
        assert not (tmp_path / "ws" / "x.txt").exists()
        tools = [m.content for m in _rows(tmp_path) if m.content.get("role") == "tool"]
        assert "not allowed in review mode" in str(tools[-1].get("content"))
        blocks = [m for m in _rows(tmp_path) if m.content.get("source") == "mode"]
        assert len(blocks) == 2  # once per task
        replay = _drive(controller, controller.send_payload({"type": "replay", "session_key": KEY}))
        assert replay[0]["type"] == "run_state" and replay[0]["run_mode"]["name"] == "review"
        # Clearing it.
        third = _drive(
            controller,
            controller.send_payload({**task_payload("plain now", KEY), "mode": "off"}),
        )
        [cleared] = [e for e in third if e.get("type") == "run_mode"]
        assert cleared["mode"] is None
    finally:
        executor.stop()


def test_the_plan_mode_is_plan_mode_and_an_unknown_mode_is_reported(tmp_path):
    executor, controller = _start(tmp_path, ["Exploring.", "ok"])
    try:
        events = _drive(
            controller, controller.send_payload({**task_payload("plan it", KEY), "mode": "plan"})
        )
        assert [e["active"] for e in events if e.get("type") == "plan_mode"] == [True]
        assert [e["mode"]["name"] for e in events if e.get("type") == "run_mode"] == ["plan"]
        bad = _drive(controller, controller.send_task("/mode nope hi", session_key=KEY))
        [frame] = [e for e in bad if e.get("type") == "run_mode" and e.get("error")]
        assert "unknown run mode" in frame["error"] and frame["mode"]["name"] == "plan"
    finally:
        executor.stop()


def _skill(ws, body="# Deploy\n\nrun ./deploy.sh"):
    d = ws / "skills" / "deploy"
    d.mkdir(parents=True, exist_ok=True)
    (d / "SKILL.md").write_text(f"---\nname: deploy\ndescription: Deploys.\n---\n\n{body}\n")


def _seed(tmp_path, *rows):
    store = StateStore(str(tmp_path / "state.db"))
    try:
        sid = store.route(KEY)
        for tag, content in rows:
            store.append_message(sid, tag, content)
    finally:
        store.close()


def _proposals(tmp_path) -> int:
    conn = sqlite3.connect(str(tmp_path / "state.db"))
    try:
        return conn.execute("SELECT count(*) FROM skill_proposals").fetchone()[0]
    except sqlite3.OperationalError:
        return 0
    finally:
        conn.close()


def test_skill_selffix_after_a_failed_skill_run(tmp_path):
    fix = json.dumps({"skill": {"name": "deploy", "why": "missing check",
                                "description": "", "body": "# Deploy\n\n1. run\n2. check"}})
    executor, controller = _start(tmp_path, [ModelResponse(text=fix, raw={"content": fix})])
    try:
        ws = tmp_path / "ws"
        _skill(ws)
        _seed(
            tmp_path,
            ("user", {"role": "user", "content": "deploy it"}),
            ("skill", {"role": "user", "content": "## ACTIVE SKILL: deploy\n\nold"}),
            ("assistant", {"role": "assistant", "content": "ran out"}),
        )
        run = type("R", (), {"profile": None, "origin": "app", "run_id": "r1",
                             "request_id": "q1", "session_key": KEY, "cost": None})()
        # A finished run is no trigger: no model client is built, nothing stored.
        before = len(_Shared.script)
        assert executor._run_skill_selffix(run, "q1", KEY, str(ws / "skills"), "finished") is False
        assert len(_Shared.script) == before and _proposals(tmp_path) == 0
        # The same run ending at its step limit proposes a pinned patch.
        assert executor._run_skill_selffix(
            run, "q1", KEY, str(ws / "skills"), "max_iterations"
        ) is True
        assert _proposals(tmp_path) == 1
        assert "2. check" not in (ws / "skills" / "deploy" / "SKILL.md").read_text()
    finally:
        executor.stop()
