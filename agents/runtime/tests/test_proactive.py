"""The proactive agent's pure part (CHAT-182, docs/agents/PROACTIVE.md):
settings, quiet hours, the nudge ledger, the prompts and the two tools."""

from __future__ import annotations

from datetime import datetime
from zoneinfo import ZoneInfo

import pytest

from chuk_agents_runtime.automations import RecordingBackend
from chuk_agents_runtime.proactive import (
    DEFAULT_CHECKLIST,
    MAX_CHECKLIST_CHARS,
    MemoryProactiveBackend,
    NudgeLedger,
    ProactiveSettings,
    ProactiveSettingsError,
    checklist_path,
    heartbeat_prompt,
    in_quiet_hours,
    is_silent_answer,
    local_day,
    morning_brief_prompt,
    next_brief_at,
    quiet_ends_at,
    read_checklist,
    register_proactive_tools,
    topic_hash,
    write_checklist,
)
from chuk_agents_runtime.registry import ToolRegistry

BERLIN = ZoneInfo("Europe/Berlin")


def _at(hour: int, minute: int = 0, day: int = 24, month: int = 11) -> float:
    return datetime(2026, month, day, hour, minute, tzinfo=BERLIN).timestamp()


def _quiet(**kw) -> ProactiveSettings:
    return ProactiveSettings().apply({"quiet_start": "22:00", "quiet_end": "07:00", "timezone": "Europe/Berlin", **kw})


# -- settings ----------------------------------------------------------------------------


def test_defaults_are_all_off():
    s = ProactiveSettings()
    assert not s.heartbeat_enabled and not s.brief_enabled and not s.has_quiet_hours
    assert s.heartbeat_every_minutes == 30 and s.max_per_day == 5


def test_apply_normalises_and_checks_values():
    s = ProactiveSettings().apply(
        {"heartbeat_enabled": "yes", "heartbeat_every_minutes": "60", "quiet_start": "22", "quiet_end": "7:00"}
    )
    assert s.heartbeat_enabled is True and s.heartbeat_every_minutes == 60
    assert (s.quiet_start, s.quiet_end) == ("22:00", "07:00")


@pytest.mark.parametrize(
    "changes",
    [
        {"heartbeat_every_minutes": 5},
        {"quiet_start": "25:00", "quiet_end": "07:00"},
        {"quiet_start": "22:00"},
        {"quiet_start": "07:00", "quiet_end": "07:00"},
        {"timezone": "Mars/Olympus"},
        {"max_per_day": -1},
        {"heartbeat_enabled": "maybe"},
        {"colour": "red"},
    ],
)
def test_bad_settings_are_refused(changes):
    with pytest.raises(ProactiveSettingsError):
        ProactiveSettings().apply(changes)


def test_clearing_one_end_clears_quiet_hours():
    s = _quiet().apply({"quiet_start": ""})
    assert not s.has_quiet_hours and s.quiet_end is None


def test_from_dict_skips_broken_values():
    s = ProactiveSettings.from_dict({"heartbeat_every_minutes": 1, "max_per_day": 3, "junk": 1})
    assert s.heartbeat_every_minutes == 30 and s.max_per_day == 3
    assert ProactiveSettings.from_dict(None) == ProactiveSettings()


# -- clock rules ----------------------------------------------------------------------------


def test_quiet_hours_cross_midnight_in_the_user_zone():
    s = _quiet()
    assert in_quiet_hours(_at(23, 30), s)
    assert in_quiet_hours(_at(3), s)
    assert not in_quiet_hours(_at(7), s)
    assert not in_quiet_hours(_at(12), s)
    assert in_quiet_hours(_at(22), s)


def test_quiet_hours_inside_one_day():
    s = ProactiveSettings().apply({"quiet_start": "12:00", "quiet_end": "14:00", "timezone": "Europe/Berlin"})
    assert in_quiet_hours(_at(13), s) and not in_quiet_hours(_at(14), s) and not in_quiet_hours(_at(11), s)


def test_quiet_hours_follow_the_time_zone():
    tokyo = ProactiveSettings().apply({"quiet_start": "22:00", "quiet_end": "07:00", "timezone": "Asia/Tokyo"})
    # 12:00 in Berlin (winter) is 20:00 in Tokyo: not quiet; 15:00 Berlin = 23:00 Tokyo: quiet.
    assert not in_quiet_hours(_at(12), tokyo)
    assert in_quiet_hours(_at(15), tokyo)


def test_quiet_end_is_the_next_morning():
    s = _quiet()
    assert quiet_ends_at(_at(12), s) is None
    assert quiet_ends_at(_at(23), s) == _at(7, day=25)
    assert quiet_ends_at(_at(3, day=25), s) == _at(7, day=25)


def test_next_brief_is_today_or_tomorrow():
    s = ProactiveSettings().apply({"brief_time": "07:30", "timezone": "Europe/Berlin"})
    assert next_brief_at(_at(6), s) == _at(7, 30)
    assert next_brief_at(_at(7, 30), s) == _at(7, 30, day=25)
    assert local_day(_at(23, 59), s) == "2026-11-24"


def test_no_quiet_hours_means_never_quiet():
    assert not in_quiet_hours(_at(3), ProactiveSettings())


# -- answers, topics, ledger ------------------------------------------------------------------


@pytest.mark.parametrize("text", ["HEARTBEAT_OK", " heartbeat_ok\n", "[SILENT]", "`NO_REPLY`", "", None])
def test_silent_answers(text):
    assert is_silent_answer(text)


@pytest.mark.parametrize("text", ["HEARTBEAT_OK but the invoice is due", "You have 2 new mails."])
def test_real_answers_are_not_silent(text):
    assert not is_silent_answer(text)


