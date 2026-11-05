"""The Home dashboard store and tool (docs/DASHBOARD.md)."""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest

from chuk_agents_runtime.dashboard import (
    MAX_WIDGETS,
    WIDGET_TYPES,
    DashboardError,
    DashboardStore,
    handle_dashboard_frame,
    register_dashboard_tool,
    slugify,
)
from chuk_agents_runtime.registry import ToolRegistry

TZ = timezone(timedelta(hours=1))


class Clock:
    def __init__(self, now: datetime) -> None:
        self.now = now

    def __call__(self) -> datetime:
        return self.now


def _store(tmp_path, now=datetime(2026, 11, 2, 21, 40, tzinfo=TZ)):
    clock = Clock(now)
    return DashboardStore(str(tmp_path / "state.db"), clock=clock, tz=TZ), clock


VALID = {
    "tracker": {"type": "tracker", "title": "Push-ups", "unit": "reps", "goal": 100,
                "period": "day", "steps": [1, 10, 25], "icon": "dumbbell",
                "entries": [{"at": "2026-11-02T08:10:00+01:00", "value": 30}]},
    "metric": {"type": "metric", "title": "MRR", "value": 1234.5, "unit": "€",
               "delta": "+4 %", "tone": "good", "trend": [1, 2, 3], "caption": "Stripe"},
    "checklist": {"type": "checklist", "title": "Today",
                  "items": [{"id": "milk", "text": "Buy milk", "done": False}, {"text": "Call mom"}]},
    "note": {"type": "note", "title": "Idea", "text": "# Hello\n\nworld"},
    "chart": {"type": "chart", "title": "Votes",
              "spec": {"kind": "bar", "points": [{"label": "A", "value": 3}, {"label": "B", "value": 5}]}},
    "agenda": {"type": "agenda", "title": "Agenda", "date": "2026-11-02",
               "items": [{"time": "09:00", "title": "Standup", "place": "Zoom"},
                         {"time": "14:30", "title": "Dentist"}]},
    "prompts": {"type": "prompts", "title": "Ask", "items": [{"label": "News", "prompt": "What's new?"}]},
    "weather": {"type": "weather", "title": "Kiel", "place": "Kiel",
                "current": {"temp": 8.5, "condition": "Rain", "code": 61},
                "daily": [{"date": "2026-11-02", "code": 61, "max": 9, "min": 4}], "unit": "C"},
}


def test_every_type_in_the_catalogue_is_valid(tmp_path):
    store, _ = _store(tmp_path)
    assert set(VALID) == set(WIDGET_TYPES)
    for kind, widget in VALID.items():
        store.apply("add", {"widget": widget}, by="Chuk")
    doc = store.get()
    assert doc["version"] == len(VALID)
    assert [w["type"] for w in doc["widgets"]] == list(VALID)
    by_type = {w["type"]: w for w in doc["widgets"]}
    assert by_type["tracker"]["id"] == "push-ups"
    assert by_type["tracker"]["size"] == "half" and by_type["metric"]["size"] == "half"
    assert by_type["note"]["size"] == "full"
    assert by_type["note"]["by"] == "Chuk"
    assert by_type["note"]["updated_at"] == "2026-11-02T21:40:00+01:00"
    assert by_type["checklist"]["items"][1] == {"text": "Call mom", "done": False, "id": "call-mom"}


