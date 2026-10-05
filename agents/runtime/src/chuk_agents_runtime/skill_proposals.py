"""Save a successful task as a skill, after the user approves (bead chuk_chat-al2u).

docs/WIRE_CONTRACT.md, "Skill proposals". After a long multi-step task that is
likely to come back, the agent may call ``propose_skill(name, description,
body)``. The tool drafts a SKILL.md (agentskills.io shape: ``name``,
``description`` of at most 300 characters, a body with the steps) from what the
run did. It **never installs it**:

1. The tool scrubs the draft (the user's secret values, credential-shaped
   strings, e-mail addresses and phone numbers) and validates it like
   ``tool/gen_skills.dart`` validates a shipped skill.
2. The executor stores the draft (:class:`SkillProposalStore`, one table in its
   state database) and streams a ``skill_proposal`` frame to the app.
3. The app answers ``skill_proposal_decision``. Only an accept writes
   ``<workspace>/skills/<name>/SKILL.md`` (:func:`decide_skill_proposal`); the
   user may edit the name, the description and the body first. A reject drops
   the draft.

The skill is then on disk like any other workspace skill, so the next task
loads it into the catalogue (``build_runtime`` reads the skills directory on
every task). A running task never sees it: the frozen prompt of that turn must
not change under the prefix cache.

This module knows nothing about frames. :class:`SkillProposalSink` is the seam:
the executor implements it with its store and its event stream; tests use
:class:`RecordingProposalSink`.
"""

from __future__ import annotations

import os
import re
import sqlite3
import time
import uuid
from collections.abc import Callable
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any, Protocol

from .context import REDACTED, _SECRET_ASSIGNMENT, _SECRET_PATTERNS
from .registry import ToolRegistry
from .skills import (
    MAX_BODY_CHARS,
    MAX_CATALOG_DESCRIPTION_CHARS,
    MAX_SKILLS,
    SKILL_FILENAME,
    SkillError,
    load_skills,
    parse_skill,
)
from .sqlite_tuning import tune_connection

PROPOSE_SKILL_TOOL = "propose_skill"

#: The same budgets ``tool/gen_skills.dart`` applies to a shipped skill: the
#: description sits in every prompt, so it gets the catalogue cap, not the
#: spec's 1024.
MAX_NAME_CHARS = 64
MAX_PROPOSAL_DESCRIPTION_CHARS = MAX_CATALOG_DESCRIPTION_CHARS
MAX_PROPOSAL_BODY_LINES = 500
MAX_PROPOSAL_BODY_CHARS = MAX_BODY_CHARS

#: One offer per task. A model that proposes five skills after one task is
#: not offering, it is spamming the thread.
MAX_PROPOSALS_PER_RUN = 1

#: The agentskills.io name rule (the Dart parser's ``_kNamePattern``): lower
#: case letters and digits in hyphen-separated segments.
NAME_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")

STATUS_PENDING = "pending"
STATUS_SAVED = "saved"
STATUS_DISMISSED = "dismissed"
#: Decision outcomes that are not a stored status.
STATUS_INVALID = "invalid"
STATUS_NOT_FOUND = "not_found"

# Personal data the draft must not carry. Bounded patterns, no nested
# quantifiers. A phone number needs a leading ``+`` so a version number or a
# date is never taken for one.
_EMAIL_RE = re.compile(r"\b[A-Za-z0-9._%+\-]{1,64}@[A-Za-z0-9\-]{1,63}(?:\.[A-Za-z0-9\-]{1,63}){1,8}\b")
_PHONE_RE = re.compile(r"\+\d{1,3}[ \-/]?\d{2,5}(?:[ \-/]?\d{2,8}){1,4}\b")
EMAIL_MASK = "<email>"
PHONE_MASK = "<phone>"


@dataclass(frozen=True)
class SkillDraft:
    name: str
    description: str
    body: str


# -- shaping ------------------------------------------------------------------


def normalize_draft(name: object, description: object, body: object) -> SkillDraft:
    """Trim what the model or the user sent into the shape a SKILL.md holds.

    The description becomes one line. Its double quotes and backslashes are
    replaced, because it is written as a double-quoted YAML scalar and must
    read back the same in our parser, the app's and any agentskills.io one.
    """
    text_name = name.strip() if isinstance(name, str) else ""
    text_description = " ".join(description.split()) if isinstance(description, str) else ""
    text_description = text_description.replace('"', "'").replace("\\", "/")
    text_body = body.strip() if isinstance(body, str) else ""
    return SkillDraft(name=text_name, description=text_description, body=text_body)


