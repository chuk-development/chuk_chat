"""Skill self-fix after a failure or a correction (CHAT-183, Hermes / Nod
idea 10, docs/agents/GOAL_JUDGE_RUN_MODES.md).

The background review (:mod:`.background_review`) runs after a task that
finished, and only when the operator turned it on. It does not look at the
two cases where a skill most often is wrong:

- a run that **used a skill and failed** (it hit the step, budget or token
  limit);
- the user **corrected** the agent in the next message after a run that used
  a skill ("no, ...", "that is wrong", "nicht so", ...).

For these two cases this module asks the cheap model one focused question:
what concrete change to the skill would have avoided the failure or the
correction? The answer goes through the same proposal flow as
``propose_skill``: pinned to the hash of the ``SKILL.md`` text read now
(:func:`~.skill_proposals.prepare_patch`), scrubbed, validated, stored as a
card, and written only when the user accepts it. A trigger costs one aux call;
no trigger costs nothing.

The correction check on the user's message is a cheap word filter. It only
decides whether to ask the model; the model decides if there is a fix, and
"no fix" is a good answer.
"""

from __future__ import annotations

import os
import re
from collections.abc import Callable, Iterable
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .background_review import (
    DO_NOT_CAPTURE,
    GROUNDING,
    ReviewReport,
    _complete,
    last_task,
    loaded_skills,
    parse_review,
    proposed_in,
    transcript_digest,
)
from .skill_proposals import (
    SkillProposalSink,
    prepare_patch,
    read_skill_text,
    scrub_draft,
    validate_draft,
)
from .skills import text_sha256

TRIGGER_FAILURE = "failure"
TRIGGER_CORRECTION = "correction"

#: Run ends that count as a failure of the work (not the user's stop).
FAILURE_REASONS = frozenset(
    {"max_iterations", "budget_exhausted", "token_budget_exhausted", "error"}
)

MAX_DIGEST_CHARS = 16_000
MAX_WHY_CHARS = 300

#: ``AGENTS_SKILL_SELFFIX=0`` turns it off (default on: it only runs after a
#: failure or a correction of a run that used a skill).
ENV_SELFFIX = "AGENTS_SKILL_SELFFIX"


def selffix_enabled(environ: Any = None) -> bool:
    env = os.environ if environ is None else environ
    raw = str(env.get(ENV_SELFFIX, "")).strip().lower()
    return raw not in ("0", "false", "no", "off")


# A short word filter on the USER's own message (never on model output). It
# only gates one optional aux call.
_CORRECTION = re.compile(
    r"^\s*(no|nope|wrong|stop|not like that|that'?s (not|wrong)|you (forgot|missed)|"
    r"nein|falsch|nicht so|stimmt nicht|das ist falsch|du hast .* vergessen)\b"
    r"|\b(that'?s wrong|is wrong|not what i (asked|wanted)|you should have|instead of|"
    r"don'?t do|do not do|next time|you forgot|you missed|that was wrong|"
    r"das war falsch|ist falsch|nicht was ich|stattdessen|beim nächsten mal|"
    r"du hättest|du sollst nicht|vergessen)\b",
    re.IGNORECASE,
)


def looks_like_correction(text: str) -> bool:
    return bool(isinstance(text, str) and _CORRECTION.search(text[:1_000]))


def _user_text(row: dict) -> str:
    content = (row.get("content") or {}).get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(str(p.get("text", "")) for p in content if isinstance(p, dict))
    return ""


@dataclass
class SelfFixTrigger:
    kind: str
    skills: list[str]
    rows: list[dict]


def find_trigger(rows: Iterable[dict], reason: str) -> SelfFixTrigger | None:
    """Whether the newest task calls for a skill fix, and on which rows.

    - failure: the newest task loaded a skill and ended in ``reason`` from
      :data:`FAILURE_REASONS`;
    - correction: the task before the newest one loaded a skill, and the
      newest task's prompt (typed by the user) reads like a correction.
    """
    items = list(rows)
    task = last_task(items)
    if not task:
        return None
    if reason in FAILURE_REASONS:
        skills = loaded_skills(task)
        if skills:
            return SelfFixTrigger(TRIGGER_FAILURE, skills, task)
        return None
    first = task[0]
    content = first.get("content") or {}
    if first.get("role_tag") != "user" or content.get("source"):
        return None  # a goal round, a schedule, a mail: nobody typed it
    if not looks_like_correction(_user_text(first)):
        return None
    before = items[: len(items) - len(task)]
    previous = last_task(before)
    skills = loaded_skills(previous)
    if not skills:
        return None
    return SelfFixTrigger(TRIGGER_CORRECTION, skills, previous + task)