@pytest.mark.parametrize(("widget", "needle"), [
    ({"type": "gauge", "title": "x"}, "allowed types: tracker"),
    ({"type": "note", "title": ""}, "title"),
    ({"type": "note", "title": "x" * 61}, "60"),
    ({"type": "note", "title": "n", "html": "<b>"}, "unknown fields ['html']"),
    ({"type": "note", "title": "n", "size": "big"}, "half or full"),
    ({"type": "note", "title": "n", "text": "x" * 4001}, "4000"),
    ({"type": "tracker", "title": "t"}, "goal"),
    ({"type": "tracker", "title": "t", "goal": 0}, "> 0"),
    ({"type": "tracker", "title": "t", "goal": 5, "period": "month"}, "day or week"),
    ({"type": "tracker", "title": "t", "goal": 5, "steps": [1, 2, 3, 4]}, "1-3"),
    ({"type": "tracker", "title": "t", "goal": 5, "steps": [-1]}, "positive"),
    ({"type": "tracker", "title": "t", "goal": 5, "icon": "rocket"}, "dumbbell"),
    ({"type": "tracker", "title": "t", "goal": 5, "entries": [{"at": "yesterday", "value": 1}]}, "ISO"),
    ({"type": "metric", "title": "m"}, "value"),
    ({"type": "metric", "title": "m", "value": 1, "tone": "great"}, "good"),
    ({"type": "metric", "title": "m", "value": 1, "trend": list(range(61))}, "60"),
    ({"type": "checklist", "title": "c", "items": [{"text": "a"}] * 51}, "50"),
    ({"type": "checklist", "title": "c", "items": [{"text": "a" * 201}]}, "200"),
    ({"type": "checklist", "title": "c", "items": [{"id": "a", "text": "x"}, {"id": "a", "text": "y"}]}, "twice"),
    ({"type": "chart", "title": "c"}, "spec"),
    ({"type": "chart", "title": "c", "spec": {"kind": "pie", "points": [{"label": "a", "value": 1}]}}, "kind"),
    ({"type": "chart", "title": "c", "spec": {"kind": "line", "series": [
        {"points": [{"label": str(i), "value": i} for i in range(40)]}] * 2}}, "60 points"),
    ({"type": "agenda", "title": "a", "date": "2.11.2026"}, "YYYY-MM-DD"),
    ({"type": "agenda", "title": "a", "items": [{"time": "9am", "title": "x"}]}, "HH:MM"),
    ({"type": "agenda", "title": "a", "items": [{"time": "09:00", "title": "x"}] * 31}, "30"),
    ({"type": "prompts", "title": "p", "items": [{"label": "l", "prompt": "p"}] * 7}, "6"),
    ({"type": "prompts", "title": "p", "items": [{"label": "l" * 31, "prompt": "p"}]}, "30"),
    ({"type": "weather", "title": "w", "unit": "K"}, "C or F"),
    ({"type": "weather", "title": "w", "daily": [{"date": "2026-11-02"}] * 8}, "7"),
    ({"type": "weather", "title": "w", "current": {"temp": "warm"}}, "number"),
    ({"type": "note", "title": "n", "id": "Bad Id"}, "[a-z0-9_-]"),
])
def test_invalid_widgets_are_refused_with_a_reason(tmp_path, widget, needle):
    store, _ = _store(tmp_path)
    with pytest.raises(DashboardError) as info:
        store.apply("add", {"widget": widget}, by="Chuk")
    assert needle in str(info.value)
    assert store.get() == {"version": 0, "widgets": []}


def test_ids_are_slugs_and_unique_and_limits_hold(tmp_path):
    store, _ = _store(tmp_path)
    assert slugify("Wasser trinken!") == "wasser-trinken"
    assert slugify("💧") == "widget"
    store.apply("add", {"widget": {"type": "note", "title": "Note"}}, by="a")
    store.apply("add", {"widget": {"type": "note", "title": "Note"}}, by="a")
    assert [w["id"] for w in store.get()["widgets"]] == ["note", "note-2"]
    with pytest.raises(DashboardError, match="exists"):
        store.apply("add", {"widget": {"type": "note", "title": "x", "id": "note"}}, by="a")
    for n in range(MAX_WIDGETS - 2):
        store.apply("add", {"widget": {"type": "note", "title": f"n{n}"}}, by="a")
    with pytest.raises(DashboardError, match="at most 40"):
        store.apply("add", {"widget": {"type": "note", "title": "one more"}}, by="a")


def test_document_size_limit(tmp_path):
    store, _ = _store(tmp_path)
    with pytest.raises(DashboardError, match="128 KiB"):
        for n in range(40):
            store.apply("add", {"widget": {"type": "note", "title": f"n{n}", "text": "x" * 4000}}, by="a")
    assert store.get()["version"] == 31  # the 32nd note would cross 128 KiB


# --- tracker maths -----------------------------------------------------------


def _tracker(store, **fields):
    widget = {"type": "tracker", "title": "Push-ups", "unit": "reps", "goal": 100, **fields}
    store.apply("add", {"widget": widget}, by="a")
    return store.get()["widgets"][0]