#: A value that only NAMES a secret (``$API_KEY``, ``${TOKEN}``,
#: ``os.environ['KEY']``, ``<TOKEN>``) is how a skill should refer to one; the
#: ``key=value`` rule of :func:`chuk_agents_runtime.context.redact_secrets` would
#: mask it and break the step.
_SECRET_REFERENCE = re.compile(r"^(?:\$|<|\{|os\.environ|os\.getenv|process\.env|getenv|env\[)")


#: ``Authorization: Bearer $TOKEN``: the scheme word is not the secret.
_AUTH_SCHEMES = frozenset({"bearer", "basic", "digest", "token"})


def _redact_credentials(text: str) -> str:
    """:func:`chuk_agents_runtime.context.redact_secrets`, except that a
    reference to a secret by name survives."""
    for pattern, replacement in _SECRET_PATTERNS:
        text = pattern.sub(replacement, text)

    def _assign(match: re.Match[str]) -> str:
        value = match.group(4)
        if _SECRET_REFERENCE.match(value) or value.lower() in _AUTH_SCHEMES:
            return match.group(0)
        return f"{match.group(1)}{match.group(2)}{match.group(3) or ''}{REDACTED}"

    return _SECRET_ASSIGNMENT.sub(_assign, text)


def scrub_text(text: str, vault: Callable[[Any], Any] | None = None) -> str:
    """Remove what a skill must never hold: the user's secret values (the
    ``vault`` filter, the same one tool results pass), credential-shaped
    strings, e-mail addresses and phone numbers."""
    if not text:
        return text
    if vault is not None:
        try:
            cleaned = vault(text)
        except Exception:  # noqa: BLE001 — a broken vault masks nothing, the patterns still run
            cleaned = text
        if isinstance(cleaned, str):
            text = cleaned
    text = _redact_credentials(text)
    text = _EMAIL_RE.sub(EMAIL_MASK, text)
    return _PHONE_RE.sub(PHONE_MASK, text)


def scrub_draft(
    draft: SkillDraft, vault: Callable[[Any], Any] | None = None
) -> tuple[SkillDraft, bool]:
    """The draft with :func:`scrub_text` applied to its description and body,
    plus whether anything was removed. The name is checked by
    :func:`validate_draft` instead: its alphabet cannot hold an address."""
    description = scrub_text(draft.description, vault)
    body = scrub_text(draft.body, vault)
    changed = description != draft.description or body != draft.body
    return replace(draft, description=description, body=body), changed


def render_skill_md(draft: SkillDraft) -> str:
    """The SKILL.md text: frontmatter, then the body. ``metadata`` records
    where the skill came from; the loader skips nested blocks."""
    return (
        "---\n"
        f"name: {draft.name}\n"
        f'description: "{draft.description}"\n'
        "metadata:\n"
        '  version: "1.0"\n'
        '  origin: "agent-proposal"\n'
        "---\n\n"
        f"{draft.body}\n"
    )


def validate_draft(draft: SkillDraft) -> list[str]:
    """Every reason the draft cannot be saved; empty when it can."""
    errors: list[str] = []
    if not draft.name:
        errors.append("name is empty")
    elif len(draft.name) > MAX_NAME_CHARS:
        errors.append(f"name is {len(draft.name)} characters, the limit is {MAX_NAME_CHARS}")
    elif not NAME_RE.match(draft.name):
        errors.append(
            f"invalid name {draft.name!r}: use lower-case letters and digits, "
            "joined by single hyphens (e.g. 'weekly-sales-report')"
        )
    if not draft.description:
        errors.append("description is empty")
    elif len(draft.description) > MAX_PROPOSAL_DESCRIPTION_CHARS:
        errors.append(
            f"description is {len(draft.description)} characters, the limit is "
            f"{MAX_PROPOSAL_DESCRIPTION_CHARS}"
        )
    if not draft.body:
        errors.append("body is empty")
    else:
        lines = draft.body.count("\n") + 1
        if lines > MAX_PROPOSAL_BODY_LINES:
            errors.append(f"body is {lines} lines, the limit is {MAX_PROPOSAL_BODY_LINES}")
        if len(draft.body) > MAX_PROPOSAL_BODY_CHARS:
            errors.append(
                f"body is {len(draft.body)} characters, the limit is {MAX_PROPOSAL_BODY_CHARS}"
            )
    if errors:
        return errors
    # The last word goes to the loader itself: what it cannot read back the
    # next task would skip, so it is never written.
    try:
        skill = parse_skill(render_skill_md(draft))
    except SkillError as exc:
        return [str(exc)]
    if skill.name != draft.name or skill.description != draft.description:
        return ["the draft does not read back unchanged; simplify the description"]
    return []


