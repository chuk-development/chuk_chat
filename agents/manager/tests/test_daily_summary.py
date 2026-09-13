"""Daily summary journal (§13 daily-summary).

Every test pins its own instant and injects a stub journal / message log and a
stub model, so nothing sleeps, touches a network, or depends on the host clock.
Covers: sectioned output with a stub model, the deterministic no-model fallback,
per-day filtering, idempotent re-runs (overwrite not append), the zero-token
no_agent script, and registration into the real scheduler.
"""

from __future__ import annotations

import json
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

from chuk_agents_manager.autonomy import (
    DAILY_SUMMARY_JOB_ID,
    JobDispatcher,
    UnattendedRunner,
    register_daily_summary,
)
from chuk_agents_manager.daily_summary import (
    daily_summary_script,
    gather_activity,
    summary_path,
    write_daily_summary,
)
from chuk_agents_manager.scheduler import JobMode, Scheduler, utc

DAY = date(2026, 2, 3)


# -- stubs ------------------------------------------------------------------


class StubModel:
    """A scripted model that records its calls and returns a fixed answer."""

    def __init__(self, text: str = "Worked on the pairing flow and shipped it.") -> None:
        self._text = text
        self.calls: list[list[dict]] = []

    def complete(self, messages: list[dict]) -> Any:
        self.calls.append(messages)

        class _Resp:
            text = self._text

        return _Resp()


class BoomModel:
    """A model that always raises — the job must survive it."""

    def __init__(self) -> None:
        self.calls = 0

    def complete(self, messages: list[dict]) -> Any:
        self.calls += 1
        raise RuntimeError("model unavailable")


def _journal_rows() -> list[dict]:
    """A day's worth of stub journal entries, journal-shaped."""
    return [
        {
            "seq": 1,
            "ts": "2026-02-03T09:15:00+00:00",
            "tool": "write",
            "args": {"path": "src/app.py"},
            "result": "wrote 40 lines",
            "ok": True,
            "changed_files": ["src/app.py"],
        },
        {
            "seq": 2,
            "ts": "2026-02-03T10:30:00+00:00",
            "tool": "run",
            "args": {"command": "pytest -q"},
            "result": "12 passed",
            "ok": True,
            "changed_files": [],
        },
        {
            "seq": 3,
            "ts": "2026-02-03T11:00:00+00:00",
            "tool": "run",
            "args": {"command": "ruff check"},
            "result": "error: E501 line too long",
            "ok": False,
            "changed_files": [],
        },
        # A different day — must be filtered out.
        {
            "seq": 4,
            "ts": "2026-02-04T08:00:00+00:00",
            "tool": "write",
            "args": {"path": "other.py"},
            "result": "next day",
            "ok": True,
            "changed_files": ["other.py"],
        },
    ]


def _messages() -> list[dict]:
    day_noon = datetime(2026, 2, 3, 12, 0, tzinfo=timezone.utc).timestamp()
    other_day = datetime(2026, 2, 4, 12, 0, tzinfo=timezone.utc).timestamp()
    return [
        {"role": "user", "content": "please fix the linter", "created_at": day_noon},
        {"role": "assistant", "content": {"text": "on it"}, "created_at": day_noon},
        {"role": "user", "content": "next day msg", "created_at": other_day},
    ]


# -- gather -----------------------------------------------------------------


def test_gather_filters_to_the_day() -> None:
    activity = gather_activity(
        day=DAY, journal_entries=_journal_rows(), messages=_messages()
    )
    # Three journal rows fall on 2026-02-03, one is the next day.
    assert activity.total_actions == 3
    assert activity.ok_actions == 2
    assert activity.error_actions == 1
    assert activity.tools["run"] == 2
    assert activity.tools["write"] == 1
    assert activity.files == ["src/app.py"]
    assert len(activity.errors) == 1
    # Two of the three messages are on the day; one user headline captured.
    assert activity.message_turns == 2
    assert activity.role_counts["user"] == 1
    assert activity.message_headlines == ["please fix the linter"]


# -- render with a model ----------------------------------------------------


EXPECTED_SECTIONS = [
    "# Daily summary — 2026-02-03",
    "## Overview",
    "## Summary",
    "## Tasks done",
    "## Decisions",
    "## Files touched",
    "## Errors",
    "## Next steps",
]


