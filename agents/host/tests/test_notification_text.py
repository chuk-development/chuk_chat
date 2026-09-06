"""What a completion notification says (docs/WIRE_CONTRACT.md, P7).

The bug this pins: a run fired by the automation "Wahlradar LT Sachsen-Anhalt
2026" announced itself as "ivory-lynx / Finish your task" — the roster codename,
which the reader has never seen, and an instruction to finish work that had just
finished."""

from __future__ import annotations

import sqlite3

from cowork_host.coworker_names import CoworkerNameStore, host_agent_id
from cowork_host.notification_text import (
    DEFAULT_COWORKER,
    RunLabels,
    approval_text,
    completion_text,
    default_roster_path,
    resolve_labels,
)

CODENAME = "ivory-lynx"
AUTOMATION = "Wahlradar LT Sachsen-Anhalt 2026"


def _automations_db(path, rows: list[tuple[str, str]]) -> str:
    conn = sqlite3.connect(str(path))
    conn.execute("CREATE TABLE automations (id TEXT PRIMARY KEY, name TEXT NOT NULL)")
    conn.executemany("INSERT INTO automations (id, name) VALUES (?, ?)", rows)
    conn.commit()
    conn.close()
    return str(path)


def test_an_automation_run_names_the_automation_and_the_coworker():
    title, body = completion_text(RunLabels(coworker="Nova", automation=AUTOMATION))
    assert title == f"Nova: {AUTOMATION}"
    assert body == "The answer is ready. Open the app to read it."
    assert CODENAME not in title


def test_the_body_reports_what_happened_and_asks_for_nothing():
    _, body = completion_text(RunLabels(coworker="Nova"))
    # The run is over; "finish your task" was the wrong sentence for it.
    assert "finish your task" not in body.lower()
    _, failed = completion_text(RunLabels(coworker="Nova"), failed=True)
    assert failed == "The run did not finish. Open the app to see what happened."


def test_a_plain_run_names_only_the_coworker():
    title, _ = completion_text(RunLabels(coworker="Nova"))
    assert title == "Nova"


def test_an_unknown_coworker_falls_back_to_a_generic_label():
    title, _ = completion_text(RunLabels(automation=AUTOMATION))
    assert title == f"{DEFAULT_COWORKER}: {AUTOMATION}"
    assert completion_text(RunLabels())[0] == DEFAULT_COWORKER


def test_an_approval_names_the_coworker():
    title, body = approval_text(RunLabels(coworker="Nova"))
    assert title == "Nova needs your approval"
    assert "publish" in body


def test_a_long_automation_name_is_clipped_to_one_line():
    title, _ = completion_text(RunLabels(coworker="Nova", automation="x" * 200))
    assert len(title) < 80 and title.endswith("…")


def test_resolve_reads_the_coworker_name_and_the_automation_name(tmp_path):
    db_path = _automations_db(tmp_path / "executor-state.db", [("a1", AUTOMATION)])
    store = CoworkerNameStore(str(tmp_path / "roster.db"))
    store.upsert(host_agent_id(), "Nova", created_by_app=True)
    store.close()

    labels = resolve_labels(db_path=db_path, automation_id="a1")
    assert labels == RunLabels(coworker="Nova", automation=AUTOMATION)
    assert completion_text(labels)[0] == f"Nova: {AUTOMATION}"


def test_resolve_finds_the_roster_next_to_the_state_file(tmp_path):
    assert default_roster_path(str(tmp_path / "executor-state.db")) == str(tmp_path / "roster.db")


def test_a_missing_store_costs_a_name_not_the_notification(tmp_path):
    # No roster file, no automations table, a stale automation id: all three
    # degrade to the generic label instead of raising or naming the codename.
    labels = resolve_labels(db_path=str(tmp_path / "nothing.db"), automation_id="gone")
    assert labels == RunLabels(coworker=None, automation=None)
    assert completion_text(labels)[0] == DEFAULT_COWORKER


def test_a_run_that_no_automation_fired_has_no_automation_label(tmp_path):
    db_path = _automations_db(tmp_path / "executor-state.db", [("a1", AUTOMATION)])
    assert resolve_labels(db_path=db_path, automation_id=None).automation is None


def test_the_thread_names_its_own_coworker(tmp_path):
    """A run's session key IS the app's agent id, so a user with several
    coworkers gets the name of the one whose thread finished."""
    db_path = _automations_db(tmp_path / "executor-state.db", [("a1", AUTOMATION)])
    store = CoworkerNameStore(str(tmp_path / "roster.db"))
    store.upsert("local:brisk-heron:2:116636868", "Wahlradar", created_by_app=True)
    store.upsert(host_agent_id(), "Nova", created_by_app=True)
    store.close()

    labels = resolve_labels(
        db_path=db_path,
        automation_id="a1",
        session_key="local:brisk-heron:2:116636868",
    )
    assert labels.coworker == "Wahlradar"
    assert completion_text(labels)[0] == AUTOMATION  # the name already carries it
    # An unknown thread key falls back to this host's own coworker.
    assert resolve_labels(db_path=db_path, session_key="default").coworker == "Nova"


def test_a_coworker_named_after_its_automation_is_not_repeated():
    title, _ = completion_text(RunLabels(coworker="Wahlradar", automation=AUTOMATION))
    assert title == AUTOMATION
