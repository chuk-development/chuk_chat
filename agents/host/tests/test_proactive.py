"""The proactive agent on the host (CHAT-182, docs/agents/PROACTIVE.md): the
heartbeat with its zero-token pre-check, the push gate (silence, repeats,
daily cap, quiet hours with a queue) and the morning brief."""

from __future__ import annotations

from datetime import date, datetime
from pathlib import Path
from zoneinfo import ZoneInfo

from chuk_agents_runtime import StateStore
from chuk_agents_runtime.proactive import KIND_HEARTBEAT, KIND_MORNING_BRIEF, register_proactive_tools
from chuk_agents_runtime.registry import ToolRegistry
from chuk_agents_host.automations import AutomationManager
from chuk_agents_host.proactive import ProactiveManager

BERLIN = ZoneInfo("Europe/Berlin")
CHAT = "local:a1"


def _at(hour: int, minute: int = 0, day: int = 24) -> float:
    return datetime(2026, 11, day, hour, minute, tzinfo=BERLIN).timestamp()


class _Clock:
    def __init__(self, now: float) -> None:
        self.now = now

    def __call__(self) -> float:
        return self.now


class _Rig:
    def __init__(self, tmp_path: Path, now: float, *, journal=None) -> None:
        self.clock = _Clock(now)
        self.fired: list[tuple[str, str, dict]] = []
        self.sent: list[dict] = []
        self.delivered: list[dict] = []
        self.busy = False
        self.workspace = tmp_path / "ws"
        self.workspace.mkdir()
        self.db = str(tmp_path / "state.db")
        self.automations = AutomationManager(
            db_path=self.db,
            workspace=str(self.workspace),
            fire=self.fire,
            send=self.sent.append,
            clock=self.clock,
            estop_path=str(tmp_path / "ESTOP"),
            tick=1000.0,
            poll=1000.0,
        )
        self.proactive = ProactiveManager(
            automations=self.automations,
            workspace=str(self.workspace),
            db_path=self.db,
            fire=self.fire,
            busy=lambda _key: self.busy,
            deliver=self.delivered.append,
            clock=self.clock,
            tick=1000.0,
            journal_writer=journal,
        )
        self.automations.proactive = self.proactive

    def fire(self, session_key: str, prompt: str, meta: dict) -> str:
        self.fired.append((session_key, prompt, meta))
        return f"run-{len(self.fired)}"

    def enable(self, **extra) -> dict:
        changes = {
            "heartbeat_enabled": True,
            "heartbeat_every_minutes": 30,
            "timezone": "Europe/Berlin",
            "quiet_start": "22:00",
            "quiet_end": "07:00",
            **extra,
        }
        out = self.proactive.update_settings(CHAT, changes)
        assert out["ok"], out
        return out

    def row(self, kind: str = KIND_HEARTBEAT) -> dict:
        rows = [r for r in self.automations.store.list(CHAT) if r["kind"] == kind]
        return rows[-1]

    def advance(self, minutes: float) -> None:
        self.clock.now += minutes * 60

    def summary(self, run_id: str, answer: str, topic: str | None = None) -> dict:
        out = {"run_id": run_id, "session_key": CHAT, "origin": "automation", "final_answer": answer}
        if topic is not None:
            out["automation_result"] = {"changed": True, "summary": topic}
        return out


# -- settings and rows ------------------------------------------------------------------------


def test_enabling_makes_an_on_change_heartbeat_row_and_disabling_cancels_it(tmp_path):
    rig = _Rig(tmp_path, _at(10))
    out = rig.enable()
    row = rig.row()
    assert row["state"] == "active" and row["notify"] == "on_change" and row["spec"] == {"every": 1800}
    assert row["next_fire_at"] == _at(10, 30)
    assert out["heartbeat_state"] == "active" and out["in_quiet_hours"] is False
    assert any(p.get("event") == "created" and p.get("kind") == KIND_HEARTBEAT for p in rig.sent)
    rig.proactive.update_settings(CHAT, {"heartbeat_every_minutes": 60})
    assert rig.row()["spec"] == {"every": 3600}
    rig.proactive.update_settings(CHAT, {"heartbeat_enabled": False})
    assert rig.row()["state"] == "done"
    assert rig.proactive.describe(CHAT)["heartbeat_state"] == "off"