SELFFIX_PROMPT = (
    "An AI agent used one or more skills (written procedures) in the task below, and "
    "{what}. Decide if ONE concrete change to ONE of these skills would have avoided it. "
    "A good change adds a missing step, fixes a wrong command or order, or adds a pitfall "
    "(a rule plus one clause of why). Keep the rest of the skill as it is.\n\n"
    "Answer 'no fix' (skill null) when the cause is not in the skill: a one-off wish of "
    "the user, a network or setup problem, a model mistake the skill already warns "
    "about.\n\n"
    + DO_NOT_CAPTURE
    + "\n"
    + GROUNDING
    + "\nAnswer with ONE JSON object and nothing else:\n"
    '{{"skill": null | {{"name": "<one of the skills below>", "why": "<one sentence: what '
    'went wrong and how the change prevents it>", "description": "<at most 300 '
    'characters>", "body": "<the FULL new markdown body, starting from the CURRENT '
    'text>"}}}}\n'
)

_WHAT = {
    TRIGGER_FAILURE: "the task FAILED (it ran out of steps or budget without a result)",
    TRIGGER_CORRECTION: "the user CORRECTED the agent in the next message",
}


def build_selffix_messages(trigger: SelfFixTrigger, current: dict[str, str]) -> list[dict]:
    parts = [SELFFIX_PROMPT.format(what=_WHAT[trigger.kind])]
    for name, text in current.items():
        parts.append(f"CURRENT text of the skill `{name}` (read now from disk):\n{text}")
    digest = transcript_digest(trigger.rows, limit=MAX_DIGEST_CHARS)
    return [
        {"role": "system", "content": "\n\n".join(parts)},
        {"role": "user", "content": "The task:\n\n" + digest},
    ]


def run_skill_selffix(
    model: Any,
    rows: Iterable[dict],
    reason: str,
    *,
    skills_root: str | Path | None,
    sink: SkillProposalSink | None,
    vault: Callable[[Any], Any] | None = None,
) -> ReviewReport:
    """Propose at most one patch to a skill the failed or corrected task
    used. Never raises; ``report.skipped`` says why nothing ran."""
    report = ReviewReport()
    if sink is None or skills_root is None:
        report.skipped = "no proposal sink"
        return report
    trigger = find_trigger(rows, reason)
    if trigger is None:
        report.skipped = "no failure or correction after a skill"
        return report
    if proposed_in(trigger.rows):
        report.skipped = "the task already proposed a skill"
        return report
    current: dict[str, str] = {}
    for name in trigger.skills:
        text = read_skill_text(skills_root, name)
        if text is not None:
            current[name] = text
    if not current:
        report.skipped = "the skills are gone"
        return report
    try:
        answer = parse_review(_complete(model, build_selffix_messages(trigger, current)))
    except Exception as exc:  # noqa: BLE001 — optional
        report.errors.append(f"self-fix model failed: {type(exc).__name__}")
        return report
    report.ran = True
    skill = answer.get("skill")
    if not isinstance(skill, dict):
        report.skipped = "no fix"
        return report
    name = skill.get("name")
    key = name.strip() if isinstance(name, str) else ""
    if key not in current:
        report.errors.append(f"fix of {key!r} refused: not a skill the task used")
        return report
    description = skill.get("description")
    prepared = prepare_patch(
        skills_root,
        key,
        description,
        skill.get("body"),
        # Pinned to the text read above: the accept refuses it when the file
        # changes in between (status ``stale``).
        loaded_sha256=text_sha256(current[key]),
    )
    if isinstance(prepared, str):
        report.errors.append(prepared)
        return report
    draft, _ = scrub_draft(prepared, vault)
    errors = validate_draft(draft)
    if errors:
        report.errors.extend(errors)
        return report
    try:
        reply = sink.submit(draft, skills_root=str(skills_root))
    except Exception as exc:  # noqa: BLE001
        report.errors.append(f"the proposal could not be stored: {type(exc).__name__}")
        return report
    why = skill.get("why")
    report.proposal = {
        **(reply if isinstance(reply, dict) else {}),
        "name": draft.name,
        "kind": draft.kind,
        "trigger": trigger.kind,
        "why": why.strip()[:MAX_WHY_CHARS] if isinstance(why, str) else "",
    }
    return report


__all__ = [
    "FAILURE_REASONS",
    "SelfFixTrigger",
    "TRIGGER_CORRECTION",
    "TRIGGER_FAILURE",
    "build_selffix_messages",
    "find_trigger",
    "looks_like_correction",
    "run_skill_selffix",
    "selffix_enabled",
]
