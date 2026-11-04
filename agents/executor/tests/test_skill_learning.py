"""The background review and the skill curator after a finished task
(Hermes H1, H5). Both are opt-in; the review's card goes through the normal
``skill_proposal`` path and is persisted for the replay, never applied."""

from __future__ import annotations

import json
import sqlite3
import time

from chuk_agents_runtime import MockModelClient, tool_call_response
from chuk_agents_runtime.skill_proposals import SkillProposalStore
from chuk_agents_sandbox import LocalEnvironment

from chuk_agents_executor import ControllerSession, Executor, loopback_pair

from wiring import paired_channel

REVIEW = json.dumps(
    {
        "memory": ["The user wants CSV."],
        "skill": {
            "action": "create",
            "name": "invoice-export",
            "description": "Export invoices as CSV.",
            "body": "# Export\n\n1. Download.\n2. Check the rows.",
        },
    }
)


def _factory(calls: list):
    def make():
        calls.append(1)
        if len(calls) == 1:  # the task's model
            return MockModelClient(
                [
                    tool_call_response(("list_dir", {"path": "."})),
                    tool_call_response(("list_dir", {"path": "."})),
                    "Done.",
                ]
            )
        if len(calls) == 2:  # the browser fallback client (unused)
            return MockModelClient(["unused"])
        return MockModelClient([REVIEW])  # the review

    return make


def _persisted(db: str) -> list[dict]:
    conn = sqlite3.connect(db)
    try:
        rows = conn.execute("SELECT content FROM messages WHERE role = 'event'").fetchall()
    finally:
        conn.close()
    return [f for f in (json.loads(r[0]) for r in rows) if f.get("type") == "skill_proposal"]


def _run(tmp_path, monkeypatch, *, enabled: bool):
    if enabled:
        monkeypatch.setenv("AGENTS_BACKGROUND_REVIEW", "1")
    else:
        monkeypatch.delenv("AGENTS_BACKGROUND_REVIEW", raising=False)
    workspace = tmp_path / "ws"
    workspace.mkdir()
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    calls: list = []
    db = str(tmp_path / "state.db")
    executor = Executor(
        name="learning",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(workspace)),
        db_path=db,
        model_factory=_factory(calls),
        workspace=str(workspace),
    )
    controller = ControllerSession(
        endpoint=controller_ep, sealer=channel.controller.sealer, opener=channel.controller.opener
    )
    executor.start()
    try:
        rid = controller.send_payload({"type": "task", "prompt": "export", "session_key": "t"})
        events = controller.collect(rid, timeout=15.0)
        deadline = time.time() + 10
        found: list[dict] = []
        while time.time() < deadline:
            found = _persisted(db)
            if found or not enabled:
                break
            time.sleep(0.05)
        if not enabled:
            time.sleep(0.3)
            found = _persisted(db)
    finally:
        executor.stop()
    return events, found, workspace, db, calls


def test_review_offers_a_card_after_done_and_writes_nothing(tmp_path, monkeypatch):
    events, found, workspace, db, _ = _run(tmp_path, monkeypatch, enabled=True)
    assert events[-1]["type"] == "done"
    # Not on the live stream: it came after the terminal.
    assert not any(e["type"] == "skill_proposal" for e in events)
    assert len(found) == 1
    card = found[0]
    assert card["name"] == "invoice-export" and card["kind"] == "create"
    assert card["origin"] == "review"
    assert not (workspace / "skills" / "invoice-export").exists()
    row = SkillProposalStore(db).get(card["proposal_id"])
    assert row["status"] == "pending"


def test_review_is_off_by_default(tmp_path, monkeypatch):
    _, found, _, _, calls = _run(tmp_path, monkeypatch, enabled=False)
    assert found == []
    assert len(calls) == 2  # no third client was built
