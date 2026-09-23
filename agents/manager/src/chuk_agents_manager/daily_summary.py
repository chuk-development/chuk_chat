"""Daily summary journal (§13 daily-summary).

A scheduled end-of-day job that writes a dated markdown summary of the agent's
day into ``journal/YYYY-MM-DD.md`` in its workspace. It complements the static
``soul.md`` / ``agents.md`` and the Mem0 memory: those hold persona and long-term
recall, this is an automatic diary of *what actually happened* each day.

The job is a ``no_agent``-style scheduled action (a plain callable, zero model
tokens) — see :func:`daily_summary_script` and
:func:`chuk_agents_manager.autonomy.register_daily_summary`. It reads only what is
already on disk or handed in:

- **the action journal** — the append-only ``.agents/journal*.jsonl`` files the
  ``GitWorkspace`` writes (one per agent/subagent). Every tool call is a row:
  ``{seq, ts, tool, args, result, ok, changed_files, ...}``. This is the record
  of actions, so it drives tasks-done, files-touched and errors directly.
- **an optional message log** — a sequence of ``{role, content, created_at}``
  mappings (the state store's ``messages`` rows). Injected, so tests pass a stub
  and the manager wires the real query without this module importing the agent.

The prose ``## Summary`` is the only part that can use a model: if an injected
:class:`ModelClient` is available the digest is summarised cheaply, otherwise a
deterministic recap is used. Every other section is built from facts, so the job
**never fails** for lack of a model. Writing is idempotent: the day's file is
overwritten, never appended to, so a re-run for the same day yields one file.
"""

from __future__ import annotations

import json
from collections import Counter
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Protocol, runtime_checkable
from zoneinfo import ZoneInfo

#: Where the dated summaries live, relative to the workspace root.
JOURNAL_SUBDIR = "journal"

#: Journal files the ``GitWorkspace`` writes: ``journal.jsonl`` (parent) and
#: ``journal-<subagent>.jsonl`` (each subagent). One glob catches them all.
_JOURNAL_GLOB = "journal*.jsonl"
_JOURNAL_DIR = ".agents"

#: Caps so the digest handed to a model — and the file — stay bounded.
MAX_HEADLINES = 40
MAX_FILES = 60
MAX_ERRORS = 25
MAX_MESSAGE_HEADLINES = 20

_NONE = "_(none recorded)_"


# --------------------------------------------------------------------------
# Model seam (structural — no import of chuk_agents_runtime)
# --------------------------------------------------------------------------


@runtime_checkable
class ModelClient(Protocol):
    """Structural match for ``chuk_agents_runtime.model.ModelClient``.

    The one method the summary needs. The manager never imports the agent
    package; any object with a ``complete(messages)`` that returns something
    carrying ``.text`` (or a plain string) works, so tests inject a stub.
    """

    def complete(self, messages: list[dict]) -> Any: ...


def _response_text(result: Any) -> str:
    """Pull the assistant text out of a model result, tolerating shapes.

    Accepts a ``ModelResponse``-like object (``.text``) or a bare string. Any
    other shape yields an empty string, which sends the caller to the
    deterministic recap rather than raising.
    """
    if result is None:
        return ""
    if isinstance(result, str):
        return result.strip()
    text = getattr(result, "text", None)
    if isinstance(text, str):
        return text.strip()
    return ""


# --------------------------------------------------------------------------
# Activity gathering
# --------------------------------------------------------------------------


@dataclass
class DailyActivity:
    """Everything the markdown is built from for one local day.

    All counts and lists are facts read off the journal / message log; nothing
    here is model-generated. ``headlines`` are one-line action descriptions in
    journal order; ``files`` and ``errors`` are de-duplicated and capped.
    """

    day: date
    tz: str
    total_actions: int = 0
    ok_actions: int = 0
    error_actions: int = 0
    tools: Counter[str] = field(default_factory=Counter)
    files: list[str] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)
    headlines: list[str] = field(default_factory=list)
    message_turns: int = 0
    role_counts: Counter[str] = field(default_factory=Counter)
    message_headlines: list[str] = field(default_factory=list)
    sources: list[str] = field(default_factory=list)

    @property
    def is_empty(self) -> bool:
        return self.total_actions == 0 and self.message_turns == 0


def _as_zone(tz: str | ZoneInfo) -> ZoneInfo:
    return tz if isinstance(tz, ZoneInfo) else ZoneInfo(str(tz))