def existing_skill_names(root: str | Path | None) -> set[str]:
    """Every skill name the workspace already uses: loaded, switched off, or
    only a directory (a half-written skill still owns its name)."""
    if root is None:
        return set()
    base = Path(root)
    names: set[str] = set()
    if base.is_dir():
        names.update(entry.name for entry in base.iterdir() if entry.is_dir())
    library = load_skills(base)
    names.update(library.skills)
    names.update(library.disabled)
    return names


def new_proposal_id() -> str:
    return "sp_" + uuid.uuid4().hex[:16]


# -- the store ----------------------------------------------------------------


class SkillProposalStore:
    """The drafts waiting for the user, and what the user decided.

    One table in the executor's state database. A draft outlives the run and
    the socket: the user may answer the card hours later, from another device,
    after a host restart. Connections are opened per call, like
    :class:`chuk_agents_runtime.skills.SkillSettingsStore`.
    """

    def __init__(self, db_path: str | Path) -> None:
        self._path = str(db_path)
        with self._connect() as conn:
            conn.execute(
                "CREATE TABLE IF NOT EXISTS skill_proposals ("
                " proposal_id TEXT PRIMARY KEY,"
                " session_key TEXT NOT NULL,"
                " run_id TEXT NOT NULL DEFAULT '',"
                " skills_root TEXT NOT NULL,"
                " name TEXT NOT NULL,"
                " description TEXT NOT NULL,"
                " body TEXT NOT NULL,"
                " status TEXT NOT NULL DEFAULT 'pending',"
                " event_mid INTEGER,"
                " created_at REAL NOT NULL,"
                " decided_at REAL)"
            )

    def _connect(self) -> sqlite3.Connection:
        conn = tune_connection(sqlite3.connect(self._path, timeout=5.0))
        conn.execute("PRAGMA busy_timeout=5000;")
        conn.row_factory = sqlite3.Row
        return conn

    def add(
        self,
        draft: SkillDraft,
        *,
        session_key: str,
        skills_root: str,
        run_id: str = "",
        proposal_id: str | None = None,
    ) -> str:
        pid = proposal_id or new_proposal_id()
        with self._connect() as conn:
            conn.execute(
                "INSERT INTO skill_proposals (proposal_id, session_key, run_id,"
                " skills_root, name, description, body, status, created_at)"
                " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (
                    pid,
                    session_key,
                    run_id,
                    skills_root,
                    draft.name,
                    draft.description,
                    draft.body,
                    STATUS_PENDING,
                    time.time(),
                ),
            )
        return pid

    def get(self, proposal_id: str) -> dict | None:
        with self._connect() as conn:
            row = conn.execute(
                "SELECT * FROM skill_proposals WHERE proposal_id = ?", (proposal_id,)
            ).fetchone()
        return dict(row) if row is not None else None

    def set_event_mid(self, proposal_id: str, mid: int | None) -> None:
        if mid is None:
            return
        with self._connect() as conn:
            conn.execute(
                "UPDATE skill_proposals SET event_mid = ? WHERE proposal_id = ?",
                (mid, proposal_id),
            )

    def decide(
        self, proposal_id: str, status: str, draft: SkillDraft | None = None
    ) -> bool:
        """Close a pending draft. ``draft`` is what was saved, edits included.
        False when the draft was not pending (already decided, or unknown)."""
        with self._connect() as conn:
            if draft is None:
                cur = conn.execute(
                    "UPDATE skill_proposals SET status = ?, decided_at = ?"
                    " WHERE proposal_id = ? AND status = ?",
                    (status, time.time(), proposal_id, STATUS_PENDING),
                )
            else:
                cur = conn.execute(
                    "UPDATE skill_proposals SET status = ?, decided_at = ?,"
                    " name = ?, description = ?, body = ?"
                    " WHERE proposal_id = ? AND status = ?",
                    (
                        status,
                        time.time(),
                        draft.name,
                        draft.description,
                        draft.body,
                        proposal_id,
                        STATUS_PENDING,
                    ),
                )
            return cur.rowcount == 1

    def close(self) -> None:  # symmetry with the other stores; nothing is held
        return None


