"""The agent's long-term search: ``<workspace>/transcript/`` (user order
2026-09-05, bead cowork-2tq.2).

The model's context is compacted (§7.3); the message store is not. This module
writes the store out as Markdown the AGENT can read back with its own tools —
``grep`` through ``run_command``, ``read_file`` — so after a compaction it can
still find exactly what happened: every prompt, answer, tool call and result,
in order, with timestamps.

One file per thread (``<session key>.md``), appended after every finished tool
call and every finished turn by the executor (:meth:`Executor._export_transcript`),
never rewritten: a cursor file (``.cursor.json``) remembers the last message id
exported per thread, so an export is one read of the rows after it. Tool results
are clipped (the model saw the full result; the transcript is for finding, not
for replaying megabytes).

Read-only, as far as a same-user process can be made to respect it: after every
write the file is ``chmod 0444`` and the directory ``0555``, so an ordinary
``rm``/``>`` in ``run_command`` is refused (a ``chmod`` first would get through
— the system prompt says the folder is not to be touched, and the Docker
sandbox can additionally bind-mount it read-only). ``chattr +i`` would be
stronger but needs root, which the host does not have.

Scrubbing: every rendered chunk passes through ``scrub`` before it is written.
Default is the store's secret redaction (:func:`chuk_agents_runtime.context.redact_secrets`);
the cowork-26 scrubber plugs in here when it exists.
"""

from __future__ import annotations

import json
import logging
import os
import re
import stat
from collections.abc import Callable
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from .context import redact_secrets
from .state import StateStore

logger = logging.getLogger(__name__)

DIRNAME = "transcript"
CURSOR_FILE = ".cursor.json"

#: Clip for one tool result / argument blob in the transcript.
RESULT_CHARS = 2_000
#: Clip for one prompt / answer.
TEXT_CHARS = 20_000
#: Clip for a runtime row (recall, skill body) — one line is enough to find it.
CONTEXT_CHARS = 500

_SLUG_RE = re.compile(r"[^A-Za-z0-9._-]+")


def thread_filename(session_key: str) -> str:
    """``<slug>.md`` for a session key; a key that is not a safe file name is
    slugged, an empty one becomes ``default``."""
    slug = _SLUG_RE.sub("-", (session_key or "").strip()).strip("-.")
    return f"{slug or 'default'}.md"


def _stamp(created_at: float) -> str:
    try:
        return datetime.fromtimestamp(float(created_at), UTC).strftime("%Y-%m-%d %H:%M:%S UTC")
    except (TypeError, ValueError, OSError, OverflowError):
        return "?"


def _text(content: Any) -> str:
    if content is None:
        return ""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for part in content:
            if isinstance(part, str):
                parts.append(part)
            elif isinstance(part, dict):
                parts.append(str(part.get("text", "")))
        return "".join(parts)
    try:
        return json.dumps(content, ensure_ascii=False, separators=(",", ":"))
    except (TypeError, ValueError):
        return str(content)


def _clip(text: str, limit: int) -> str:
    text = text.rstrip()
    if len(text) <= limit:
        return text
    return text[: limit - 1] + "…" + f"\n_[clipped: {len(text)} characters]_"


def _fence(text: str) -> str:
    """A code fence that cannot be closed by its own content."""
    ticks = "```"
    while ticks in text:
        ticks += "`"
    return f"{ticks}\n{text}\n{ticks}"


def render_row(role: str, content: dict, created_at: float) -> str:
    """One stored row as Markdown, or ``''`` for a row the transcript skips
    (the frozen system prompt)."""
    when = _stamp(created_at)
    wire_role = content.get("role")
    if role == "system":
        return ""
    if role == "user":
        body = _clip(_text(content.get("content")), TEXT_CHARS)
        return f"## {when} · user\n\n{body}\n"
    if role == "assistant":
        lines = [f"## {when} · assistant\n"]
        reasoning = content.get("reasoning")
        if isinstance(reasoning, str) and reasoning.strip():
            lines.append("_thinking:_ " + _clip(" ".join(reasoning.split()), 1_000) + "\n")
        text = _text(content.get("content")).strip()
        if text:
            lines.append(_clip(text, TEXT_CHARS) + "\n")
        for call in content.get("tool_calls") or []:
            if not isinstance(call, dict):
                continue
            fn = call.get("function") or {}
            args = fn.get("arguments")
            args_text = args if isinstance(args, str) else _text(args)
            lines.append(
                f"- **call** `{fn.get('name', '?')}` ({call.get('id', '')})\n"
                + _fence(_clip(args_text, RESULT_CHARS))
            )
        return "\n".join(lines) + "\n"
    if role == "tool" or wire_role == "tool":
        name = content.get("name") or "tool"
        result = _clip(_text(content.get("content")), RESULT_CHARS)
        return f"- **result** `{name}` ({content.get('tool_call_id', '')})\n{_fence(result)}\n"
    if role == "event":
        kind = content.get("type", "event")
        slim = {k: v for k, v in content.items() if k not in ("data", "replay", "mid")}
        return f"- **{kind}** {_clip(_text(slim), CONTEXT_CHARS)}\n"
    # context / memory / any runtime row: one line, so it can be found but does
    # not read as a turn.
    body = " ".join(_text(content.get("content")).split())
    return f"- _[{role}]_ {_clip(body, CONTEXT_CHARS)}\n"