def test_today_counts_only_the_local_day(tmp_path):
    store, _ = _store(tmp_path)
    w = _tracker(store, entries=[
        {"at": "2026-11-02T00:10:00+01:00", "value": 30},
        {"at": "2026-11-01T23:50:00+00:00", "value": 5},   # 00:50 local: today
        {"at": "2026-11-01T23:50:00+01:00", "value": 70},  # yesterday local
    ])
    assert store.tracker_summary(w)["today"] == 35


def test_negative_entry_corrects(tmp_path):
    store, _ = _store(tmp_path)
    _tracker(store)
    store.apply("log", {"id": "push-ups", "value": 50}, by="a")
    result = store.apply("log", {"id": "push-ups", "value": -10}, by="a")
    assert "today 40/100 reps" in result.message
    with pytest.raises(DashboardError, match="not 0"):
        store.apply("log", {"id": "push-ups", "value": 0}, by="a")


def test_streak_ends_yesterday_or_today_when_reached(tmp_path):
    store, clock = _store(tmp_path, now=datetime(2026, 11, 2, 23, 50, tzinfo=TZ))
    entries = [{"at": f"2026-10-{d:02d}T12:00:00+01:00", "value": 100} for d in (29, 30, 31)]
    entries.append({"at": "2026-11-01T12:00:00+01:00", "value": 100})
    entries.append({"at": "2026-10-27T12:00:00+01:00", "value": 100})  # gap on the 28th
    w = _tracker(store, entries=entries)
    assert store.tracker_summary(w)["streak"] == 4          # today not reached yet
    store.apply("log", {"id": "push-ups", "value": 100}, by="a")
    w = store.get()["widgets"][0]
    assert store.tracker_summary(w)["streak"] == 5          # today counts once reached
    clock.now = datetime(2026, 11, 3, 0, 10, tzinfo=TZ)     # across midnight
    s = store.tracker_summary(w)
    assert (s["today"], s["streak"]) == (0, 5)
    clock.now = datetime(2026, 11, 4, 0, 10, tzinfo=TZ)     # a day missed
    assert store.tracker_summary(w)["streak"] == 0


def test_week_period_is_the_iso_week_monday_first(tmp_path):
    # 2026-11-02 is a Monday.
    store, clock = _store(tmp_path, now=datetime(2026, 11, 8, 20, 0, tzinfo=TZ))
    w = _tracker(store, goal=300, period="week", entries=[
        {"at": "2026-11-01T23:00:00+01:00", "value": 300},  # Sunday: last week
        {"at": "2026-11-02T07:00:00+01:00", "value": 100},
        {"at": "2026-11-08T07:00:00+01:00", "value": 150},
        {"at": "2026-10-26T07:00:00+01:00", "value": 100},  # with Sunday: 400
        {"at": "2026-10-19T07:00:00+01:00", "value": 299},  # one short
    ])
    s = store.tracker_summary(w)
    assert (s["today"], s["streak"]) == (250, 1)
    assert store.summary_text(w) == "this week 250/300 reps, streak 1"


def test_log_at_and_entry_cap(tmp_path):
    store, _ = _store(tmp_path)
    entries = [{"at": (datetime(2026, 1, 1, tzinfo=TZ) + timedelta(minutes=i)).isoformat(), "value": 1}
               for i in range(2000)]
    _tracker(store, entries=entries)
    store.apply("log", {"id": "push-ups", "value": 7, "at": "2026-11-02T09:00:00+01:00"}, by="a")
    w = store.get()["widgets"][0]
    assert len(w["entries"]) == 2000
    assert w["entries"][-1] == {"at": "2026-11-02T09:00:00+01:00", "value": 7}
    assert w["entries"][0]["at"] == "2026-01-01T00:01:00+01:00"  # the oldest went


# --- actions -----------------------------------------------------------------


