"""The ``[clock]`` note: the local date and time for each task.

The model has no clock. Without one it guesses the date from its training
data or from old rows in the history, and it gets the weekday wrong (bead
chuk_chat-gaep: on Friday 9 October it said "tomorrow, Friday 9 October").

So every task gets one short note, appended after the user's prompt: the
local date, the weekday, the time, the time zone, and the next day. It is
made when the task starts, never cached, so a session that started last week
still sees today.

The note is NOT in the system prompt. The system prompt is frozen per session
for the provider's prefix cache; a clock there would change the prefix on
every task. A row after the prompt keeps the cached prefix intact, like the
memory recall row.

The time is the local time of the host process. That is the clock the
schedules use too (``automations.next_fire`` reads local time), so "tomorrow
at 9" in the answer and the schedule agree.
"""

from __future__ import annotations

import os
from datetime import datetime, timedelta
from pathlib import Path

#: The head of a clock row. The context ladder keys on it
#: (:data:`chuk_agents_runtime.context.CLOCK_MARK`).
CLOCK_PREFIX = "[clock]"

#: English names, independent of the process locale.
WEEKDAYS = ("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday")


def local_zone_name() -> str | None:
    """The IANA name of the local time zone (``Europe/Berlin``), or ``None``.

    ``TZ`` first, then ``/etc/timezone``, then the target of the
    ``/etc/localtime`` link. Best effort: the note carries the UTC offset
    anyway, so a missing name costs only readability.
    """
    tz = (os.environ.get("TZ") or "").strip().lstrip(":")
    if tz and "/" in tz and not tz.startswith("/"):
        return tz
    try:
        name = Path("/etc/timezone").read_text(encoding="utf-8").strip()
        if name:
            return name
    except OSError:
        pass
    try:
        target = os.path.realpath("/etc/localtime")
    except OSError:
        return None
    marker = "zoneinfo/"
    if marker in target:
        return target.split(marker, 1)[1] or None
    return None


def _offset(moment: datetime) -> str:
    """``UTC+02:00`` for an aware datetime."""
    delta = moment.utcoffset() or timedelta(0)
    minutes = int(delta.total_seconds() // 60)
    sign = "+" if minutes >= 0 else "-"
    minutes = abs(minutes)
    return f"UTC{sign}{minutes // 60:02d}:{minutes % 60:02d}"


def describe_day(moment: datetime) -> str:
    """``Friday, 2026-10-09``."""
    return f"{WEEKDAYS[moment.weekday()]}, {moment.date().isoformat()}"


def describe_local_time(stamp: float) -> str:
    """Unix seconds -> ``Saturday, 2026-10-10 09:00 (UTC+02:00)``, local time.

    The automation tools add this next to a raw ``next_fire_at``: the model
    must not convert unix seconds to a weekday in its head."""
    moment = datetime.fromtimestamp(float(stamp)).astimezone()
    return f"{describe_day(moment)} {moment:%H:%M} ({_offset(moment)})"


def clock_note(now: datetime | None = None, *, zone: str | None = None) -> str:
    """The text of one clock row.

    ``now`` and ``zone`` are for tests; a naive ``now`` is read as local
    time, an aware one keeps its own zone.
    """
    if now is not None and now.tzinfo is not None:
        moment = now
    else:
        moment = (now or datetime.now()).astimezone()
    name = zone if zone is not None else local_zone_name()
    abbreviation = moment.tzname() or ""
    parts = [p for p in (name, abbreviation if abbreviation != name else "", _offset(moment)) if p]
    tomorrow = moment + timedelta(days=1)
    yesterday = moment - timedelta(days=1)
    return (
        f"{CLOCK_PREFIX} Now: {describe_day(moment)}, {moment:%H:%M} local time "
        f"({', '.join(parts)}). Today is {describe_day(moment)}. "
        f"Tomorrow is {describe_day(tomorrow)}. Yesterday was {describe_day(yesterday)}. "
        "Use this note for every date and weekday; it is the clock of the user's "
        "computer and of the schedules."
    )


def clock_messages() -> list[dict]:
    """The clock row as the loop appends it (``role_tag`` = the store role)."""
    return [{"role_tag": "clock", "role": "user", "content": clock_note()}]


__all__ = [
    "CLOCK_PREFIX",
    "WEEKDAYS",
    "clock_messages",
    "clock_note",
    "describe_day",
    "describe_local_time",
    "local_zone_name",
]
