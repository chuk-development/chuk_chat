"""``agents-host agents list|delete`` (agent_admin.py): a delete tombstones the
name for every app, stops the agent's automations and, with ``purge``, removes
its thread and workspace. The host's own agent is refused."""

from __future__ import annotations

import sqlite3

from chuk_agents_host.agent_admin import delete_agent, list_agents
from chuk_agents_host.cli import main
from chuk_agents_host.coworker_names import CoworkerNameStore, agent_list_answer
from chuk_agents_host.host import _agent_dirname

AGENT = "local:r2-p1:8:7"
KEEP = "local:Mail:14:1"


def _seed(tmp_path):
    names = CoworkerNameStore(str(tmp_path / "roster.db"), device_id="cowork-host")
    names.upsert(AGENT, "r2-p1", created_by_app=True)
    names.upsert(KEEP, "Mail", created_by_app=True)
    names.close()
    conn = sqlite3.connect(str(tmp_path / "executor-state.db"))
    conn.executescript(
        """
        CREATE TABLE sessions (session_id INTEGER PRIMARY KEY, created_at REAL, meta TEXT);
        CREATE TABLE session_routes (session_key TEXT PRIMARY KEY, session_id INTEGER);
        CREATE TABLE messages (id INTEGER PRIMARY KEY, session_id INTEGER, role TEXT,
                               content TEXT, created_at REAL);
        CREATE TABLE event_blobs (message_id INTEGER PRIMARY KEY, data BLOB);
        CREATE TABLE runs (run_id TEXT PRIMARY KEY, session_id INTEGER);
        CREATE TABLE automations (id TEXT PRIMARY KEY, session_key TEXT, name TEXT,
                                  state TEXT, next_fire_at REAL, last_error TEXT);
        INSERT INTO sessions VALUES (1, 0, '{}'), (2, 0, '{}');
        INSERT INTO session_routes VALUES ('local:r2-p1:8:7', 1), ('local:Mail:14:1', 2);
        INSERT INTO messages VALUES (1, 1, 'user', 'hi', 100), (2, 1, 'assistant', 'Hi', 101),
                                    (3, 2, 'user', 'mail?', 200);
        INSERT INTO event_blobs VALUES (2, x'00');
        INSERT INTO runs VALUES ('r1', 1);
        INSERT INTO automations VALUES ('a1', 'local:r2-p1:8:7', 'Check', 'active', 5, NULL),
                                       ('a2', 'local:Mail:14:1', 'Mail', 'active', 5, NULL);
        """
    )
    conn.commit()
    conn.close()
    ws = tmp_path / "agents" / _agent_dirname(AGENT)
    ws.mkdir(parents=True)
    (ws / "note.txt").write_text("x")
    return ws


def test_list_shows_messages_activity_and_automations(tmp_path):
    _seed(tmp_path)
    rows = {row.agent_id: row for row in list_agents(tmp_path, device_id="cowork-host")}
    assert rows[AGENT].messages == 2
    assert rows[AGENT].active_automations == ["Check (active)"]
    assert rows[KEEP].name == "Mail"
    assert "host:cowork-host" in rows


def test_delete_with_purge(tmp_path):
    ws = _seed(tmp_path)
    result = delete_agent(tmp_path, AGENT, purge=True, device_id="cowork-host")
    assert result["ok"] and result["automations_stopped"] == 1
    assert result["messages_removed"] == 2
    assert not ws.exists()
    names = CoworkerNameStore(str(tmp_path / "roster.db"), device_id="cowork-host")
    answer = agent_list_answer(names)
    names.close()
    assert [row["agent_id"] for row in answer["agents"]] == [KEEP]
    assert answer["deleted"] == [AGENT]
    conn = sqlite3.connect(str(tmp_path / "executor-state.db"))
    assert conn.execute("SELECT COUNT(*) FROM messages").fetchone()[0] == 1
    assert conn.execute("SELECT COUNT(*) FROM event_blobs").fetchone()[0] == 0
    assert conn.execute("SELECT state FROM automations WHERE id='a1'").fetchone()[0] == "done"
    assert conn.execute("SELECT state FROM automations WHERE id='a2'").fetchone()[0] == "active"
    conn.close()


def test_delete_without_purge_keeps_the_history(tmp_path):
    ws = _seed(tmp_path)
    assert delete_agent(tmp_path, AGENT, device_id="cowork-host")["ok"]
    assert ws.exists()
    conn = sqlite3.connect(str(tmp_path / "executor-state.db"))
    assert conn.execute("SELECT COUNT(*) FROM messages").fetchone()[0] == 3
    conn.close()


def test_the_host_agent_is_refused(tmp_path):
    _seed(tmp_path)
    assert delete_agent(tmp_path, "host:cowork-host", device_id="cowork-host")["ok"] is False


def test_cli_delete(tmp_path, capsys):
    _seed(tmp_path)
    assert main(["agents", "--workspace", str(tmp_path), "delete", AGENT]) == 0
    assert "deleted" in capsys.readouterr().out
    assert main(["agents", "--workspace", str(tmp_path), "list"]) == 0
    assert AGENT not in capsys.readouterr().out
