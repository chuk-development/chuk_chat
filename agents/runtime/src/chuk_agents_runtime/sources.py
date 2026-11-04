"""Typed ``source`` of synthetic rows (DeepSeek harness idea 52).

Not every ``user`` row was typed by the user. A fired schedule, a finished
background job, a mail, a goal round, a loaded skill, the ``[clock]`` note and
a settled subagent all reach the model as a user-role message. The stored row
and the wire frame carry ``source`` so the app can draw a chip ("Schedule",
"Goal round") instead of a bubble the user never wrote
(docs/WIRE_CONTRACT.md, "Typed source on synthetic rows").

Backward compatible: a row without ``source`` is what it always was, a
message the user typed (``user`` row) or a runtime note (``context`` row).
"""

from __future__ import annotations

from typing import Any

SOURCE_GOAL = "goal"
SOURCE_SCHEDULE = "schedule"
SOURCE_JOB = "job"
SOURCE_SKILL = "skill"
SOURCE_MAIL = "mail"
SOURCE_TIME = "time"
SOURCE_SUBAGENT = "subagent"
SOURCE_REVIEW = "review"
SOURCE_PLAN = "plan"

SOURCES = frozenset(
    {
        SOURCE_GOAL,
        SOURCE_SCHEDULE,
        SOURCE_JOB,
        SOURCE_SKILL,
        SOURCE_MAIL,
        SOURCE_TIME,
        SOURCE_SUBAGENT,
        SOURCE_REVIEW,
        SOURCE_PLAN,
    }
)

#: The ``source`` a stored row gets from its role tag when the writer named
#: none. One place, so a provider that predates ``source`` is tagged too.
ROLE_TAG_SOURCES = {
    "clock": SOURCE_TIME,
    "skill": SOURCE_SKILL,
    "skill_catalog": SOURCE_SKILL,
    "subagent": SOURCE_SUBAGENT,
}

#: The ``source`` of the prompt row of a run, by the run's origin
#: (``chuk_agents_executor.executor._Run.origin``). ``app`` and the browser
#: panel are typed by the user: no source.
ORIGIN_SOURCES = {
    "automation": SOURCE_SCHEDULE,
    "job": SOURCE_JOB,
    "mail": SOURCE_MAIL,
    "mail_untrusted": SOURCE_MAIL,
    "goal": SOURCE_GOAL,
}

#: Context rows a replay carries as ``context`` events. ``time`` stays out:
#: one ``[clock]`` row per task is noise in a thread.
REPLAYED_CONTEXT_SOURCES = SOURCES - {SOURCE_TIME}


def valid_source(value: Any) -> str | None:
    """``value`` when it is a known source, else ``None``."""
    return value if isinstance(value, str) and value in SOURCES else None


def source_for_origin(origin: Any) -> str | None:
    return ORIGIN_SOURCES.get(origin) if isinstance(origin, str) else None


def tag_row(role_tag: str, content: dict) -> dict:
    """``content`` with ``source`` filled from ``role_tag`` when it has none.
    Rows the user or the model wrote (``user`` / ``assistant`` / ``tool`` /
    ``system``) are never tagged here."""
    if "source" in content:
        return content
    source = ROLE_TAG_SOURCES.get(role_tag)
    if source is None:
        return content
    return {**content, "source": source}