def test_topic_hash_ignores_case_and_spaces():
    assert topic_hash("Invoice  ACME due") == topic_hash("invoice acme due")
    assert topic_hash("invoice acme due") != topic_hash("invoice beta due")


def test_ledger_blocks_a_repeat_inside_the_cooldown():
    s = _quiet(cooldown_hours=12)
    ledger = NudgeLedger()
    assert ledger.check("invoice", _at(9), s) is None
    ledger.record("invoice", _at(9), s)
    assert ledger.check("Invoice", _at(15), s) == "repeat"
    assert ledger.check("other topic", _at(15), s) is None
    assert ledger.check("invoice", _at(22), s) is None  # 13 h later


def test_ledger_stops_at_the_daily_cap_in_the_user_day():
    s = _quiet(max_per_day=2, cooldown_hours=0)
    ledger = NudgeLedger()
    ledger.record("a", _at(9), s)
    ledger.record("b", _at(10), s)
    assert ledger.check("c", _at(11), s) == "daily_cap"
    assert ledger.check("c", _at(9, day=25), s) is None


def test_ledger_round_trips_and_prunes():
    s = _quiet()
    ledger = NudgeLedger()
    ledger.record("old", _at(9, day=1), s)
    ledger.record("new", _at(9), s)
    again = NudgeLedger.from_dict(ledger.to_dict())
    assert again.sent == ledger.sent
    assert topic_hash("old") not in again.sent  # pruned: older than one week
    assert NudgeLedger.from_dict("junk") == NudgeLedger()


# -- checklist and prompts -----------------------------------------------------------------------


def test_checklist_file_per_chat(tmp_path):
    path = checklist_path(tmp_path, "local:a1")
    assert path == tmp_path / "memory" / "heartbeat" / "local_a1.md"
    assert read_checklist(path) == DEFAULT_CHECKLIST
    write_checklist(path, "- mail\n" + "x" * (MAX_CHECKLIST_CHARS + 10))
    assert len(read_checklist(path)) == MAX_CHECKLIST_CHARS and read_checklist(path).startswith("- mail")


def test_heartbeat_prompt_carries_the_rules():
    text = heartbeat_prompt("hb1", "- check mail", ["the todo list changed"], last_summary="HEARTBEAT_OK")
    first = text.split("\n", 1)[0]
    assert first == "[automation hb1 fired: Heartbeat]"
    assert "- check mail" in text and "- the todo list changed" in text
    assert "Only speak if the user would want to know this now" in text
    assert "HEARTBEAT_OK" in text and "automation_result(changed=false" in text


def test_morning_brief_prompt_names_weather_only_with_a_location():
    s = ProactiveSettings()
    assert "Weather" not in morning_brief_prompt("mb", s)
    with_city = morning_brief_prompt("mb", s.apply({"brief_location": "Kiel"}), journal_file="journal/2026-11-23.md")
    assert "Weather for Kiel" in with_city and "journal/2026-11-23.md" in with_city
    assert with_city.startswith("[automation mb fired: Morning brief]")


# -- tools ------------------------------------------------------------------------------------------


def test_tools_register_with_a_backend_and_change_settings():
    registry = ToolRegistry()
    backend = MemoryProactiveBackend()
    register_proactive_tools(registry, backend)
    assert registry.has("proactive_settings") and registry.has("heartbeat_checklist")
    out = registry.dispatch(
        "proactive_settings",
        {"heartbeat_enabled": True, "heartbeat_every_minutes": 60, "quiet_start": "22:00", "quiet_end": "07:00"},
    )
    assert out["ok"] and out["heartbeat_every_minutes"] == 60 and out["quiet_end"] == "07:00"
    read = registry.dispatch("proactive_settings", {})
    assert read["ok"] and read["heartbeat_enabled"] is True
    bad = registry.dispatch("proactive_settings", {"heartbeat_every_minutes": 1})
    assert bad["ok"] is False


def test_checklist_tool_appends_and_writes():
    registry = ToolRegistry()
    backend = MemoryProactiveBackend(checklist="# list\n")
    register_proactive_tools(registry, backend)
    registry.dispatch("heartbeat_checklist", {"action": "append", "text": "check the mail every hour"})
    assert backend.checklist == "# list\n- check the mail every hour\n"
    assert registry.dispatch("heartbeat_checklist", {"action": "read"})["checklist"] == backend.checklist
    registry.dispatch("heartbeat_checklist", {"action": "write", "text": "- only this"})
    assert backend.checklist == "- only this"
    assert registry.dispatch("heartbeat_checklist", {"action": "append", "text": " "})["ok"] is False
    assert registry.dispatch("heartbeat_checklist", {"action": "drop"})["ok"] is False


def test_tools_come_through_the_automation_backend():
    class _WithProactive(RecordingBackend):
        def proactive(self):
            return MemoryProactiveBackend()

    registry = ToolRegistry()
    register_proactive_tools(registry, _WithProactive())
    assert registry.has("proactive_settings")


def test_no_backend_no_tools():
    registry = ToolRegistry()
    register_proactive_tools(registry, None)
    register_proactive_tools(registry, RecordingBackend())  # no proactive part

    class _Refused(RecordingBackend):
        def proactive(self):
            return None

    register_proactive_tools(registry, _Refused())
    assert not registry.has("proactive_settings")


def test_from_dict_reads_quiet_hours_as_one_pair():
    s = ProactiveSettings.from_dict({"quiet_start": "22:00", "quiet_end": "07:00", "timezone": "Europe/Berlin"})
    assert s.has_quiet_hours and s.timezone == "Europe/Berlin"