def test_update_move_remove_check(tmp_path):
    store, _ = _store(tmp_path)
    store.apply("add", {"widget": VALID["note"]}, by="a")
    store.apply("add", {"widget": VALID["checklist"]}, by="a")
    store.apply("update", {"id": "idea", "patch": {"text": "changed", "by": "x"}}, by="Chuk")
    assert store.get()["widgets"][0]["text"] == "changed"
    assert store.get()["widgets"][0]["by"] == "Chuk"
    with pytest.raises(DashboardError, match="type cannot change"):
        store.apply("update", {"id": "idea", "patch": {"type": "metric"}}, by="a")
    with pytest.raises(DashboardError, match="unknown fields"):
        store.apply("update", {"id": "idea", "patch": {"items": []}}, by="a")
    store.apply("move", {"id": "today", "index": 0}, by="a")
    assert [w["id"] for w in store.get()["widgets"]] == ["today", "idea"]
    result = store.apply("check", {"id": "today", "item": "milk", "done": True}, by="You")
    assert "1 of 2 open" in result.message
    with pytest.raises(DashboardError, match="items: milk, call-mom"):
        store.apply("check", {"id": "today", "item": "eggs", "done": True}, by="You")
    with pytest.raises(DashboardError, match="log works on a tracker"):
        store.apply("log", {"id": "today", "value": 1}, by="a")
    store.apply("remove", {"id": "idea"}, by="a")
    with pytest.raises(DashboardError, match="ids: today"):
        store.apply("remove", {"id": "idea"}, by="a")


def test_tool_actions_and_expected_version_conflict(tmp_path):
    store, _ = _store(tmp_path)
    registry = ToolRegistry()
    register_dashboard_tool(registry, store, by="Chuk")
    assert not registry.spec("dashboard").deferrable
    added = registry.dispatch("dashboard", {"action": "add", "widget": {
        "type": "tracker", "title": "Push-ups", "unit": "reps", "goal": 100, "icon": "dumbbell"}})
    assert "added tracker 'Push-ups' (id push-ups)" in added and "(version 1)" in added
    logged = registry.dispatch("dashboard", {"action": "log", "id": "push-ups", "value": 40,
                                             "expected_version": 1})
    assert logged == "logged 40 reps to Push-ups: today 40/100 reps, streak 0 (version 2)"
    stale = registry.dispatch("dashboard", {"action": "log", "id": "push-ups", "value": 10,
                                            "expected_version": 1})
    assert stale.startswith("refused") and "version 2" in stale and "get" in stale
    assert store.get()["version"] == 2
    bad = registry.dispatch("dashboard", {"action": "add", "widget": {"type": "html", "title": "x"}})
    assert "allowed types: tracker, metric" in bad
    view = registry.dispatch("dashboard", {"action": "get"})
    assert view["version"] == 2
    assert view["widgets"][0]["summary"] == "today 40/100 reps, streak 0"


def test_listener_hears_every_stored_change_only(tmp_path):
    store, _ = _store(tmp_path)
    heard = []
    store.add_listener(lambda doc: heard.append(doc["version"]))
    store.apply("add", {"widget": VALID["note"]}, by="a")
    with pytest.raises(DashboardError):
        store.apply("remove", {"id": "nope"}, by="a")
    store.apply("get", by="a")
    assert heard == [1]


def test_frames_dedup_op_id_and_refuse(tmp_path):
    store, _ = _store(tmp_path)
    store.apply("add", {"widget": {"type": "tracker", "title": "Water", "goal": 8}}, by="a")
    op = {"type": "dashboard_op", "op_id": "u-1", "action": "log", "id": "water", "value": 1}
    first = handle_dashboard_frame(store, op)
    again = handle_dashboard_frame(DashboardStore(store.path, tz=TZ), op)  # survives a restart
    assert first["type"] == again["type"] == "dashboard_state"
    assert first["op_id"] == again["op_id"] == "u-1"
    assert first["dashboard"]["version"] == again["dashboard"]["version"] == 2
    assert first["dashboard"]["widgets"][0]["by"] == "You"
    refused = handle_dashboard_frame(store, {"type": "dashboard_op", "op_id": "u-2",
                                             "action": "add", "widget": {}})
    assert refused == {"type": "dashboard_error", "op_id": "u-2",
                       "message": "action must be one of log, check, remove, move, update"}
    got = handle_dashboard_frame(store, {"type": "dashboard_get"})
    assert got == {"type": "dashboard_state", "dashboard": store.get()}


def test_only_the_last_200_op_ids_are_kept(tmp_path):
    store, _ = _store(tmp_path)
    store.apply("add", {"widget": {"type": "tracker", "title": "Water", "goal": 8}}, by="a")
    for n in range(201):
        store.apply("log", {"id": "water", "value": 1}, by="You", op_id=f"op-{n}")
    assert store.apply("log", {"id": "water", "value": 1}, by="You", op_id="op-200").duplicate
    assert not store.apply("log", {"id": "water", "value": 1}, by="You", op_id="op-0").duplicate