def _local_date(ts: Any, zone: ZoneInfo) -> date | None:
    """Local date of a journal/message timestamp, or ``None`` if unparseable.

    Accepts an ISO string (the journal's ``ts``) or an epoch number (the state
    store's ``created_at``). A naive value is assumed UTC.
    """
    dt: datetime | None = None
    if isinstance(ts, bool):
        return None
    if isinstance(ts, (int, float)):
        dt = datetime.fromtimestamp(float(ts), tz=timezone.utc)
    elif isinstance(ts, str):
        try:
            dt = datetime.fromisoformat(ts)
        except ValueError:
            return None
    if dt is None:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(zone).date()


def _headline(entry: Mapping[str, Any]) -> str:
    """A one-line description of one journal action, mirroring the commit
    subject style: ``tool: hint`` with a short result tail."""
    tool = str(entry.get("tool", "?")).strip() or "?"
    args = entry.get("args") or {}
    hint = ""
    if isinstance(args, Mapping):
        for key in ("path", "command", "url", "query", "name"):
            value = args.get(key)
            if isinstance(value, str) and value.strip():
                hint = ": " + _cap(value.strip().splitlines()[0], 60)
                break
    result = entry.get("result")
    tail = ""
    if isinstance(result, str) and result.strip():
        tail = " — " + _cap(result.strip().splitlines()[0], 80)
    return f"{tool}{hint}{tail}"


def _cap(text: str, limit: int) -> str:
    text = text.strip()
    if len(text) <= limit:
        return text
    return text[: max(0, limit - 1)].rstrip() + "…"


def _iter_journal_entries(workspace: Path) -> list[Mapping[str, Any]]:
    """Read every ``.agents/journal*.jsonl`` row, tolerating bad lines.

    A corrupt or partial line (a killed process can leave one) is skipped, not
    raised — one bad row must not lose the whole day.
    """
    root = workspace / _JOURNAL_DIR
    if not root.is_dir():
        return []
    entries: list[Mapping[str, Any]] = []
    for path in sorted(root.glob(_JOURNAL_GLOB)):
        try:
            text = path.read_text(encoding="utf-8")
        except OSError:
            continue
        for line in text.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            if isinstance(obj, Mapping):
                obj = dict(obj)
                obj["__source"] = path.name
                entries.append(obj)
    return entries


def _message_text(content: Any) -> str:
    """Best-effort one-line text of a message ``content`` (str or dict)."""
    if isinstance(content, str):
        return content.strip()
    if isinstance(content, Mapping):
        for key in ("text", "content", "message", "prompt"):
            value = content.get(key)
            if isinstance(value, str) and value.strip():
                return value.strip()
    return ""


def gather_activity(
    *,
    day: date,
    tz: str | ZoneInfo = "UTC",
    workspace: str | Path | None = None,
    journal_entries: Sequence[Mapping[str, Any]] | None = None,
    messages: Sequence[Mapping[str, Any]] | None = None,
) -> DailyActivity:
    """Aggregate one local day's activity from the journal and message log.

    ``journal_entries`` overrides on-disk reading (used by tests); otherwise the
    ``.agents/journal*.jsonl`` files under ``workspace`` are read. ``messages``
    is an optional injected sequence of ``{role, content, created_at}`` mappings.
    Only rows whose timestamp falls on ``day`` in ``tz`` are counted.
    """
    zone = _as_zone(tz)
    activity = DailyActivity(day=day, tz=str(getattr(zone, "key", zone)))

    entries = (
        list(journal_entries)
        if journal_entries is not None
        else _iter_journal_entries(Path(workspace))
        if workspace is not None
        else []
    )

    seen_files: set[str] = set()
    seen_sources: set[str] = set()
    for entry in entries:
        if _local_date(entry.get("ts"), zone) != day:
            continue
        activity.total_actions += 1
        tool = str(entry.get("tool", "?")).strip() or "?"
        activity.tools[tool] += 1
        ok = entry.get("ok", True)
        if ok:
            activity.ok_actions += 1
        else:
            activity.error_actions += 1
            if len(activity.errors) < MAX_ERRORS:
                activity.errors.append(_headline(entry))
        if len(activity.headlines) < MAX_HEADLINES:
            activity.headlines.append(_headline(entry))
        changed = entry.get("changed_files") or []
        if isinstance(changed, Sequence) and not isinstance(changed, (str, bytes)):
            for path in changed:
                if isinstance(path, str) and path not in seen_files:
                    seen_files.add(path)
                    if len(activity.files) < MAX_FILES:
                        activity.files.append(path)
        source = entry.get("__source")
        if isinstance(source, str) and source not in seen_sources:
            seen_sources.add(source)
            activity.sources.append(source)

    if messages:
        for msg in messages:
            ts = msg.get("created_at", msg.get("ts"))
            if _local_date(ts, zone) != day:
                continue
            activity.message_turns += 1
            role = str(msg.get("role", "?")).strip() or "?"
            activity.role_counts[role] += 1
            if role in ("user", "human") and len(
                activity.message_headlines
            ) < MAX_MESSAGE_HEADLINES:
                text = _message_text(msg.get("content"))
                if text:
                    activity.message_headlines.append(_cap(text, 100))

    return activity


