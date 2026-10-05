"""Skill proposals over the wire (docs/WIRE_CONTRACT.md, "Skill proposals",
bead chuk_chat-al2u).

The agent's ``propose_skill`` streams a ``skill_proposal`` frame and stores the
draft; it writes nothing. The app's ``skill_proposal_decision`` is answered with
one terminal ``skill_proposal_result``: an accept writes
``<workspace>/skills/<name>/SKILL.md`` (the next ``skills_list`` shows it), a
reject drops the draft. The outcome is patched into the persisted frame, so a
replayed card shows it as decided.
"""

from __future__ import annotations

import json
import sqlite3

from chuk_agents_runtime import MockModelClient, tool_call_response
from chuk_agents_runtime.skill_proposals import SkillProposalStore
from chuk_agents_sandbox import LocalEnvironment

from chuk_agents_executor import ControllerSession, Executor, loopback_pair
from chuk_agents_executor.protocol import (
    skill_proposal_decision_payload,
    skills_list_request_payload,
)

from wiring import paired_channel

DESCRIPTION = "Export the monthly invoices as CSV. Load it when the user asks for the invoice export."
BODY = "# Export the monthly invoices\n\n1. Download the CSV.\n2. Check the row count."


def _proposing_model() -> MockModelClient:
    return MockModelClient(
        [
            tool_call_response(
                (
                    "propose_skill",
                    {
                        "name": "invoice-export",
                        "description": DESCRIPTION,
                        "body": BODY + "\n3. Mail it to anna@example.com.",
                    },
                )
            ),
            "Done.",
        ]
    )


class _Session:
    def __init__(self, tmp_path) -> None:
        self.tmp_path = tmp_path
        self.workspace = tmp_path / "ws"
        self.workspace.mkdir(exist_ok=True)
        channel = paired_channel()
        controller_ep, executor_ep = loopback_pair()
        self.executor = Executor(
            name="skill-proposals",
            endpoint=executor_ep,
            opener=channel.executor.opener,
            sealer=channel.executor.sealer,
            environment=LocalEnvironment(workdir=str(self.workspace)),
            db_path=str(tmp_path / "state.db"),
            model_factory=_proposing_model,
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

    def send(self, payload: dict, timeout: float = 15.0) -> list[dict]:
        rid = self.controller.send_payload(payload)
        return self.controller.collect(rid, timeout=timeout)

    def propose(self) -> dict:
        events = self.send({"type": "task", "prompt": "export the invoices", "session_key": "thread-A"})
        proposals = [e for e in events if e["type"] == "skill_proposal"]
        assert len(proposals) == 1, [e["type"] for e in events]
        tool = [e for e in events if e["type"] == "tool" and e["name"] == "propose_skill"]
        assert tool and tool[0]["status"] == "completed"
        return proposals[0]

    def persisted_proposals(self) -> list[dict]:
        conn = sqlite3.connect(str(self.tmp_path / "state.db"))
        try:
            rows = conn.execute(
                "SELECT content FROM messages WHERE role = 'event'"
            ).fetchall()
        finally:
            conn.close()
        frames = [json.loads(row[0]) for row in rows]
        return [f for f in frames if f.get("type") == "skill_proposal"]


def test_a_proposal_streams_a_card_and_writes_nothing(tmp_path):
    with _Session(tmp_path) as session:
        proposal = session.propose()
    assert proposal["proposal_id"].startswith("sp_")
    assert proposal["agent_id"] == "thread-A"
    assert proposal["name"] == "invoice-export"
    assert proposal["description"] == DESCRIPTION
    # Scrubbed before the user ever saw it.
    assert "anna@example.com" not in proposal["body"] and "<email>" in proposal["body"]
    assert not (session.workspace / "skills" / "invoice-export").exists()
    row = SkillProposalStore(tmp_path / "state.db").get(proposal["proposal_id"])
    assert row["status"] == "pending" and row["session_key"] == "thread-A"
    assert row["skills_root"] == str(session.workspace / "skills")
    # Persisted in the thread, so a replay shows the card.
    (persisted,) = session.persisted_proposals()
    assert persisted["proposal_id"] == proposal["proposal_id"]


def test_accept_saves_the_skill_and_the_skills_list_shows_it(tmp_path):
    with _Session(tmp_path) as session:
        proposal = session.propose()
        (result,) = session.send(
            skill_proposal_decision_payload(
                proposal_id=proposal["proposal_id"],
                accept=True,
                description="Export invoices as CSV.",
            )
        )
        (listing,) = session.send(skills_list_request_payload())
        (again,) = session.send(
            skill_proposal_decision_payload(proposal_id=proposal["proposal_id"], accept=False)
        )
    path = session.workspace / "skills" / "invoice-export" / "SKILL.md"
    assert result == {
        "type": "skill_proposal_result",
        "proposal_id": proposal["proposal_id"],
        "status": "saved",
        "errors": [],
        "name": "invoice-export",
        "path": str(path),
        "scrubbed": False,
    }
    assert path.is_file() and "Export invoices as CSV." in path.read_text()
    assert [(s["name"], s["source"], s["enabled"]) for s in listing["skills"]] == [
        ("invoice-export", "workspace", True)
    ]
    assert again["status"] == "saved" and again["already_decided"] is True
    (persisted,) = session.persisted_proposals()
    assert persisted["status"] == "saved" and persisted["saved_name"] == "invoice-export"


def test_reject_drops_the_draft(tmp_path):
    with _Session(tmp_path) as session:
        proposal = session.propose()
        (result,) = session.send(
            skill_proposal_decision_payload(proposal_id=proposal["proposal_id"], accept=False)
        )
    assert result["type"] == "skill_proposal_result" and result["status"] == "dismissed"
    assert not (session.workspace / "skills").exists()
    (persisted,) = session.persisted_proposals()
    assert persisted["status"] == "dismissed" and persisted["saved_name"] is None


def test_an_invalid_edit_is_refused_and_can_be_fixed(tmp_path):
    with _Session(tmp_path) as session:
        proposal = session.propose()
        (bad,) = session.send(
            skill_proposal_decision_payload(
                proposal_id=proposal["proposal_id"], accept=True, name="Invoice Export"
            )
        )
        (good,) = session.send(
            skill_proposal_decision_payload(
                proposal_id=proposal["proposal_id"], accept=True, name="invoices"
            )
        )
    assert bad["status"] == "invalid" and "invalid name" in bad["errors"][0]
    assert good["status"] == "saved"
    assert (session.workspace / "skills" / "invoices" / "SKILL.md").is_file()


def test_an_unknown_proposal_is_answered_not_found(tmp_path):
    with _Session(tmp_path) as session:
        (result,) = session.send(skill_proposal_decision_payload(proposal_id="sp_nope", accept=True))
    assert result["type"] == "skill_proposal_result"
    assert result["status"] == "not_found"
    assert result["errors"] == ["no skill proposal 'sp_nope'"]