def test_quiet_hours_are_shared_by_every_chat_of_the_user(tmp_path):
    rig = _Rig(tmp_path, _at(10))
    rig.enable()
    other = rig.proactive.settings_for("local:b2")
    assert other.quiet_start == "22:00" and other.heartbeat_enabled is False


def test_bad_settings_change_nothing(tmp_path):
    rig = _Rig(tmp_path, _at(10))
    out = rig.proactive.update_settings(CHAT, {"heartbeat_every_minutes": 2})
    assert out["ok"] is False
    assert not [r for r in rig.automations.store.list(CHAT)]


def test_a_paused_row_is_resumed_when_the_user_switches_it_on_again(tmp_path):
    rig = _Rig(tmp_path, _at(10))
    rig.enable()
    rig.automations.control(None, rig.row()["id"], "pause")
    rig.proactive.update_settings(CHAT, {"heartbeat_enabled": True})
    assert rig.row()["state"] == "active"


# -- heartbeat and pre-check --------------------------------------------------------------------


def test_first_beat_runs_then_an_unchanged_beat_costs_nothing(tmp_path):
    rig = _Rig(tmp_path, _at(10))
    rig.enable()
    assert rig.proactive.run_once() == 0  # not due yet
    rig.advance(30)
    assert rig.proactive.run_once() == 1
    session, prompt, meta = rig.fired[0]
    assert session == CHAT and meta["automation_id"] == rig.row()["id"]
    assert prompt.startswith(f"[automation {rig.row()['id']} fired: Heartbeat]")
    assert "Check these points" in prompt  # the default checklist
    rig.advance(30)
    assert rig.proactive.run_once() == 0 and rig.proactive.skipped == 1
    row = rig.row()
    assert row["suppressed_count"] == 1 and row["next_fire_at"] == rig.clock.now + 1800


def test_an_edited_checklist_wakes_the_model_with_the_change(tmp_path):
    rig = _Rig(tmp_path, _at(10))
    rig.enable()
    rig.advance(30)
    rig.proactive.run_once()
    rig.proactive.write_checklist(CHAT, "- check my mail every hour")
    rig.advance(30)
    assert rig.proactive.run_once() == 1
    prompt = rig.fired[-1][1]
    assert "- check my mail every hour" in prompt and "the checklist was edited" in prompt


def test_a_watcher_hit_and_a_todo_change_are_signals(tmp_path):
    rig = _Rig(tmp_path, _at(10))
    rig.enable()
    watch = rig.automations.store.create(
        session_key=CHAT, kind="watch_url", name="price", spec={"url": "https://x.test", "every": 3600},
        prompt="p", next_fire_at=None,
    )
    rig.advance(30)
    rig.proactive.run_once()
    rig.automations.store.record_fire(watch["id"], fired_at=rig.clock.now, next_fire_at=None)
    store = StateStore(rig.db)
    store.save_feature(CHAT, "todo", {"todos": [{"content": "pay rent", "status": "pending"}]})
    store.close()
    rig.advance(30)
    assert rig.proactive.run_once() == 1
    prompt = rig.fired[-1][1]
    assert "automation 'price' has a new result" in prompt and "the todo list changed" in prompt


def test_extra_signal_providers_are_read(tmp_path):
    rig = _Rig(tmp_path, _at(10))
    mail = {"count": "0"}
    rig.proactive._providers.append(lambda _key: {"agent mail": mail["count"]})
    rig.enable()
    rig.advance(30)
    rig.proactive.run_once()
    mail["count"] = "1"
    rig.advance(30)
    assert rig.proactive.run_once() == 1 and "agent mail changed" in rig.fired[-1][1]


def test_a_full_check_runs_after_some_hours_without_a_change(tmp_path):
    rig = _Rig(tmp_path, _at(10))
    rig.enable(full_check_hours=1)
    rig.advance(30)
    rig.proactive.run_once()
    rig.advance(30)
    assert rig.proactive.run_once() == 0
    rig.advance(30)
    assert rig.proactive.run_once() == 1


def test_no_beat_while_the_chat_is_busy(tmp_path):
    rig = _Rig(tmp_path, _at(10))
    rig.enable()
    rig.busy = True
    rig.advance(30)
    assert rig.proactive.run_once() == 0 and not rig.fired
    rig.busy = False
    rig.advance(5)
    assert rig.proactive.run_once() == 1  # the missed beat runs once, not twice
    assert rig.proactive.run_once() == 0