# --------------------------------------------------------------------------
# Rendering
# --------------------------------------------------------------------------


_SUMMARY_SYSTEM = (
    "You write a terse end-of-day work log for one AI agent. "
    "Given a digest of the day's tool actions and conversation, write two to "
    "five short sentences covering what was worked on and any decisions made. "
    "Plain prose, no headings, no lists, no preamble. If nothing of note "
    "happened, say so in one sentence."
)


def _digest_for_model(activity: DailyActivity) -> str:
    """The compact, fact-only text handed to the model to summarise."""
    lines: list[str] = [
        f"Date: {activity.day.isoformat()} ({activity.tz})",
        (
            f"Actions: {activity.total_actions} "
            f"({activity.ok_actions} ok, {activity.error_actions} error)"
        ),
    ]
    if activity.tools:
        tools = ", ".join(
            f"{name} x{count}" for name, count in activity.tools.most_common()
        )
        lines.append(f"Tools: {tools}")
    if activity.headlines:
        lines.append("Actions log:")
        lines.extend(f"- {h}" for h in activity.headlines)
    if activity.message_headlines:
        lines.append("User messages:")
        lines.extend(f"- {h}" for h in activity.message_headlines)
    if activity.files:
        lines.append("Files touched: " + ", ".join(activity.files))
    if activity.errors:
        lines.append("Errors:")
        lines.extend(f"- {e}" for e in activity.errors)
    return "\n".join(lines)


def _summary_prose(activity: DailyActivity, model: ModelClient | None) -> str:
    """The ``## Summary`` body: model prose if available, else a deterministic
    recap. Any model failure falls back rather than propagating — the job must
    not fail because a model call did."""
    if model is not None and not activity.is_empty:
        try:
            result = model.complete(
                [
                    {"role": "system", "content": _SUMMARY_SYSTEM},
                    {"role": "user", "content": _digest_for_model(activity)},
                ]
            )
            text = _response_text(result)
            if text:
                return text
        except Exception:  # noqa: BLE001 — never let a model fault fail the job
            pass
    return _deterministic_recap(activity)


def _deterministic_recap(activity: DailyActivity) -> str:
    if activity.is_empty:
        return "No recorded activity for this day."
    parts: list[str] = []
    if activity.total_actions:
        top = ", ".join(
            f"{name} ({count})" for name, count in activity.tools.most_common(5)
        )
        parts.append(
            f"Ran {activity.total_actions} tool "
            f"action{'s' if activity.total_actions != 1 else ''} "
            f"({activity.ok_actions} ok, {activity.error_actions} error). "
            f"Most used: {top}."
        )
    if activity.message_turns:
        parts.append(
            f"Exchanged {activity.message_turns} "
            f"message{'s' if activity.message_turns != 1 else ''}."
        )
    if activity.files:
        parts.append(f"Touched {len(activity.files)} file(s).")
    return " ".join(parts)


def _bullets(items: Sequence[str]) -> str:
    if not items:
        return _NONE
    return "\n".join(f"- {item}" for item in items)


def _next_steps(activity: DailyActivity) -> str:
    """Deterministic, fact-derived next steps — no model, so it never invents
    work. Failed actions are the one thing that reliably implies follow-up."""
    if activity.error_actions:
        return (
            f"- Investigate {activity.error_actions} failed "
            f"action{'s' if activity.error_actions != 1 else ''} "
            "(see Errors)."
        )
    return _NONE