class TranscriptExporter:
    """Appends a thread's new rows to ``<workspace>/transcript/<thread>.md``."""

    def __init__(
        self,
        workspace: str | Path,
        *,
        scrub: Callable[[str], str] | None = None,
        dirname: str = DIRNAME,
    ) -> None:
        self._dir = Path(workspace).expanduser() / dirname
        self._scrub = scrub or redact_secrets
        self._cursor_path = self._dir / CURSOR_FILE

    @property
    def directory(self) -> Path:
        return self._dir

    def path_for(self, session_key: str) -> Path:
        return self._dir / thread_filename(session_key)

    # -- cursor -----------------------------------------------------------

    def _read_cursors(self) -> dict[str, int]:
        try:
            data = json.loads(self._cursor_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return {}
        if not isinstance(data, dict):
            return {}
        out: dict[str, int] = {}
        for key, value in data.items():
            try:
                out[str(key)] = int(value)
            except (TypeError, ValueError):
                continue
        return out

    def cursor(self, session_key: str) -> int:
        return self._read_cursors().get(session_key, 0)

    def _write_cursors(self, cursors: dict[str, int]) -> None:
        self._cursor_path.write_text(
            json.dumps(cursors, indent=0, sort_keys=True), encoding="utf-8"
        )

    # -- read-only handling -------------------------------------------------

    def _unlock(self, *paths: Path) -> None:
        for path in (self._dir, *paths):
            try:
                if path.is_dir():
                    path.chmod(0o755)
                elif path.exists():
                    path.chmod(0o644)
            except OSError:
                pass

    def _lock(self, *paths: Path) -> None:
        for path in paths:
            try:
                if path.exists():
                    path.chmod(stat.S_IRUSR | stat.S_IRGRP | stat.S_IROTH)
            except OSError:
                pass
        try:
            self._dir.chmod(0o555)
        except OSError:
            pass

    # -- export -------------------------------------------------------------

    def export(self, store: StateStore, session_key: str) -> int:
        """Append every row after the thread's cursor. Returns how many rows
        were written. Raises nothing the caller must handle beyond OSError."""
        session_id = store.route(session_key)
        cursors = self._read_cursors()
        after = cursors.get(session_key, 0)
        rows = [
            m
            for m in store.get_conversation(session_id, include_events=True)
            if m.id > after
        ]
        if not rows:
            return 0
        chunks: list[str] = []
        for row in rows:
            rendered = render_row(row.role, row.content, row.created_at)
            if rendered:
                chunks.append(self._scrub(rendered))
        target = self.path_for(session_key)
        self._dir.mkdir(parents=True, exist_ok=True)
        self._unlock(target, self._cursor_path)
        try:
            new_file = not target.exists()
            with target.open("a", encoding="utf-8") as handle:
                if new_file:
                    handle.write(
                        f"# Transcript · thread `{session_key}`\n\n"
                        "Read-only. The host appends every prompt, answer, tool "
                        "call and result of this thread here, in order. Search it "
                        "with `grep`; open it with `read_file`.\n\n"
                    )
                if chunks:
                    handle.write("\n".join(chunks))
                    if not chunks[-1].endswith("\n"):
                        handle.write("\n")
            cursors[session_key] = rows[-1].id
            self._write_cursors(cursors)
        finally:
            self._lock(target, self._cursor_path)
        return len(rows)

    def is_locked(self, session_key: str) -> bool:
        """Whether the thread file is currently read-only (tests)."""
        try:
            mode = self.path_for(session_key).stat().st_mode
        except OSError:
            return False
        return not (mode & (stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH)) and not os.access(
            self.path_for(session_key), os.W_OK
        )