def test_no_beat_in_the_quiet_hours(tmp_path):
    rig = _Rig(tmp_path, _at(21, 50))
    rig.enable()
    rig.advance(30)  # 22:20
    assert rig.proactive.run_once() == 0 and not rig.fired
    assert rig.row()["next_fire_at"] == _at(7, day=25)


def test_a_paused_heartbeat_does_not_beat(tmp_path):
    rig = _Rig(tmp_path, _at(10))
    rig.enable()
    rig.automations.control(None, rig.row()["id"], "pause")
    rig.advance(60)
    assert rig.proactive.run_once() == 0


def test_estop_stops_the_heartbeat(tmp_path):
    rig = _Rig(tmp_path, _at(10))
    rig.enable()
    (tmp_path / "ESTOP").write_text("")
    rig.advance(60)
    assert rig.proactive.run_once() == 0


# -- the push gate ----------------------------------------------------------------------------------


def _fired_heartbeat(rig: _Rig) -> str:
    rig.advance(30)
    rig.proactive.write_checklist(CHAT, f"- x {rig.clock.now}")  # force a change
    assert rig.proactive.run_once() == 1
    return f"run-{len(rig.fired)}"


def test_a_silent_heartbeat_is_not_announced(tmp_path):
    rig = _Rig(tmp_path, _at(10))
    rig.enable()
    run_id = _fired_heartbeat(rig)
    assert rig.proactive.filter_run(rig.summary(run_id, "HEARTBEAT_OK")) is True


def test_a_real_nudge_goes_out_once_per_cooldown(tmp_path):
    rig = _Rig(tmp_path, _at(10))
    rig.enable(cooldown_hours=12)
    first = _fired_heartbeat(rig)
    assert rig.proactive.filter_run(rig.summary(first, "The ACME invoice is due today.", "invoice ACME due")) is False
    second = _fired_heartbeat(rig)
    assert rig.proactive.filter_run(rig.summary(second, "Reminder: ACME invoice.", "Invoice ACME due")) is True
    third = _fired_heartbeat(rig)
    assert rig.proactive.filter_run(rig.summary(third, "Your flight moved.", "flight moved")) is False


def test_the_daily_cap(tmp_path):
    rig = _Rig(tmp_path, _at(10))
    rig.enable(max_per_day=1, cooldown_hours=0)
    assert rig.proactive.filter_run(rig.summary(_fired_heartbeat(rig), "a", "topic a")) is False
    assert rig.proactive.filter_run(rig.summary(_fired_heartbeat(rig), "b", "topic b")) is True


def test_other_runs_pass_the_gate_outside_quiet_hours(tmp_path):
    rig = _Rig(tmp_path, _at(10))
    rig.enable()
    assert rig.proactive.filter_run(rig.summary("run-x", "2 new mails")) is False
    assert rig.proactive.filter_run({"run_id": "r", "origin": "app", "final_answer": "HEARTBEAT_OK"}) is False


def test_quiet_hours_queue_the_push_until_morning(tmp_path):
    rig = _Rig(tmp_path, _at(23))
    rig.enable()
    for n in range(5):
        assert rig.proactive.filter_run(rig.summary(f"run-m{n}", f"mail {n}")) is True
    assert len(rig.proactive.queue) == 5
    rig.clock.now = _at(6, 59, day=25)
    rig.proactive.run_once()
    assert rig.delivered == []
    rig.clock.now = _at(7, 1, day=25)
    rig.proactive.run_once()
    # Only the newest three go out; the runs stay in the chat.
    assert [d["run_id"] for d in rig.delivered] == ["run-m2", "run-m3", "run-m4"]
    assert rig.delivered[0]["final_answer"] == "mail 2" and rig.proactive.queue == []


def test_the_queue_survives_a_restart(tmp_path):
    rig = _Rig(tmp_path, _at(23))
    rig.enable()
    rig.proactive.filter_run(rig.summary("run-q", "late news"))
    again = ProactiveManager(
        automations=rig.automations,
        workspace=str(rig.workspace),
        db_path=rig.db,
        fire=rig.fire,
        clock=rig.clock,
    )
    assert [q["run_id"] for q in again.queue] == ["run-q"]


# -- morning brief ------------------------------------------------------------------------------------


