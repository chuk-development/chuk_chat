"""Background review of a finished task (Hermes H1 + H2).

After a task ends, an optional pass on a cheap model reads a digest of the
transcript and asks one question: is there a memory fact or a skill worth
keeping? Its answer is a small JSON object. Nothing it says is ever applied
directly:

- a **skill** (a new one, or a new version of a skill the task loaded) goes
  through the existing ``propose_skill`` card path
  (:mod:`chuk_agents_runtime.skill_proposals`): scrubbed, validated, stored,
  shown to the user, written only on the user's accept;
- **memory** candidates are returned in the report and nothing else. There is
  no approval path for memory writes yet, so the caller decides (today: they
  are logged as counts and dropped).

Read-before-write for a skill update: the review re-reads the CURRENT
``SKILL.md`` of every skill the task loaded and gives that text to the model.
An update is only accepted for one of those skills, and it is pinned to the
hash of the text the model saw, so the accept refuses it when the file
changed in between (status ``stale``).

The prompt carries Hermes' "do not capture" rules: no environment failures,
no "tool X is broken" claims, no transient errors, no one-off narratives, no
dead ends written up as best practice, and only facts grounded in a user
message or a tool result.

The model is anything with ``complete(messages) -> response`` where
``response.text`` is the answer (the runtime's ``ModelClient``), or a plain
callable ``messages -> str``.
"""

from __future__ import annotations

import json
import re
from collections.abc import Callable, Iterable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .skill_proposals import (
    KIND_PATCH,
    MAX_PROPOSALS_PER_RUN,
    PROPOSE_SKILL_TOOL,
    SkillProposalSink,
    existing_skill_names,
    normalize_draft,
    prepare_patch,
    read_skill_text,
    scrub_draft,
    validate_draft,
)
from .skills import text_sha256

#: The digest the review model reads. The tail of the task is what matters
#: (the corrections and the result); a long task is cut from the front.
MAX_DIGEST_CHARS = 24_000
MAX_TOOL_RESULT_CHARS = 300
MAX_MEMORY_ITEMS = 5
MAX_MEMORY_CHARS = 400
#: Tasks shorter than this (model rounds) are not worth a review.
MIN_ITERATIONS = 3

_SKILL_MARK = re.compile(r"^## ACTIVE SKILL: ([a-z0-9][a-z0-9._-]{0,63})", re.M)

DO_NOT_CAPTURE = (
    "Do NOT capture (these turn into rules that hurt later, when the "
    "environment changes):\n"
    "- Environment-dependent failures: missing binaries, fresh-install "
    "errors, 'command not found', unconfigured credentials, uninstalled "
    "packages. The user can fix these; they are not lasting rules.\n"
    "- Negative claims about tools or features ('the browser does not work', "
    "'tool X is broken'). They harden into refusals long after the problem "
    "is fixed.\n"
    "- Transient errors that resolved during the task. If a retry worked, the "
    "lesson is the retry pattern, not the failure.\n"
    "- One-off task narratives. 'Summarize today's news' is not a class of "
    "work that needs a skill.\n"
    "- Unresolved failures: if the task ended WITHOUT a working method, do "
    "not write the attempts up as a procedure.\n"
    "If a tool failed because of setup, capture the FIX (the install command, "
    "the config step), never 'this does not work'.\n"
)

GROUNDING = (
    "Save only facts GROUNDED in this conversation: a user message or a tool "
    "result you can point to. Never infer the user's traits, skill level, "
    "role, mood or preferences from topic, tone or tools used. Never turn a "
    "one-off request into a standing preference unless the user marked it "
    "general ('always', 'from now on', 'remember'). If unsure, leave it out.\n"
)