# -- the decision -------------------------------------------------------------


def _result(proposal_id: str, status: str, **fields: Any) -> dict:
    return {"proposal_id": proposal_id, "status": status, "errors": [], **fields}


def write_skill(root: str | Path, draft: SkillDraft) -> Path:
    """Write ``<root>/<name>/SKILL.md`` atomically (a temp file, then a
    rename), so a task that starts mid-write reads the old state or the new
    one, never half a file."""
    directory = Path(root) / draft.name
    directory.mkdir(parents=True, exist_ok=True)
    target = directory / SKILL_FILENAME
    temp = directory / f".{SKILL_FILENAME}.{uuid.uuid4().hex[:8]}.tmp"
    temp.write_text(render_skill_md(draft), encoding="utf-8")
    os.replace(temp, target)
    return target


def decide_skill_proposal(
    store: SkillProposalStore,
    *,
    proposal_id: object,
    accept: object,
    name: object = None,
    description: object = None,
    body: object = None,
    vault: Callable[[Any], Any] | None = None,
) -> dict:
    """Apply the app's ``skill_proposal_decision``; the body of the reply.

    ``status`` is ``saved`` / ``dismissed`` (now or earlier — then
    ``already_decided`` is true), ``invalid`` (the accept was refused; the
    draft stays pending so the user can fix it) or ``not_found``.
    """
    pid = proposal_id.strip() if isinstance(proposal_id, str) else ""
    row = store.get(pid) if pid else None
    if row is None:
        return _result(pid, STATUS_NOT_FOUND, errors=[f"no skill proposal {pid!r}"])
    if row["status"] != STATUS_PENDING:
        return _result(pid, row["status"], name=row["name"], already_decided=True)
    if accept is not True:
        store.decide(pid, STATUS_DISMISSED)
        return _result(pid, STATUS_DISMISSED, name=row["name"])

    # The user's edits replace the draft field by field; an absent field keeps
    # the draft. Edits are scrubbed like the draft was: whatever is saved here
    # is read by the model on every future task that loads the skill.
    draft = normalize_draft(
        name if isinstance(name, str) else row["name"],
        description if isinstance(description, str) else row["description"],
        body if isinstance(body, str) else row["body"],
    )
    draft, scrubbed = scrub_draft(draft, vault)
    errors = validate_draft(draft)
    root = row["skills_root"]
    if not errors:
        taken = existing_skill_names(root)
        if draft.name in taken:
            errors.append(f"a skill named {draft.name!r} already exists; pick another name")
        elif len(taken) >= MAX_SKILLS:
            errors.append(
                f"the workspace already holds {MAX_SKILLS} skills; delete one first"
            )
    if errors:
        return _result(pid, STATUS_INVALID, name=draft.name, errors=errors, scrubbed=scrubbed)
    try:
        path = write_skill(root, draft)
        parse_skill(path.read_text(encoding="utf-8"), path=str(path))
    except (OSError, SkillError) as exc:
        return _result(
            pid, STATUS_INVALID, name=draft.name, errors=[f"could not write the skill: {exc}"]
        )
    if not store.decide(pid, STATUS_SAVED, draft):
        # Another device answered in between. The file is written; report the
        # outcome the store holds.
        current = store.get(pid) or {}
        return _result(pid, current.get("status", STATUS_SAVED), name=draft.name, already_decided=True)
    return _result(pid, STATUS_SAVED, name=draft.name, path=str(path), scrubbed=scrubbed)


# -- the tool -----------------------------------------------------------------


class SkillProposalSink(Protocol):
    """What the tool needs from the host, bound to ONE run.

    ``submit`` stores the (already scrubbed and validated) draft together with
    the skills directory an accept writes to, shows the card to the user and
    answers ``{"ok": True, "proposal_id": ...}``.
    """

    def submit(self, draft: SkillDraft, *, skills_root: str) -> dict: ...


