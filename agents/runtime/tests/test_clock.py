"""The ``[clock]`` note (bead chuk_chat-gaep).

On Friday 2026-10-09 the agent said "tomorrow, Friday 9 October": the model
had no clock. Each task now gets one row with the local date, the weekday and
the next day, made when the task starts. These tests pin the text, the row
the loop appends, and that an old row leaves the history like an old recall.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta, timezone

from chuk_agents_runtime import MockModelClient, StateStore, build_runtime
from chuk_agents_runtime.clock import (
    CLOCK_PREFIX,
    clock_messages,
    clock_note,
    describe_day,
    describe_local_time,
)
from chuk_agents_runtime.context import CLOCK_MARK, IDLE_DROP_KEY, _stale_marks

BERLIN_SUMMER = timezone(timedelta(hours=2), "CEST")


def test_the_note_names_today_tomorrow_and_the_zone():
    friday = datetime(2026, 10, 9, 22, 29, tzinfo=BERLIN_SUMMER)
    note = clock_note(friday, zone="Europe/Berlin")
    assert note.startswith(CLOCK_PREFIX)
    assert "Friday, 2026-10-09, 22:29 local time" in note
    assert "Europe/Berlin" in note and "CEST" in note and "UTC+02:00" in note
    assert "Today is Friday, 2026-10-09." in note
    assert "Tomorrow is Saturday, 2026-10-10." in note
    assert "Yesterday was Thursday, 2026-10-08." in note


def test_the_note_crosses_a_month_and_a_year():
    note = clock_note(datetime(2026, 12, 31, 23, 50, tzinfo=UTC), zone="UTC")
    assert "Today is Thursday, 2026-12-31." in note
    assert "Tomorrow is Friday, 2027-01-01." in note
    assert "UTC+00:00" in note


def test_weekday_names_do_not_depend_on_the_locale():
    assert describe_day(datetime(2026, 10, 11)) == "Sunday, 2026-10-11"
    assert describe_day(datetime(2026, 10, 12)) == "Monday, 2026-10-12"


def test_a_timestamp_is_described_with_its_weekday():
    stamp = datetime(2026, 10, 10, 9, 0).astimezone().timestamp()
    text = describe_local_time(stamp)
    assert text.startswith("Saturday, 2026-10-10 09:00 (UTC")


def test_the_clock_row_is_a_user_turn_tagged_clock():
    [row] = clock_messages()
    assert row["role_tag"] == "clock" and row["role"] == "user"
    assert row["content"].startswith(CLOCK_PREFIX)
    assert CLOCK_MARK == CLOCK_PREFIX


def test_each_task_gets_a_fresh_clock_row_after_its_prompt(tmp_path):
    path = str(tmp_path / "state.db")
    model = MockModelClient(["first", "second"])
    loop = build_runtime(model, db_path=path, context_ladder=False, enable_memory=False)
    loop.run("s", "hello")
    loop.run("s", "what day is tomorrow?")

    store = StateStore(path)
    rows = store.get_conversation(store.route("s"))
    store.close()
    roles = [row.role for row in rows]
    assert roles.count("clock") == 2
    for index, row in enumerate(rows):
        if row.role == "clock":
            assert rows[index - 1].role == "user"  # right after the prompt
            assert row.content["role"] == "user"
            assert row.content["content"].startswith(CLOCK_PREFIX)
    # The model saw today's note in the request of the second task.
    sent = model.calls[-1]
    assert any(
        isinstance(m.get("content"), str) and m["content"].startswith(CLOCK_PREFIX) for m in sent
    )


def test_a_verbatim_prompt_run_gets_no_clock_row(tmp_path):
    path = str(tmp_path / "state.db")
    loop = build_runtime(
        MockModelClient(["ok"]),
        db_path=path,
        system_prompt="Be brief.",
        include_tool_docs=False,
        context_ladder=False,
        enable_memory=False,
    )
    loop.run("s", "hi")
    store = StateStore(path)
    roles = [row.role for row in store.get_conversation(store.route("s"))]
    store.close()
    assert "clock" not in roles


def test_an_old_clock_row_leaves_like_an_old_recall_row():
    messages = [
        {"role": "system", "content": "sys"},
        {"role": "user", "content": "first task"},
        {"role": "user", "content": f"{CLOCK_PREFIX} Now: Friday, 2026-10-09"},
        {"role": "assistant", "content": "done"},
        {"role": "user", "content": "second task"},
        {"role": "user", "content": f"{CLOCK_PREFIX} Now: Saturday, 2026-10-10"},
    ]
    # Before the idle cut: the old row stays byte for byte (prefix cache).
    kept, changed = _stale_marks(messages, 1, 4, recall_end=0)
    assert changed == 0 and kept is messages
    # After a long pause: the old row is dropped, the current one stays.
    marked, changed = _stale_marks(messages, 1, 4, recall_end=4)
    assert changed == 1
    assert marked[2].get(IDLE_DROP_KEY) is True
    assert IDLE_DROP_KEY not in marked[5]
