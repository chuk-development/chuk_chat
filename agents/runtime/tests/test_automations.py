"""Automations, agent side: spec grammar, cron arithmetic, tool registration,
session scoping through the bound backend (docs/WIRE_CONTRACT.md, "Automations")."""

from __future__ import annotations

import json
import os
import time
from datetime import datetime, timedelta

import pytest

from chuk_agents_runtime import agents_hooks
from chuk_agents_runtime.automations import (
    AUTOMATION_TOOL_NAMES,
    MIN_INTERVAL_SECONDS,
    PAYLOAD_MARKER,
    AutomationSpecError,
    CronSpec,
    RecordingBackend,
    cap_payload,
    fired_prompt,
    next_fire,
    parse_schedule_spec,
    register_automation_tools,
    spec_label,
)
from chuk_agents_runtime.registry import ToolRegistry

# -- spec grammar --------------------------------------------------------------


@pytest.mark.parametrize(
    "text, expected",
    [
        ("every 5m", {"every": 300}),
        ("every: 300", {"every": 300}),
        ("EVERY 2h", {"every": 7200}),
        ("every 1d", {"every": 86400}),
        ("0 9 * * 1-5", {"cron": "0 9 * * 1-5"}),
        ("cron: */15 * * * *", {"cron": "*/15 * * * *"}),
        ("cron 0   9 * *   mon", {"cron": "0 9 * * mon"}),
    ],
)
def test_spec_strings_parse_to_their_json_form(text, expected):
    assert parse_schedule_spec(text) == expected


def test_at_spec_is_normalised_to_utc_iso():
    parsed = parse_schedule_spec("at 2030-01-02T03:04:05+00:00")
    assert parsed == {"at": "2030-01-02T03:04:05+00:00"}
    naive = parse_schedule_spec("at: 2030-06-01T12:00")
    # A naive time is local time; the stored form is UTC and round-trips.
    assert datetime.fromisoformat(naive["at"]).timestamp() == datetime(
        2030, 6, 1, 12, 0
    ).astimezone().timestamp()


def test_dict_specs_are_validated_and_normalised():
    assert parse_schedule_spec({"every": "10m"}) == {"every": 600}
    assert parse_schedule_spec({"cron": "0 0 1 1 *"}) == {"cron": "0 0 1 1 *"}
    with pytest.raises(AutomationSpecError):
        parse_schedule_spec({"weekly": True})


@pytest.mark.parametrize(
    "text",
    ["", "   ", "every 5x", "every 0", "0 9 * *", "61 * * * *", "* * 32 * *", "* * * 13 *", "at yesterday"],
)
def test_bad_specs_raise_with_a_readable_message(text):
    with pytest.raises(AutomationSpecError) as info:
        parse_schedule_spec(text)
    assert str(info.value)


def test_an_interval_under_the_floor_is_refused_and_points_at_watchers():
    with pytest.raises(AutomationSpecError) as info:
        parse_schedule_spec("every 5s")
    assert "start_watcher" in str(info.value)
    assert str(MIN_INTERVAL_SECONDS) in str(info.value)


def test_spec_label_is_short_and_human():
    assert spec_label({"every": 300}) == "every 5m"
    assert spec_label({"every": 7200}) == "every 2h"
    assert spec_label({"every": 90}) == "every 90s"
    assert spec_label({"cron": "0 9 * * *"}) == "cron 0 9 * * *"
    assert spec_label({"script_path": "watch.py"}) == "watch watch.py"


# -- cron ----------------------------------------------------------------------


def _local(y, mo, d, h, mi):
    return datetime(y, mo, d, h, mi).astimezone()


def test_cron_every_15_minutes_from_an_odd_minute():
    cron = CronSpec.parse("*/15 * * * *")
    got = cron.next_after(_local(2026, 9, 5, 10, 7))
    assert (got.hour, got.minute) == (10, 15)


def test_cron_weekday_mornings_skip_the_weekend():
    cron = CronSpec.parse("0 9 * * 1-5")
    # 2026-09-05 is a Saturday.
    got = cron.next_after(_local(2026, 9, 5, 10, 0))
    assert (got.month, got.day, got.hour, got.minute) == (9, 7, 9, 0)  # Monday


