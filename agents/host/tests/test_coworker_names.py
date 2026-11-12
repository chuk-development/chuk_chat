"""Agent names (docs/WIRE_CONTRACT.md "Agent names", bead cowork-817):
the host keeps the names the user chose in the app, keyed by the app's id, and
answers every frame with the current list."""

from __future__ import annotations

import sqlite3

from chuk_agents_manager import RosterStore

from chuk_agents_host.coworker_names import (
    CoworkerNameStore,
    agent_list_answer,
    clean_name,
    handle_agent_frame,
    host_agent_id,
)


def test_create_rename_list_roundtrip():
    store = CoworkerNameStore(device_id="cowork-host")
    logs: list[str] = []

    out = handle_agent_frame(
        store, {"type": "agent_create", "agent_id": "local:desk:1:7", "name": "  Crypto Desk "}, log=logs.append
    )
    assert out == [{"agent_id": "local:desk:1:7", "name": "Crypto Desk", "host": False}]

    out = handle_agent_frame(
        store, {"type": "agent_rename", "agent_id": host_agent_id("cowork-host"), "name": "Laptop Bot"}
    )
    assert out[-1] == {"agent_id": "host:cowork-host", "name": "Laptop Bot", "host": True}
    assert len(out) == 2

    # A rename moves the row to the end (updated_at ascending).
    out = handle_agent_frame(store, {"type": "agent_rename", "agent_id": "local:desk:1:7", "name": "Desk 2"})
    assert [e["name"] for e in out] == ["Laptop Bot", "Desk 2"]

    # The plain list request changes nothing.
    assert handle_agent_frame(store, {"type": "agent_list"}) == out
    assert any("local:desk:1:7" in line for line in logs)


def test_bad_frames_are_dropped_but_the_list_is_still_answered():
    store = CoworkerNameStore()
    store.upsert("local:a:1:1", "Kept", created_by_app=True)
    logs: list[str] = []

    for bad in (
        {"type": "agent_create", "agent_id": "local:b:1:1", "name": "   "},
        {"type": "agent_create", "agent_id": "local:b:1:1", "name": "x" * 81},
        {"type": "agent_create", "agent_id": "", "name": "Nope"},
        {"type": "agent_rename", "name": "Nope"},
        {"type": "agent_rename", "agent_id": "local:b:1:1", "name": 42},
    ):
        out = handle_agent_frame(store, bad, log=logs.append)
        assert out == [{"agent_id": "local:a:1:1", "name": "Kept", "host": False}]
    assert len(logs) == 5
    assert clean_name(" ok ") == "ok" and clean_name("") is None and clean_name(None) is None


def test_upsert_reports_change_and_is_idempotent():
    store = CoworkerNameStore()
    assert store.upsert("local:a:1:1", "One", created_by_app=True) is True
    assert store.upsert("local:a:1:1", "One", created_by_app=False) is False
    assert store.upsert("local:a:1:1", "Two", created_by_app=False) is True
    assert store.list() == [{"agent_id": "local:a:1:1", "name": "Two", "host": False}]


def test_lives_next_to_the_roster_and_never_touches_the_agents_row(tmp_path):
    path = str(tmp_path / "roster.db")
    roster = RosterStore(path)
    agent = roster.create(workspace_dir=str(tmp_path / "ws"), name="amber-otter")

    names = CoworkerNameStore(path)
    names.upsert(host_agent_id(), "Laptop Bot", created_by_app=False)
    names.close()

    # Same file, own table; the roster row (and so the workspace dir) is as it was.
    assert roster.get(agent.id).name == "amber-otter"
    tables = {
        r[0]
        for r in sqlite3.connect(path).execute("SELECT name FROM sqlite_master WHERE type='table'")
    }
    assert {"agents", "coworker_names"} <= tables
    roster.close()

    # A reopen sees the name: this is what outlives the app install.
    again = CoworkerNameStore(path)
    assert again.list() == [{"agent_id": "host:cowork-host", "name": "Laptop Bot", "host": True}]
    again.close()


def test_delete_forgets_the_name_and_lists_the_id_as_deleted():
    store = CoworkerNameStore(device_id="cowork-host")
    handle_agent_frame(store, {"type": "agent_create", "agent_id": "local:r2-p1:8:7", "name": "r2-p1"})
    handle_agent_frame(store, {"type": "agent_create", "agent_id": "local:Mail:14:1", "name": "Mail"})

    out = handle_agent_frame(store, {"type": "agent_delete", "agent_id": "local:r2-p1:8:7"})
    assert [e["agent_id"] for e in out] == ["local:Mail:14:1"]
    answer = agent_list_answer(store, out)
    assert answer == {
        "type": "agent_list",
        "agents": [{"agent_id": "local:Mail:14:1", "name": "Mail", "host": False}],
        "deleted": ["local:r2-p1:8:7"],
    }
    # A second delete changes nothing and lists the id once.
    assert store.delete("local:r2-p1:8:7") is False
    assert store.deleted() == ["local:r2-p1:8:7"]


def test_neither_a_rename_nor_a_re_announce_revives_a_deleted_agent():
    """An older app still holds the agent and sends ``agent_create`` again for
    every agent the host does not list; the delete must survive that."""
    store = CoworkerNameStore(device_id="cowork-host")
    store.upsert("local:a:1:1", "A", created_by_app=True)
    store.delete("local:a:1:1")
    assert store.upsert("local:a:1:1", "Renamed", created_by_app=False) is False
    assert store.upsert("local:a:1:1", "A", created_by_app=True) is False
    assert store.list() == []
    assert store.deleted() == ["local:a:1:1"]
    assert store.name_of("local:a:1:1") is None


def test_the_host_agent_cannot_be_deleted():
    store = CoworkerNameStore(device_id="cowork-host")
    store.upsert("host:cowork-host", "Main", created_by_app=False)
    assert store.delete("host:cowork-host") is False
    assert store.name_of("host:cowork-host") == "Main"
    assert store.deleted() == []


def test_bad_delete_is_dropped_with_a_log_line():
    store = CoworkerNameStore(device_id="cowork-host")
    logs: list[str] = []
    assert handle_agent_frame(store, {"type": "agent_delete"}, log=logs.append) == []
    assert any("dropped agent_delete" in line for line in logs)