REVIEW_PROMPT = (
    "You review a finished task of an AI agent. Decide if there is ONE "
    "reusable skill to save or fix, and if there are memory facts worth "
    "keeping. Most tasks need nothing; 'nothing' is a good answer.\n\n"
    "A skill is the procedure for a CLASS of task, done the way this user "
    "wants: the steps in order, the commands or tool calls that worked, the "
    "checks that prove the result, and the pitfalls (a rule plus one clause "
    "of why). No ids, dates, paths or names of this one case; use "
    "placeholders like <URL>. No secrets, no personal data.\n\n"
    "Prefer, in this order: (1) update a skill the task loaded, when it was "
    "wrong, missing a step or the user corrected the approach; (2) a new "
    "class-level skill when nothing covers the work. Name a new skill at the "
    "class level (lower-case words joined by hyphens), never after this one "
    "case. An update must start from the CURRENT text shown below and give "
    "the full new body.\n\n"
    + DO_NOT_CAPTURE
    + "\n"
    + GROUNDING
    + "\nAnswer with ONE JSON object and nothing else:\n"
    '{"memory": ["<fact>", ...], "skill": null | {"action": "create" | '
    '"update", "name": "...", "description": "<at most 300 characters>", '
    '"body": "<markdown>"}}\n'
)


@dataclass
class ReviewReport:
    """What one review did. ``proposal`` is the sink's reply, if any."""

    ran: bool = False
    skipped: str | None = None
    memory_candidates: list[str] = field(default_factory=list)
    proposal: dict | None = None
    errors: list[str] = field(default_factory=list)

    def as_dict(self) -> dict:
        return {
            "ran": self.ran,
            "skipped": self.skipped,
            "memory_candidates": list(self.memory_candidates),
            "proposal": self.proposal,
            "errors": list(self.errors),
        }


# -- the digest ----------------------------------------------------------------


def _text_of(content: Any) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):  # multimodal parts
        return " ".join(
            str(part.get("text", "")) for part in content if isinstance(part, dict)
        )
    return ""


def last_task(rows: Iterable[dict]) -> list[dict]:
    """The rows of the newest task: from the last ``user`` row (by stored
    role) to the end. ``rows`` are ``{"role_tag", "content"}`` dicts."""
    items = list(rows)
    start = 0
    for index in range(len(items) - 1, -1, -1):
        if items[index].get("role_tag") == "user":
            start = index
            break
    return items[start:]


def loaded_skills(rows: Iterable[dict]) -> list[str]:
    """Skills whose body entered the conversation in these rows."""
    names: list[str] = []
    for row in rows:
        if row.get("role_tag") != "skill":
            continue
        match = _SKILL_MARK.search(_text_of((row.get("content") or {}).get("content")))
        if match and match.group(1) not in names:
            names.append(match.group(1))
    return names


def proposed_in(rows: Iterable[dict]) -> bool:
    """Did the task already call ``propose_skill`` itself?"""
    for row in rows:
        message = row.get("content") or {}
        for call in message.get("tool_calls") or []:
            function = call.get("function") if isinstance(call, dict) else None
            if isinstance(function, dict) and function.get("name") == PROPOSE_SKILL_TOOL:
                return True
    return False


def transcript_digest(rows: Iterable[dict], *, limit: int = MAX_DIGEST_CHARS) -> str:
    """User and assistant text, tool calls by name, tool results cut short.
    System, clock, recall and skill rows are left out (the skills are shown
    separately, as they are on disk now)."""
    lines: list[str] = []
    for row in rows:
        tag = row.get("role_tag")
        message = row.get("content") or {}
        role = message.get("role")
        if tag in ("system", "clock", "skill", "skill_catalog", "event") or role == "system":
            continue
        text = _text_of(message.get("content")).strip()
        if role == "user" and tag == "user":
            lines.append(f"USER: {text}")
        elif role == "assistant":
            if text:
                lines.append(f"ASSISTANT: {text}")
            for call in message.get("tool_calls") or []:
                function = call.get("function") if isinstance(call, dict) else None
                if isinstance(function, dict):
                    args = str(function.get("arguments") or "")[:200]
                    lines.append(f"TOOL CALL {function.get('name')}: {args}")
        elif role == "tool":
            cut = text[:MAX_TOOL_RESULT_CHARS]
            more = "…" if len(text) > MAX_TOOL_RESULT_CHARS else ""
            lines.append(f"TOOL RESULT: {cut}{more}")
    digest = "\n".join(lines)
    if len(digest) > limit:
        digest = "[earlier part of the task cut]\n" + digest[-limit:]
    return digest


def build_review_messages(
    digest: str, *, catalog: str = "", current_skills: dict[str, str] | None = None
) -> list[dict]:
    parts = [REVIEW_PROMPT]
    if catalog:
        parts.append("Skills that exist now (do not create a duplicate):\n" + catalog)
    for name, text in (current_skills or {}).items():
        parts.append(f"CURRENT text of the loaded skill `{name}` (read now from disk):\n{text}")
    return [
        {"role": "system", "content": "\n\n".join(parts)},
        {"role": "user", "content": "The finished task:\n\n" + digest},
    ]