def test_cron_names_for_month_and_weekday_and_sunday_as_7():
    assert CronSpec.parse("0 0 * jan sun").weekdays == frozenset({0})
    assert CronSpec.parse("0 0 * * 7").weekdays == frozenset({0})
    assert CronSpec.parse("0 0 * jan *").months == frozenset({1})


def test_cron_day_of_month_or_weekday_when_both_restricted():
    # POSIX: "on the 1st OR on a Monday".
    cron = CronSpec.parse("0 0 1 * 1")
    # 2026-09-05 (Sat) -> next Monday 2026-09-07, before the 1st of October.
    got = cron.next_after(_local(2026, 9, 5, 1, 0))
    assert (got.month, got.day) == (9, 7)


def test_cron_that_never_matches_returns_none():
    assert CronSpec.parse("0 0 30 2 *").next_after(_local(2026, 1, 1, 0, 0)) is None


def test_cron_fields_out_of_range_are_rejected():
    for text in ("60 * * * *", "* 24 * * *", "* * 0 * *", "* * * 0 *", "* * * * 8", "*/0 * * * *"):
        with pytest.raises(AutomationSpecError):
            CronSpec.parse(text)


# -- next_fire -----------------------------------------------------------------


def test_next_fire_for_interval_is_after_plus_every():
    assert next_fire({"every": 300}, after=1000.0) == 1300.0


def test_next_fire_for_cron_is_the_next_local_minute_match():
    after = _local(2026, 9, 5, 10, 7).timestamp()
    got = next_fire({"cron": "*/15 * * * *"}, after=after)
    assert got == _local(2026, 9, 5, 10, 15).timestamp()


def test_next_fire_for_at_is_once_and_none_when_spent():
    when = (datetime.now().astimezone() + timedelta(hours=1)).isoformat()
    stamp = next_fire({"at": when}, after=time.time())
    assert stamp is not None and stamp > time.time()
    assert next_fire({"at": when}, after=stamp + 1) is None


# -- fired prompt + payload cap ------------------------------------------------


def test_fired_prompt_marks_the_payload_as_data():
    text = fired_prompt("ab12", "new video", "Summarize it.", {"url": "https://x"})
    lines = text.split("\n")
    assert lines[0] == "[automation ab12 fired: new video]"
    assert lines[1] == "Summarize it."
    assert lines[2] == PAYLOAD_MARKER
    assert json.loads(lines[3]) == {"url": "https://x"}


def test_fired_prompt_without_prompt_or_payload_is_one_line():
    assert fired_prompt("ab12", "nightly", None) == "[automation ab12 fired: nightly]"
    assert fired_prompt("ab12", "nightly", "  ") == "[automation ab12 fired: nightly]"


def test_payload_over_16_kb_is_cut_and_marked():
    big = {"text": "x" * 20_000}
    capped = cap_payload(big)
    assert capped["truncated"] is True
    assert len(json.dumps(capped).encode()) <= 16 * 1024
    assert cap_payload({"a": 1}) == {"a": 1}


# -- tools ---------------------------------------------------------------------


def test_no_backend_registers_no_tool():
    registry = ToolRegistry()
    register_automation_tools(registry, None)
    assert registry.names() == []


def test_all_six_tools_are_registered_and_declared_natively():
    registry = ToolRegistry()
    register_automation_tools(registry, RecordingBackend())
    assert set(registry.names()) == set(AUTOMATION_TOOL_NAMES)
    declared = {t["function"]["name"] for t in registry.openai_tools()}
    assert declared == set(AUTOMATION_TOOL_NAMES)
    for tool in registry.openai_tools():
        assert tool["function"]["description"]


def test_schedule_task_parses_the_spec_and_hands_the_backend_its_json_form():
    backend = RecordingBackend()
    registry = ToolRegistry()
    register_automation_tools(registry, backend)
    out = registry.dispatch(
        "schedule_task", {"spec": "every 5m", "prompt": "check the inbox", "name": "  inbox   check "}
    )
    assert out["ok"] is True and out["kind"] == "schedule"
    assert backend.calls == [("schedule", {"every": 300}, "check the inbox", "inbox check")]
    assert out["next_fire_at"] == 300.0