def test_the_morning_brief_fires_at_its_time_with_yesterdays_journal(tmp_path):
    written: list[tuple[date, str]] = []

    def journal(day: date, tz_name: str):
        written.append((day, tz_name))
        path = tmp_path / "ws" / "journal" / f"{day.isoformat()}.md"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("# day")
        return path

    rig = _Rig(tmp_path, _at(6), journal=journal)
    rig.proactive.update_settings(
        CHAT, {"brief_enabled": True, "brief_time": "07:30", "brief_location": "Kiel", "timezone": "Europe/Berlin"}
    )
    row = rig.row(KIND_MORNING_BRIEF)
    assert row["next_fire_at"] == _at(7, 30) and row["notify"] == "on_change"
    rig.clock.now = _at(7, 31)
    assert rig.proactive.run_once() == 1
    prompt = rig.fired[-1][1]
    assert "Weather for Kiel" in prompt and "journal/2026-11-23.md" in prompt
    assert written == [(date(2026, 11, 23), "Europe/Berlin")]
    assert rig.row(KIND_MORNING_BRIEF)["next_fire_at"] == _at(7, 30, day=25)


def test_a_brief_missed_by_hours_waits_for_the_next_day(tmp_path):
    rig = _Rig(tmp_path, _at(6))
    rig.proactive.update_settings(CHAT, {"brief_enabled": True, "brief_time": "07:30", "timezone": "Europe/Berlin"})
    rig.clock.now = _at(12)
    assert rig.proactive.run_once() == 0
    assert rig.row(KIND_MORNING_BRIEF)["next_fire_at"] == _at(7, 30, day=25)


# -- the tools through the automation backend -----------------------------------------------------------


def test_the_tools_reach_the_manager_through_session_automations(tmp_path):
    rig = _Rig(tmp_path, _at(10))
    registry = ToolRegistry()
    register_proactive_tools(registry, rig.automations.bound(CHAT))
    out = registry.dispatch(
        "proactive_settings",
        {"heartbeat_enabled": True, "heartbeat_every_minutes": 60, "quiet_start": "22:00", "quiet_end": "07:00"},
    )
    assert out["ok"] and out["heartbeat_state"] == "active"
    registry.dispatch("heartbeat_checklist", {"action": "append", "text": "check my mail"})
    assert "- check my mail" in rig.proactive.read_checklist(CHAT)
    assert (rig.workspace / "memory" / "heartbeat" / "local_a1.md").exists()


def test_an_automation_run_gets_no_proactive_tools_without_chaining(tmp_path):
    rig = _Rig(tmp_path, _at(10))
    backend = rig.automations.bound(CHAT).with_origin("automation")
    assert backend.proactive() is None
    assert rig.automations.bound(CHAT).proactive() is not None


# -- the host's run end ------------------------------------------------------------------------------


class _Notifier:
    def __init__(self) -> None:
        self.summaries: list[dict] = []

    def notify_run_finished(self, summary: dict) -> bool:
        self.summaries.append(summary)
        return True


def test_the_host_holds_a_push_in_quiet_hours_and_sends_it_in_the_morning(tmp_path):
    from chuk_agents_host.host import LocalHost

    host = LocalHost(
        port=0,
        workspace_dir=str(tmp_path / "host"),
        agent_name="t",
        channel_id="testchannel00",
        digits="428913",
        model_factory_override=lambda: None,
    )
    try:
        rig = _Rig(tmp_path, _at(23))
        rig.proactive._deliver = host._deliver_queued_push
        rig.enable()
        notifier = _Notifier()
        host._notifier = notifier  # type: ignore[assignment]
        host._controller_attached = lambda: False  # type: ignore[method-assign]
        host._proactive = rig.proactive  # type: ignore[attr-defined]
        base = {"session_key": CHAT, "origin": "automation", "automation_id": "a1"}
        host._on_run_finished({**base, "run_id": "r1", "final_answer": "2 new mails"})
        host._on_run_finished({**base, "run_id": "r2", "origin": "app", "final_answer": "hi"})
        # r1 (unattended) waits; r2 is the user's own message: it is told now.
        assert [s["run_id"] for s in notifier.summaries] == ["r2"]
        rig.clock.now = _at(7, 5, day=25)
        rig.proactive.run_once()
        assert [s["run_id"] for s in notifier.summaries] == ["r2", "r1"]
    finally:
        host._roster.close()
        host._coworker_names.close()