# -- the answer ----------------------------------------------------------------


def parse_review(text: str) -> dict:
    """The JSON object in the model's answer; ``{}`` when there is none.
    A fenced block or prose around the object is tolerated."""
    if not isinstance(text, str):
        return {}
    start = text.find("{")
    end = text.rfind("}")
    if start < 0 or end <= start:
        return {}
    try:
        value = json.loads(text[start : end + 1])
    except ValueError:
        return {}
    return value if isinstance(value, dict) else {}


def _complete(model: Any, messages: list[dict]) -> str:
    complete = getattr(model, "complete", None)
    reply = complete(messages) if callable(complete) else model(messages)
    text = getattr(reply, "text", reply)
    return text if isinstance(text, str) else ""


# -- the review ----------------------------------------------------------------


def run_background_review(
    model: Any,
    rows: Iterable[dict],
    *,
    skills_root: str | Path | None,
    sink: SkillProposalSink | None,
    catalog: str = "",
    vault: Callable[[Any], Any] | None = None,
) -> ReviewReport:
    """Review the newest task in ``rows``; propose at most one skill.

    ``rows`` are the session's ``{"role_tag", "content"}`` rows. Never
    raises: a broken review costs the review, not the agent.
    """
    report = ReviewReport()
    task = last_task(rows)
    if not task:
        report.skipped = "no task"
        return report
    if proposed_in(task):
        report.skipped = "the task already proposed a skill"
        return report
    current: dict[str, str] = {}
    for name in loaded_skills(task):
        text = read_skill_text(skills_root, name)
        if text is not None:
            current[name] = text  # re-read now: the update starts from this
    messages = build_review_messages(
        transcript_digest(task), catalog=catalog, current_skills=current
    )
    try:
        answer = parse_review(_complete(model, messages))
    except Exception as exc:  # noqa: BLE001 — the review is optional
        report.errors.append(f"review model failed: {type(exc).__name__}")
        return report
    report.ran = True

    memory = answer.get("memory")
    if isinstance(memory, list):
        for item in memory[:MAX_MEMORY_ITEMS]:
            fact = item.get("fact") if isinstance(item, dict) else item
            if isinstance(fact, str) and fact.strip():
                report.memory_candidates.append(fact.strip()[:MAX_MEMORY_CHARS])

    skill = answer.get("skill")
    if not isinstance(skill, dict) or sink is None or skills_root is None:
        return report
    if MAX_PROPOSALS_PER_RUN < 1:
        return report
    action = str(skill.get("action") or "create").lower()
    name, description, body = skill.get("name"), skill.get("description"), skill.get("body")
    if action in ("update", "patch"):
        key = name.strip() if isinstance(name, str) else ""
        if key not in current:
            report.errors.append(
                f"update of {key!r} refused: only a skill the task loaded can be updated"
            )
            return report
        prepared = prepare_patch(
            skills_root, key, description, body, loaded_sha256=text_sha256(current[key])
        )
        if isinstance(prepared, str):
            report.errors.append(prepared)
            return report
        draft = prepared
    else:
        draft = normalize_draft(name, description, body)
    draft, _ = scrub_draft(draft, vault)
    errors = validate_draft(draft)
    if not errors and draft.kind != KIND_PATCH and draft.name in existing_skill_names(skills_root):
        errors.append(f"a skill named {draft.name!r} already exists")
    if errors:
        report.errors.extend(errors)
        return report
    try:
        reply = sink.submit(draft, skills_root=str(skills_root))
    except Exception as exc:  # noqa: BLE001
        report.errors.append(f"the proposal could not be stored: {type(exc).__name__}")
        return report
    report.proposal = {**reply, "name": draft.name, "kind": draft.kind}
    return report


__all__ = [
    "DO_NOT_CAPTURE",
    "GROUNDING",
    "MIN_ITERATIONS",
    "REVIEW_PROMPT",
    "ReviewReport",
    "build_review_messages",
    "last_task",
    "loaded_skills",
    "parse_review",
    "proposed_in",
    "run_background_review",
    "transcript_digest",
]