def test_schedule_task_reports_a_bad_spec_to_the_model_instead_of_raising():
    registry = ToolRegistry()
    register_automation_tools(registry, RecordingBackend())
    out = registry.dispatch("schedule_task", {"spec": "every 5s", "prompt": "x"})
    assert out["ok"] is False and "start_watcher" in out["error"]
    out = registry.dispatch("schedule_task", {"spec": "every 5m", "prompt": " "})
    assert out["ok"] is False


def test_start_watcher_refuses_paths_outside_the_workspace():
    backend = RecordingBackend()
    registry = ToolRegistry()
    register_automation_tools(registry, backend)
    for bad in ("/etc/passwd.py", "../x.py", "~/x.py", "watch.sh", ""):
        out = registry.dispatch("start_watcher", {"script_path": bad})
        assert out["ok"] is False, bad
    assert backend.calls == []
    out = registry.dispatch("start_watcher", {"script_path": "watch.py", "restart": "false"})
    assert out["ok"] is True and out["kind"] == "watcher"
    assert backend.calls == [("start_watcher", "watch.py", None, False)]


def test_control_tools_go_through_the_bound_backend_only():
    backend = RecordingBackend()
    registry = ToolRegistry()
    register_automation_tools(registry, backend)
    row = registry.dispatch("schedule_task", {"spec": "every 5m", "prompt": "x"})
    assert registry.dispatch("pause_automation", {"id": row["id"]})["state"] == "paused"
    assert registry.dispatch("resume_automation", {"id": row["id"]})["state"] == "active"
    assert registry.dispatch("cancel_automation", {"id": row["id"]})["state"] == "done"
    # Another session's id is simply "not found": the backend is bound to ONE
    # session, and there is no argument through which a tool could name another.
    assert registry.dispatch("cancel_automation", {"id": "someone-elses"}) == {
        "ok": False,
        "error": "not found",
    }
    assert registry.dispatch("cancel_automation", {"id": ""})["ok"] is False
    listed = registry.dispatch("list_automations", {})
    assert listed["ok"] is True and [r["id"] for r in listed["automations"]] == [row["id"]]


# -- agents_hooks (the module a watcher script imports) --------------------------


def test_trigger_outside_a_watcher_writes_nothing(tmp_path, monkeypatch, capsys):
    monkeypatch.delenv(agents_hooks.ENV_AUTOMATION_ID, raising=False)
    monkeypatch.setenv(agents_hooks.ENV_TRIGGERS_PATH, str(tmp_path / "t.jsonl"))
    assert agents_hooks.trigger("x") is False
    assert not (tmp_path / "t.jsonl").exists()
    assert "not running as a watcher" in capsys.readouterr().err


def test_trigger_appends_one_json_line_per_call(tmp_path, monkeypatch):
    path = tmp_path / "sub" / "triggers.jsonl"
    monkeypatch.setenv(agents_hooks.ENV_AUTOMATION_ID, "w1")
    monkeypatch.setenv(agents_hooks.ENV_TRIGGERS_PATH, str(path))
    assert agents_hooks.trigger("new video", payload={"url": "https://x", "n": 1})
    assert agents_hooks.trigger("again")
    lines = path.read_text().splitlines()
    assert len(lines) == 2
    first = json.loads(lines[0])
    assert first["automation_id"] == "w1"
    assert first["reason"] == "new video"
    assert first["payload"] == {"url": "https://x", "n": 1}
    assert isinstance(first["ts"], float)
    assert json.loads(lines[1])["payload"] is None


def test_trigger_caps_its_own_payload(tmp_path, monkeypatch):
    path = tmp_path / "triggers.jsonl"
    monkeypatch.setenv(agents_hooks.ENV_AUTOMATION_ID, "w1")
    monkeypatch.setenv(agents_hooks.ENV_TRIGGERS_PATH, str(path))
    assert agents_hooks.trigger("big", payload="y" * 40_000)
    record = json.loads(path.read_text())
    assert record["payload"]["truncated"] is True
    assert len(path.read_bytes()) < 17 * 1024


def test_hook_module_has_no_agent_imports():
    # It is copied into the sandbox alone; it must not import the package.
    source = open(agents_hooks.__file__, encoding="utf-8").read()
    assert "chuk_agents_runtime" not in source.replace("chuk_agents_runtime/agents_hooks", "")
    assert "from ." not in source
    assert os.path.basename(agents_hooks.__file__) == "agents_hooks.py"