def test_write_with_stub_model_has_all_sections(tmp_path: Path) -> None:
    model = StubModel()
    path = write_daily_summary(
        tmp_path,
        day=DAY,
        model=model,
        journal_entries=_journal_rows(),
        messages=_messages(),
        now=lambda: utc(2026, 2, 4, 0, 0),
    )
    assert path == summary_path(tmp_path, DAY)
    text = path.read_text(encoding="utf-8")
    for header in EXPECTED_SECTIONS:
        assert header in text, header
    # The model summarised the digest, and its prose is under ## Summary.
    assert model.calls, "model should have been called"
    assert "Worked on the pairing flow" in text
    # Facts land in their sections.
    assert "src/app.py" in text
    assert "ruff check" in text  # the failed action surfaces under Errors
    assert "Investigate 1 failed action" in text  # deterministic next steps


# -- deterministic fallback (no model) --------------------------------------


def test_deterministic_fallback_no_model(tmp_path: Path) -> None:
    path = write_daily_summary(
        tmp_path,
        day=DAY,
        model=None,
        journal_entries=_journal_rows(),
        now=lambda: utc(2026, 2, 4, 0, 0),
    )
    text = path.read_text(encoding="utf-8")
    for header in EXPECTED_SECTIONS:
        assert header in text, header
    # No model, so the deterministic recap describes the actions.
    assert "Ran 3 tool actions" in text
    assert "src/app.py" in text


def test_model_failure_falls_back(tmp_path: Path) -> None:
    boom = BoomModel()
    path = write_daily_summary(
        tmp_path,
        day=DAY,
        model=boom,
        journal_entries=_journal_rows(),
        now=lambda: utc(2026, 2, 4, 0, 0),
    )
    text = path.read_text(encoding="utf-8")
    assert boom.calls == 1  # it was tried
    assert "Ran 3 tool actions" in text  # and the job still produced a summary


def test_empty_day_never_fails(tmp_path: Path) -> None:
    path = write_daily_summary(
        tmp_path, day=DAY, model=None, journal_entries=[], now=lambda: utc(2026, 2, 4)
    )
    text = path.read_text(encoding="utf-8")
    assert "No recorded activity for this day." in text
    assert "## Errors" in text


# -- idempotency ------------------------------------------------------------


def test_rerun_overwrites_not_appends(tmp_path: Path) -> None:
    kwargs = dict(
        day=DAY, model=None, journal_entries=_journal_rows(), now=lambda: utc(2026, 2, 4)
    )
    p1 = write_daily_summary(tmp_path, **kwargs)
    first = p1.read_text(encoding="utf-8")
    p2 = write_daily_summary(tmp_path, **kwargs)
    second = p2.read_text(encoding="utf-8")
    assert p1 == p2
    assert first == second  # byte-identical, no duplication
    # Exactly one H1 — proof it was overwritten, not appended to.
    assert second.count("# Daily summary — 2026-02-03") == 1
    # And exactly one file in the journal dir.
    files = list((tmp_path / "journal").glob("*.md"))
    assert files == [summary_path(tmp_path, DAY)]


# -- on-disk journal reading ------------------------------------------------


def test_reads_agents_journal_files(tmp_path: Path) -> None:
    agents = tmp_path / ".agents"
    agents.mkdir()
    # Parent journal + one subagent journal — both must be picked up.
    (agents / "journal.jsonl").write_text(
        json.dumps(_journal_rows()[0]) + "\n"
        "not valid json\n"  # a corrupt line must be skipped, not raised
        + json.dumps(_journal_rows()[1]) + "\n",
        encoding="utf-8",
    )
    (agents / "journal-sub1.jsonl").write_text(
        json.dumps(_journal_rows()[2]) + "\n", encoding="utf-8"
    )
    activity = gather_activity(day=DAY, workspace=tmp_path)
    assert activity.total_actions == 3
    assert activity.error_actions == 1
    assert set(activity.sources) == {"journal.jsonl", "journal-sub1.jsonl"}


# -- timezone / run's local date --------------------------------------------