def render_markdown(
    activity: DailyActivity,
    *,
    generated_at: datetime,
    model: ModelClient | None = None,
) -> str:
    """Render the full dated summary. Facts (Overview, Tasks done, Files,
    Errors) are deterministic; only ``## Summary`` may use the model."""
    tools_line = (
        ", ".join(
            f"{name} ({count})" for name, count in activity.tools.most_common()
        )
        or "none"
    )
    overview = [
        f"- Actions recorded: {activity.total_actions} "
        f"({activity.ok_actions} ok, {activity.error_actions} error)",
        f"- Tools used: {tools_line}",
        f"- Files touched: {len(activity.files)}",
    ]
    if activity.message_turns:
        roles = ", ".join(
            f"{name} {count}" for name, count in activity.role_counts.most_common()
        )
        overview.append(
            f"- Conversation turns: {activity.message_turns} ({roles})"
        )

    doc = [
        f"# Daily summary — {activity.day.isoformat()}",
        "",
        f"_Generated {generated_at.isoformat(timespec='seconds')} "
        f"· timezone {activity.tz}_",
        "",
        "## Overview",
        "\n".join(overview),
        "",
        "## Summary",
        _summary_prose(activity, model),
        "",
        "## Tasks done",
        _bullets(activity.headlines),
        "",
        "## Decisions",
        _NONE,
        "",
        "## Files touched",
        _bullets(activity.files),
        "",
        "## Errors",
        _bullets(activity.errors),
        "",
        "## Next steps",
        _next_steps(activity),
        "",
    ]
    return "\n".join(doc)


# --------------------------------------------------------------------------
# Writing (idempotent)
# --------------------------------------------------------------------------


def summary_path(workspace: str | Path, day: date) -> Path:
    """The file a given day's summary is written to."""
    return Path(workspace) / JOURNAL_SUBDIR / f"{day.isoformat()}.md"


def write_daily_summary(
    workspace: str | Path,
    *,
    day: date | None = None,
    tz: str | ZoneInfo = "UTC",
    model: ModelClient | None = None,
    messages: Sequence[Mapping[str, Any]] | None = None,
    journal_entries: Sequence[Mapping[str, Any]] | None = None,
    now: Callable[[], datetime] | None = None,
) -> Path:
    """Write ``journal/<day>.md`` for one local day and return its path.

    ``day`` defaults to the run's local date (``now`` in ``tz``). The write is
    idempotent: the file is fully overwritten, so re-running for the same day
    replaces that day's summary and never appends a duplicate.
    """
    zone = _as_zone(tz)
    clock = now or (lambda: datetime.now(timezone.utc))
    generated_at = clock()
    if day is None:
        day = generated_at.astimezone(zone).date()

    activity = gather_activity(
        day=day,
        tz=zone,
        workspace=workspace,
        journal_entries=journal_entries,
        messages=messages,
    )
    content = render_markdown(activity, generated_at=generated_at, model=model)

    path = summary_path(workspace, day)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    return path


# --------------------------------------------------------------------------
# no_agent job glue
# --------------------------------------------------------------------------


def _default_target_day(now: datetime, zone: ZoneInfo) -> date:
    """The day a fire at ``now`` summarises.

    A midnight (``00:00``) fire closes the day that just ended, so the target is
    the local date one minute before the fire. Any other fire time maps to its
    own local date. This makes ``0 0 * * *`` an end-of-day job while a manual
    mid-day run still summarises today.
    """
    return (now.astimezone(zone) - timedelta(minutes=1)).date()


def daily_summary_script(
    workspace: str | Path,
    *,
    tz: str | ZoneInfo = "UTC",
    model: ModelClient | None = None,
    messages_provider: Callable[[date], Sequence[Mapping[str, Any]]] | None = None,
    day_for: Callable[[datetime], date] | None = None,
    now: Callable[[], datetime] | None = None,
) -> Callable[[], Path]:
    """Build the zero-arg callable a ``no_agent`` job fires.

    ``messages_provider`` is called with the target day to fetch that day's
    message rows (the manager wires the state query; tests pass a stub). No
    model means zero tokens. ``day_for`` maps the fire time to the summarised
    day; the default closes the day that just ended at a midnight fire.
    """
    zone = _as_zone(tz)
    clock = now or (lambda: datetime.now(timezone.utc))
    pick_day = day_for or (lambda fired: _default_target_day(fired, zone))

    def script() -> Path:
        fired = clock()
        day = pick_day(fired)
        messages = messages_provider(day) if messages_provider is not None else None
        return write_daily_summary(
            workspace,
            day=day,
            tz=zone,
            model=model,
            messages=messages,
            now=lambda: fired,
        )

    return script