PROPOSE_SKILL_SCHEMA = {
    "type": "object",
    "description": (
        "Offer the user to save the procedure you just finished as a reusable "
        "skill. Use it only after a long multi-step task that worked and is "
        "likely to come back, or when the user says 'remember how to do this'. "
        "The user sees a card with your draft and decides; nothing is saved "
        "without them. Write the steps that worked, in order, with the commands "
        "or tool calls that did the job. Generalize: no secrets, no personal "
        "data, no one-off values (paths, ids, dates, names of this one case); "
        "use placeholders like <URL> instead. Do not write files under "
        "`skills/` yourself."
    ),
    "properties": {
        "name": {
            "type": "string",
            "description": (
                "Short skill name: lower-case words joined by hyphens, at most "
                "64 characters, e.g. 'monthly-invoice-export'."
            ),
        },
        "description": {
            "type": "string",
            "description": (
                "One or two sentences, at most 300 characters: what the skill "
                "does and when to load it. It is all a future task sees before "
                "loading the skill."
            ),
        },
        "body": {
            "type": "string",
            "description": (
                "The instructions in Markdown: a title, the goal, then the "
                "numbered steps that worked, with the exact commands or code, "
                "and the checks that prove the result."
            ),
        },
    },
    "required": ["name", "description", "body"],
}


def make_propose_skill_handler(
    sink: SkillProposalSink,
    *,
    skills_root: str | Path | None,
    registry: ToolRegistry | None = None,
):
    """The ``propose_skill`` handler. It reads ``registry.result_filter`` (the
    user's secret values) at call time, so a secret set mid-run is masked too."""
    submitted: list[str] = []

    def propose_skill(name: str, description: str, body: str) -> dict:
        if len(submitted) >= MAX_PROPOSALS_PER_RUN:
            return {
                "ok": False,
                "error": "you already offered a skill in this task; one offer per task",
            }
        vault = registry.result_filter if registry is not None else None
        draft, scrubbed = scrub_draft(normalize_draft(name, description, body), vault)
        errors = validate_draft(draft)
        if not errors and draft.name in existing_skill_names(skills_root):
            errors.append(f"a skill named {draft.name!r} already exists; pick another name")
        if errors:
            return {"ok": False, "error": "; ".join(errors)}
        try:
            reply = sink.submit(draft, skills_root=str(skills_root))
        except Exception as exc:  # noqa: BLE001 — the run goes on without the card
            return {"ok": False, "error": f"the proposal could not be stored: {type(exc).__name__}"}
        if not reply.get("ok"):
            return {"ok": False, "error": str(reply.get("error") or "the proposal was refused")}
        submitted.append(str(reply.get("proposal_id", "")))
        result = {
            "ok": True,
            "proposal_id": reply.get("proposal_id"),
            "name": draft.name,
            "status": "waiting_for_user",
            "note": (
                "The user sees a card with the draft and decides whether to save "
                "it. Do not write the skill yourself and do not wait for the "
                "answer; finish your reply."
            ),
        }
        if scrubbed:
            result["scrubbed"] = (
                "Secrets or personal data were removed from the draft before "
                "the user saw it."
            )
        return result

    return propose_skill


def register_propose_skill_tool(
    registry: ToolRegistry,
    sink: SkillProposalSink | None,
    *,
    skills_root: str | Path | None,
) -> None:
    """Register ``propose_skill``. ``None`` (no host, no app to ask) or no
    skills directory registers nothing. Deferred behind ``search_tools``: the
    prompt names it, and it is used at most once per long task."""
    if sink is None or skills_root is None:
        return
    registry.register(
        PROPOSE_SKILL_TOOL,
        PROPOSE_SKILL_SCHEMA,
        make_propose_skill_handler(sink, skills_root=skills_root, registry=registry),
        deferrable=True,
    )


class RecordingProposalSink:
    """An in-memory sink for tests: records the drafts it was handed."""

    def __init__(self, *, ok: bool = True) -> None:
        self.ok = ok
        self.drafts: list[SkillDraft] = []
        self.roots: list[str] = []

    def submit(self, draft: SkillDraft, *, skills_root: str) -> dict:
        if not self.ok:
            return {"ok": False, "error": "refused"}
        self.drafts.append(draft)
        self.roots.append(skills_root)
        return {"ok": True, "proposal_id": f"sp_{len(self.drafts)}"}