def test_default_day_is_runs_local_date(tmp_path: Path) -> None:
    # 01:30 UTC on the 4th is still the 3rd in a US/Pacific-ish -8 zone... use a
    # fixed offset zone to keep the test hermetic.
    tz = ZoneInfo("Etc/GMT+5")  # UTC-5
    # 03:00 UTC on the 4th -> 22:00 on the 3rd local.
    path = write_daily_summary(
        tmp_path, tz=tz, journal_entries=[], now=lambda: utc(2026, 2, 4, 3, 0)
    )
    assert path == summary_path(tmp_path, date(2026, 2, 3))


# -- no_agent script --------------------------------------------------------


def test_daily_summary_script_zero_tokens(tmp_path: Path) -> None:
    provider_calls: list[date] = []

    def provider(day: date) -> list[dict]:
        provider_calls.append(day)
        return _messages()

    # Fire at exactly midnight on the 4th -> closes the 3rd (end-of-day).
    script = daily_summary_script(
        tmp_path,
        model=None,
        messages_provider=provider,
        now=lambda: utc(2026, 2, 4, 0, 0),
    )
    # Seed an on-disk journal so the script reads real activity.
    agents = tmp_path / ".agents"
    agents.mkdir()
    (agents / "journal.jsonl").write_text(
        "\n".join(json.dumps(r) for r in _journal_rows()[:3]) + "\n",
        encoding="utf-8",
    )
    path = script()
    assert path == summary_path(tmp_path, DAY)
    assert provider_calls == [DAY]  # asked for the day that just ended
    text = path.read_text(encoding="utf-8")
    assert "# Daily summary — 2026-02-03" in text
    assert "Ran 3 tool actions" in text


# -- scheduler registration -------------------------------------------------


def _dispatcher() -> JobDispatcher:
    # A runner is required to build a dispatcher, but a no_agent job never
    # touches it — script_action provably bypasses the runner.
    runner = UnattendedRunner(agent_factory=lambda spec: None)  # type: ignore[arg-type]
    return JobDispatcher(runner=runner)


def test_register_disabled_by_default(tmp_path: Path) -> None:
    sched = Scheduler(tz="UTC")
    job = register_daily_summary(
        sched, _dispatcher(), workspace=tmp_path, now=utc(2026, 2, 3, 12, 0)
    )
    assert job is None
    assert sched.jobs() == []  # nothing registered, so nothing can fire


def test_register_enabled_parses_daily_schedule(tmp_path: Path) -> None:
    sched = Scheduler(tz="UTC")
    now = utc(2026, 2, 3, 12, 0)
    job = register_daily_summary(
        sched,
        _dispatcher(),
        workspace=tmp_path,
        now=now,
        enabled=True,
        agent_id="agent-7",
    )
    assert job is not None
    assert job.id == DAILY_SUMMARY_JOB_ID
    assert job.mode is JobMode.NO_AGENT
    assert job.agent_id == "agent-7"
    # "0 0 * * *" parsed to a cron spec; next fire is the coming midnight.
    assert job.spec == {"kind": "cron", "expr": "0 0 * * *"}
    assert job.next_run == utc(2026, 2, 4, 0, 0)
    # It shows up in the agent's routine view.
    assert sched.jobs_for("agent-7") == [job]


def test_registered_job_fires_and_writes(tmp_path: Path) -> None:
    sched = Scheduler(tz="UTC")
    now = utc(2026, 2, 3, 12, 0)
    # In production the ticker fires the job in real time, so the script reads
    # the real clock; here we pin that clock to the tick instant we drive below.
    register_daily_summary(
        sched,
        _dispatcher(),
        workspace=tmp_path,
        now=now,
        enabled=True,
        clock=lambda: utc(2026, 2, 4, 0, 0),
    )
    # Seed journal activity for the 3rd.
    agents = tmp_path / ".agents"
    agents.mkdir()
    (agents / "journal.jsonl").write_text(
        "\n".join(json.dumps(r) for r in _journal_rows()[:3]) + "\n",
        encoding="utf-8",
    )
    # Tick at the coming midnight -> the job fires and closes the 3rd.
    results = sched.tick(utc(2026, 2, 4, 0, 0))
    assert len(results) == 1
    written = results[0]
    assert written == summary_path(tmp_path, DAY)
    assert Path(written).read_text(encoding="utf-8").count(
        "# Daily summary — 2026-02-03"
    ) == 1
